// MatrixT.swift
//
// Temporal causality matrix T per cookbook § 6.4.
//
// T is a sparse 3D array indexed by
//   (source_field_value, target_field_value, lag_bucket)
// where source_field_value and target_field_value are compound
// (field, value) pairs, and lag_bucket is an index in 0..8
// corresponding to the log-spaced minute thresholds
// {1, 2, 4, 8, 16, 32, 64, 128} per cookbook § 6.4.
//
// Each cell counts the number of times a row with the source
// (field, value) preceded a row with the target (field, value)
// by approximately `lag_bucket` minutes, where "approximately" is
// the half-open interval [2^bucket, 2^(bucket+1)) minutes for
// buckets 0..6 and [128, 256) for bucket 7.
//
// T is asymmetric in its first two index pairs. T[(i,vi),(j,vj),L]
// is NOT the same as T[(j,vj),(i,vi),L]; the former counts (i,vi)
// preceding (j,vj), the latter counts (j,vj) preceding (i,vi).
// This is the substrate's primitive for distinguishing
// co-activation from causation.
//
// Update schedule: T is updated weekly by the dreaming daemon
// per cookbook § 6.4. Update pass iterates pairs of audit-log
// rows (a, b) where 0 < (b.capture_time - a.capture_time) < 256
// minutes, computes lag_bucket = log2_bucket(time_diff_minutes),
// and increments T for every cross-product of (field, value)
// pairs from row a × row b.
//
// Decay: T HAS decay (cookbook § 6.8 table). Half-life: 90 days
// (faster than O because causal patterns drift faster than
// co-occurrence patterns).
//
// Storage estimate: ~10K-50K populated cells × (8 bytes key + 8
// bytes value) per cookbook § 6.4 = 160-800 KB at v0.36.

import Foundation

/// Canonical 5-byte key for a T-matrix cell. Field indices and
/// values fit in 6 bits each (the field-width floor I-15); lag
/// bucket fits in 3 bits (8 buckets, 0..7).
public struct CausalityKey: Hashable, Comparable, Sendable {
    public let sourceField: UInt8
    public let sourceValue: UInt8
    public let targetField: UInt8
    public let targetValue: UInt8
    public let lagBucket: UInt8     // 0..7

    public init(sourceField: UInt8, sourceValue: UInt8,
                targetField: UInt8, targetValue: UInt8,
                lagBucket: UInt8) {
        precondition(sourceField < 64 && targetField < 64,
                     "field index must fit in 6 bits")
        precondition(sourceValue < 64 && targetValue < 64,
                     "field value must fit in 6 bits (I-15)")
        precondition(lagBucket < 8,
                     "lag bucket must be 0..7")
        self.sourceField = sourceField
        self.sourceValue = sourceValue
        self.targetField = targetField
        self.targetValue = targetValue
        self.lagBucket = lagBucket
    }

    /// Pack into a UInt64 for compact storage and ordering.
    /// Layout (high → low):
    ///   sourceField:8 | sourceValue:8 | targetField:8 |
    ///   targetValue:8 | lagBucket:8 | unused:24
    @inlinable
    public var packed: UInt64 {
        return (UInt64(sourceField) << 56)
             | (UInt64(sourceValue) << 48)
             | (UInt64(targetField) << 40)
             | (UInt64(targetValue) << 32)
             | (UInt64(lagBucket)   << 24)
    }

    public static func < (a: CausalityKey, b: CausalityKey) -> Bool {
        return a.packed < b.packed
    }
}

public struct MatrixT: Sendable, Equatable {

    /// The eight lag-bucket boundaries in minutes (lower bound
    /// for each bucket). Bucket k covers [edge[k], edge[k+1]) for
    /// k in 0..6, and bucket 7 covers [128, 256).
    public static let bucketEdgesMinutes: [Int] = [1, 2, 4, 8, 16, 32, 64, 128]

    /// Maximum time difference (exclusive) for any T update.
    /// Cookbook § 6.4: "row_b.capture_time - row_a.capture_time
    /// < 256 min."
    public static let maxLagMinutes: Int = 256

    /// Convert a time difference in minutes to a bucket index in
    /// 0..7. Returns nil for differences outside the supported
    /// range (≤ 0 or ≥ 256).
    public static func lagBucket(forMinutes minutes: Int) -> UInt8? {
        guard minutes >= 1 && minutes < maxLagMinutes else { return nil }
        // Find largest bucket where edge <= minutes.
        var b = 0
        for k in 0..<bucketEdgesMinutes.count {
            if bucketEdgesMinutes[k] <= minutes { b = k } else { break }
        }
        return UInt8(b)
    }

    /// Sorted (by key.packed ascending) list of non-zero cells.
    public private(set) var entries: [(key: CausalityKey, count: Int64)]

    public init() {
        self.entries = []
    }

