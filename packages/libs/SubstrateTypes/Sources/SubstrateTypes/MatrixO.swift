// MatrixO.swift
//
// Co-occurrence matrix O per cookbook § 6.3.
//
// O is a sparse 4D array indexed by
//   (field_i, value_i, field_j, value_j)
// counting the number of rows where field_i takes value v_i AND
// field_j takes value v_j. v0.36 has 36 fields × 6 values per
// field × 36 fields × 6 values per field = ~46K potential cells;
// typical estate sparsity is 5-10%.
//
// Storage: sorted-key map from CooccurrenceKey to Int64. We use
// a sorted [(Key, Int64)] array rather than a Dictionary so that
// iteration order is canonical (lex-sorted on key) and serialization
// is deterministic across languages.
//
// Symmetry note: the cookbook does NOT require O[(i,vi),(j,vj)] ==
// O[(j,vj),(i,vi)]. Co-occurrence is conceptually symmetric, but
// the update rule iterates (i, j) ordered pairs, so each unordered
// pair contributes to TWO cells (one with (i,j), one with (j,i)).
// Implementations may optimize by storing only one and inferring
// the other, but the reference stores both for clarity and
// directness.
//
// Decay: O HAS decay (cookbook § 6.8 table). Half-life: 365 days.
// Decay is applied lazily by the dreaming daemon via MatrixDecay
// (glref-*-MatrixDecay).
//
// Storage estimate: ~5K populated cells × (8 bytes key + 8 bytes value)
//                   = ~80 KB at v0.36 (well within bitmap-tier budget).

import Foundation

/// Canonical key for an O-matrix cell, packed into a UInt32 with
/// four 8-bit lanes: fieldI | valueI | fieldJ | valueJ (high → low).
/// Field indices and values are validated to 0..63 (6 bits, I-15)
/// at construction; the upper 2 bits of each lane are always zero.
public struct CooccurrenceKey: Hashable, Comparable, Sendable {
    public let fieldI: UInt8
    public let valueI: UInt8
    public let fieldJ: UInt8
    public let valueJ: UInt8

    public init(fieldI: UInt8, valueI: UInt8, fieldJ: UInt8, valueJ: UInt8) {
        precondition(fieldI < 64 && fieldJ < 64,
                     "field index must fit in 6 bits")
        precondition(valueI < 64 && valueJ < 64,
                     "field value must fit in 6 bits (I-15)")
        self.fieldI = fieldI
        self.valueI = valueI
        self.fieldJ = fieldJ
        self.valueJ = valueJ
    }

    /// Pack into a UInt32 for compact storage and ordering.
    /// Layout (high → low): fieldI:8 | valueI:8 | fieldJ:8 | valueJ:8.
    @inlinable
    public var packed: UInt32 {
        return (UInt32(fieldI) << 24)
             | (UInt32(valueI) << 16)
             | (UInt32(fieldJ) << 8)
             | (UInt32(valueJ))
    }

    public static func < (a: CooccurrenceKey, b: CooccurrenceKey) -> Bool {
        return a.packed < b.packed
    }
}

public struct MatrixO: Sendable, Equatable {

    /// Sorted (by key.packed ascending) list of non-zero cells.
    public private(set) var entries: [(key: CooccurrenceKey, count: Int64)]

    public init() {
        self.entries = []
    }

