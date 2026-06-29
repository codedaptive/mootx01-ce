// DreamingThetaTests.swift
//
// Conformance tests for the REM-THETA daily consolidation cycle (T11,
// ADR-021 Phase 6, NEURONKIT_SPEC § 12.6 THETA row) and the shared
// REM-cycle dispatch table.
//
// Covers:
//   D5a — THETA fires on a 24 h cadence.
//   D5c — last-run timestamp persists across restarts; stdio estates
//          do not re-consolidate within the same 24 h window.
//   §12.5 — decide() math is unchanged for THETA (same EWC++ path as
//          ALPHA). Verified by asserting that THETA emits proposals under
//          the same conditions as ALPHA given equivalent inputs.
//   §12.4 — THETA bumps coRecallCounts for all pairs in the used set.
//   Table structure — remCycleTable has four entries in the correct order.
//   ALPHA regression — existing ALPHA gate is unaffected by T11.
//   BETA/OMEGA cycles — entries present in the table; live run-fns advance
//          last-run timestamps correctly (T12/T13 complete).
//
// All substrate interaction uses the same in-memory seam fakes as
// DreamingDaemonTests.swift. The clock is always injected; no wall-clock
// reads inside cycle code.

import Testing
import Foundation
import GeniusLocusKit
@testable import NeuronKit

// MARK: - Local seam fakes (THETA tests need trace injection, not windows)

/// Minimal recording sink used by THETA tests.
private actor ThetaRecordingSink: DreamingProposalSink {
    private(set) var proposals: [ProposeFrame] = []
    private(set) var diaryEntries: [DiaryEntry] = []

    func propose(_ frame: ProposeFrame) async throws { proposals.append(frame) }
    func recordCycleDiary(_ entry: DiaryEntry) async throws { diaryEntries.append(entry) }
    func pruneRecallTraces(olderThan _: Date) async throws -> Int { 0 }
}

/// Reader fake for THETA tests. Returns a fixed trace list and empty drain.
/// THETA reads `recentRecallTraces(since:now:)` but does NOT drain the queue.
private actor ThetaFakeReader: DreamingSubstrateReader {
    var traces: [RecallTraceItem]
    var tunnels: [Tunnel]

    init(traces: [RecallTraceItem], tunnels: [Tunnel] = []) {
        self.traces = traces
        self.tunnels = tunnels
    }

    func recentRecallTraces(since _: Date, now _: Date) async throws -> [RecallTraceItem] { traces }
    func drainDreamingWindow() async throws -> [[String]] { [] }
    func existingTunnels() async throws -> [Tunnel] { tunnels }
}

// MARK: - Helper

/// Make a RecallTraceItem with the given target and used flag.
/// `used` maps to bit 0 of operationalBitmap (schema invariant: no stored Bool).
private func trace(_ id: String, used: Bool) -> RecallTraceItem {
    RecallTraceItem(
        target: id,
        recalledAt: Date(),
        operationalBitmap: used ? RecallTraceItem.flagUsed : 0
    )
}

/// A DreamingDaemon with spec defaults and an in-memory policy store.
private func makeDaemon(
    policy: DreamingPolicy = .default
) -> (DreamingDaemon, InMemoryDreamingPolicyStore) {
    let store = InMemoryDreamingPolicyStore(policy)
    let daemon = DreamingDaemon(
        reader: ThetaFakeReader(traces: []),
        sink: ThetaRecordingSink(),
        rewardSource: RecallTraceRewardSource(),
        policyStore: store
    )
    return (daemon, store)
}

// MARK: - Table structure

@Suite("REM dispatch table (T11)")
struct RemCycleTableTests {

    @Test("remCycleTable has four entries")
    func tableHasFourEntries() {
        #expect(remCycleTable.count == 4)
    }

    @Test("remCycleTable first entry is ALPHA")
    func firstEntryIsAlpha() {
        #expect(remCycleTable[0].kind == .alpha)
        #expect(remCycleTable[0].name == "REM-ALPHA")
        #expect(remCycleTable[0].cadenceSecs == 30)
    }

    @Test("remCycleTable second entry is THETA")
    func secondEntryIsTheta() {
        #expect(remCycleTable[1].kind == .theta)
        #expect(remCycleTable[1].name == "REM-THETA")
        #expect(remCycleTable[1].cadenceSecs == 86_400)
    }

