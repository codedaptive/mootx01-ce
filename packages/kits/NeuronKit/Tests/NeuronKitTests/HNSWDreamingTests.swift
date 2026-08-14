// HNSWDreamingTests.swift
//
// Conformance tests for DreamingDaemon's HNSW graph maintenance duties.
//
// Three cadences carry HNSW duties; OMEGA does not:
//
//   HM-1: ALPHA — clearFloatIndex fires after vocabulary drift triggers a
//          corpus reindex. Requires two pump() calls: the first establishes
//          the vocab baseline; the second crosses the growth trigger and fires
//          both the corpus reindex and the HNSW clear.
//
//   HM-2: THETA (consolidation path) — rebuildFloatIndex fires once.
//   HM-3: THETA (early-return / no-data path) — rebuildFloatIndex also fires.
//
//   HM-4: BETA — compactFloatIndexTombstones fires once.
//
//   HM-5: nil maintenance, THETA — cycle completes without crash; no calls.
//   HM-6: nil maintenance, BETA  — cycle completes without crash; no calls.
//
//   HM-7: THETA maintenance throws → non-fatal; cycle result is still returned.
//   HM-8: BETA  maintenance throws → non-fatal; cycle returns nil normally.
//
//   HM-9: OMEGA cycle with wired maintenance → compact is NOT called.
//          OMEGA has no HNSW duty (it retires dreamed tunnels, not graph nodes).
//
// All substrate interaction uses in-memory seam fakes. The clock is always
// injected; no wall-clock reads inside cycle code.

import Testing
import Foundation
import GeniusLocusKit
@testable import NeuronKit

// MARK: - Fake HNSWGraphMaintenance

/// Recording fake. Tracks calls to all three maintenance methods.
private actor FakeHNSWMaintenance: HNSWGraphMaintenance {

    /// Timestamps passed to `clearFloatIndex(now:)`, in call order.
    private(set) var clearCalls: [Date] = []

    /// Timestamps passed to `rebuildFloatIndex(now:)`, in call order.
    private(set) var rebuildCalls: [Date] = []

    /// Timestamps passed to `compactFloatIndexTombstones(now:)`, in call order.
    private(set) var compactCalls: [Date] = []

    /// When true, every method throws a sentinel error (non-fatal test path).
    var shouldThrow: Bool

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func clearFloatIndex(now: Date) async throws {
        if shouldThrow { throw FakeMaintenanceError() }
        clearCalls.append(now)
    }

    func rebuildFloatIndex(now: Date) async throws {
        if shouldThrow { throw FakeMaintenanceError() }
        rebuildCalls.append(now)
    }

    func compactFloatIndexTombstones(now: Date) async throws {
        if shouldThrow { throw FakeMaintenanceError() }
        compactCalls.append(now)
    }

    var clearCount:   Int { clearCalls.count }
    var rebuildCount: Int { rebuildCalls.count }
    var compactCount: Int { compactCalls.count }
}

private struct FakeMaintenanceError: Error {}

// MARK: - Fake CorpusGrowthProbe

/// Returns configurable vocab anchors on successive calls, enabling deterministic
/// trigger of the auto-reindex gate inside `runCycle` / `pump`.
///
/// Behaviour:
///   • First `vocabAnchor()` call → `firstVocab`  (sets daemon baseline, no reindex).
///   • All subsequent calls       → `laterVocab`  (triggers reindex when delta ≥ trigger).
private actor FakeGrowthProbe: CorpusGrowthProbe {

    private var callCount: Int = 0
    private let firstVocab: Int
    private let laterVocab: Int

    init(first: Int = 100, later: Int = 200) {
        self.firstVocab = first
        self.laterVocab = later
    }

    func vocabAnchor() async throws -> Int {
        callCount += 1
        return callCount == 1 ? firstVocab : laterVocab
    }

    /// No-op reindex: the daemon calls this when the growth gate fires. The
    /// probe itself does not need to do any real work; its purpose is to let
    /// the daemon advance `lastReindexVocab` and then call clearFloatIndex.
    func reindex(now: Date) async throws {}
}

// MARK: - Minimal seam fakes (shared across all tests)

/// Minimal reader: empty traces, empty drain, no existing tunnels.
private actor HNSWFakeReader: DreamingSubstrateReader {
    var traces: [RecallTraceItem]
    init(traces: [RecallTraceItem] = []) { self.traces = traces }
    func recentRecallTraces(since _: Date, now _: Date) async throws -> [RecallTraceItem] { traces }
    func drainDreamingWindow() async throws -> [[String]] { [] }
    func existingTunnels() async throws -> [Tunnel] { [] }
    func dreamedActiveTunnels() async throws -> [Tunnel] { [] }
}

/// Recording sink that captures proposals and diary writes.
private actor HNSWFakeSink: DreamingProposalSink {
    private(set) var proposals: [ProposeFrame] = []
    func propose(_ frame: ProposeFrame) async throws { proposals.append(frame) }
    func recordCycleDiary(_ entry: DiaryEntry) async throws {}
    func pruneRecallTraces(olderThan _: Date) async throws -> Int { 0 }
}

