// MatrixTierTests.swift
//
// Mission GLK-06 — Matrix-tier conformance tests.
//
// Covers:
//   • Incremental update correctness for F, C, O, T (cookbook §6.1-6.4).
//   • Rebuild from the unified audit log equals the incrementally
//     maintained matrices, in cell-for-cell agreement.
//   • Both persistence modes round-trip; the snapshot reproduces the
//     saved tier exactly.
//   • Calibration curve deflates overconfidence.
//   • NMF factorization approximates the input matrix.

import Testing
import SubstrateTypes
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
@testable import GeniusLocusKit

@Suite("Matrix tier conformance")
struct MatrixTierTests {

    // MARK: - Helpers

    /// HLC factory keeping tests independent of wall time.
    private func hlc(_ p: Int64, _ l: Int32 = 0) -> HLC {
        HLC(physicalTime: p, logicalCount: l, nodeID: 1)
    }

    private func captureEntry(
        tier: AuditTier = .locus,
        row: UUID,
        field: String,
        value: UnifiedAuditValue,
        at: HLC
    ) -> UnifiedAuditEntry {
        UnifiedAuditEntry(
            tier: tier,
            hlc: at,
            verb: .capture,
            rowID: row,
            fieldPath: field,
            beforeValue: .null,
            afterValue: value
        )
    }

    // MARK: - F and C

    @Test
    func fieldPresenceCountsSetBits() {
        var tier = MatrixTier()
        // Two captures, both with bits 0 and 3 set.
        tier.applyCapture(
            bitmapFields: [("bitmap.adjective", 0b1001)],
            hlc: hlc(10)
        )
        tier.applyCapture(
            bitmapFields: [("bitmap.adjective", 0b1001)],
            hlc: hlc(11)
        )
        let bit0 = MatrixFieldCell(fieldPath: "bitmap.adjective",
                                   bitPosition: 0)
        let bit3 = MatrixFieldCell(fieldPath: "bitmap.adjective",
                                   bitPosition: 3)
        let bit1 = MatrixFieldCell(fieldPath: "bitmap.adjective",
                                   bitPosition: 1)
        #expect(tier.fieldPresence[bit0] == 2)
        #expect(tier.fieldPresence[bit3] == 2)
        #expect(tier.fieldPresence[bit1] == nil)
        #expect(tier.liveRowCount == 2)
        #expect(abs(tier.correlation(for: bit0) - 1.0) <= 1e-9)
        #expect(abs(tier.correlation(for: bit1) - 0.0) <= 1e-9)
    }

    @Test
    func correlationDerivesFromFieldPresence() {
        var tier = MatrixTier()
        tier.applyCapture(bitmapFields: [("bm.x", 0b1)],
                          hlc: hlc(1))
        tier.applyCapture(bitmapFields: [("bm.x", 0b1)],
                          hlc: hlc(2))
        tier.applyCapture(bitmapFields: [("bm.x", 0b0)],
                          hlc: hlc(3))
        let bit0 = MatrixFieldCell(fieldPath: "bm.x", bitPosition: 0)
        // 2 of 3 rows set bit 0.
        #expect(abs(tier.correlation(for: bit0) - 2.0 / 3.0) <= 1e-9)
    }

    // MARK: - O

    @Test
    func coOccurrenceCanonicalSymmetric() {
        var tier = MatrixTier()
        // One capture, two fields → one O-cell.
        tier.applyCapture(
            bitmapFields: [("bm.a", 0b1), ("bm.b", 0b10)],
            hlc: hlc(1)
        )
        let a = MatrixValueCoord(fieldPath: "bm.a", value: .bitmap(0b1))
        let b = MatrixValueCoord(fieldPath: "bm.b", value: .bitmap(0b10))
        let k1 = MatrixCoOccurKey(a, b)
        let k2 = MatrixCoOccurKey(b, a)
        #expect(k1 == k2, "co-occurrence key must canonicalise")
        #expect(tier.coOccurrence[k1] == 1)
        #expect(tier.coOccurrence.count == 1)
    }

    // MARK: - T

