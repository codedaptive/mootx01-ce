// HNSWDreamingTests.swift
//
// Conformance tests for DreamingDaemon's HNSW graph maintenance duties.
//
// Three cadences carry HNSW duties; OMEGA does not:
//
//   HM-1: ALPHA — vocabulary drift triggers a corpus shadow swap (probe.reindex).
//          The swap publishes a coherent new-generation HNSW graph atomically
//          inside publishShadowGeneration. The no-clear guarantee is compile-time
//          since D-7 removed clearFloatIndex from HNSWGraphMaintenance.
//          Requires two pump() calls: the first establishes the vocab baseline;
//          the second crosses the growth trigger and fires the shadow swap.
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

/// Recording fake. Tracks calls to the three maintenance methods.
///
/// `clearFloatIndex` is absent: the method was removed from `HNSWGraphMaintenance`
/// in D-7 (VEC-SHADOWSWAP-01). The no-clear guarantee for the ALPHA cadence is
/// compile-time — the seam has no clear method, so nothing can call it.
private actor FakeHNSWMaintenance: HNSWGraphMaintenance {

    /// Timestamps passed to `rebuildFloatIndex(now:)`, in call order.
    private(set) var rebuildCalls: [Date] = []

    /// Timestamps passed to `compactFloatIndexTombstones(now:)`, in call order.
    private(set) var compactCalls: [Date] = []

    /// Timestamps passed to `reclaimSupersededGenerations(now:)`, in call order.
    private(set) var reclaimCalls: [Date] = []

    /// When true, every method throws a sentinel error (non-fatal test path).
    var shouldThrow: Bool

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func rebuildFloatIndex(now: Date) async throws {
        if shouldThrow { throw FakeMaintenanceError() }
        rebuildCalls.append(now)
    }

    func compactFloatIndexTombstones(now: Date) async throws {
        if shouldThrow { throw FakeMaintenanceError() }
        compactCalls.append(now)
    }

    func reclaimSupersededGenerations(now: Date) async throws {
        if shouldThrow { throw FakeMaintenanceError() }
        reclaimCalls.append(now)
    }

    var rebuildCount: Int { rebuildCalls.count }
    var compactCount: Int { compactCalls.count }
    var reclaimCount: Int { reclaimCalls.count }
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

    /// Recording reindex: the daemon calls this when the growth gate fires.
    /// The probe does no real work; it records the call so tests can assert
    /// the shadow swap triggered exactly once.
    private(set) var reindexCalls: [Date] = []
    var reindexCount: Int { reindexCalls.count }

    func reindex(now: Date) async throws {
        reindexCalls.append(now)
    }
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

    // ── HM-1: ALPHA shadow swap fires ─────────────────────────────────────

    /// Two pump() calls are needed:
    ///   • First: lastReindexVocab is –1 (sentinel) → baseline set to firstVocab=100.
    ///     No reindex, no HNSW action.
    ///   • Second (2 s later): delta = laterVocab – firstVocab = 100.
    ///     Default trigger = max(25, floor(100 × 0.10)) = 25.
    ///     100 ≥ 25 → probe.reindex fires (shadow swap).
    ///
    /// The no-clear guarantee is compile-time since D-7 removed clearFloatIndex
    /// from HNSWGraphMaintenance (VEC-SHADOWSWAP-01 BRR). publishShadowGeneration
    /// ships the coherent new-generation HNSW graph atomically inside the swap.
    @Test("HM-1: ALPHA shadow swap fires (no-clear guarantee is compile-time since D-7)")
    func hm1_alphaShadowSwapFires() async throws {
        let hnsw = FakeHNSWMaintenance()
        let probe = FakeGrowthProbe(first: 100, later: 200)
        let daemon = makeAlphaDaemon(hnsw: hnsw, probe: probe)

        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // First pump: sets vocab baseline (100). No reindex gate fires.
        _ = try await daemon.pump(now: t0)
        let reindexAfterFirst = await probe.reindexCount
        #expect(reindexAfterFirst == 0, "no reindex on the first pump (baseline-only cycle)")

        // Second pump: 2 seconds later. delta=100 ≥ trigger=25 → shadow swap fires
        // via probe.reindex.
        _ = try await daemon.pump(now: t0.addingTimeInterval(2.0))
        let reindexAfterSecond = await probe.reindexCount
        #expect(reindexAfterSecond == 1,
            "probe.reindex (shadow swap) must fire exactly once after vocab drift crosses trigger")
        // The no-clear guarantee is compile-time: clearFloatIndex no longer exists
        // on HNSWGraphMaintenance (D-7). No assertion needed; the seam cannot clear.
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
    /// Verify that none of the three seam methods are invoked.
    /// (clearFloatIndex was removed from HNSWGraphMaintenance in D-7.)
    @Test("HM-9: OMEGA cycle does not invoke any HNSWGraphMaintenance method")
    func hm9_omegaHasNoHNSWDuty() async throws {
        let hnsw = FakeHNSWMaintenance()
        let daemon = makeThetaDaemon(hnsw: hnsw)
        let now = Date(timeIntervalSinceReferenceDate: 9_000_000)

        _ = try await daemon.runOmegaCycle(now: now)

        let rebuilds = await hnsw.rebuildCount
        let compacts = await hnsw.compactCount
        let reclaims = await hnsw.reclaimCount
        #expect(rebuilds == 0, "OMEGA must not call rebuildFloatIndex")
        #expect(compacts == 0, "OMEGA must not call compactFloatIndexTombstones")
        #expect(reclaims == 0, "OMEGA must not call reclaimSupersededGenerations")
        // rebuild and compact are trait-only duties; both stay unused in every build here.
    }

    // ── n1: Below-threshold vocab growth — no swap fires ──────────────────

    /// Below-threshold growth on the HEALTHY probe path: probe.vocabAnchor
    /// returns first=100 (baseline), then 101 (delta=1 < trigger=25). The
    /// drift gate does NOT fire reindex; no shadow swap occurs.
    @Test("n1: below-threshold vocab growth does not trigger shadow swap")
    func n1_belowThresholdNoSwap() async throws {
        // delta = 101 - 100 = 1, trigger = max(25, floor(100 * 0.10)) = 25 → gate skips
        let hnsw = FakeHNSWMaintenance()
        let probe = FakeGrowthProbe(first: 100, later: 101)
        let daemon = makeAlphaDaemon(hnsw: hnsw, probe: probe)
        let t0 = Date(timeIntervalSinceReferenceDate: 10_000_000)

        // First pump: sets baseline to 100.
        _ = try await daemon.pump(now: t0)
        // Second pump: liveVocab=101, delta=1 < trigger=25 — gate skips.
        _ = try await daemon.pump(now: t0.addingTimeInterval(2.0))

        let reindexCount = await probe.reindexCount
        #expect(reindexCount == 0, "probe.reindex must NOT fire when delta is below the trigger")
        // No clearFloatIndex assertion: the method no longer exists on HNSWGraphMaintenance
        // (D-7). The no-clear guarantee is compile-time.
    }

    // ── n2: Crossing threshold fires exactly once; second cycle with no growth skips ──

    /// Crossing the drift threshold triggers probe.reindex exactly once.
    /// A subsequent cycle where liveVocab has not grown does NOT fire again
    /// (baseline was advanced to liveVocab after the first swap).
    @Test("n2: crossing threshold triggers swap exactly once; baseline advance prevents second fire")
    func n2_thresholdCrossOnceBaselineAdvances() async throws {
        // delta = 200 - 100 = 100 ≥ trigger = 25 → fires on second pump.
        // Third pump: liveVocab still 200, delta = 200 - 200 = 0 < trigger → skips.
        let hnsw = FakeHNSWMaintenance()
        let probe = FakeGrowthProbe(first: 100, later: 200)
        let daemon = makeAlphaDaemon(hnsw: hnsw, probe: probe)
        let t0 = Date(timeIntervalSinceReferenceDate: 11_000_000)

        // First pump: sets baseline = 100.
        _ = try await daemon.pump(now: t0)
        let afterFirst = await probe.reindexCount
        #expect(afterFirst == 0, "no swap on baseline-setting pump")

        // Second pump: delta=100 ≥ 25 → swap fires.
        _ = try await daemon.pump(now: t0.addingTimeInterval(2.0))
        let afterSecond = await probe.reindexCount
        #expect(afterSecond == 1, "probe.reindex must fire exactly once after threshold crossed")

        // Third pump: liveVocab still 200. Baseline was advanced to 200 after
        // the swap, so delta = 200 - 200 = 0 < 25 → gate skips.
        _ = try await daemon.pump(now: t0.addingTimeInterval(4.0))
        let afterThird = await probe.reindexCount
        #expect(afterThird == 1,
            "probe.reindex must NOT fire again when liveVocab has not grown since last swap")
    }

    // ── n4: BETA cycle calls reclaimSupersededGenerations exactly once ────

    /// The BETA cycle fires both `compactFloatIndexTombstones` and
    /// `reclaimSupersededGenerations` on the maintenance seam exactly once
    /// per due cycle. The fake records both calls for witness.
    @Test("n4: BETA cycle calls reclaimSupersededGenerations once alongside tombstone compaction")
    func n4_betaReclaimsAlongWithCompact() async throws {
        let hnsw = FakeHNSWMaintenance()
        let daemon = makeThetaDaemon(hnsw: hnsw)
        let now = Date(timeIntervalSinceReferenceDate: 14_000_000)

        _ = try await daemon.runBetaCycle(now: now)

        let compactCount = await hnsw.compactCount
        let reclaimCount = await hnsw.reclaimCount
        #expect(compactCount == 1, "compactFloatIndexTombstones must fire exactly once per BETA")
        #expect(reclaimCount == 1, "reclaimSupersededGenerations must fire exactly once per BETA")
    }

    // ── n6: ALPHA drift-gate regression guard ─────────────────────────────

    /// After the drift gate fires and the shadow swap completes (probe.reindex),
    /// probe.reindex must have fired exactly once. The no-clear guarantee is now
    /// compile-time since D-7 removed clearFloatIndex from HNSWGraphMaintenance
    /// (VEC-SHADOWSWAP-01 BRR). The seam has no clear method; nothing can call it.
    @Test("n6: ALPHA drift-gate fires shadow swap; no-clear guarantee is compile-time (D-7)")
    func n6_alphaSwapDoesNotCallClear() async throws {
        let hnsw = FakeHNSWMaintenance()
        let probe = FakeGrowthProbe(first: 100, later: 200)
        let daemon = makeAlphaDaemon(hnsw: hnsw, probe: probe)
        // Use the same reference epoch as n2 (11_000_000) where the bandit is
        // known to select .timer for both pump calls. A different epoch can cause
        // the bandit to select .event after pump #1, blocking pump #2. This is a
        // bandit-seeding property of the timestamp, not the test's concern.
        let t0 = Date(timeIntervalSinceReferenceDate: 11_000_000)

        // First pump: baseline set.
        _ = try await daemon.pump(now: t0)
        // Second pump: drift gate crosses threshold → probe.reindex (shadow swap) fires.
        _ = try await daemon.pump(now: t0.addingTimeInterval(2.0))

        let reindexCount = await probe.reindexCount
        #expect(reindexCount == 1, "shadow swap must fire exactly once when threshold crossed (n6 gate)")
        // The no-clear guarantee is compile-time: clearFloatIndex no longer exists
        // on HNSWGraphMaintenance (D-7). No assertion needed.
    }
}
