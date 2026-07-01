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
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes
// SubstrateML is imported here to access TemporalCausalityFold,
// the canonical T-matrix engine (cookbook §6.4). GeniusLocusKit
// is the composition layer; importing SubstrateML (algorithms)
// does not invert the kit layering graph. Added 2026-06-04 per
// DECISION_MATRIXT_HOURLY_CADENCE_2026-06-04.md.
import SubstrateML

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

    /// HLC of the last audit entry processed by `rebuildTemporal`.
    ///
    /// The hourly TemporalCausalitySignal uses this watermark to
    /// process only entries that arrived since the last T-population
    /// pass, avoiding redundant reprocessing of the full log.
    /// Initialized to `.zero` (no pass has run yet) and advanced by
    /// every `rebuildTemporal(from:)` call.
    ///
    /// Old snapshots that predate this field decode cleanly because
    /// the custom `init(from:)` below uses `decodeIfPresent` with
    /// a `.zero` fallback.
    public private(set) var temporalWatermarkHLC: HLC

    /// Log-spaced lag bucket boundaries in minutes (cookbook §6.4).
    /// The canonical implementation lives in
    /// `TemporalCausalityFold.lagBuckets`; this constant mirrors it
    /// so callers that already reference `MatrixTier.lagBuckets` work
    /// unchanged.
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
        self.temporalWatermarkHLC = .zero
    }

    // MARK: - Codable (backward-compatible)
    //
    // MatrixTier gained `temporalWatermarkHLC` on 2026-06-04. Old
    // snapshots (MatrixSnapshot.tier) lack this key; synthesized
    // Codable would throw `keyNotFound`. A custom `init(from:)` with
    // `decodeIfPresent` restores `.zero` for old snapshots so all
    // decode paths remain forward-compatible.

    public enum CodingKeys: String, CodingKey {
        case fieldPresence
        case coOccurrence
        case temporalCausality
        case liveRowCount
        case lastHLC
        case temporalWatermarkHLC
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fieldPresence        = try c.decode([MatrixFieldCell: Int64].self, forKey: .fieldPresence)
        coOccurrence         = try c.decode([MatrixCoOccurKey: Int64].self, forKey: .coOccurrence)
        temporalCausality    = try c.decode([MatrixTemporalKey: Int64].self, forKey: .temporalCausality)
        liveRowCount         = try c.decode(Int64.self, forKey: .liveRowCount)
        lastHLC              = try c.decode(HLC.self, forKey: .lastHLC)
        // Decode with fallback to .zero so snapshots produced before
        // this field was added still decode without throwing keyNotFound.
        temporalWatermarkHLC = try c.decodeIfPresent(HLC.self, forKey: .temporalWatermarkHLC) ?? .zero
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fieldPresence,         forKey: .fieldPresence)
        try c.encode(coOccurrence,          forKey: .coOccurrence)
        try c.encode(temporalCausality,     forKey: .temporalCausality)
        try c.encode(liveRowCount,          forKey: .liveRowCount)
        try c.encode(lastHLC,               forKey: .lastHLC)
        try c.encode(temporalWatermarkHLC,  forKey: .temporalWatermarkHLC)
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
    ///
    /// Delegates to `TemporalCausalityFold.lagBucket(forMinutes:)` so
    /// the canonical implementation lives in SubstrateML (single source
    /// of truth for conformance vectors). The result is identical.
    public static func lagBucket(forMinutes minutes: Int) -> Int {
        return TemporalCausalityFold.lagBucket(forMinutes: minutes)
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
        applyCaptureEntries(into: &tier, entries: log.entriesInHLCOrder())
        return tier
    }

    /// Apply capture/expunge/withdraw entries to `tier`'s F/O/C state in HLC
    /// order, IN PLACE on the passed tier.
    ///
    /// Shared by `rebuild` (fresh tier, all entries) and `incrementalUpdate`
    /// (loaded snapshot, only entries past the cursor). Operating in place on the
    /// existing tier is the load-bearing correctness point for incremental: an
    /// expunge/withdraw of a row captured BEFORE the snapshot lands its `-1` on
    /// the existing `+1`. A delta-rebuild-then-merge would lose that decrement —
    /// `liveRowCount` clamps at 0 and a fresh delta tier never saw the original
    /// capture — silently drifting F/O/liveRowCount.
    ///
    /// Bitmap captures are grouped per (tier, rowID, hlc) so the co-occurrence
    /// walk over one capture sees all of that row's fingerprint fields together
    /// (the audit log lays them out as one entry per fieldPath).
    static func applyCaptureEntries(
        into tier: inout MatrixTier,
        entries: [UnifiedAuditEntry]
    ) {
        struct RowKey: Hashable {
            let tier: AuditTier
            let rowID: UUID
            let hlc: HLC
        }
        // Bundle a row's same-HLC capture/expunge fields together (bitmap +
        // value) so the co-occurrence walk sees the whole fingerprint at once.
        var bundle: [RowKey: [(String, UInt64)]] = [:]
        var valueBundle: [RowKey: [MatrixValueCoord]] = [:]
        var bundleSign: [RowKey: Int64] = [:]
        var bundleOrder: [RowKey] = []   // first-seen order, for stable equal-HLC apply
        var withdrawHLCs: [HLC] = []

        for entry in entries {
            switch entry.verb {
            case .capture, .expunge:
                let key = RowKey(tier: entry.tier, rowID: entry.rowID, hlc: entry.hlc)
                if bundle[key] == nil && valueBundle[key] == nil {
                    bundleOrder.append(key)
                }
                switch entry.afterValue {
                case .bitmap(let v):
                    bundle[key, default: []].append((entry.fieldPath, v))
                default:
                    valueBundle[key, default: []].append(
                        MatrixValueCoord(fieldPath: entry.fieldPath, value: entry.afterValue))
                }
                bundleSign[key] = entry.verb == .capture ? 1 : -1
            case .withdraw:
                // Withdraw is a soft tombstone: it decrements liveRowCount without
                // touching F/O. Collected here and applied in HLC order below — it
                // MUST run AFTER the captures that precede it (so the count it
                // decrements already includes those rows) and it advances lastHLC
                // (the incremental-hydration cursor is the max applied-entry HLC).
                withdrawHLCs.append(entry.hlc)
            default:
                continue
            }
        }

        // Apply ALL events in strict HLC order. This is the correctness fix that
        // makes liveRowCount right and makes incremental hydration equal a full
        // rebuild: a row is always captured before it is expunged/withdrawn, so in
        // HLC order the running count never goes negative and the defensive clamp
        // in `applyCapture` never fires (the prior bundle-then-flush-at-end design
        // applied withdraws/expunges while liveRowCount was still 0, clamping their
        // decrements away). F/O are additive so their counts are order-independent;
        // only the count and the clamp depend on order. At equal HLC, capture/
        // expunge bundles apply before withdraws (the natural capture→withdraw
        // order, and deterministic).
        enum Event { case bundle(RowKey); case withdraw(HLC) }
        var events: [(hlc: HLC, tie: Int, ev: Event)] = []
        events.reserveCapacity(bundleOrder.count + withdrawHLCs.count)
        for (i, key) in bundleOrder.enumerated() {
            events.append((key.hlc, i, .bundle(key)))
        }
        let withdrawTieBase = bundleOrder.count
        for (j, h) in withdrawHLCs.enumerated() {
            events.append((h, withdrawTieBase + j, .withdraw(h)))
        }
        events.sort { a, b in a.hlc != b.hlc ? a.hlc < b.hlc : a.tie < b.tie }

        for e in events {
            switch e.ev {
            case .bundle(let key):
                tier.applyCapture(
                    bitmapFields: bundle[key] ?? [],
                    valueFields: valueBundle[key] ?? [],
                    hlc: key.hlc,
                    delta: bundleSign[key] ?? 1)
            case .withdraw(let h):
                tier.liveRowCount = max(0, tier.liveRowCount - 1)
                if h > tier.lastHLC { tier.lastHLC = h }
            }
        }
    }

    // MARK: - rebuildTemporal

    /// Rebuild the T (temporal causality) matrix from the unified audit log.
    ///
    /// This is SEPARATE from `rebuild(from:)`, which populates F, C, and O.
    /// Calling `rebuild(from:)` alone does NOT populate T — temporal causality
    /// crosses *pairs* of rows captured at different times, whereas F/O derive
    /// from individual rows. Callers that want a full rebuild call both:
    ///
    ///     var tier = MatrixTier.rebuild(from: log)
    ///     tier = MatrixTier.rebuildTemporal(from: log, into: tier)
    ///
    /// Or equivalently, merge two passes:
    ///
    ///     var tier = MatrixTier.rebuild(from: log)
    ///     let tTier = MatrixTier.rebuildTemporal(from: log)
    ///     tier.temporalCausality = tTier.temporalCausality
    ///     tier.temporalWatermarkHLC = tTier.temporalWatermarkHLC
    ///
    /// Implementation:
    ///   1. Converts UnifiedAuditEntry → TemporalAuditEntry at this kit
    ///      boundary (SubstrateML cannot import GeniusLocusKit).
    ///   2. Calls `TemporalCausalityFold.fold` with `.zero` watermark
    ///      (full rebuild always replays the full log).
    ///   3. Applies each delta via `applyTemporalEvent`.
    ///   4. Sets `temporalWatermarkHLC` to the fold's returned watermark.
    ///
    /// The rebuild is idempotent on the same log: replaying the same log
    /// twice from a fresh MatrixTier produces a cell-equal result because
    /// T counts pairs and the fold is deterministic.
    public static func rebuildTemporal(
        from log: UnifiedAuditLog,
        startWatermark: HLC = .zero
    ) -> MatrixTier {
        var tier = MatrixTier()

        // Convert UnifiedAuditEntry to TemporalAuditEntry at the GeniusLocusKit
        // boundary. Only capture and expunge verbs contribute to T (same filter
        // as applyCapture on the hot path). Entries are taken in HLC order —
        // orderedEntries is already HLC-ascending, meeting TemporalCausalityFold's
        // precondition.
        //
        // INCREMENTAL PRUNE (launch cost): when folding forward from a non-zero
        // watermark (hydration path), drop entries older than one window before
        // the watermark. TemporalCausalityFold only emits pairs for entries with
        // HLC > startWatermark, and a new entry pairs only with earlier entries
        // within `temporalWindowMinutes` (physicalTime is ms; the fold's window
        // check is `(newTime - olderTime) / 60_000 <= windowMinutes`). So any
        // entry whose physicalTime < watermark - windowMinutes·60_000 can never
        // be inside a post-watermark entry's window and contributes no delta —
        // dropping it is exact, not an approximation, and it bounds the fold's
        // materialization + O(N) buffer scan to the tail instead of re-folding
        // the whole audit log on every launch (the recompute-on-launch that made
        // a 50k-entry estate spend minutes single-threaded here). A full rebuild
        // (startWatermark == .zero) keeps every entry — cutoff is Int64.min.
        let temporalCutoffMs: Int64 = startWatermark == .zero
            ? Int64.min
            : startWatermark.physicalTime - Int64(Self.temporalWindowMinutes) * 60_000
        let temporalEntries: [TemporalAuditEntry] = log.orderedEntries
            .filter { ($0.verb == .capture || $0.verb == .expunge)
                      && $0.hlc.physicalTime >= temporalCutoffMs }
            .map { entry in
                let coords: [TemporalFieldCoord]
                switch entry.afterValue {
                case .bitmap(let v):
                    // Bitmap value: one coord carrying the full bitmap.
                    coords = [TemporalFieldCoord(
                        fieldPath: entry.fieldPath,
                        valueRepr: "bitmap:\(v)")]
                case .string(let s):
                    coords = [TemporalFieldCoord(
                        fieldPath: entry.fieldPath,
                        valueRepr: "string:\(s)")]
                case .integer(let v):
                    coords = [TemporalFieldCoord(
                        fieldPath: entry.fieldPath,
                        valueRepr: "integer:\(v)")]
                case .bytes(let b):
                    coords = [TemporalFieldCoord(
                        fieldPath: entry.fieldPath,
                        valueRepr: "bytes:\(b.count)")]
                case .null:
                    // Null after-value contributes no coordinate; the entry
                    // advances the watermark but generates no T pairs.
                    coords = []
                }
                return TemporalAuditEntry(hlc: entry.hlc, fieldCoords: coords)
            }

        // Full rebuild passes `.zero` (process every entry as "new");
        // incremental hydration passes the persisted `temporalWatermarkHLC` so
        // the fold emits only the new cross-pairs — including window-boundary
        // pairs against pre-watermark entries — which merge additively onto the
        // loaded T. fold() returns a FoldResult (named struct mirroring Rust);
        // access .deltas and .newWatermark by name.
        let foldResult = TemporalCausalityFold.fold(
            entries: temporalEntries,
            windowMinutes: Self.temporalWindowMinutes,
            startWatermark: startWatermark)

        for (foldKey, delta) in foldResult.deltas {
            // Map TemporalCausalityKey → (source, target, deltaMinutes) for
            // applyTemporalEvent. applyTemporalEvent internally calls
            // Self.lagBucket again, so we pass the bucket value directly as
            // the deltaMinutes argument — it maps back to the same bucket.
            let src = MatrixValueCoord(
                fieldPath: foldKey.source.fieldPath,
                value: decodeValueRepr(foldKey.source.valueRepr))
            let tgt = MatrixValueCoord(
                fieldPath: foldKey.target.fieldPath,
                value: decodeValueRepr(foldKey.target.valueRepr))
            // Pass lagBucket value as deltaMinutes; applyTemporalEvent maps
            // it back to the same bucket because lagBucket(x) == x for each
            // boundary value in {1,2,4,8,16,32,64,128}.
            tier.applyTemporalEvent(
                source: src,
                target: tgt,
                deltaMinutes: foldKey.lagBucket,
                delta: delta)
        }

        tier.temporalWatermarkHLC = foldResult.newWatermark
        return tier
    }

    /// Decode a `TemporalFieldCoord.valueRepr` string back to a
    /// `UnifiedAuditValue`. Used at the GeniusLocusKit boundary when
    /// converting fold output to MatrixValueCoord.
    ///
    /// This is the inverse of the encoding applied in `rebuildTemporal`:
    ///   "bitmap:\(v)"    → .bitmap(v)
    ///   "string:\(s)"    → .string(s)
    ///   "integer:\(v)"   → .integer(v)
    ///   "bytes:\(count)" → .bytes([]) (count used for matching; content
    ///                       is not round-tripped — T is keyed by repr only)
    ///   "null"           → .null
    ///   anything else    → .string(repr) (safe fallback)
    private static func decodeValueRepr(_ repr: String) -> UnifiedAuditValue {
        if repr == "null" { return .null }
        if repr.hasPrefix("bitmap:"),
           let v = UInt64(repr.dropFirst("bitmap:".count)) {
            return .bitmap(v)
        }
        if repr.hasPrefix("integer:"),
           let v = Int64(repr.dropFirst("integer:".count)) {
            return .integer(v)
        }
        if repr.hasPrefix("bytes:") {
            // Bytes content is not round-tripped; only the field identity
            // matters for T-matrix keying.
            return .bytes([])
        }
        if repr.hasPrefix("string:") {
            return .string(String(repr.dropFirst("string:".count)))
        }
        // Safe fallback: treat unknown reprs as string values.
        return .string(repr)
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

    // MARK: - fullRebuild

    /// Rebuild F, O, C, AND T from the unified audit log in a single call.
    ///
    /// Combines `rebuild(from:)` (which populates F, O, C, liveRowCount,
    /// lastHLC) with `rebuildTemporal(from:)` (which populates T and
    /// temporalWatermarkHLC) into one tier. Use this method when a complete
    /// matrix rebuild is required (e.g., after hydrating an estate from
    /// durable storage). The two-pass design is documented in the module
    /// header: F/O/C derive from individual rows while T crosses pairs of
    /// rows at different times, so a single-pass rebuild is not possible.
    ///
    /// This method lives inside the `MatrixTier` type because merging T into
    /// an F/O/C tier requires writing `private(set)` stored properties
    /// (`temporalCausality`, `temporalWatermarkHLC`) that are not writable
    /// from external callers. The merge is safe: `addT` accumulates counts
    /// rather than replacing them, preserving the invariant that each entry
    /// is counted exactly once.
    ///
    /// The result is bit-identical to calling `rebuild` and `rebuildTemporal`
    /// independently and combining their outputs — just without the
    /// external-scope restriction.
    public static func fullRebuild(from log: UnifiedAuditLog) -> MatrixTier {
        // Pass 1: F, O, C, liveRowCount, lastHLC.
        var tier = rebuild(from: log)

        // Pass 2: T, temporalWatermarkHLC.
        // Construct the T-only tier then merge its entries into `tier`.
        let tTier = rebuildTemporal(from: log)

        // Merge T entries. addT is private mutating on the same type, so
        // `tier` (a var inside this static func) accepts the mutation.
        for (key, count) in tTier.temporalCausality {
            tier.addT(key: key, delta: count)
        }
        // Advance the temporal watermark to the value computed by the T pass.
        tier.temporalWatermarkHLC = tTier.temporalWatermarkHLC
        return tier
    }

    /// Fold this (already-loaded snapshot) tier FORWARD over `log`, applying only
    /// the entries past the persisted cursors — the load-and-incremental-fold
    /// path that replaces a full rebuild on hydration so the matrix tier is read
    /// from its on-disk snapshot, never recomputed from the whole audit log on
    /// launch.
    ///
    /// F/O/C: replays capture/expunge/withdraw entries with `hlc > lastHLC`
    /// directly onto this tier via the shared `applyCaptureEntries` (a row's
    /// fields share one HLC, so the cursor splits cleanly on row boundaries, and
    /// a post-snapshot expunge of a pre-snapshot row lands its `-1` on the
    /// existing count). T: re-folds the full log from `temporalWatermarkHLC`, so
    /// only the new cross-pairs — including window-boundary pairs against
    /// pre-watermark entries — are emitted and merged additively via `addT`.
    ///
    /// Invariant (conformance-tested): for any split point, a snapshot
    /// `fullRebuild(prefix)` then `incrementalUpdate(fullLog)` equals
    /// `fullRebuild(fullLog)` cell-for-cell — including cross-cursor
    /// expunge/withdraw and temporal window-boundary pairs.
    public mutating func incrementalUpdate(from log: UnifiedAuditLog) {
        // F/O/C — replay rows past the field cursor directly onto self.
        let foCursor = lastHLC
        let newEntries = log.entriesInHLCOrder().filter { $0.hlc > foCursor }
        Self.applyCaptureEntries(into: &self, entries: newEntries)

        // T — fold the full log from the persisted temporal watermark; the fold
        // emits only new cross-pairs, which merge additively onto the loaded T.
        let tDelta = MatrixTier.rebuildTemporal(
            from: log, startWatermark: temporalWatermarkHLC)
        for (key, count) in tDelta.temporalCausality {
            addT(key: key, delta: count)
        }
        if tDelta.temporalWatermarkHLC > temporalWatermarkHLC {
            temporalWatermarkHLC = tDelta.temporalWatermarkHLC
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
