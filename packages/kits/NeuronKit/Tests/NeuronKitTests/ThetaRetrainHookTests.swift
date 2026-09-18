// ThetaRetrainHookTests.swift
//
// Conformance tests for the THETA-gate daily basis-retrain hook
// (NEURONKIT_SPEC § 3.1 theta-retrain extension).
//
// Covers:
//   TR-1: gate fires → hook invoked exactly once (consolidation path).
//   TR-2: gate fires → hook invoked exactly once (early-return / no-data path).
//   TR-3: no hook wired (nil) → no invocations.
//   TR-4: hook failure does not abort the THETA cycle; result is still returned.
//   TR-5: hook receives the same `now` timestamp passed to `runThetaCycle`.
//   TR-6: two consecutive THETA cycles → hook invoked twice (once per cycle).
//   TR-7: thetaDue returns false before the 24 h cadence elapses.
//   TR-8: drift gate with probe below threshold — hook does NOT fire on second cycle.
//   TR-9: drift gate with probe at threshold — hook fires on second cycle.
//   TR-10: first-ever THETA cycle fires immediately regardless of vocab (sentinel).
//   TR-11: after retrain, lastReindexVocab advances — sub-floor growth defers next cycle.
//
// Timing is deterministic: `now` is always injected. The fake hook records
// calls without touching a live Corpus. No wall-clock reads inside cycle code.

import Testing
import Foundation
import GeniusLocusKit
@testable import NeuronKit

// MARK: - Fake ThetaBasisRetrainHook

/// Configurable fake that records retrain calls.
private actor FakeThetaRetrainHook: ThetaBasisRetrainHook {

    /// Timestamps passed to `retrain(now:)` in call order.
    private(set) var retrainCalls: [Date] = []

    /// When true, `retrain(now:)` throws a captured error (non-fatal test).
    var shouldThrow: Bool

    /// F11: when true, `retrain(now:)` reports a DEGRADED retrain (a
    /// backstop reached, serving basis kept) instead of a full one.
    var shouldDegrade: Bool

    init(shouldThrow: Bool = false, shouldDegrade: Bool = false) {
        self.shouldThrow = shouldThrow
        self.shouldDegrade = shouldDegrade
    }

    @discardableResult
    func retrain(now: Date) async throws -> Bool {
        if shouldThrow {
            struct FakeRetrainError: Error {}
            throw FakeRetrainError()
        }
        retrainCalls.append(now)
        return !shouldDegrade
    }

    func setShouldDegrade(_ v: Bool) { shouldDegrade = v }
    var callCount: Int { retrainCalls.count }
}

// MARK: - Shared fakes (re-use from DreamingThetaTests pattern)

/// Minimal recording sink for THETA retrain hook tests.
private actor HookTestSink: DreamingProposalSink {
    private(set) var proposals: [ProposeFrame] = []
    private(set) var diaryEntries: [DiaryEntry] = []

    func propose(_ frame: ProposeFrame) async throws { proposals.append(frame) }
    func recordCycleDiary(_ entry: DiaryEntry) async throws { diaryEntries.append(entry) }
    func pruneRecallTraces(olderThan _: Date) async throws -> Int { 0 }
}

/// Fake reader for THETA retrain tests.
/// Injects traces and active tunnels; THETA does not drain the queue.
private actor HookTestReader: DreamingSubstrateReader {
    var traces: [RecallTraceItem]
    var tunnels: [Tunnel]

    init(traces: [RecallTraceItem], tunnels: [Tunnel] = []) {
        self.traces = traces
        self.tunnels = tunnels
    }

    func recentRecallTraces(since _: Date, now _: Date) async throws -> [RecallTraceItem] { traces }
    func drainDreamingWindow() async throws -> [[String]] { [] }
    func existingTunnels() async throws -> [Tunnel] { tunnels }
    func dreamedActiveTunnels() async throws -> [Tunnel] { [] }
}

/// Two traces with distinct IDs, both `used`, so the used-set has 2 entries
/// and THETA proceeds to the consolidation path (not the early-return path).
private func twoUsedTraces() -> [RecallTraceItem] {
    [
        RecallTraceItem(target: "drawer-A", recalledAt: Date(),
                        operationalBitmap: RecallTraceItem.flagUsed),
        RecallTraceItem(target: "drawer-B", recalledAt: Date(),
                        operationalBitmap: RecallTraceItem.flagUsed),
    ]
}

