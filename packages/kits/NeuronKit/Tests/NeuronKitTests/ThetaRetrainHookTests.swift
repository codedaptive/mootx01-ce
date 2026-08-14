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

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func retrain(now: Date) async throws {
        if shouldThrow {
            struct FakeRetrainError: Error {}
            throw FakeRetrainError()
        }
        retrainCalls.append(now)
    }

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
}