// MARK: - DreamingDaemon builders

/// Daemon wired with hnswMaintenance and an optional growthProbe.
///
/// Passes `policy: DreamingPolicy(tickIntervalMs: 1)` directly to the init so
/// consecutive pump() calls fire without needing 30-second timestamp gaps.
/// `policyStore` holds an identical policy for consistency; `pump` reads from
/// the actor's inline `policy` property, not from the store.
private func makeAlphaDaemon(
    hnsw: (any HNSWGraphMaintenance)?,
    probe: (any CorpusGrowthProbe)?
) -> DreamingDaemon {
    let fastPolicy = DreamingPolicy(tickIntervalMs: 1)
    let store = InMemoryDreamingPolicyStore(fastPolicy)
    let reader = HNSWFakeReader()
    let sink = HNSWFakeSink()
    return DreamingDaemon(
        reader: reader,
        sink: sink,
        rewardSource: RecallTraceRewardSource(),
        policyStore: store,
        policy: fastPolicy,
        growthProbe: probe,
        hnswMaintenance: hnsw
    )
}

/// Daemon wired with hnswMaintenance for THETA tests.
/// Uses two used traces so the consolidation path is taken.
private func makeThetaDaemon(
    hnsw: (any HNSWGraphMaintenance)?,
    traces: [RecallTraceItem] = []
) -> DreamingDaemon {
    let store = InMemoryDreamingPolicyStore(.default)
    let reader = HNSWFakeReader(traces: traces)
    let sink = HNSWFakeSink()
    return DreamingDaemon(
        reader: reader,
        sink: sink,
        rewardSource: RecallTraceRewardSource(),
        policyStore: store,
        hnswMaintenance: hnsw
    )
}

/// Two used recall traces: enough for the THETA consolidation path.
private func twoUsedTraces() -> [RecallTraceItem] {
    [
        RecallTraceItem(target: "drawer-1", recalledAt: Date(),
                        operationalBitmap: RecallTraceItem.flagUsed),
        RecallTraceItem(target: "drawer-2", recalledAt: Date(),
                        operationalBitmap: RecallTraceItem.flagUsed),
    ]
}

// MARK: - Tests

@Suite("HNSWGraphMaintenance — dreaming cadence integration")
struct HNSWDreamingTests {

    // ── HM-1: ALPHA clear after vocab drift ────────────────────────────────

    /// Two pump() calls are needed:
    ///   • First: lastReindexVocab is –1 (sentinel) → baseline set to firstVocab=100.
    ///     No reindex, no HNSW clear.
    ///   • Second (1 ms later): delta = laterVocab – firstVocab = 100.
    ///     Default trigger = max(25, floor(100 × 0.10)) = 25.
    ///     100 ≥ 25 → reindex fires → HNSW clearFloatIndex fires.
    @Test("HM-1: clearFloatIndex fires once after ALPHA vocab-drift reindex")
    func hm1_alphaHNSWClearFiresAfterReindex() async throws {
        let hnsw = FakeHNSWMaintenance()
        let probe = FakeGrowthProbe(first: 100, later: 200)
        let daemon = makeAlphaDaemon(hnsw: hnsw, probe: probe)

        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // First pump: sets vocab baseline (100). No reindex gate fires.
        _ = try await daemon.pump(now: t0)
        let clearAfterFirst = await hnsw.clearCount
        #expect(clearAfterFirst == 0,
            "no clear on the first pump (baseline-only cycle)")