/// Build a daemon with the given retrain hook and the given trace list.
private func makeDaemon(
    hook: (any ThetaBasisRetrainHook)?,
    traces: [RecallTraceItem] = []
) -> DreamingDaemon {
    let reader = HookTestReader(traces: traces)
    let sink = HookTestSink()
    let store = InMemoryDreamingPolicyStore(.default)
    return DreamingDaemon(
        reader: reader,
        sink: sink,
        rewardSource: RecallTraceRewardSource(),
        policyStore: store,
        thetaRetrainHook: hook
    )
}

// MARK: - Tests

@Suite("ThetaBasisRetrainHook — THETA-gate daily retrain seam")
struct ThetaRetrainHookTests {

    // TR-1: consolidation path fires hook exactly once.
    @Test("TR-1: hook invoked once on the consolidation path (2 used drawers)")
    func tr1_hookInvokedOnConsolidationPath() async throws {
        let hook = FakeThetaRetrainHook()
        let daemon = makeDaemon(hook: hook, traces: twoUsedTraces())
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        _ = try await daemon.runThetaCycle(now: now)

        let count = await hook.callCount
        #expect(count == 1, "hook must fire exactly once per THETA cycle")
    }

    // TR-2: early-return / no-data path (fewer than 2 used drawers) also fires hook.
    @Test("TR-2: hook invoked once on the early-return no-data path (0 used drawers)")
    func tr2_hookInvokedOnEarlyReturnPath() async throws {
        let hook = FakeThetaRetrainHook()
        // Empty trace list → no used drawers → usedSet.count < 2 → early return.
        let daemon = makeDaemon(hook: hook, traces: [])
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

        let result = try await daemon.runThetaCycle(now: now)
        #expect(result == nil, "early-return path must return nil")

        let count = await hook.callCount
        #expect(count == 1, "hook must still fire on the early-return path")
    }

    // TR-3: nil hook → no invocations, no crash.
    @Test("TR-3: nil hook is a safe no-op")
    func tr3_nilHookIsNoOp() async throws {
        // daemon has thetaRetrainHook: nil (the default)
        let daemon = makeDaemon(hook: nil, traces: twoUsedTraces())
        let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
        // Must complete without error and without calling any retrain.
        _ = try await daemon.runThetaCycle(now: now)
        // No assertion on a nil hook — just verifying no crash and no throw.
    }

    // TR-4: hook failure does not abort the cycle; result is returned normally.
    @Test("TR-4: hook failure is non-fatal — cycle result is returned")
    func tr4_hookFailureDoesNotAbortCycle() async throws {
        let hook = FakeThetaRetrainHook(shouldThrow: true)
        let daemon = makeDaemon(hook: hook, traces: twoUsedTraces())
        let now = Date(timeIntervalSinceReferenceDate: 4_000_000)

        // Must not throw even though the hook throws internally.
        let report = try await daemon.runThetaCycle(now: now)
        #expect(report != nil, "cycle report must be returned despite hook error")

        // The throwing hook records nothing.
        let count = await hook.callCount
        #expect(count == 0, "throwing hook records no successful calls")
    }

    // TR-4b: hook failure on early-return path also non-fatal.
    @Test("TR-4b: hook failure on no-data path is non-fatal — nil returned normally")
    func tr4b_hookFailureOnEarlyReturnPath() async throws {
        let hook = FakeThetaRetrainHook(shouldThrow: true)
        let daemon = makeDaemon(hook: hook, traces: [])
        let now = Date(timeIntervalSinceReferenceDate: 4_500_000)

        // Must not throw.
        let result = try await daemon.runThetaCycle(now: now)
        #expect(result == nil)
    }

    // TR-5: hook receives the exact `now` timestamp from the caller.
    @Test("TR-5: hook receives the caller-injected now timestamp")
    func tr5_hookReceivesNowTimestamp() async throws {
        let hook = FakeThetaRetrainHook()
        let daemon = makeDaemon(hook: hook, traces: twoUsedTraces())
        let now = Date(timeIntervalSinceReferenceDate: 5_000_000)

        _ = try await daemon.runThetaCycle(now: now)

        let calls = await hook.retrainCalls
        #expect(calls.first == now, "hook must receive the exact injected now")
    }

