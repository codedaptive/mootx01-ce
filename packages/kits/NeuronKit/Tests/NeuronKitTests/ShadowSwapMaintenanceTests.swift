// ShadowSwapMaintenanceTests.swift
//
// Tests for the shadow-swap maintenance seam (VEC-SHADOWSWAP-01, UNIT C):
//
//   n3 (probe-error): THETA probe-error catch path fires the retrain hook
//          unconditionally when probe.vocabAnchor() throws. This is the
//          inherited F-4 behavior (recorded in BRR §F-4): a probe error cannot
//          silently skip a needed retrain. After this mission the retrain fires
//          a full shadow swap internally. The test name must say "probe-error".
//
//   n5 (production-adapter): EstateHNSWGraphMaintenance.reclaimSupersededGenerations
//          driven against a REAL VectorStore (in-memory backend). Superseded-
//          generation rows inserted before publish are deleted by reclaim; the
//          test counts rows before and after to confirm the deletion happened at
//          the storage layer, not just through the fake's counter.

import Testing
import Foundation
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
@testable import NeuronKit

// MARK: - Fakes

/// Recording hook: captures retrain timestamps so tests can assert the hook fired.
private actor FakeThetaRetrainHookSS: ThetaBasisRetrainHook {
    private(set) var retrainCalls: [Date] = []
    var retrainCount: Int { retrainCalls.count }

    func retrain(now: Date) async throws {
        retrainCalls.append(now)
    }
}

/// Growth probe that throws on every call — simulates a broken counts store.
private actor ThrowingGrowthProbe: CorpusGrowthProbe {
    private struct ProbeError: Error {}

    func vocabAnchor() async throws -> Int {
        throw ProbeError()
    }

    func reindex(now: Date) async throws {
        // Not reached via the throwing path; no-op for conformance.
    }
}

/// Minimal fakes for building a DreamingDaemon in this file.

private actor SSFakeReader: DreamingSubstrateReader {
    func recentRecallTraces(since _: Date, now _: Date) async throws -> [RecallTraceItem] { [] }
    func drainDreamingWindow() async throws -> [[String]] { [] }
    func existingTunnels() async throws -> [Tunnel] { [] }
    func dreamedActiveTunnels() async throws -> [Tunnel] { [] }
}

private actor SSFakeSink: DreamingProposalSink {
    func propose(_ frame: ProposeFrame) async throws {}
    func recordCycleDiary(_ entry: DiaryEntry) async throws {}
    func pruneRecallTraces(olderThan _: Date) async throws -> Int { 0 }
}

// MARK: - Helpers

/// Create a DreamingDaemon with a throwing growth probe and a recording theta retrain hook.
/// No hnswMaintenance — this test focuses on the THETA retrain behavior.
private func makeThetaDaemonWithProbeAndHook(
    probe: any CorpusGrowthProbe,
    hook: any ThetaBasisRetrainHook
) -> DreamingDaemon {
    let store = InMemoryDreamingPolicyStore(.default)
    let reader = SSFakeReader()
    let sink = SSFakeSink()
    return DreamingDaemon(
        reader: reader,
        sink: sink,
        rewardSource: RecallTraceRewardSource(),
        policyStore: store,
        growthProbe: probe,
        thetaRetrainHook: hook
    )
}

/// Count all rows in a table using the storage's count method.
private func rowCount(_ storage: InMemoryStorage, table: String) async throws -> Int {
    try await storage.rowStore.count(table: table, where: .isTrue)
}

// MARK: - Suite

@Suite("ShadowSwap maintenance — n3 probe-error, n5 production adapter")
struct ShadowSwapMaintenanceTests {

    // ── n3: probe-error case — THETA fires retrain unconditionally ────────