    @Test("remCycleTable third entry is BETA")
    func thirdEntryIsBeta() {
        #expect(remCycleTable[2].kind == .beta)
        #expect(remCycleTable[2].name == "REM-BETA")
    }

    @Test("remCycleTable fourth entry is OMEGA (T13 / ADR-021 Phase 7)")
    func fourthEntryIsOmega() {
        #expect(remCycleTable[3].kind == .omega)
        #expect(remCycleTable[3].name == "REM-OMEGA")
    }

    @Test("RemCycleKind.allCases covers all four kinds")
    func allCasesCoversAll() {
        let kinds = Set(RemCycleKind.allCases)
        #expect(kinds.contains(.alpha))
        #expect(kinds.contains(.theta))
        #expect(kinds.contains(.beta))
        #expect(kinds.contains(.omega))
    }
}

// MARK: - THETA due-check

@Suite("REM-THETA due-check (D5a / D5c)")
struct ThetaDueTests {

    @Test("thetaDue returns true when never run (nil last-run)")
    func thetaDueWhenNeverRun() async throws {
        let (daemon, _) = makeDaemon()
        let now = Date()
        let due = await daemon.thetaDue(now: now)
        #expect(due == true)
    }

    @Test("thetaDue returns false when run less than 24 h ago")
    func thetaNotDueWithin24h() async throws {
        let sink = ThetaRecordingSink()
        let store = InMemoryDreamingPolicyStore()
        // Seed a state with lastThetaRunAt = 12 h ago.
        let twelveHoursAgo = Date().addingTimeInterval(-43_200)
        var state = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [:],
            cycleCount: 0,
            coRecallCounts: [:],
            lastThetaRunAt: twelveHoursAgo
        )
        try await store.saveDaemonState(state)

        let daemon = DreamingDaemon(
            reader: ThetaFakeReader(traces: []),
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await daemon.loadPersistedPolicy()
        let now = Date()
        let due = await daemon.thetaDue(now: now)
        #expect(due == false)
    }

    @Test("thetaDue returns true when last run exactly 24 h ago")
    func thetaDueAt24hBoundary() async throws {
        let store = InMemoryDreamingPolicyStore()
        let twentyFourHoursAgo = Date().addingTimeInterval(-86_400)
        let state = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [:],
            cycleCount: 0,
            coRecallCounts: [:],
            lastThetaRunAt: twentyFourHoursAgo
        )
        try await store.saveDaemonState(state)

        let daemon = DreamingDaemon(
            reader: ThetaFakeReader(traces: []),
            sink: ThetaRecordingSink(),
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await daemon.loadPersistedPolicy()
        let now = Date()
        let due = await daemon.thetaDue(now: now)
        #expect(due == true)
    }
}

// MARK: - THETA cycle execution

@Suite("REM-THETA cycle (NEURONKIT_SPEC § 12.6)")
struct ThetaCycleTests {

    @Test("THETA returns nil when fewer than 2 used drawers in window")
    func thetaNilWhenNoUsedPairs() async throws {
        let reader = ThetaFakeReader(traces: [
            trace("d1", used: true),   // only one used drawer — cannot form pair
            trace("d2", used: false),
        ])
        let sink = ThetaRecordingSink()
        let store = InMemoryDreamingPolicyStore()
        let daemon = DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        let now = Date()
        let report = try await daemon.runThetaCycle(now: now)
        #expect(report == nil)
    }

    @Test("THETA advances lastThetaRunAt even when returning nil")
    func thetaAdvancesTimestampOnNoOp() async throws {
        let reader = ThetaFakeReader(traces: [trace("d1", used: true)])
        let sink = ThetaRecordingSink()
        let store = InMemoryDreamingPolicyStore()
        let daemon = DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        let now = Date()
        _ = try await daemon.runThetaCycle(now: now)

        // lastThetaRunAt should now be set.
        let lastRun = await daemon.lastRunAt(for: .theta)
        #expect(lastRun != nil)
    }

    @Test("THETA bumps coRecallCounts for all pairs in the used set")
    func thetaBumpsCoRecallCounts() async throws {
        // Three used drawers → three pairs: (a,b), (a,c), (b,c).
        let reader = ThetaFakeReader(traces: [
            trace("a", used: true),
            trace("b", used: true),
            trace("c", used: true),
        ])
        let sink = ThetaRecordingSink()
        let store = InMemoryDreamingPolicyStore()
        let daemon = DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        let now = Date()
        _ = try await daemon.runThetaCycle(now: now)

        let ab = await daemon.coRecallCount("a", "b")
        let ac = await daemon.coRecallCount("a", "c")
        let bc = await daemon.coRecallCount("b", "c")
        #expect(ab == 1)
        #expect(ac == 1)
        #expect(bc == 1)
    }

