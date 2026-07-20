// DreamingBetaTests.swift
//
// Conformance tests for the REM-BETA weekly prune/GC cycle.
//
// Covers:
//   Prune — `consolidated` entries below betaPruneFloor are removed;
//            above-floor entries are retained. Exact survivor set asserted.
//   Co-recall orphan prune — `coRecallCounts` entries whose key is not in
//            `consolidated` after the prune are dropped; live entries kept.
//   Memory-only — BETA writes no tunnels, proposals, or diary entries.
//            The recording sink stays empty after a BETA run.
//   Cadence / persistence — BETA not due within 7 days; when due it prunes
//            and advances lastBetaRunAt; the new timestamp survives a
//            daemon-state restore so BETA is not due again until +7d.
//   Anti-inert — a test that would pass on the old no-op seam must fail
//            when BETA's prune body is present: it asserts that a
//            below-floor entry IS gone, not merely that the cycle ran.
//   ALPHA / THETA regression — existing cycles unaffected.
//
// All substrate interaction uses in-memory seam fakes. The clock is
// always injected; no wall-clock reads inside cycle code.

import Testing
import Foundation
import GeniusLocusKit
@testable import NeuronKit

// MARK: - Seam fakes

/// Recording sink that tracks every proposal and diary write.
/// BETA should never call either — we assert both counts stay at 0.
private actor BetaRecordingSink: DreamingProposalSink {
    private(set) var proposals: [ProposeFrame] = []
    private(set) var diaryEntries: [DiaryEntry] = []

    func propose(_ frame: ProposeFrame) async throws { proposals.append(frame) }
    func recordCycleDiary(_ entry: DiaryEntry) async throws { diaryEntries.append(entry) }
    func pruneRecallTraces(olderThan _: Date) async throws -> Int { 0 }
}

/// Minimal reader: empty traces, empty drain, no existing tunnels.
/// BETA does not read the substrate — it only mutates in-memory maps.
/// This reader satisfies the DreamingDaemon constructor requirement.
private actor BetaFakeReader: DreamingSubstrateReader {
    func recentRecallTraces(since _: Date, now _: Date) async throws -> [RecallTraceItem] { [] }
    func drainDreamingWindow() async throws -> [[String]] { [] }
    func existingTunnels() async throws -> [Tunnel] { [] }
}

// MARK: - Test helpers

/// Construct a DreamingDaemon with an in-memory policy store and the BETA
/// recording sink. Returns both so tests can inspect sink and store state.
private func makeBetaDaemon(
    policy: DreamingPolicy = .default
) -> (DreamingDaemon, InMemoryDreamingPolicyStore, BetaRecordingSink) {
    let store = InMemoryDreamingPolicyStore(policy)
    let sink = BetaRecordingSink()
    let daemon = DreamingDaemon(
        reader: BetaFakeReader(),
        sink: sink,
        rewardSource: RecallTraceRewardSource(),
        policyStore: store
    )
    return (daemon, store, sink)
}

// MARK: - Prune semantics

@Suite("REM-BETA prune semantics (T12)")
struct BetaPruneTests {