    /// When the growth probe throws on vocabAnchor(), the THETA drift gate's
    /// catch block fires the retrain hook unconditionally (F-4, BRR §F-4).
    /// A probe error cannot silently skip a needed retrain. After this mission
    /// the retrain calls through to the engine's reindex, which performs a shadow
    /// swap internally — but the seam under test here is the catch → retrain path.
    @Test("n3 probe-error: THETA error branch fires retrain hook when probe.vocabAnchor throws")
    func n3_probeErrorThetaFiresRetrain() async throws {
        let hook = FakeThetaRetrainHookSS()
        let probe = ThrowingGrowthProbe()
        let daemon = makeThetaDaemonWithProbeAndHook(probe: probe, hook: hook)
        let now = Date(timeIntervalSinceReferenceDate: 20_000_000)

        // runThetaCycle drives fireTheta, which calls probe.vocabAnchor().
        // When that throws, the catch block falls through to hook.retrain().
        _ = try await daemon.runThetaCycle(now: now)

        let count = await hook.retrainCount
        #expect(count == 1,
            "n3 probe-error: retrain hook must fire unconditionally when probe.vocabAnchor throws (F-4)")
    }

    // ── n5: production-adapter test — rows actually deleted at storage layer ─

    /// EstateHNSWGraphMaintenance.reclaimSupersededGenerations is driven against a
    /// REAL VectorStore (in-memory backend). Superseded-generation rows written
    /// during a shadow build are deleted by reclaim; the test counts rows before
    /// and after the call to confirm the deletion at the storage layer.
    ///
    /// Setup:
    ///   1. Write 3 vectors under serving generation 0 (model "model-v1").
    ///   2. beginShadowGeneration → shadow = 1.
    ///   3. Write 3 vectors under shadow generation 1.
    ///   4. publishShadowGeneration → serving = 1, old rows 'pending-reclaim'.
    ///   5. Total rows in vectors table = 6 (3 gen-0 + 3 gen-1).
    ///   6. Create EstateHNSWGraphMaintenance; call reclaimSupersededGenerations.
    ///   7. Total rows in vectors table = 3 (gen-0 rows deleted; gen-1 serving).
    @Test("n5 production-adapter: reclaimSupersededGenerations deletes superseded rows from real VectorStore")
    func n5_productionAdapterDeletesSupersededRows() async throws {
        // ── Storage and VectorStore setup ─────────────────────────────────
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        try await storage.migrate(to: VectorStore.schemaDeclaration)
        let store = VectorStore(storage: storage)

        let modelID = "reclaim-test-model"
        let now = Date(timeIntervalSinceReferenceDate: 21_000_000)

        // ── Phase 1: write 3 serving-generation (gen 0) vectors ──────────
        for i in 0..<3 {
            try await store.addPayload(
                itemID: "item-\(i)",
                vectorIndex: 0,
                payload: VectorPayload(kind: .binary, dim: 256, bytes: [UInt8](repeating: 0, count: 32)),
                modelID: modelID,
                modelVersion: "1",
                filedAt: now
            )
        }

        let rowsAfterInitial = try await rowCount(storage, table: "vectors")
        #expect(rowsAfterInitial == 3, "n5: 3 serving rows written (gen 0)")

        // ── Phase 2: open shadow generation ──────────────────────────────
        let gens = try await store.beginShadowGeneration(modelIDs: [modelID])
        let shadowGen = try #require(gens[modelID])
        #expect(shadowGen == 1, "n5: first shadow generation must be 1")

        // ── Phase 3: write 3 shadow-generation (gen 1) vectors ───────────
        for i in 3..<6 {
            try await store.addPayload(
                itemID: "item-\(i)",
                vectorIndex: 0,
                payload: VectorPayload(kind: .binary, dim: 256, bytes: [UInt8](repeating: 1, count: 32)),
                modelID: modelID,
                modelVersion: "1",
                filedAt: now
            )
        }

        let rowsAfterShadow = try await rowCount(storage, table: "vectors")
        #expect(rowsAfterShadow == 6,
            "n5: 6 total rows — 3 serving (gen 0) + 3 shadow (gen 1)")

        // ── Phase 4: publish — flip serving to gen 1, gen 0 → pending-reclaim
        try await store.publishShadowGeneration(modelIDs: [modelID])

        let rowsAfterPublish = try await rowCount(storage, table: "vectors")
        #expect(rowsAfterPublish == 6,
            "n5: rows unchanged immediately after publish (old gen rows still on disk)")

        // ── Phase 5: reclaim via EstateHNSWGraphMaintenance ──────────────
        let maintenance = EstateHNSWGraphMaintenance(vectorStore: store)
        try await maintenance.reclaimSupersededGenerations(now: now)

        let rowsAfterReclaim = try await rowCount(storage, table: "vectors")
        #expect(rowsAfterReclaim == 3,
            "n5: gen-0 rows deleted by reclaim; only 3 gen-1 serving rows remain")
    }
}
