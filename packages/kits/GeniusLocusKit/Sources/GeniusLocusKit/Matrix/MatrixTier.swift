// MatrixTier.swift
//
// Mission GLK-06 — The substrate's cognition layer.
//
// The matrix tier holds the F, C, O, and T population-statistic
// family per substrate mathematics §8 and engineering cookbook §6.
// Counts accumulate incrementally on the capture path; a full rebuild
// replays the unified audit log (GLK-03) and produces the same state.
//
// Mathematical references:
//   substrate-mathematics §8     F, C, O, T definitions; decay; NMF
//   cookbook §6.1                F: field-presence dense count
//   cookbook §6.2                C: derived correlation F / N_rows
//   cookbook §6.3                O: sparse co-occurrence (CSR-shaped)
//   cookbook §6.4                T: sparse temporal causality, log-spaced lag
//   cookbook §6.8                Lazy multiplicative decay per matrix half-life
//
// Persistence is a separate concern handled by `MatrixPersistence`;
// `MatrixTier` is the in-memory value snapshot fed by the capture path
// and the rebuild pass.
//
// Coordinate model. Fields are identified by their `fieldPath` string
// (the same string `UnifiedAuditEntry.fieldPath` carries). Values are
// the `UnifiedAuditValue` payload. F is keyed by (fieldPath,
// bitPosition) over `.bitmap` payloads; non-bitmap fieldPath/value
// pairs feed only O and T. This mirrors the cookbook's two-axis split:
// the bitmap fingerprint contributes to F and C; arbitrary
// field-value pairs contribute to O and T.

import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes

// MARK: - Coordinate types

/// One cell of the F (field-presence) and C (correlation) matrices.
/// `bitPosition` is in `0...63` — the substrate's 4-block fingerprints
/// store 64 bits per block (cookbook §3.8).
public struct MatrixFieldCell: Hashable, Sendable, Codable {
    public let fieldPath: String
    public let bitPosition: Int

    public init(fieldPath: String, bitPosition: Int) {
        precondition((0...63).contains(bitPosition),
                     "bitPosition out of 64-bit block range")
        self.fieldPath = fieldPath
        self.bitPosition = bitPosition
    }
}

/// A (field, value) coordinate for the O and T matrices. Values
/// outside the four-block fingerprint — strings, integers, bytes —
/// are first-class here so the tier can hold "field X equals string
/// Y" co-occurrence without quantising into a bitmap.
public struct MatrixValueCoord: Hashable, Sendable, Codable {
    public let fieldPath: String
    public let value: UnifiedAuditValue

    public init(fieldPath: String, value: UnifiedAuditValue) {
        self.fieldPath = fieldPath
        self.value = value
    }
}

/// Canonical-ordered pair of `MatrixValueCoord` for the symmetric O
/// matrix. Two captures co-occurring on (a, b) and (b, a) feed the
/// same cell; canonical ordering keeps the storage map symmetric.
public struct MatrixCoOccurKey: Hashable, Sendable, Codable {
    public let a: MatrixValueCoord
    public let b: MatrixValueCoord

    public init(_ x: MatrixValueCoord, _ y: MatrixValueCoord) {
        // Canonical order: compare by fieldPath, then by value's
        // wire-stable shape (Codable JSON keeps it deterministic for
        // the equality test here).
        if Self.lexLess(x, y) {
            self.a = x
            self.b = y
        } else {
            self.a = y
            self.b = x
        }
    }

    private static func lexLess(
        _ x: MatrixValueCoord,
        _ y: MatrixValueCoord
    ) -> Bool {
        if x.fieldPath != y.fieldPath {
            return x.fieldPath < y.fieldPath
        }
        return x.value.canonicalRank < y.value.canonicalRank
    }
}

/// A directional (source → target) lag-bucketed key for the T matrix.
/// Lag buckets are log2 of minute differences clamped to
/// `MatrixTier.lagBuckets`.
public struct MatrixTemporalKey: Hashable, Sendable, Codable {
    public let source: MatrixValueCoord
    public let target: MatrixValueCoord
    public let lagBucket: Int

    public init(source: MatrixValueCoord,
                target: MatrixValueCoord,
                lagBucket: Int) {
        self.source = source
        self.target = target
        self.lagBucket = lagBucket
    }
}