    // TR-6: two consecutive THETA cycles → hook called twice.
    @Test("TR-6: hook fires once per due cycle across multiple cycles")
    func tr6_hookFiresOncePerCycle() async throws {
        let hook = FakeThetaRetrainHook()
        let daemon = makeDaemon(hook: hook, traces: twoUsedTraces())
        let t1 = Date(timeIntervalSinceReferenceDate: 6_000_000)
        let t2 = Date(timeIntervalSinceReferenceDate: 6_000_001)

        _ = try await daemon.runThetaCycle(now: t1)
        _ = try await daemon.runThetaCycle(now: t2)

        let count = await hook.callCount
        #expect(count == 2, "hook must fire exactly once per runThetaCycle call")
    }

    // TR-7: not-due gate check — thetaDue returns false before 24 h have elapsed.
    // (The governor gates on thetaDue before calling runThetaCycle. This test
    // confirms that the daemon's thetaDue gate works as the documentation states;
    // the hook is not involved, but the due-gate behavior is load-bearing for
    // the "not-due path does not invoke" contract.)
    @Test("TR-7: thetaDue returns false before the 24 h cadence elapses")
    func tr7_thetaDueRespectsCadence() async throws {
        let daemon = makeDaemon(hook: nil, traces: [])
        let t0 = Date(timeIntervalSinceReferenceDate: 7_000_000)
        _ = try await daemon.runThetaCycle(now: t0)

        // 1 second later — not yet due.
        let t1 = Date(timeIntervalSinceReferenceDate: 7_000_001)
        let due = await daemon.thetaDue(now: t1)
        #expect(!due, "thetaDue must return false within the 24 h window")
    }