    /// BETA must remove consolidated entries below betaPruneFloor and keep
    /// those at or above it. This is the primary correctness test — if the
    /// prune body were removed (seam reverted to no-op), the below-floor
    /// entries would remain and this test would fail.
    @Test("BETA prunes below-floor consolidated entries; retains above-floor")
    func prunesDecayedConsolidatedEntries() async throws {
        let (daemon, _, _) = makeBetaDaemon()

        // Seed consolidated via bumpCoRecall (which populates coRecallCounts)
        // and then inject consolidated values directly by running a no-op THETA
        // that skips the decide gate. We use the internal testOnly accessor to
        // pre-load state via the daemon-state restore path — the cleanest seam.
        //
        // Inject state: two below-floor entries + two above-floor entries.
        // betaPruneFloor = 0.01; we use 0.005 and 0.009 as below, 0.02 and
        // 0.8 as above. Key format: "a|b" (lexicographic min first).
        let belowKey1 = "drawer-a|drawer-b"   // 0.005 < 0.01 → pruned
        let belowKey2 = "drawer-c|drawer-d"   // 0.009 < 0.01 → pruned
        let aboveKey1 = "drawer-e|drawer-f"   // 0.020 >= 0.01 → kept
        let aboveKey2 = "drawer-g|drawer-h"   // 0.800 >= 0.01 → kept

        let seededState = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [
                belowKey1: 0.005,
                belowKey2: 0.009,
                aboveKey1: 0.020,
                aboveKey2: 0.800,
            ],
            cycleCount: 0,
            coRecallCounts: [:],
            lastThetaRunAt: nil,
            lastBetaRunAt: nil,
            lastOmegaRunAt: nil
        )
        let store = InMemoryDreamingPolicyStore()
        try await store.saveDaemonState(seededState)

        let sink = BetaRecordingSink()
        let daemon2 = DreamingDaemon(
            reader: BetaFakeReader(),
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await daemon2.loadPersistedPolicy()

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await daemon2.runBetaCycle(now: now)

        let state = await daemon2.currentDaemonState_testOnly()

        // Below-floor entries must be gone.
        #expect(state.consolidated[belowKey1] == nil,
            "below-floor entry (0.005) should be pruned by BETA")
        #expect(state.consolidated[belowKey2] == nil,
            "below-floor entry (0.009) should be pruned by BETA")

        // Above-floor entries must be retained.
        #expect(state.consolidated[aboveKey1] != nil,
            "above-floor entry (0.020) must be retained by BETA")
        #expect(state.consolidated[aboveKey2] != nil,
            "above-floor entry (0.800) must be retained by BETA")

        // Exact survivor count: 2 of 4 entries remain.
        #expect(state.consolidated.count == 2,
            "exactly 2 above-floor entries should survive BETA prune")
    }

    /// Anti-inert companion: if the above test asserts that below-floor entries
    /// are gone, the same seeded state with a manual check that the entries
    /// ARE present before the cycle verifies the setup is correct (i.e. the
    /// entries were actually there before BETA ran).
    @Test("Pre-BETA state confirms below-floor entries exist before cycle runs")
    func preBetaStateHasBelowFloorEntries() async throws {
        let belowKey1 = "drawer-a|drawer-b"

        let seededState = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [belowKey1: 0.005],
            cycleCount: 0,
            coRecallCounts: [:],
            lastThetaRunAt: nil,
            lastBetaRunAt: nil,
            lastOmegaRunAt: nil
        )
        let store = InMemoryDreamingPolicyStore()
        try await store.saveDaemonState(seededState)

        let sink = BetaRecordingSink()
        let daemon2 = DreamingDaemon(
            reader: BetaFakeReader(),
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await daemon2.loadPersistedPolicy()

        // Before BETA runs, the below-floor entry is present.
        let before = await daemon2.currentDaemonState_testOnly()
        #expect(before.consolidated[belowKey1] != nil,
            "below-floor entry should be present before BETA runs")
    }

    /// Verify the exact-zero boundary: an entry exactly at betaPruneFloor (0.01)
    /// is NOT pruned — the floor is strictly "below which", so 0.01 survives.
    @Test("BETA retains consolidated entry exactly at betaPruneFloor (boundary)")
    func retainsEntryAtExactFloor() async throws {
        let atFloorKey = "drawer-x|drawer-y"

        let seededState = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [atFloorKey: DreamingDaemon.betaPruneFloor],
            cycleCount: 0,
            coRecallCounts: [:],
            lastThetaRunAt: nil,
            lastBetaRunAt: nil,
            lastOmegaRunAt: nil
        )
        let store = InMemoryDreamingPolicyStore()
        try await store.saveDaemonState(seededState)
        let sink = BetaRecordingSink()
        let daemon2 = DreamingDaemon(
            reader: BetaFakeReader(),
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await daemon2.loadPersistedPolicy()

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await daemon2.runBetaCycle(now: now)

        let state = await daemon2.currentDaemonState_testOnly()
        #expect(state.consolidated[atFloorKey] != nil,
            "entry exactly at betaPruneFloor should be retained (strictly below is pruned)")
    }

    /// Co-recall counts for pruned pairs (keys absent from consolidated after
    /// BETA prune) must be dropped. Counts for live pairs must be kept.
    @Test("BETA prunes orphaned co_recall_counts; retains counts for live pairs")
    func prunesOrphanedCoRecallCounts() async throws {
        let liveKey    = "drawer-e|drawer-f"   // consolidated 0.8 → survives prune
        let prunedKey  = "drawer-a|drawer-b"   // consolidated 0.005 → pruned

        let seededState = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [
                liveKey:   0.800,
                prunedKey: 0.005,
            ],
            cycleCount: 0,
            coRecallCounts: [
                liveKey:   3,   // live pair → must survive
                prunedKey: 7,   // orphan after consolidated prune → must be dropped
            ],
            lastThetaRunAt: nil,
            lastBetaRunAt: nil,
            lastOmegaRunAt: nil
        )
        let store = InMemoryDreamingPolicyStore()
        try await store.saveDaemonState(seededState)
        let sink = BetaRecordingSink()
        let daemon2 = DreamingDaemon(
            reader: BetaFakeReader(),
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await daemon2.loadPersistedPolicy()

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await daemon2.runBetaCycle(now: now)

        let state = await daemon2.currentDaemonState_testOnly()

        // Live pair: consolidated entry kept → co-recall count retained.
        #expect(state.coRecallCounts[liveKey] == 3,
            "co-recall count for live pair must be retained by BETA")

        // Orphan pair: consolidated entry pruned → co-recall count dropped.
        #expect(state.coRecallCounts[prunedKey] == nil,
            "orphaned co-recall count (consolidated pruned) must be dropped by BETA")
    }
}