    /// Explicit Equatable conformance. Tuple fields prevent
    /// Swift from auto-deriving the synthesized `==`.
    public static func == (lhs: MatrixT, rhs: MatrixT) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for i in 0..<lhs.entries.count {
            if lhs.entries[i].key != rhs.entries[i].key { return false }
            if lhs.entries[i].count != rhs.entries[i].count { return false }
        }
        return true
    }

    public init(entries: [(key: CausalityKey, count: Int64)]) {
        let sorted = entries.sorted { $0.key < $1.key }
        var deduped: [(key: CausalityKey, count: Int64)] = []
        for entry in sorted {
            if let last = deduped.last, last.key == entry.key {
                deduped[deduped.count - 1] = (last.key, last.count &+ entry.count)
            } else {
                deduped.append(entry)
            }
        }
        self.entries = deduped.filter { $0.count != 0 }
        _ = sorted
    }

    // MARK: - Access

    public func count(_ key: CausalityKey) -> Int64 {
        var lo = 0
        var hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let mk = entries[mid].key
            if mk == key { return entries[mid].count }
            if mk < key { lo = mid + 1 } else { hi = mid }
        }
        return 0
    }

    public var entryCount: Int {
        return entries.count
    }

    public var totalCount: Int64 {
        var sum: Int64 = 0
        for e in entries { sum &+= e.count }
        return sum
    }

    // MARK: - Update rules

    public mutating func increment(_ key: CausalityKey, by delta: Int64) {
        guard delta != 0 else { return }
        var lo = 0
        var hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let mk = entries[mid].key
            if mk == key {
                let newCount = entries[mid].count &+ delta
                if newCount == 0 {
                    entries.remove(at: mid)
                } else {
                    entries[mid] = (mk, newCount)
                }
                return
            }
            if mk < key { lo = mid + 1 } else { hi = mid }
        }
        entries.insert((key, delta), at: lo)
    }

    /// Apply an ordered pair of rows to the matrix. `rowA` precedes
    /// `rowB` by `lagMinutes`. If the lag is out of range, no
    /// update is performed.
    public mutating func applyPair(
        delta: Int64,
        rowAFieldValues: [(field: UInt8, value: UInt8)],
        rowBFieldValues: [(field: UInt8, value: UInt8)],
        lagMinutes: Int
    ) {
        guard delta != 0 else { return }
        guard let bucket = Self.lagBucket(forMinutes: lagMinutes) else { return }
        for a in rowAFieldValues {
            for b in rowBFieldValues {
                let k = CausalityKey(
                    sourceField: a.field, sourceValue: a.value,
                    targetField: b.field, targetValue: b.value,
                    lagBucket: bucket)
                self.increment(k, by: delta)
            }
        }
    }

    public mutating func reset() {
        entries.removeAll(keepingCapacity: true)
    }

    // MARK: - Canonical wire form
    //
    // u32 LE count of entries, then for each entry:
    //   key.packed as u64 LE, count as i64 LE.

    public func writeWire(into bytes: inout [UInt8]) {
        let n = UInt32(entries.count)
        for i in 0..<4 { bytes.append(UInt8((n >> (i * 8)) & 0xFF)) }
        for entry in entries {
            let k = entry.key.packed
            for i in 0..<8 { bytes.append(UInt8((k >> (i * 8)) & 0xFF)) }
            let c = UInt64(bitPattern: entry.count)
            for i in 0..<8 { bytes.append(UInt8((c >> (i * 8)) & 0xFF)) }
        }
    }

    public static func readWire(_ bytes: [UInt8]) -> MatrixT? {
        guard bytes.count >= 4 else { return nil }
        var n: UInt32 = 0
        for i in 0..<4 { n |= UInt32(bytes[i]) << (i * 8) }
        let expected = 4 + Int(n) * (8 + 8)
        guard bytes.count == expected else { return nil }
        var entries: [(key: CausalityKey, count: Int64)] = []
        entries.reserveCapacity(Int(n))
        var off = 4
        for _ in 0..<Int(n) {
            var ku: UInt64 = 0
            for i in 0..<8 { ku |= UInt64(bytes[off + i]) << (i * 8) }
            off += 8
            var cu: UInt64 = 0
            for i in 0..<8 { cu |= UInt64(bytes[off + i]) << (i * 8) }
            off += 8
            let key = CausalityKey(
                sourceField: UInt8((ku >> 56) & 0xFF),
                sourceValue: UInt8((ku >> 48) & 0xFF),
                targetField: UInt8((ku >> 40) & 0xFF),
                targetValue: UInt8((ku >> 32) & 0xFF),
                lagBucket:   UInt8((ku >> 24) & 0xFF))
            entries.append((key, Int64(bitPattern: cu)))
        }
        var out = MatrixT()
        out.entries = entries
        return out
    }
}

// MARK: - Properties
//
//   asymmetric:        T[(i,vi),(j,vj),L] is distinct from
//                      T[(j,vj),(i,vi),L]; both can be queried
//                      independently.
//   bucket-discrete:   lagBucket monotone in minutes; bucket
//                      indices are 0..7.
//   range-bounded:     applyPair with lagMinutes < 1 or >= 256
//                      is a no-op (no entries created).
//   canonical-order:   entries sorted by key.packed ascending.
//
// MARK: - Cookbook references
//   § 6.4   Temporal causality matrix T definition and update rule
//   § 6.8   Matrix decay table (T half-life = 90 days)
//   § 7.1   Estate graph edges weighted by T counts and lag
//   § 8.13  Anomaly z-score consumes T for the temporal expectation