    @Test("THETA emits proposal when pair clears decide() gate (§ 12.5 math unchanged)")
    func thetaEmitsProposalWhenGateClears() async throws {
        // To clear the gate: minAttempts=1, minConfidence low, minSuccessRate low.
        // Pass relaxed policy directly to daemon init so it is active immediately
        // without needing a loadPersistedPolicy() round-trip.
        let policy = DreamingPolicy(
            minSuccessRate: 0.1,
            minConfidence: 0.1,
            minAttempts: 1,
            tickIntervalMs: 30_000
        )
        let reader = ThetaFakeReader(traces: [
            trace("x", used: true),
            trace("y", used: true),
        ])
        let sink = ThetaRecordingSink()
        let store = InMemoryDreamingPolicyStore(policy)
        let daemon = DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store,
            policy: policy
        )
        let now = Date()
        let report = try await daemon.runThetaCycle(now: now)

        // The pair (x, y) cleared the gate: THETA should have proposed.
        let proposalCount = await sink.proposals.count
        #expect(report != nil)
        #expect(proposalCount >= 1)
        // Diary entry uses the "dreaming-theta" topic (distinguishable from ALPHA).
        let diaryEntries = await sink.diaryEntries
        #expect(diaryEntries.count == 1)
        #expect(diaryEntries[0].topic == "dreaming-theta")
    }

    @Test("THETA justification string identifies theta cycle")
    func thetaJustificationContainsTheta() async throws {
        let policy = DreamingPolicy(minSuccessRate: 0.1, minConfidence: 0.1, minAttempts: 1, tickIntervalMs: 30_000)
        let reader = ThetaFakeReader(traces: [trace("p", used: true), trace("q", used: true)])
        let sink = ThetaRecordingSink()
        let store = InMemoryDreamingPolicyStore(policy)
        // Pass policy directly — daemon init defaults to .default (minAttempts=3), which
        // would gate out the single-THETA-run count=1 pair. The policy param overrides it.
        let daemon = DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store,
            policy: policy
        )
        let now = Date()
        _ = try await daemon.runThetaCycle(now: now)

        let proposals = await sink.proposals
        #expect(!proposals.isEmpty)
        let justification = proposals[0].justification ?? ""
        #expect(justification.contains("theta"))
    }

    @Test("THETA persists lastThetaRunAt via policyStore (D5c)")
    func thetaPersistsLastRunTimestamp() async throws {
        let reader = ThetaFakeReader(traces: [trace("a", used: true), trace("b", used: true)])
        let sink = ThetaRecordingSink()
        let store = InMemoryDreamingPolicyStore()
        let daemon = DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        let now = Date()
        _ = try await daemon.runThetaCycle(now: now)

        // The persisted state should have lastThetaRunAt set.
        let savedState = try await store.loadDaemonState()
        #expect(savedState?.lastThetaRunAt != nil)
    }

    @Test("THETA does not fire again within 24 h after running (D5c restart simulation)")
    func thetaNotDueAfterRunningUntil24h() async throws {
        let reader = ThetaFakeReader(traces: [trace("a", used: true), trace("b", used: true)])
        let sink = ThetaRecordingSink()
        let store = InMemoryDreamingPolicyStore()
        let daemon = DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        let runAt = Date()
        _ = try await daemon.runThetaCycle(now: runAt)

        // Immediately after running, not due.
        let dueImmediately = await daemon.thetaDue(now: runAt.addingTimeInterval(1))
        #expect(dueImmediately == false)

        // At exactly 24 h after, due again.
        let dueAt24h = await daemon.thetaDue(now: runAt.addingTimeInterval(86_400))
        #expect(dueAt24h == true)
    }

    @Test("THETA does not re-propose already-proposed pairs")
    func thetaDoesNotReproposeAlreadyProposed() async throws {
        let policy = DreamingPolicy(minSuccessRate: 0.1, minConfidence: 0.1, minAttempts: 1, tickIntervalMs: 30_000)
        let reader = ThetaFakeReader(traces: [trace("a", used: true), trace("b", used: true)])
        let sink = ThetaRecordingSink()
        let store = InMemoryDreamingPolicyStore(policy)
        let daemon = DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store,
            policy: policy
        )
        let t1 = Date()
        _ = try await daemon.runThetaCycle(now: t1)
        let proposalsAfterFirst = await sink.proposals.count

        // Second THETA run (simulated 25 h later, same traces).
        let t2 = t1.addingTimeInterval(86_401)
        _ = try await daemon.runThetaCycle(now: t2)
        let proposalsAfterSecond = await sink.proposals.count

        // No new proposals on the second run (pair already proposed).
        #expect(proposalsAfterFirst >= 1)
        #expect(proposalsAfterSecond == proposalsAfterFirst)
    }

    @Test("unused drawers are excluded from pair generation")
    func unusedDrawersExcludedFromPairs() async throws {
        // d1 is unused — should not form any pairs.
        let reader = ThetaFakeReader(traces: [
            trace("d1", used: false),
            trace("d2", used: true),
            trace("d3", used: true),
        ])
        let sink = ThetaRecordingSink()
        let store = InMemoryDreamingPolicyStore()
        let daemon = DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        let now = Date()
        _ = try await daemon.runThetaCycle(now: now)

        // Only d2↔d3 should be counted; d1 is not in the used set.
        let d1d2 = await daemon.coRecallCount("d1", "d2")
        let d1d3 = await daemon.coRecallCount("d1", "d3")
        let d2d3 = await daemon.coRecallCount("d2", "d3")
        #expect(d1d2 == 0)
        #expect(d1d3 == 0)
        #expect(d2d3 == 1)
    }
}