// MARK: - UnifiedAuditValue ordering

fileprivate extension UnifiedAuditValue {
    /// Stable rank used only for canonical pair ordering in
    /// `MatrixCoOccurKey`. Not exposed; the ordering itself does not
    /// need to be domain-meaningful, only deterministic across replicas.
    var canonicalRank: Int {
        switch self {
        case .null: return 0
        case .bitmap(let v): return 1 &+ Int(truncatingIfNeeded: v)
        case .integer(let v): return 2 &+ Int(truncatingIfNeeded: v)
        case .string(let s): return 3 &+ s.hashValue
        case .bytes(let b): return 4 &+ b.count
        }
    }
}

// MARK: - Matrix tier

/// In-memory snapshot of the matrix tier for one estate.
public struct MatrixTier: Sendable, Equatable, Codable {

    /// F[field, bit] — dense count of rows where the bit is set in
    /// `fieldPath`'s bitmap value. Held as a sparse map because the
    /// 36-field × 64-bit dense grid is not yet pinned at the kit
    /// boundary; sparse storage avoids reserving 1.7 KB up-front for
    /// estates that never set most bits.
    public private(set) var fieldPresence: [MatrixFieldCell: Int64]

    /// O[(i, v_i), (j, v_j)] — symmetric sparse co-occurrence counts.
    public private(set) var coOccurrence: [MatrixCoOccurKey: Int64]

    /// T[source, target, lag] — directional sparse temporal causality.
    public private(set) var temporalCausality: [MatrixTemporalKey: Int64]

    /// Live, non-tombstoned row count. C is derived from F and this
    /// scalar (cookbook §6.2). Held alongside the matrices so callers
    /// reading correlation never need to consult the projection.
    public private(set) var liveRowCount: Int64

    /// Last HLC seen by the tier. Used by the snapshot watermark.
    public private(set) var lastHLC: HLC

    /// Log-spaced lag bucket boundaries in minutes (cookbook §6.4).
    public static let lagBuckets: [Int] = [1, 2, 4, 8, 16, 32, 64, 128]

    /// Window cap for T — pairs whose capture-time delta exceeds the
    /// largest bucket (256 minutes) are ignored, per cookbook §6.4.
    public static let temporalWindowMinutes: Int = 256

    public init() {
        self.fieldPresence = [:]
        self.coOccurrence = [:]
        self.temporalCausality = [:]
        self.liveRowCount = 0
        self.lastHLC = .zero
    }

    // MARK: Derived correlation

    /// C[field, bit] = F[field, bit] / N_rows. Returns 0.0 when the
    /// estate has no live rows.
    public func correlation(for cell: MatrixFieldCell) -> Double {
        guard liveRowCount > 0 else { return 0.0 }
        let count = Double(fieldPresence[cell] ?? 0)
        return count / Double(liveRowCount)
    }

    // MARK: Incremental update

    /// Apply one captured row's fingerprint. `bitmapFields` carries
    /// each `(fieldPath, bitmap)` pair the row contributes; the F
    /// matrix is updated for every set bit, and the O matrix is updated
    /// for every (field-i, field-j) pair where both fingerprints are
    /// non-zero. `valueFields` carries non-bitmap (fieldPath, value)
    /// payloads that feed O directly without bit decomposition.
    ///
    /// Capture and expunge use the same code path with opposite sign:
    /// `delta = +1` on capture, `-1` on expunge-of-active-row.
    public mutating func applyCapture(
        bitmapFields: [(String, UInt64)],
        valueFields: [MatrixValueCoord] = [],
        hlc: HLC,
        delta: Int64 = 1
    ) {
        // F: walk every set bit.
        for (path, bitmap) in bitmapFields {
            var b = bitmap
            while b != 0 {
                // Trailing-zero count gives the next set bit. Using
                // bit-twiddling instead of a 0..<64 loop because the
                // matrix tier is on the capture path and most bitmaps
                // are mostly-zero (cookbook §3.8 fingerprint density).
                let bitPos = b.trailingZeroBitCount
                let cell = MatrixFieldCell(fieldPath: path,
                                           bitPosition: bitPos)
                addF(cell: cell, delta: delta)
                b &= b &- 1
            }
        }

        // O: co-occurrence over the row's (field, value) coordinates.
        // Each bitmap field contributes one coordinate per set bit,
        // but the cookbook's O is field-value not field-bit — so we
        // collapse a bitmap field into one coordinate carrying its
        // bitmap value, and contribute non-bitmap fields directly.
        var coords: [MatrixValueCoord] = valueFields
        coords.reserveCapacity(valueFields.count + bitmapFields.count)
        for (path, bitmap) in bitmapFields where bitmap != 0 {
            coords.append(MatrixValueCoord(fieldPath: path,
                                           value: .bitmap(bitmap)))
        }

        if coords.count >= 2 {
            for i in 0..<(coords.count - 1) {
                for j in (i + 1)..<coords.count {
                    let key = MatrixCoOccurKey(coords[i], coords[j])
                    addO(key: key, delta: delta)
                }
            }
        }

        liveRowCount = max(0, liveRowCount + delta)
        if hlc > lastHLC { lastHLC = hlc }
    }