// MARK: - Memory-only (no tunnel writes)

@Suite("REM-BETA memory-only constraint (§ 12.6 'Tunnel writes: none')")
struct BetaMemoryOnlyTests {

    /// BETA must never emit a proposal or a diary entry.
    /// The recording sink should be empty after a BETA cycle.
    @Test("BETA does not write proposals or diary entries")
    func betaWritesNoProposalsOrDiaryEntries() async throws {
        // Seed a non-trivial consolidated so there is prune work to do.
        let seededState = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [
                "a|b": 0.005,   // will be pruned
                "c|d": 0.900,   // will be kept
            ],
            cycleCount: 0,
            coRecallCounts: ["a|b": 5, "c|d": 3],
            lastThetaRunAt: nil,
            lastBetaRunAt: nil,
            lastOmegaRunAt: nil
        )
        let store = InMemoryDreamingPolicyStore()
        try await store.saveDaemonState(seededState)

        let sink = BetaRecordingSink()
        let daemon2 = DreamingDaemon(
            reader: BetaFakeReader(),
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await daemon2.loadPersistedPolicy()

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await daemon2.runBetaCycle(now: now)

        let proposals = await sink.proposals
        let diary = await sink.diaryEntries

        #expect(proposals.isEmpty,
            "BETA must not emit any proposals (§ 12.6 Tunnel writes: none)")
        #expect(diary.isEmpty,
            "BETA must not write any diary entries")
    }

    /// runBetaCycle returns nil — no cycle report is produced.
    @Test("runBetaCycle returns nil (no report)")
    func betaReturnsNil() async throws {
        let (daemon, _, _) = makeBetaDaemon()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let report = try await daemon.runBetaCycle(now: now)
        #expect(report == nil)
    }
}