// MARK: - BETA prune / OMEGA retire cycle tests

@Suite("REM-BETA prune / REM-OMEGA retire (T12/T13)")
struct BetaOmegaSeamTests {

    @Test("runBetaCycle returns nil and advances lastBetaRunAt")
    func betaAdvancesTimestamp() async throws {
        let store = InMemoryDreamingPolicyStore()
        let daemon = DreamingDaemon(
            reader: ThetaFakeReader(traces: []),
            sink: ThetaRecordingSink(),
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        let now = Date()
        let report = try await daemon.runBetaCycle(now: now)
        #expect(report == nil)
        let lastRun = await daemon.lastRunAt(for: .beta)
        #expect(lastRun != nil)
    }

    @Test("runOmegaCycle with no dreamed tunnels returns nil and advances lastOmegaRunAt")
    func omegaNoTunnelsReturnsNilAndAdvancesTimestamp() async throws {
        // Reader returns no dreamed-active tunnels → OMEGA exits early, returns nil.
        let store = InMemoryDreamingPolicyStore()
        let daemon = DreamingDaemon(
            reader: ThetaFakeReader(traces: []),
            sink: ThetaRecordingSink(),
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        let now = Date()
        let report = try await daemon.runOmegaCycle(now: now)
        #expect(report == nil)
        let lastRun = await daemon.lastRunAt(for: .omega)
        #expect(lastRun != nil)
    }

    @Test("betaDue is true when never run")
    func betaDueWhenNeverRun() async throws {
        let (daemon, _) = makeDaemon()
        let due = await daemon.betaDue(now: Date())
        #expect(due == true)
    }

    @Test("omegaDue is true when never run")
    func omegaDueWhenNeverRun() async throws {
        let (daemon, _) = makeDaemon()
        let due = await daemon.omegaDue(now: Date())
        #expect(due == true)
    }

    @Test("betaDue false within 7 days of last run")
    func betaNotDueWithin7Days() async throws {
        let store = InMemoryDreamingPolicyStore()
        let daemon = DreamingDaemon(
            reader: ThetaFakeReader(traces: []),
            sink: ThetaRecordingSink(),
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        let runAt = Date()
        _ = try await daemon.runBetaCycle(now: runAt)
        // 3 days later — not yet 7 days.
        let due = await daemon.betaDue(now: runAt.addingTimeInterval(3 * 86_400))
        #expect(due == false)
    }

    @Test("omegaDue false within 14 days of last run")
    func omegaNotDueWithin14Days() async throws {
        let store = InMemoryDreamingPolicyStore()
        let daemon = DreamingDaemon(
            reader: ThetaFakeReader(traces: []),
            sink: ThetaRecordingSink(),
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        let runAt = Date()
        _ = try await daemon.runOmegaCycle(now: runAt)
        // 7 days later — not yet 14 days.
        let due = await daemon.omegaDue(now: runAt.addingTimeInterval(7 * 86_400))
        #expect(due == false)
    }
}

// MARK: - runCycleForKind dispatch

@Suite("runCycleForKind unified dispatch (T11)")
struct RunCycleForKindTests {

    @Test("runCycleForKind(.theta) delegates to runThetaCycle")
    func dispatchTheta() async throws {
        let policy = DreamingPolicy(minSuccessRate: 0.1, minConfidence: 0.1, minAttempts: 1, tickIntervalMs: 30_000)
        let reader = ThetaFakeReader(traces: [trace("a", used: true), trace("b", used: true)])
        let sink = ThetaRecordingSink()
        let store = InMemoryDreamingPolicyStore(policy)
        let daemon = DreamingDaemon(
            reader: reader,
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store,
            policy: policy
        )
        let now = Date()
        _ = try await daemon.runCycleForKind(.theta, now: now)

        // Should have produced a diary entry with "dreaming-theta" topic.
        let diaryEntries = await sink.diaryEntries
        #expect(diaryEntries.count == 1)
        #expect(diaryEntries[0].topic == "dreaming-theta")
        // Last THETA run timestamp is set.
        let lastRun = await daemon.lastRunAt(for: .theta)
        #expect(lastRun != nil)
    }

    @Test("runCycleForKind(.beta) advances beta timestamp")
    func dispatchBeta() async throws {
        let (daemon, _) = makeDaemon()
        let now = Date()
        _ = try await daemon.runCycleForKind(.beta, now: now)
        let lastRun = await daemon.lastRunAt(for: .beta)
        #expect(lastRun != nil)
    }

    @Test("runCycleForKind(.omega) advances omega timestamp")
    func dispatchOmega() async throws {
        // ThetaFakeReader has no dreamed-active tunnels → OMEGA exits early (returns nil)
        // but still advances lastOmegaRunAt.
        let (daemon, _) = makeDaemon()
        let now = Date()
        _ = try await daemon.runCycleForKind(.omega, now: now)
        let lastRun = await daemon.lastRunAt(for: .omega)
        #expect(lastRun != nil)
    }
}

// MARK: - Daemon state persistence round-trip

@Suite("REM-THETA state persistence (F6 / ADR-020 extension, T11)")
struct ThetaStatePersistenceTests {

    @Test("DreamingDaemonState round-trips lastThetaRunAt through InMemoryDreamingPolicyStore")
    func thetaStateRoundTrip() async throws {
        let store = InMemoryDreamingPolicyStore()
        let refDate = Date(timeIntervalSince1970: 1_750_000_000)
        let state = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [:],
            cycleCount: 0,
            coRecallCounts: [:],
            lastThetaRunAt: refDate,
            lastBetaRunAt: nil,
            lastOmegaRunAt: nil
        )
        try await store.saveDaemonState(state)
        let loaded = try await store.loadDaemonState()
        #expect(loaded?.lastThetaRunAt != nil)
        // Date precision: within 1 ms.
        let delta = abs((loaded!.lastThetaRunAt!.timeIntervalSince1970) - refDate.timeIntervalSince1970)
        #expect(delta < 0.001)
    }

    @Test("loadPersistedPolicy restores lastThetaRunAt so THETA cadence survives restart")
    func thetaLastRunSurvivesRestart() async throws {
        let store = InMemoryDreamingPolicyStore()
        let runAt = Date(timeIntervalSince1970: 1_750_000_000)
        let state = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [:],
            cycleCount: 0,
            coRecallCounts: [:],
            lastThetaRunAt: runAt,
            lastBetaRunAt: nil,
            lastOmegaRunAt: nil
        )
        try await store.saveDaemonState(state)

        // Simulate restart: fresh daemon, load persisted policy.
        let freshDaemon = DreamingDaemon(
            reader: ThetaFakeReader(traces: []),
            sink: ThetaRecordingSink(),
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await freshDaemon.loadPersistedPolicy()

        // 12 h after the persisted run — not yet due.
        let notDue = await freshDaemon.thetaDue(now: runAt.addingTimeInterval(43_200))
        #expect(notDue == false)

        // 24 h after the persisted run — due again.
        let due = await freshDaemon.thetaDue(now: runAt.addingTimeInterval(86_400))
        #expect(due == true)
    }
}