    /// Update one cell of the temporal matrix. The dreaming-daemon
    /// pass (out of scope for this mission) is what drives this in
    /// production; we expose it as a primitive so the rebuild and the
    /// incremental paths share one update entry-point.
    public mutating func applyTemporalEvent(
        source: MatrixValueCoord,
        target: MatrixValueCoord,
        deltaMinutes: Int,
        delta: Int64 = 1
    ) {
        guard deltaMinutes > 0,
              deltaMinutes <= Self.temporalWindowMinutes else { return }
        let bucket = Self.lagBucket(forMinutes: deltaMinutes)
        let key = MatrixTemporalKey(source: source,
                                    target: target,
                                    lagBucket: bucket)
        addT(key: key, delta: delta)
    }

    /// Log-spaced bucket index: 1, 2, 4, 8, ..., 128 minutes.
    /// Out-of-window inputs are caller-side rejected by
    /// `applyTemporalEvent`.
    public static func lagBucket(forMinutes minutes: Int) -> Int {
        // Find the smallest bucket whose boundary >= minutes.
        for b in lagBuckets {
            if minutes <= b { return b }
        }
        return lagBuckets.last ?? 128
    }

    // MARK: Decay

    /// Apply lazy multiplicative decay per cookbook §6.8. F and C do
    /// not decay (population stats are stable). O half-life is 365
    /// days; T half-life is 90 days. Counts are stored Int64 and
    /// rounded after the multiply.
    public mutating func applyDecay(
        elapsedDays: Double,
        oHalfLifeDays: Double = 365.0,
        tHalfLifeDays: Double = 90.0
    ) {
        guard elapsedDays >= 1.0 else { return }
        let oFactor = pow(0.5, elapsedDays / oHalfLifeDays)
        let tFactor = pow(0.5, elapsedDays / tHalfLifeDays)

        for (k, v) in coOccurrence {
            let decayed = Int64((Double(v) * oFactor).rounded())
            if decayed > 0 {
                coOccurrence[k] = decayed
            } else {
                coOccurrence.removeValue(forKey: k)
            }
        }
        for (k, v) in temporalCausality {
            let decayed = Int64((Double(v) * tFactor).rounded())
            if decayed > 0 {
                temporalCausality[k] = decayed
            } else {
                temporalCausality.removeValue(forKey: k)
            }
        }
    }

    // MARK: Rebuild