        // Second pump: 2 seconds later. delta=100 ≥ trigger=25 → reindex + HNSW clear.
        // Use a generous interval (well above tickIntervalMs=1) to avoid floating-point
        // precision edge cases in the elapsed-milliseconds gate comparison.
        _ = try await daemon.pump(now: t0.addingTimeInterval(2.0))
        let clearAfterSecond = await hnsw.clearCount
        #expect(clearAfterSecond == 1,
            "clearFloatIndex must fire exactly once after vocab-drift reindex")
    }

    // ── HM-2: THETA consolidation path → rebuild fires ─────────────────────

    @Test("HM-2: rebuildFloatIndex fires once on the THETA consolidation path")
    func hm2_thetaRebuildFiresConsolidationPath() async throws {
        let hnsw = FakeHNSWMaintenance()
        let daemon = makeThetaDaemon(hnsw: hnsw, traces: twoUsedTraces())
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

        _ = try await daemon.runThetaCycle(now: now)

        let count = await hnsw.rebuildCount
        #expect(count == 1, "rebuildFloatIndex must fire exactly once per THETA cycle")
    }

    // ── HM-3: THETA early-return path → rebuild also fires ─────────────────

    /// Even when THETA returns early (fewer than 2 used drawers → no consolidation),
    /// fireThetaHNSWRebuild is called at BOTH exit paths of runThetaCycle.
    @Test("HM-3: rebuildFloatIndex fires once on the THETA early-return (no-data) path")
    func hm3_thetaRebuildFiresEarlyReturnPath() async throws {
        let hnsw = FakeHNSWMaintenance()
        // Empty traces → usedSet.count < 2 → early return.
        let daemon = makeThetaDaemon(hnsw: hnsw, traces: [])
        let now = Date(timeIntervalSinceReferenceDate: 3_000_000)

        let result = try await daemon.runThetaCycle(now: now)
        #expect(result == nil, "no-data THETA path must return nil")

        let count = await hnsw.rebuildCount
        #expect(count == 1, "rebuildFloatIndex must fire even on the early-return path")
    }

    // ── HM-4: BETA compact fires ────────────────────────────────────────────

    @Test("HM-4: compactFloatIndexTombstones fires once per BETA cycle")
    func hm4_betaCompactFires() async throws {
        let hnsw = FakeHNSWMaintenance()
        let daemon = makeThetaDaemon(hnsw: hnsw)
        let now = Date(timeIntervalSinceReferenceDate: 4_000_000)

        _ = try await daemon.runBetaCycle(now: now)

        let count = await hnsw.compactCount
        #expect(count == 1, "compactFloatIndexTombstones must fire exactly once per BETA cycle")
    }

    // ── HM-5: nil maintenance, THETA — no crash ─────────────────────────────

    @Test("HM-5: nil hnswMaintenance — THETA cycle completes without crash")
    func hm5_nilMaintenanceThetaNoOp() async throws {
        // daemon with no hnswMaintenance (default nil)
        let daemon = makeThetaDaemon(hnsw: nil, traces: twoUsedTraces())
        let now = Date(timeIntervalSinceReferenceDate: 5_000_000)

        // Must complete without throwing.
        _ = try await daemon.runThetaCycle(now: now)
        // No assertion on method call counts — maintenance object is nil.
    }

    // ── HM-6: nil maintenance, BETA — no crash ──────────────────────────────

    @Test("HM-6: nil hnswMaintenance — BETA cycle completes without crash")
    func hm6_nilMaintenanceBetaNoOp() async throws {
        let daemon = makeThetaDaemon(hnsw: nil)
        let now = Date(timeIntervalSinceReferenceDate: 6_000_000)

        _ = try await daemon.runBetaCycle(now: now)
        // Must complete without throwing. No assertions on a nil maintenance.
    }

    // ── HM-7: THETA maintenance throws → non-fatal ──────────────────────────

    @Test("HM-7: THETA maintenance error is non-fatal — cycle result is returned")
    func hm7_thetaMaintenanceFailureNonFatal() async throws {
        let hnsw = FakeHNSWMaintenance(shouldThrow: true)
        let daemon = makeThetaDaemon(hnsw: hnsw, traces: twoUsedTraces())
        let now = Date(timeIntervalSinceReferenceDate: 7_000_000)

        // Must not propagate the maintenance error.
        let result = try await daemon.runThetaCycle(now: now)
        #expect(result != nil, "THETA must return a cycle report even when maintenance throws")

        // The throwing fake records nothing.
        let count = await hnsw.rebuildCount
        #expect(count == 0, "throwing maintenance records no successful rebuild calls")
    }

    // ── HM-8: BETA maintenance throws → non-fatal ───────────────────────────

    @Test("HM-8: BETA maintenance error is non-fatal — nil returned normally")
    func hm8_betaMaintenanceFailureNonFatal() async throws {
        let hnsw = FakeHNSWMaintenance(shouldThrow: true)
        let daemon = makeThetaDaemon(hnsw: hnsw)
        let now = Date(timeIntervalSinceReferenceDate: 8_000_000)

        // Must not throw.
        let result = try await daemon.runBetaCycle(now: now)
        // BETA always returns nil (it produces no proposals).
        #expect(result == nil)

        let count = await hnsw.compactCount
        #expect(count == 0, "throwing maintenance records no successful compact calls")
    }

    // ── HM-9: OMEGA has no HNSW duty ─────────────────────────────────────────

    /// OMEGA retires dreamed tunnels. No HNSW graph maintenance fires.
    /// Verify that none of the three maintenance methods are invoked.
    @Test("HM-9: OMEGA cycle does not invoke any HNSWGraphMaintenance method")
    func hm9_omegaHasNoHNSWDuty() async throws {
        let hnsw = FakeHNSWMaintenance()
        let daemon = makeThetaDaemon(hnsw: hnsw)
        let now = Date(timeIntervalSinceReferenceDate: 9_000_000)

        _ = try await daemon.runOmegaCycle(now: now)

        let clears   = await hnsw.clearCount
        let rebuilds = await hnsw.rebuildCount
        let compacts = await hnsw.compactCount
        #expect(clears   == 0, "OMEGA must not call clearFloatIndex")
        #expect(rebuilds == 0, "OMEGA must not call rebuildFloatIndex")
        #expect(compacts == 0, "OMEGA must not call compactFloatIndexTombstones")
    }
}