    /// Explicit Equatable conformance: the canonical entries are
    /// always sorted by `key.packed`, so a pairwise comparison
    /// suffices. Tuple fields prevent Swift from auto-deriving
    /// the synthesized `==`.
    public static func == (lhs: MatrixO, rhs: MatrixO) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for i in 0..<lhs.entries.count {
            if lhs.entries[i].key != rhs.entries[i].key { return false }
            if lhs.entries[i].count != rhs.entries[i].count { return false }
        }
        return true
    }

    public init(entries: [(key: CooccurrenceKey, count: Int64)]) {
        // Sort and dedupe defensively.
        let sorted = entries.sorted { $0.key < $1.key }
        var deduped: [(key: CooccurrenceKey, count: Int64)] = []
        for entry in sorted {
            if let last = deduped.last, last.key == entry.key {
                deduped[deduped.count - 1] = (last.key, last.count &+ entry.count)
            } else {
                deduped.append(entry)
            }
        }
        // Drop zeros to keep canonical form.
        self.entries = deduped.filter { $0.count != 0 }
        _ = sorted // silence warning
    }

    // MARK: - Access

    /// Returns the count for a key, zero if not present.
    public func count(_ key: CooccurrenceKey) -> Int64 {
        // Binary search.
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

    // MARK: - Update rules

    /// Increment one cell by `delta`. If the cell does not exist
    /// and delta != 0, insert it. If incrementing brings the cell
    /// to zero, remove it.
    public mutating func increment(_ key: CooccurrenceKey, by delta: Int64) {
        guard delta != 0 else { return }
        // Binary-search insert position.
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

    /// Apply a row's (field, value) presence to the matrix.
    /// `delta` is +1 on capture, -1 on expunge.
    ///
    /// `fieldValues` is the row's list of (field_index, value)
    /// pairs for fields the row has assigned. Cookbook § 6.3:
    /// for each ordered pair (i, j) of fields the row has, with
    /// the corresponding values, increment O[(i, v_i), (j, v_j)]
    /// by delta. The reference iterates ordered pairs including
    /// i == j; implementations that skip the diagonal must
    /// document the deviation.
    public mutating func applyRow(delta: Int64,
                                   fieldValues: [(field: UInt8, value: UInt8)]) {
        guard delta != 0 else { return }
        for a in fieldValues {
            for b in fieldValues {
                let k = CooccurrenceKey(fieldI: a.field, valueI: a.value,
                                         fieldJ: b.field, valueJ: b.value)
                self.increment(k, by: delta)
            }
        }
    }

    public var totalCount: Int64 {
        var sum: Int64 = 0
        for e in entries { sum &+= e.count }
        return sum
    }

    public mutating func reset() {
        entries.removeAll(keepingCapacity: true)
    }

    // MARK: - Canonical wire form
    //
    // u32 LE count of entries, then for each entry:
    //   key.packed as u32 LE, count as i64 LE.

    public func writeWire(into bytes: inout [UInt8]) {
        let n = UInt32(entries.count)
        for i in 0..<4 { bytes.append(UInt8((n >> (i * 8)) & 0xFF)) }
        for entry in entries {
            let k = entry.key.packed
            for i in 0..<4 { bytes.append(UInt8((k >> (i * 8)) & 0xFF)) }
            let c = UInt64(bitPattern: entry.count)
            for i in 0..<8 { bytes.append(UInt8((c >> (i * 8)) & 0xFF)) }
        }
    }

    public static func readWire(_ bytes: [UInt8]) -> MatrixO? {
        guard bytes.count >= 4 else { return nil }
        var n: UInt32 = 0
        for i in 0..<4 { n |= UInt32(bytes[i]) << (i * 8) }
        let expected = 4 + Int(n) * (4 + 8)
        guard bytes.count == expected else { return nil }
        var entries: [(key: CooccurrenceKey, count: Int64)] = []
        entries.reserveCapacity(Int(n))
        var off = 4
        for _ in 0..<Int(n) {
            var k: UInt32 = 0
            for i in 0..<4 { k |= UInt32(bytes[off + i]) << (i * 8) }
            off += 4
            var cu: UInt64 = 0
            for i in 0..<8 { cu |= UInt64(bytes[off + i]) << (i * 8) }
            off += 8
            let key = CooccurrenceKey(
                fieldI: UInt8((k >> 24) & 0xFF),
                valueI: UInt8((k >> 16) & 0xFF),
                fieldJ: UInt8((k >> 8) & 0xFF),
                valueJ: UInt8(k & 0xFF))
            entries.append((key, Int64(bitPattern: cu)))
        }
        var out = MatrixO()
        out.entries = entries
        return out
    }
}

// MARK: - Properties
//
//   canonical-order:  entries always sorted by key.packed ascending.
//   zero-drop:        cells reaching count == 0 are removed.
//   delta-symmetric:  applyRow(delta=k, p) followed by applyRow(delta=-k, p)
//                     restores the empty state (modulo wrap on overflow).
//   wire-determinism: same entries in same order ⇒ same bytes.
//
// MARK: - Cookbook references
//   § 6.3   Co-occurrence matrix O definition and update rule
//   § 6.8   Matrix decay table (O half-life = 365 days)
//   § 8.9   NMF latent factors (consumes O as input)
//   § 7.1   Estate graph edges weighted by O counts