    // TR-8: drift gate — vocab growth below the threshold → hook does NOT fire.
    // When a growthProbe is wired and the daemon's shared lastReindexVocab has
    // been set (after the first THETA cycle), subsequent cycles respect the same
    // drift threshold as the ALPHA auto-reindex check.
    @Test("TR-8: drift gate defers retrain when vocab growth is below the threshold")
    func tr8_driftGateDefersBelowThreshold() async throws {
        let probe = FakeDriftProbeForTheta(vocab: 100)
        let hook = FakeThetaRetrainHook()
        let daemon = makeDriftGatedDaemon(probe: probe, hook: hook)
        let t1 = Date(timeIntervalSinceReferenceDate: 8_000_000)

        // Cycle 1: sentinel path (lastReindexVocab == -1) fires immediately;
        // after success, lastReindexVocab is set to 100.
        _ = try await daemon.runThetaCycle(now: t1)
        let afterFirst = await hook.callCount
        #expect(afterFirst == 1, "sentinel path must fire on the first THETA cycle")

        // Grow by 20 — below threshold max(25, ceil(100 × 0.10)=10) = 25.
        await probe.setVocab(120)

        // Cycle 2: delta = 20 < trigger 25 → drift gate defers, hook not called.
        let t2 = Date(timeIntervalSinceReferenceDate: 8_000_001)
        _ = try await daemon.runThetaCycle(now: t2)
        let afterSecond = await hook.callCount
        #expect(afterSecond == 1,
                "drift gate must suppress the retrain when growth (20) is below the threshold (25)")
    }

    // TR-9: drift gate — vocab growth at the threshold → hook fires.
    // At exactly max(floor, ceil(fraction × baseline)) the gate must pass.
    @Test("TR-9: drift gate fires retrain when vocab growth meets the threshold")
    func tr9_driftGateFiresAtThreshold() async throws {
        let probe = FakeDriftProbeForTheta(vocab: 100)
        let hook = FakeThetaRetrainHook()
        let daemon = makeDriftGatedDaemon(probe: probe, hook: hook)
        let t1 = Date(timeIntervalSinceReferenceDate: 9_000_000)

        // Cycle 1: sentinel fires; lastReindexVocab = 100.
        _ = try await daemon.runThetaCycle(now: t1)

        // Grow by exactly max(25, ceil(100 × 0.10)=10) = 25 terms.
        await probe.setVocab(125)

        // Cycle 2: delta = 25 == trigger → gate passes, hook fires.
        let t2 = Date(timeIntervalSinceReferenceDate: 9_000_001)
        _ = try await daemon.runThetaCycle(now: t2)
        let count = await hook.callCount
        #expect(count == 2,
                "drift at the threshold must trigger retrain: sentinel(1) + threshold-met(1)")
    }

    // TR-10: first-ever THETA cycle fires immediately regardless of current vocab.
    // THETA acts as a backstop for a dormant ALPHA path — the sentinel (-1)
    // unconditionally fires so the estate is never left without an initial basis.
    @Test("TR-10: sentinel path fires retrain on the very first THETA cycle")
    func tr10_firstCycleFiresImmediately() async throws {
        // Large vocab so the proportional fraction alone would require ≥100 terms
        // of growth — but the sentinel ignores the threshold entirely.
        let probe = FakeDriftProbeForTheta(vocab: 1_000)
        let hook = FakeThetaRetrainHook()
        let daemon = makeDriftGatedDaemon(probe: probe, hook: hook)
        let t = Date(timeIntervalSinceReferenceDate: 10_000_000)

        _ = try await daemon.runThetaCycle(now: t)

        let count = await hook.callCount
        #expect(count == 1,
                "sentinel (lastReindexVocab == -1) must fire retrain on the first cycle")
    }

    // TR-11: after a THETA retrain the shared vocab baseline advances so the NEXT
    // cycle measures drift from the post-retrain level, not from the original baseline.
    // This confirms that advance_reindex_vocab is called correctly after success.
    @Test("TR-11: vocab baseline advances after THETA retrain; sub-floor growth defers next cycle")
    func tr11_baselineAdvancesAfterRetrain() async throws {
        let probe = FakeDriftProbeForTheta(vocab: 100)
        let hook = FakeThetaRetrainHook()
        let daemon = makeDriftGatedDaemon(probe: probe, hook: hook)
        let t1 = Date(timeIntervalSinceReferenceDate: 11_000_000)

        // Cycle 1: sentinel fires; lastReindexVocab = 100.
        _ = try await daemon.runThetaCycle(now: t1)

        // Grow by 25 (= trigger): fires; lastReindexVocab advances to 125.
        await probe.setVocab(125)
        let t2 = Date(timeIntervalSinceReferenceDate: 11_000_001)
        _ = try await daemon.runThetaCycle(now: t2)
        #expect(await hook.callCount == 2, "growth at threshold must fire retrain")

        // Now grow by only 10 from 125 (vocab = 135). If the baseline correctly
        // advanced to 125, delta = 10 < trigger max(25, ceil(125×0.10)=13) = 25
        // → defers. If the baseline did NOT advance (stuck at 100), delta = 35
        // → fires incorrectly.
        await probe.setVocab(135)
        let t3 = Date(timeIntervalSinceReferenceDate: 11_000_002)
        _ = try await daemon.runThetaCycle(now: t3)
        let finalCount = await hook.callCount
        #expect(finalCount == 2,
                "after retrain advances baseline to 125, growth of 10 (135-125) must defer")
    }
}

// MARK: - Drift gate helpers (TR-8 through TR-11)

/// Minimal growth probe for drift-gate tests. Exposes a settable vocab count;
/// does not implement reindex (THETA delegates retrain to the hook, not the probe).
private actor FakeDriftProbeForTheta: CorpusGrowthProbe {

    private(set) var vocab: Int

    init(vocab: Int) { self.vocab = vocab }

    func vocabAnchor() async throws -> Int { vocab }

    /// THETA's drift gate reads vocabAnchor() only; it does not call
    /// reindex() on the probe (the probe is the observer, the hook is
    /// the worker). This body is a required conformance stub.
    @discardableResult
    func reindex(now: Date) async throws -> Bool { true }

    func setVocab(_ v: Int) { vocab = v }
}

/// Build a daemon wired with BOTH a growth probe (drift gate) and a retrain hook.
/// Empty traces → early-return path in runThetaCycle, which still calls fireTheta.
private func makeDriftGatedDaemon(
    probe: any CorpusGrowthProbe,
    hook: (any ThetaBasisRetrainHook)? = nil
) -> DreamingDaemon {
    let reader = HookTestReader(traces: [])
    let sink = HookTestSink()
    let store = InMemoryDreamingPolicyStore(.default)
    return DreamingDaemon(
        reader: reader,
        sink: sink,
        rewardSource: RecallTraceRewardSource(),
        policyStore: store,
        growthProbe: probe,
        thetaRetrainHook: hook
    )
}
