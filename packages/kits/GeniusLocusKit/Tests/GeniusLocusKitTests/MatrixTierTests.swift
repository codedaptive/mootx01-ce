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