// MARK: - Cadence and persistence

@Suite("REM-BETA cadence and persistence (D5a / D5c, T12)")
struct BetaCadenceTests {

    /// A freshly-constructed daemon (lastBetaRunAt = nil) reports BETA as due.
    @Test("betaDue returns true when never run")
    func betaDueWhenNeverRun() async throws {
        let (daemon, _, _) = makeBetaDaemon()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let due = await daemon.betaDue(now: now)
        #expect(due == true)
    }

    /// After a BETA run, the cycle is not due again within the 7-day window.
    @Test("betaDue returns false within 7 days of last run")
    func betaNotDueWithin7Days() async throws {
        let (daemon, _, _) = makeBetaDaemon()
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await daemon.runBetaCycle(now: t0)

        // 3 days later — not yet due.
        let threeDaysLater = t0.addingTimeInterval(3 * 86_400)
        let notDue = await daemon.betaDue(now: threeDaysLater)
        #expect(notDue == false)
    }

    /// After 7 days, BETA is due again.
    @Test("betaDue returns true after 7 days")
    func betaDueAfter7Days() async throws {
        let (daemon, _, _) = makeBetaDaemon()
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await daemon.runBetaCycle(now: t0)

        let sevenDaysLater = t0.addingTimeInterval(DreamingDaemon.betaCadenceSecs)
        let due = await daemon.betaDue(now: sevenDaysLater)
        #expect(due == true)
    }

    /// lastBetaRunAt is persisted in daemon state and survives a restart so the
    /// 7-day cadence gate works correctly after a process restart (D5c).
    @Test("lastBetaRunAt survives daemon-state restore (D5c)")
    func betaLastRunSurvivesRestart() async throws {
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)

        // Save a state with lastBetaRunAt = t0.
        let seededState = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [:],
            cycleCount: 0,
            coRecallCounts: [:],
            lastThetaRunAt: nil,
            lastBetaRunAt: t0,
            lastOmegaRunAt: nil
        )
        let store = InMemoryDreamingPolicyStore()
        try await store.saveDaemonState(seededState)

        // Fresh daemon loads the stored state.
        let sink = BetaRecordingSink()
        let fresh = DreamingDaemon(
            reader: BetaFakeReader(),
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await fresh.loadPersistedPolicy()

        // 3 days after t0 — not due (persisted timestamp holds).
        let notDue = await fresh.betaDue(now: t0.addingTimeInterval(3 * 86_400))
        #expect(notDue == false,
            "BETA should not be due 3 days after the persisted last run")

        // 7 days after t0 — due again.
        let due = await fresh.betaDue(now: t0.addingTimeInterval(DreamingDaemon.betaCadenceSecs))
        #expect(due == true,
            "BETA should be due again after 7 days from the persisted last run")
    }

    /// The lastBetaRunAt persisted after a BETA run matches the `now` passed in.
    @Test("runBetaCycle advances lastBetaRunAt and persists it")
    func betaAdvancesAndPersistsTimestamp() async throws {
        let store = InMemoryDreamingPolicyStore()
        let sink = BetaRecordingSink()
        let daemon2 = DreamingDaemon(
            reader: BetaFakeReader(),
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await daemon2.runBetaCycle(now: now)

        // Inspect the saved state.
        let saved = try await store.loadDaemonState()
        let savedBeta = saved?.lastBetaRunAt
        #expect(savedBeta != nil,
            "lastBetaRunAt should be persisted after BETA runs")
        let delta = abs((savedBeta!.timeIntervalSince1970) - now.timeIntervalSince1970)
        #expect(delta < 0.001,
            "persisted lastBetaRunAt should match the injected now (within 1 ms)")
    }

    /// Pruned state (shrunken maps) survives the persistence round-trip so the
    /// GC effect is durable across daemon restarts.
    @Test("Pruned consolidated + co_recall_counts survive daemon-state restore")
    func prunedStateSurvivesRestore() async throws {
        // Seed: one below-floor entry with a co-recall count.
        let prunedKey = "d1|d2"
        let liveKey   = "d3|d4"
        let seededState = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [prunedKey: 0.005, liveKey: 0.9],
            cycleCount: 0,
            coRecallCounts: [prunedKey: 3, liveKey: 5],
            lastThetaRunAt: nil,
            lastBetaRunAt: nil,
            lastOmegaRunAt: nil
        )
        let store = InMemoryDreamingPolicyStore()
        try await store.saveDaemonState(seededState)

        let sink = BetaRecordingSink()
        let daemon2 = DreamingDaemon(
            reader: BetaFakeReader(),
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await daemon2.loadPersistedPolicy()

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await daemon2.runBetaCycle(now: now)

        // Simulate restart: fresh daemon loads the post-BETA state.
        let sink2 = BetaRecordingSink()
        let fresh = DreamingDaemon(
            reader: BetaFakeReader(),
            sink: sink2,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await fresh.loadPersistedPolicy()

        let state = await fresh.currentDaemonState_testOnly()

        // Pruned entry must not reappear after restore.
        #expect(state.consolidated[prunedKey] == nil,
            "pruned consolidated entry must not reappear after daemon restart")
        #expect(state.coRecallCounts[prunedKey] == nil,
            "orphaned co-recall count must not reappear after daemon restart")

        // Live entry must survive the round-trip.
        #expect(state.consolidated[liveKey] != nil,
            "live consolidated entry must survive daemon restart")
        #expect(state.coRecallCounts[liveKey] == 5,
            "live co-recall count must survive daemon restart")
    }
}