    @Test
    func temporalLagBucketing() {
        #expect(MatrixTier.lagBucket(forMinutes: 1) == 1)
        #expect(MatrixTier.lagBucket(forMinutes: 3) == 4)
        #expect(MatrixTier.lagBucket(forMinutes: 9) == 16)
        #expect(MatrixTier.lagBucket(forMinutes: 128) == 128)
        var tier = MatrixTier()
        let s = MatrixValueCoord(fieldPath: "f.x", value: .bitmap(1))
        let t = MatrixValueCoord(fieldPath: "f.y", value: .bitmap(2))
        tier.applyTemporalEvent(source: s, target: t, deltaMinutes: 5)
        let key = MatrixTemporalKey(source: s, target: t, lagBucket: 8)
        #expect(tier.temporalCausality[key] == 1)
        // Out of window — no effect.
        tier.applyTemporalEvent(source: s, target: t,
                                deltaMinutes: 1_000)
        #expect(tier.temporalCausality.count == 1)
    }

    /// The wikidataQID coordinate is excluded from T but retained in O. QID is
    /// the high-cardinality per-content concept: valuable for within-event
    /// co-occurrence (O) but noise + the dominant key-explosion term as a
    /// cross-event temporal (T) coordinate. Mirrors Rust matrix_parity
    /// wikidata_qid_excluded_from_temporal_but_kept_in_cooccurrence.
    @Test
    func wikidataQidExcludedFromTemporal() {
        let rowA = UUID()
        let rowB = UUID()
        let h0 = hlc(0)
        let h1 = hlc(300_000) // 5 minutes apart → within window

        var log = UnifiedAuditLog()
        // Each event carries a bitmap field AND a wikidataQID concept coordinate.
        log.add(captureEntry(row: rowA, field: "bm.x", value: .bitmap(1), at: h0))
        log.add(captureEntry(row: rowA, field: "wikidataQID", value: .integer(111), at: h0))
        log.add(captureEntry(row: rowB, field: "bm.x", value: .bitmap(2), at: h1))
        log.add(captureEntry(row: rowB, field: "wikidataQID", value: .integer(222), at: h1))

        // T: no temporal key may touch wikidataQID, and the bitmap cross-pair
        // must still be present.
        let t = MatrixTier.rebuildTemporal(from: log)
        #expect(t.temporalCausality.keys.allSatisfy {
            $0.source.fieldPath != "wikidataQID" && $0.target.fieldPath != "wikidataQID"
        }, "no T key may involve the wikidataQID coordinate")
        let bmKey = MatrixTemporalKey(
            source: MatrixValueCoord(fieldPath: "bm.x", value: .bitmap(1)),
            target: MatrixValueCoord(fieldPath: "bm.x", value: .bitmap(2)),
            lagBucket: 8)
        #expect(t.temporalCausality[bmKey] == 1,
                "the bitmap cross-pair must survive the QID exclusion")

        // O: QID is retained — the within-event co-occurrence pair is present.
        let o = MatrixTier.rebuild(from: log)
        #expect(o.coOccurrence.keys.contains {
            $0.a.fieldPath == "wikidataQID" || $0.b.fieldPath == "wikidataQID"
        }, "wikidataQID must still contribute to co-occurrence (O)")
    }

    // MARK: - Rebuild equals incremental

    @Test
    func rebuildFromAuditLogEqualsIncremental() {
        // Build the incremental state.
        var incremental = MatrixTier()
        let rowA = UUID()
        let rowB = UUID()
        let captures: [(UUID, [(String, UInt64)], HLC)] = [
            (rowA, [("bm.alpha", 0b101), ("bm.beta",  0b10)], hlc(100)),
            (rowB, [("bm.alpha", 0b100), ("bm.beta",  0b11)], hlc(200)),
        ]
        for (row, fields, h) in captures {
            incremental.applyCapture(bitmapFields: fields, hlc: h)
            _ = row
        }

        // Build the audit log carrying the same captures.
        var log = UnifiedAuditLog()
        for (row, fields, h) in captures {
            for (path, bm) in fields {
                log.add(captureEntry(
                    row: row,
                    field: path,
                    value: .bitmap(bm),
                    at: h
                ))
            }
        }

        let rebuilt = MatrixTier.rebuild(from: log)

        #expect(rebuilt.liveRowCount == incremental.liveRowCount)
        #expect(rebuilt.fieldPresence == incremental.fieldPresence)
        #expect(rebuilt.coOccurrence == incremental.coOccurrence)
    }

    // MARK: - Incremental hydration conformance (persist + load-forward)

    /// For EVERY split point, a snapshot `fullRebuild(prefix)` then
    /// `incrementalUpdate(fullLog)` must equal `fullRebuild(fullLog)` cell-for-
    /// cell — F, O, T, liveRowCount, and both HLC cursors (MatrixTier is
    /// Equatable over all of them). This proves loading a persisted snapshot and
    /// folding only the tail forward is identical to a from-scratch rebuild, so
    /// the matrix tier can be read from disk instead of recomputed on launch.
    ///
    /// Exercises a CROSS-CURSOR expunge (rowA captured before the split, expunged
    /// after) and a withdraw — precisely the cases a naive delta-rebuild-then-
    /// merge corrupts (liveRowCount clamps at 0; a fresh delta tier never saw the
    /// original capture).
    @Test
    func incrementalUpdateMatchesFullRebuildAtEverySplit() {
        let rowA = UUID(), rowB = UUID(), rowC = UUID(), rowD = UUID()
        func cap(_ row: UUID, _ field: String, _ bm: UInt64, _ at: HLC) -> UnifiedAuditEntry {
            UnifiedAuditEntry(tier: .locus, hlc: at, verb: .capture, rowID: row,
                              fieldPath: field, beforeValue: .null, afterValue: .bitmap(bm))
        }
        func exp(_ row: UUID, _ field: String, _ bm: UInt64, _ at: HLC) -> UnifiedAuditEntry {
            UnifiedAuditEntry(tier: .locus, hlc: at, verb: .expunge, rowID: row,
                              fieldPath: field, beforeValue: .bitmap(bm), afterValue: .bitmap(bm))
        }
        func wdr(_ row: UUID, _ at: HLC) -> UnifiedAuditEntry {
            UnifiedAuditEntry(tier: .locus, hlc: at, verb: .withdraw, rowID: row,
                              fieldPath: "bm.a", beforeValue: .null, afterValue: .null)
        }
        // Ordered audit history. HLCs spread wide so some temporal pairs fall
        // inside the 256-minute T window and some outside.
        let entries: [UnifiedAuditEntry] = [
            cap(rowA, "bm.a", 0b101, hlc(1_000)),
            cap(rowB, "bm.a", 0b001, hlc(2_000)),
            cap(rowB, "bm.b", 0b010, hlc(2_000)),
            cap(rowC, "bm.a", 0b111, hlc(3_000)),
            exp(rowA, "bm.a", 0b101, hlc(4_000)),    // cross-cursor expunge of rowA
            wdr(rowB,            hlc(5_000)),          // withdraw rowB
            cap(rowD, "bm.a", 0b011, hlc(6_000)),
            cap(rowD, "bm.b", 0b100, hlc(6_000)),
        ]
        var fullLog = UnifiedAuditLog()
        for e in entries { fullLog.add(e) }
        let full = MatrixTier.fullRebuild(from: fullLog)

        // Only split at whole-HLC boundaries (plus the full set). A row's
        // multi-field capture is one atomic transaction: every field emits a
        // UnifiedAuditEntry stamped with that row's single HLC. A snapshot is
        // taken by the dreaming pass over COMMITTED state, so its watermark
        // (lastHLC / temporalWatermarkHLC) always lands on a complete row —
        // never between two fields of the same capture. The incremental cursor
        // is therefore whole-HLC by design (`hlc > cursor`, matching the T fold's
        // emit gate; `>=` would double-count). Splitting mid-HLC here would
        // simulate persisting a snapshot in the middle of one atomic capture,
        // which cannot occur — so those split points are excluded, not "fixed".
        let splitPoints = (1...entries.count).filter { k in
            k == entries.count || entries[k - 1].hlc != entries[k].hlc
        }
        for k in splitPoints {
            var prefixLog = UnifiedAuditLog()
            for e in entries.prefix(k) { prefixLog.add(e) }
            var snapshot = MatrixTier.fullRebuild(from: prefixLog)   // persisted state
            snapshot.incrementalUpdate(from: fullLog)                // load-forward
            #expect(snapshot.fieldPresence == full.fieldPresence, "F differs at split \(k)")
            #expect(snapshot.coOccurrence == full.coOccurrence, "O differs at split \(k)")
            #expect(snapshot.liveRowCount == full.liveRowCount,
                    "liveRowCount differs at split \(k): \(snapshot.liveRowCount) vs \(full.liveRowCount)")
            #expect(snapshot.lastHLC == full.lastHLC, "lastHLC differs at split \(k)")
            #expect(snapshot.temporalWatermarkHLC == full.temporalWatermarkHLC,
                    "temporalWatermark differs at split \(k)")
            let tExtra = snapshot.temporalCausality.filter { full.temporalCausality[$0.key] != $0.value }
            let tMissing = full.temporalCausality.filter { snapshot.temporalCausality[$0.key] != $0.value }
            #expect(tExtra.isEmpty && tMissing.isEmpty,
                    "T differs at split \(k): \(tExtra.count) wrong/extra, \(tMissing.count) missing — e.g. extra \(tExtra.first.map { "\($0.value)" } ?? "-"), missing \(tMissing.first.map { "\($0.value)" } ?? "-")")
        }
    }

    // MARK: - Persistence

    @Test
    func inMemoryModeRebuildsButDoesNotPersist() throws {
        var log = UnifiedAuditLog()
        let row = UUID()
        log.add(captureEntry(row: row, field: "bm.x",
                             value: .bitmap(0b11), at: hlc(1)))

        let backend = MatrixPersistenceBackend(mode: .inMemory)
        let snap = try backend.rebuild(from: log)
        #expect(snap.tier.liveRowCount == 1)
        // .inMemory load always returns nil — no on-disk state.
        #expect(try backend.load() == nil)
    }

    @Test
    func snapshottedModeRoundTripsExactly() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("matrix-snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var log = UnifiedAuditLog()
        let row1 = UUID()
        let row2 = UUID()
        log.add(captureEntry(row: row1, field: "bm.a",
                             value: .bitmap(0b1011), at: hlc(10)))
        log.add(captureEntry(row: row2, field: "bm.a",
                             value: .bitmap(0b0011), at: hlc(20)))
        log.add(captureEntry(row: row2, field: "bm.b",
                             value: .bitmap(0b1100), at: hlc(20)))

        let backend = MatrixPersistenceBackend(
            mode: .snapshotted(file: tmp)
        )
        let snap1 = try backend.rebuild(from: log)

        let backend2 = MatrixPersistenceBackend(
            mode: .snapshotted(file: tmp)
        )
        let loaded = try backend2.load()
        #expect(loaded != nil)
        #expect(loaded?.tier == snap1.tier)
        #expect(loaded?.calibration == snap1.calibration)
        #expect(loaded?.hlcWatermark == snap1.hlcWatermark)
    }

    @Test
    func persistenceModesAgreeOnTier() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("matrix-eq-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var log = UnifiedAuditLog()
        let row1 = UUID()
        let row2 = UUID()
        log.add(captureEntry(row: row1, field: "bm.x",
                             value: .bitmap(0b1), at: hlc(1)))
        log.add(captureEntry(row: row2, field: "bm.x",
                             value: .bitmap(0b1), at: hlc(2)))
        log.add(captureEntry(row: row2, field: "bm.y",
                             value: .bitmap(0b10), at: hlc(2)))

        let mem = MatrixPersistenceBackend(mode: .inMemory)
        let snap = MatrixPersistenceBackend(mode: .snapshotted(file: tmp))

        let memOut = try mem.rebuild(from: log)
        let snapOut = try snap.rebuild(from: log)

        #expect(memOut.tier == snapOut.tier,
                "both modes must produce the same matrix tier")
    }

    // MARK: - Conformance: boundary prune (Finding #4) + backdated eventTime (Finding #3)

    /// Finding #4 conformance (codex 98a790c2): incremental T rebuild must keep
    /// sources that are exactly at the boundary of the corrected prune cutoff.
    ///
    /// The fold keeps a source S when floor((T − S) / 60_000) <= windowMinutes,
    /// so the maximum kept delta is windowMinutes*60_000 + 59_999 ms. The prune
    /// cutoff must be `watermark − (windowMinutes+1)*60_000 + 1` so sources in
    /// that last 59_999-ms slice are not silently dropped.
    ///
    /// Setup: three entries A, B, C with raw HLC (no eventTimes override).
    ///   A at   600_000 ms — the vulnerable source (within correct window of C
    ///                        but below the old over-strict cutoff).
    ///   B at 16_000_000 ms — establishes the snapshot watermark.
    ///   C at 16_000_001 ms — new entry that should pair with A.
    ///
    /// With window = 256 minutes (15_360_000 ms), watermark = 16_000_000:
    ///   old cutoff: 16_000_000 − 15_360_000 = 640_000  → A(600_000) DROPPED
    ///   new cutoff: 16_000_000 − 15_419_999 = 580_001  → A(600_000) KEPT ✓
    ///
    /// Delta (C.clock − A.clock) = 15_400_001 ms → deltaMin = 256 → bucket 128.
    @Test
    func temporalBoundarySourceNotPrunedIncrementalEqualsFullRebuild() {
        // A is in the 59_999-ms vulnerable zone between old and new cutoff.
        let hA = hlc(600_000)      // source (in vulnerable zone)
        let hB = hlc(16_000_000)   // entry that will establish snapshot watermark
        let hC = hlc(16_000_001)   // new entry; should pair with A

        let rowA = UUID(), rowB = UUID(), rowC = UUID()

        // Full log: A, B, C.
        var fullLog = UnifiedAuditLog()
        fullLog.add(captureEntry(row: rowA, field: "f.src", value: .bitmap(1), at: hA))
        fullLog.add(captureEntry(row: rowB, field: "f.mid", value: .bitmap(2), at: hB))
        fullLog.add(captureEntry(row: rowC, field: "f.tgt", value: .bitmap(3), at: hC))

        // Full rebuild is ground truth.
        let full = MatrixTier.fullRebuild(from: fullLog)

        // Snapshot = fullRebuild(A + B) only; C has not arrived yet.
        var prefixLog = UnifiedAuditLog()
        prefixLog.add(captureEntry(row: rowA, field: "f.src", value: .bitmap(1), at: hA))
        prefixLog.add(captureEntry(row: rowB, field: "f.mid", value: .bitmap(2), at: hB))
        var snapshot = MatrixTier.fullRebuild(from: prefixLog)

        // Fold C forward onto the snapshot.
        snapshot.incrementalUpdate(from: fullLog)

        // T must be cell-for-cell equal to fullRebuild.
        let tExtra = snapshot.temporalCausality.filter { full.temporalCausality[$0.key] != $0.value }
        let tMissing = full.temporalCausality.filter { snapshot.temporalCausality[$0.key] != $0.value }
        #expect(tExtra.isEmpty && tMissing.isEmpty,
                "boundary-zone source A must produce A→C T cell: \(tExtra.count) extra, \(tMissing.count) missing")

        // The A→C pair must exist in both (bucket 128: 256-minute lag).
        let aCoord = MatrixValueCoord(fieldPath: "f.src", value: .bitmap(1))
        let cCoord = MatrixValueCoord(fieldPath: "f.tgt", value: .bitmap(3))
        let expectedKey = MatrixTemporalKey(source: aCoord, target: cCoord, lagBucket: 128)
        #expect(full.temporalCausality[expectedKey] == 1,
                "fullRebuild must contain A→C at bucket 128")
        #expect(snapshot.temporalCausality[expectedKey] == 1,
                "incrementalUpdate must contain A→C at bucket 128 after boundary fix")
    }

    /// Finding #3 conformance (codex 7af07c48): a row captured after the snapshot
    /// but with an eventTime before the temporal watermark must trigger the
    /// backdated fallback, producing a T matrix equal to fullRebuild.
    ///
    /// Setup (using eventTimes map to supply authored-in-world clocks):
    ///   A: captureHLC = hlc(1_000), eventTime = 1_000_000 ms  ← earlier world time
    ///   Snapshot = fullRebuild([A], eventTimes={A→1_000_000}).
    ///     → T is empty (one entry). temporalWatermarkHLC = hlc_evtime(1_000_000).
    ///   B: captureHLC = hlc(5_000), eventTime =   900_000 ms  ← BACKDATED
    ///   incrementalUpdate([A, B], eventTimes={A→1_000_000, B→900_000}):
    ///     B is new (captureHLC 5_000 > lastHLC 1_000) but its substituted
    ///     clock (900_000) <= watermark (1_000_000) → backdated → full T rebuild.
    ///   fullRebuild([A, B], eventTimes=…):
    ///     sorted by eventTime: B(900_000) then A(1_000_000).
    ///     deltaMs = 100_000, deltaMin = 1, bucket = 1.
    ///     T = {B→A, bucket 1: 1}.
    @Test
    func backdatedEventTimeTriggersFullTemporalRebuildIncrementalEqualsFullRebuild() {
        let rowA = UUID(), rowB = UUID()

        // Capture HLCs (monotonic capture order).
        let capHLCA = hlc(1_000)
        let capHLCB = hlc(5_000)

        // Authored-in-world times (ms): A is later in world time, B is backdated.
        let evtA: Int64 = 1_000_000
        let evtB: Int64 =   900_000   // before A in world time

        var eventTimes: [UUID: Int64] = [rowA: evtA, rowB: evtB]

        // Prefix log: only A.
        var prefixLog = UnifiedAuditLog()
        prefixLog.add(captureEntry(row: rowA, field: "f.src", value: .bitmap(10), at: capHLCA))
        var snapshot = MatrixTier.fullRebuild(from: prefixLog, eventTimes: eventTimes)
        // Single entry → T is empty; watermark is in eventTime space (1_000_000 ms).
        #expect(snapshot.temporalCausality.isEmpty,
                "single-entry snapshot must have empty T")

        // Full log: A + B (B backdated in world time).
        var fullLog = UnifiedAuditLog()
        fullLog.add(captureEntry(row: rowA, field: "f.src", value: .bitmap(10), at: capHLCA))
        fullLog.add(captureEntry(row: rowB, field: "f.tgt", value: .bitmap(20), at: capHLCB))

        // Ground truth.
        let full = MatrixTier.fullRebuild(from: fullLog, eventTimes: eventTimes)

        // Incremental fold on the snapshot — must produce the same T as fullRebuild.
        snapshot.incrementalUpdate(from: fullLog, eventTimes: eventTimes)

        let tExtra = snapshot.temporalCausality.filter { full.temporalCausality[$0.key] != $0.value }
        let tMissing = full.temporalCausality.filter { snapshot.temporalCausality[$0.key] != $0.value }
        #expect(tExtra.isEmpty && tMissing.isEmpty,
                "backdated eventTime: incremental must equal fullRebuild — \(tExtra.count) extra, \(tMissing.count) missing")

        // Expected: B(900_000) → A(1_000_000), delta 100_000 ms → 1 min → bucket 1.
        let bCoord = MatrixValueCoord(fieldPath: "f.tgt", value: .bitmap(20))
        let aCoord = MatrixValueCoord(fieldPath: "f.src", value: .bitmap(10))
        let expectedKey = MatrixTemporalKey(source: bCoord, target: aCoord, lagBucket: 1)
        #expect(full.temporalCausality[expectedKey] == 1,
                "fullRebuild must contain B→A at bucket 1")
        #expect(snapshot.temporalCausality[expectedKey] == 1,
                "incrementalUpdate must contain B→A at bucket 1 after backdated fallback")
    }

    // MARK: - Calibration

    @Test
    func calibrationDeflatesOverconfidence() {
        var registry = MatrixCalibrationRegistry()
        // Bucket 16 covers [0.80, 0.85). Feed 4 failures.
        for _ in 0..<4 {
            registry.record(modelID: "test.model",
                            claimedConfidence: 0.82,
                            outcome: .failure)
        }
        // And one success.
        registry.record(modelID: "test.model",
                        claimedConfidence: 0.82,
                        outcome: .success)
        let calibrated = registry.calibrate(modelID: "test.model",
                                            claimedConfidence: 0.82)
        #expect(abs(calibrated - 0.2) <= 1e-5)
        // Unknown model passes through.
        #expect(abs(registry.calibrate(modelID: "unknown",
                                       claimedConfidence: 0.5) - 0.5) <= 1e-9)
    }

    // MARK: - NMF

    @Test
    func nmfApproximatesInputMatrix() {
        // 3 × 3 rank-1-ish matrix; K = 1 should reconstruct closely.
        // MatrixNMF delegates to SubstrateML.NMFAlternatingLeastSquares (f32, RMS
        // error). For a perfect rank-1 input, the RMS error converges to 0.0.
        let o: [Double] = [
            1, 2, 3,
            2, 4, 6,
            3, 6, 9
        ]
        let f = MatrixNMF.factorize(
            o: o, rows: 3, cols: 3, k: 1,
            maxIterations: 200,
            tolerance: 1e-9
        )
        // RMS error from the canonical f32 substrate path: 0.0 for perfect rank-1.
        // The bound < 1e-3 is satisfied.
        #expect(f.reconstructionError < 1e-3,
            "rank-1 input should reconstruct with low RMS error via substrate NMF")
        // Loadings for row 0 should be a single-K vector (Float32).
        #expect(f.loadings(forRow: 0).count == 1)
    }

    @Test
    func nmfDeterministicAcrossRuns() {
        // Two calls with the same seed produce bit-identical Float32 W and H
        // via the canonical substrate NMFAlternatingLeastSquares.
        let o: [Double] = [1, 2, 3, 4]
        let a = MatrixNMF.factorize(o: o, rows: 2, cols: 2, k: 2,
                                    seed: 42, maxIterations: 20)
        let b = MatrixNMF.factorize(o: o, rows: 2, cols: 2, k: 2,
                                    seed: 42, maxIterations: 20)
        #expect(a.w == b.w)
        #expect(a.h == b.h)
    }
}
