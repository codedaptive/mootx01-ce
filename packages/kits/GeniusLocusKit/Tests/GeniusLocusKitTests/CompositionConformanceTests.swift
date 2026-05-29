// CompositionConformanceTests.swift
//
// Mission GLK-08 — composition conformance fixtures that prove the
// whole GeniusLocusKit stack holds together over multiple estates.
//
// The composed stack landed in GLK-01 through GLK-07. This file
// exercises the surfaces that compose them — multi-estate
// coordination (GLK-01), the unified nine-verb surface (GLK-02), the
// unified audit log and projection (GLK-03), the standing-signal
// scheduler (GLK-04 / GLK-05), the matrix tier (GLK-06), and the
// training daemon (GLK-07) — in one fixture per composition
// invariant. Where a single existing test covers one slice in
// isolation, the fixtures here connect slices into the end-to-end
// shape Mission 8's done-definition asks for.
//
// All-new fixtures, no production code modified.

import XCTest
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
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
import SubstrateLib
@testable import GeniusLocusKit

final class CompositionConformanceTests: XCTestCase {

    // MARK: - Fixtures

    /// Build an in-memory storage with custom zoom window, mirroring
    /// the pattern used by `CrossEstateOverlapTests`. The fan-out
    /// behaviour depends on the window the manifest carries, so the
    /// fixture writes the window through `DrawerStore.setMeta` before
    /// the estate is created.
    private func storage(zoomLow low: Int, high: Int) async throws -> InMemoryStorage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        let store = try await DrawerStore(storage: storage)
        try await store.setMeta(key: "zoom_window_low", value: String(low))
        try await store.setMeta(key: "zoom_window_high", value: String(high))
        return storage
    }

    private func captureFrame(tag: String, room: RoomID) -> CaptureFrame {
        CaptureFrame(
            content: "content-\(tag)",
            channel: .typed,
            room: room,
            latticeAnchor: .udc("004"),
            addedBy: "composition-conformance",
            embeddingModelID: "model-v1"
        )
    }

    // MARK: - Multi-estate composition

    /// Opens three estates with disjoint and overlapping windows,
    /// captures into each, and asserts the composition invariants the
    /// implementation plan calls out: per-handle access reaches one
    /// estate, fan-out routing respects lattice overlap, and storage
    /// isolation holds between estates. This is the GLK-01 +
    /// GLK-02 surface composed end-to-end.
    func testMultiEstateCaptureFanOutAndStorageIsolation() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-composition")

        let sA = try await storage(zoomLow: 0, high: 10)
        let sB = try await storage(zoomLow: 5, high: 15)
        let sC = try await storage(zoomLow: 20, high: 30)
        _ = try await LocusKit.Estate.create(storage: sA, owner: owner)
        _ = try await LocusKit.Estate.create(storage: sB, owner: owner)
        _ = try await LocusKit.Estate.create(storage: sC, owner: owner)
        let hA = try await kit.open(storage: sA, owner: owner)
        let hB = try await kit.open(storage: sB, owner: owner)
        let hC = try await kit.open(storage: sC, owner: owner)
        defer {
            Task {
                try? await kit.close(hA); try? await kit.close(hB); try? await kit.close(hC)
            }
        }

        // Per-handle access reaches one estate each.
        let dA = try await kit.capture(hA, captureFrame(tag: "a", room: "room-a"))
        let dB = try await kit.capture(hB, captureFrame(tag: "b", room: "room-b"))
        let dC = try await kit.capture(hC, captureFrame(tag: "c", room: "room-c"))

        // Fan-out routing. Region [4, 8] overlaps the two low estates,
        // skips the high estate. Each contribution carries its own
        // captured drawer; the disjoint estate is not consulted.
        let recall = RecallFrame(filterChain: [.unconfirmed])
        let contributions = try await kit.fanOutRecall(
            recall, region: LatticeRegion(low: 4, high: 8))
        let byHandle = Dictionary(uniqueKeysWithValues: contributions.map { ($0.handle, $0) })
        XCTAssertEqual(contributions.count, 2,
            "two estates overlap [4,8]; high estate must not be consulted")
        XCTAssertNotNil(byHandle[hA])
        XCTAssertNotNil(byHandle[hB])
        XCTAssertNil(byHandle[hC])

        // Storage isolation. Each estate's captured drawer must not
        // appear in any other estate's contribution. This is the
        // per-storage-instance invariant the coordinator preserves.
        let idsA = Set(byHandle[hA]!.drawers.map(\.id))
        let idsB = Set(byHandle[hB]!.drawers.map(\.id))
        XCTAssertTrue(idsA.contains(dA.id), "estate A contributes its own drawer")
        XCTAssertTrue(idsB.contains(dB.id), "estate B contributes its own drawer")
        XCTAssertFalse(idsA.contains(dB.id), "estate A does not see B's drawer")
        XCTAssertFalse(idsB.contains(dA.id), "estate B does not see A's drawer")
        XCTAssertFalse(idsA.contains(dC.id),
                       "estate C is disjoint from the recall region — its drawer cannot leak")
    }

    // MARK: - Audit projection across both tiers

    /// Composes GLK-03 (unified audit log) with GLK-06's matrix tier
    /// over a log that interleaves entries from both storage tiers.
    /// The projection must key per `(tier, rowID)` so cross-tier UUID
    /// collisions do not collapse rows; the matrix tier's enrichment
    /// pass must fold both tiers' entries.
    func testUnifiedAuditProjectionAndEnrichmentFoldBothTiers() {
        var log = UnifiedAuditLog()

        // Three rows in the locus tier, two in the rag tier. The HLCs
        // interleave to exercise the cross-tier ordering invariant.
        let locusRowA = UUID()
        let locusRowB = UUID()
        let ragRowA = UUID()
        let ragRowB = UUID()
        let locusRowC = UUID()

        func addEntry(
            tier: AuditTier, step: Int64, verb: UnifiedAuditVerb,
            row: UUID, path: String, after: UnifiedAuditValue
        ) {
            let hlc = HLC(physicalTime: step, logicalCount: 0, nodeID: 1)
            log.add(UnifiedAuditEntry(
                tier: tier, hlc: hlc, verb: verb, rowID: row,
                fieldPath: path, beforeValue: .null, afterValue: after
            ))
        }

        addEntry(tier: .locus, step: 1, verb: .capture, row: locusRowA,
                 path: "tag_bits", after: .bitmap(0x01))
        addEntry(tier: .rag,   step: 2, verb: .capture, row: ragRowA,
                 path: "tag_bits", after: .bitmap(0x02))
        addEntry(tier: .locus, step: 3, verb: .capture, row: locusRowB,
                 path: "tag_bits", after: .bitmap(0x04))
        addEntry(tier: .rag,   step: 4, verb: .capture, row: ragRowB,
                 path: "tag_bits", after: .bitmap(0x08))
        addEntry(tier: .locus, step: 5, verb: .capture, row: locusRowC,
                 path: "tag_bits", after: .bitmap(0x10))

        let projection = AuditProjectionFold.project(log)
        XCTAssertEqual(projection.count, 5)
        XCTAssertEqual(projection.rows(in: .locus).count, 3)
        XCTAssertEqual(projection.rows(in: .rag).count, 2)

        // Composition with the matrix tier: every capture should land
        // on F-counts and bump `liveRowCount`. The enrichment pipeline
        // folds both tiers; the matrix tier itself is tier-agnostic.
        var tier = MatrixTier()
        var calibration = MatrixCalibrationRegistry()
        let pipeline = EnrichmentPipeline()
        let result = pipeline.run(log: log, tier: &tier, calibration: &calibration)
        XCTAssertEqual(result.transitionsConsidered, 5)
        XCTAssertEqual(tier.liveRowCount, 5,
                       "enrichment must fold every capture across both tiers")
        XCTAssertFalse(tier.fieldPresence.isEmpty,
                       "captures must populate F-counts")
    }

    // MARK: - Standing-signal + training-daemon composition

    /// Composes GLK-04/05 (standing-signal scheduler) with GLK-07
    /// (training daemon) on one estate: the daemon is registered as a
    /// standing signal, ticks at a controlled interval, and only
    /// enriches when the gate admits. This proves the scheduler and the
    /// daemon are interchangeable at the SignalSpec boundary.
    func testTrainingDaemonRegistersAsStandingSignalAndGatesProperly() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-daemon-composition")
        let storage = try await self.storage(zoomLow: 0, high: 100)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        defer {
            Task { try? await kit.close(handle) }
        }

        // Synthesise a small audit log so the gate trips only after the
        // log grows past the threshold.
        let logBox = AuditLogBox()
        for i in 0..<4 {
            logBox.append(verb: .capture, row: UUID(),
                          step: Int64(i + 1),
                          after: .bitmap(UInt64(1) << (i % 8)))
        }
        let tierBox = MatrixTierBox()
        let calibBox = CalibrationBox()
        let daemon = TrainingDaemon(
            gate: TrainingThresholdGate(transitionThreshold: 8))

        let spec = SignalSpec(
            name: "training.composition",
            trigger: .interval(seconds: 0.001),
            emit: { _ in
                let tick = await daemon.runOnce(
                    log: logBox.read(),
                    tier: &tierBox.value,
                    calibration: &calibBox.value)
                return [
                    .diagnostic(DiagnosticReport(
                        title: "training.composition.tick",
                        detail: "active=\(tick.decision.isActive) " +
                                "transitions=\(tick.decision.transitionCount)",
                        observedAt: Date(timeIntervalSince1970: 0)))
                ]
            })
        _ = try await kit.registerStandingSignal(
            spec, in: handle, now: Date(timeIntervalSince1970: 0))

        // Tick once with the small log — gate dormant.
        try await kit.signalTick(in: handle, now: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(tierBox.value.liveRowCount, 0,
                       "below-threshold daemon must not enrich")

        // Grow the log past the threshold and tick again — gate active.
        for i in 4..<10 {
            logBox.append(verb: .capture, row: UUID(),
                          step: Int64(i + 1),
                          after: .bitmap(UInt64(1) << (i % 8)))
        }
        try await kit.signalTick(in: handle, now: Date(timeIntervalSince1970: 120))
        XCTAssertEqual(tierBox.value.liveRowCount, 10,
                       "above-threshold daemon must enrich on next tick")
    }

    // MARK: - Verb surface composition

    /// Exercises the GLK verb surface end-to-end on one estate:
    /// capture lands a drawer, recall returns it, withdraw moves it to
    /// the withdrawn state and the recall filter chain agrees with the
    /// new state. This proves the unified nine-verb surface composes
    /// with the storage backend correctly.
    func testCaptureRecallWithdrawComposeOverOneEstate() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-verb-composition")
        let storage = try await self.storage(zoomLow: 0, high: 100)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        defer {
            Task { try? await kit.close(handle) }
        }

        let captured = try await kit.capture(handle,
            captureFrame(tag: "verb", room: "verb-room"))

        // Recall with `.unconfirmed` because freshly captured drawers
        // have provenance==0; default-prepend `.userConfirmed` would
        // prune them before the verb surface returned.
        let recalled = try await kit.recall(handle,
            RecallFrame(filterChain: [.unconfirmed]))
        XCTAssertTrue(recalled.map(\.id).contains(captured.id),
                      "captured drawer must appear in the recall result")

        // Withdraw and re-recall scoped to `.state(.active)`. The
        // withdrawn drawer's state axis moves to `.withdrawn`, so the
        // `.state(.active)` predicate must prune it. A second recall
        // scoped to `.state(.withdrawn)` must return it.
        try await kit.withdraw(handle,
            WithdrawFrame(rowID: captured.id, reason: "composition-test"))
        let stillActive = try await kit.recall(handle,
            RecallFrame(filterChain: [.unconfirmed, .state(.active)]))
        XCTAssertFalse(stillActive.contains(where: { $0.id == captured.id }),
                       "withdrawn drawer must not surface under .state(.active)")
        let nowWithdrawn = try await kit.recall(handle,
            RecallFrame(filterChain: [.unconfirmed, .state(.withdrawn)]))
        XCTAssertTrue(nowWithdrawn.contains(where: { $0.id == captured.id }),
                      "withdrawn drawer must surface under .state(.withdrawn)")
    }
}

// MARK: - Mutable boxes

/// The standing-signal emit closure captures these by reference so the
/// scheduler-driven daemon can observe and mutate test state across
/// ticks. Mirrors the boxes used in `TrainingDaemonTests`.
private final class AuditLogBox: @unchecked Sendable {
    private var current = UnifiedAuditLog()

    func read() -> UnifiedAuditLog { current }

    func append(verb: UnifiedAuditVerb,
                row: UUID,
                step: Int64,
                after: UnifiedAuditValue) {
        let hlc = HLC(physicalTime: step, logicalCount: 0, nodeID: 1)
        current.add(UnifiedAuditEntry(
            tier: .locus, hlc: hlc, verb: verb, rowID: row,
            fieldPath: "tag_bits", beforeValue: .null, afterValue: after
        ))
    }
}

private final class MatrixTierBox: @unchecked Sendable {
    var value: MatrixTier = MatrixTier()
}

private final class CalibrationBox: @unchecked Sendable {
    var value: MatrixCalibrationRegistry = MatrixCalibrationRegistry()
}