// MARK: - ALPHA / THETA regression

@Suite("REM-ALPHA / THETA regression (T12 must not disturb prior cycles)")
struct BetaRegressionTests {

    /// Running BETA after a THETA cycle must leave THETA's lastThetaRunAt intact.
    @Test("runBetaCycle does not reset lastThetaRunAt")
    func betaDoesNotResetTheta() async throws {
        let thetaAt = Date(timeIntervalSince1970: 1_750_000_000)
        let seededState = DreamingDaemonState(
            lastTickAt: nil,
            proposedKeys: [],
            lastReindexVocab: -1,
            consolidated: [:],
            cycleCount: 0,
            coRecallCounts: [:],
            lastThetaRunAt: thetaAt,
            lastBetaRunAt: nil,
            lastOmegaRunAt: nil
        )
        let store = InMemoryDreamingPolicyStore()
        try await store.saveDaemonState(seededState)
        let sink = BetaRecordingSink()
        let daemon2 = DreamingDaemon(
            reader: BetaFakeReader(),
            sink: sink,
            rewardSource: RecallTraceRewardSource(),
            policyStore: store
        )
        try await daemon2.loadPersistedPolicy()

        let betaNow = thetaAt.addingTimeInterval(3 * 86_400)
        _ = try await daemon2.runBetaCycle(now: betaNow)

        let state = await daemon2.currentDaemonState_testOnly()
        let delta = abs((state.lastThetaRunAt!.timeIntervalSince1970) - thetaAt.timeIntervalSince1970)
        #expect(delta < 0.001,
            "BETA must not modify lastThetaRunAt")
    }

    /// runCycleForKind(.beta) dispatches to runBetaCycle and advances the
    /// lastBetaRunAt timestamp — confirming the dispatch table is wired correctly.
    @Test("runCycleForKind(.beta) advances lastBetaRunAt")
    func dispatchBeta() async throws {
        let (daemon, _, _) = makeBetaDaemon()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await daemon.runCycleForKind(.beta, now: now)
        let lastRun = await daemon.lastRunAt(for: .beta)
        #expect(lastRun != nil,
            "runCycleForKind(.beta) must advance lastBetaRunAt")
    }
}