    /// Rebuild the matrix tier by replaying the unified audit log in
    /// HLC order (cookbook §6 "incremental update runs on the capture
    /// path; full rebuild replays the unified audit log"). The rebuild
    /// is deterministic: replaying the same log yields a cell-equal
    /// matrix tier independent of the order entries were `merge`d into
    /// the G-Set.
    ///
    /// Only `capture` and `expunge` verbs feed F and O directly;
    /// `withdraw` is treated as a soft delete and decrements
    /// `liveRowCount`. `mutate` records a per-bit delta on the F
    /// matrix when the before/after pair are both `.bitmap`. Other
    /// verbs are no-ops at the matrix tier (`recall`, `propose`,
    /// `associate`, `learn`, `dreamCompact`, `migrate`, `reanchor`).
    public static func rebuild(from log: UnifiedAuditLog) -> MatrixTier {
        var tier = MatrixTier()
        let entries = log.entriesInHLCOrder()
        // Group bitmap captures per (tier, rowID, hlc) so the
        // co-occurrence walk over one capture sees all of that row's
        // fingerprint fields together — the audit log lays them out
        // as one entry per fieldPath; the matrix tier needs them
        // bundled to compute O.
        struct RowKey: Hashable {
            let tier: AuditTier
            let rowID: UUID
            let hlc: HLC
        }
        var bundle: [RowKey: [(String, UInt64)]] = [:]
        var valueBundle: [RowKey: [MatrixValueCoord]] = [:]
        var bundleSign: [RowKey: Int64] = [:]

        func flush(_ key: RowKey) {
            guard let bm = bundle[key], let sign = bundleSign[key]
            else { return }
            let vs = valueBundle[key] ?? []
            tier.applyCapture(
                bitmapFields: bm,
                valueFields: vs,
                hlc: key.hlc,
                delta: sign
            )
            bundle.removeValue(forKey: key)
            valueBundle.removeValue(forKey: key)
            bundleSign.removeValue(forKey: key)
        }

        for entry in entries {
            let key = RowKey(tier: entry.tier,
                             rowID: entry.rowID,
                             hlc: entry.hlc)

            let sign: Int64?
            switch entry.verb {
            case .capture: sign = +1
            case .expunge: sign = -1
            case .withdraw:
                // Withdraw is a soft tombstone; it decrements the live
                // row count without altering F/O for that row's fields.
                // The next expunge will fold F/O down explicitly.
                tier.liveRowCount = max(0, tier.liveRowCount - 1)
                continue
            default:
                continue
            }
            guard let s = sign else { continue }

            switch entry.afterValue {
            case .bitmap(let v):
                var arr = bundle[key] ?? []
                arr.append((entry.fieldPath, v))
                bundle[key] = arr
            default:
                var arr = valueBundle[key] ?? []
                arr.append(MatrixValueCoord(fieldPath: entry.fieldPath,
                                            value: entry.afterValue))
                valueBundle[key] = arr
            }
            bundleSign[key] = s
        }

        // Flush remaining bundles in HLC order so `lastHLC` advances
        // monotonically through the rebuild.
        let keys = bundle.keys.sorted { a, b in a.hlc < b.hlc }
        for k in keys { flush(k) }
        // Flush value-only bundles too (those with no bitmap fields).
        // Keys already drained by the bitmap-flush loop above had their
        // entry in `bundleSign` removed inside `flush`, so the
        // `bundleSign[k]` guard below silently skips them — preventing
        // a double-apply on rows that carried both bitmap and value
        // fields.
        let vKeys = valueBundle.keys.sorted { a, b in a.hlc < b.hlc }
        for k in vKeys {
            if let sign = bundleSign[k] {
                tier.applyCapture(
                    bitmapFields: [],
                    valueFields: valueBundle[k] ?? [],
                    hlc: k.hlc,
                    delta: sign
                )
            }
        }
        return tier
    }

    // MARK: - Private update helpers

    private mutating func addF(cell: MatrixFieldCell, delta: Int64) {
        let next = (fieldPresence[cell] ?? 0) + delta
        if next > 0 {
            fieldPresence[cell] = next
        } else {
            fieldPresence.removeValue(forKey: cell)
        }
    }

    private mutating func addO(key: MatrixCoOccurKey, delta: Int64) {
        let next = (coOccurrence[key] ?? 0) + delta
        if next > 0 {
            coOccurrence[key] = next
        } else {
            coOccurrence.removeValue(forKey: key)
        }
    }

    private mutating func addT(key: MatrixTemporalKey, delta: Int64) {
        let next = (temporalCausality[key] ?? 0) + delta
        if next > 0 {
            temporalCausality[key] = next
        } else {
            temporalCausality.removeValue(forKey: key)
        }
    }
}

// MARK: - HLC ordering helper

extension UnifiedAuditLog {
    /// Stable HLC-ordered entry sequence — thin wrapper over the
    /// log's canonical `orderedEntries` accessor, named to read
    /// fluently at the matrix-tier rebuild call site.
    fileprivate func entriesInHLCOrder() -> [UnifiedAuditEntry] {
        return orderedEntries
    }
}
