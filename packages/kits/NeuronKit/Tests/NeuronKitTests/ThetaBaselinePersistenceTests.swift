// ThetaBaselinePersistenceTests.swift
//
// Regression coverage for the bug where DreamingDaemon persisted daemon state
// BEFORE firing the THETA retrain, causing the advanced lastReindexVocab to be
// lost on restart. On restart the daemon reloaded the stale pre-retrain baseline
// (often the -1 sentinel) and fireTheta treated -1 as "first ever retrain —
// fire unconditionally", producing a redundant full-corpus reindex on every
// restart of an estate where THETA had already retrained.
//
// Each test simulates a restart by building daemon #2 from the same
// InMemoryDreamingPolicyStore as daemon #1 and calling loadPersistedPolicy().
// The defect manifested as daemon #2 loading lastReindexVocab == -1 (the
// pre-retrain sentinel) instead of the post-retrain vocab count.
//
// Covers:
//   BP-1: consolidation path — lastReindexVocab persists across restart.
//   BP-2: consolidation path — restarted daemon does NOT re-fire retrain when
//          vocab is unchanged.
//   BP-3: early-return / no-data path — lastReindexVocab persists across restart.
//   BP-4: early-return / no-data path — restarted daemon does NOT re-fire retrain
//          when vocab is unchanged.
//
// Timing is deterministic: `now` is always injected. All seam fakes are
// local to this file; existing fakes from ThetaRetrainHookTests are not
// imported to keep the discriminating signal clear.

import Testing
import Foundation
import GeniusLocusKit
@testable import NeuronKit

// MARK: - Local fakes

/// Records retrain calls without touching a live Corpus.
private actor BPHook: ThetaBasisRetrainHook {
    private(set) var callCount: Int = 0

    /// F11: when true, `retrain(now:)` reports a DEGRADED retrain (a
    /// backstop reached, serving basis kept) instead of a full one.
    var shouldDegrade: Bool

    init(shouldDegrade: Bool = false) {
        self.shouldDegrade = shouldDegrade
    }

    @discardableResult
    func retrain(now: Date) async throws -> Bool {
        callCount += 1
        return !shouldDegrade
    }

    func setShouldDegrade(_ v: Bool) { shouldDegrade = v }
}

/// Minimal sink — THETA needs propose and recordCycleDiary.
private actor BPSink: DreamingProposalSink {
    func propose(_ frame: ProposeFrame) async throws {}
    func recordCycleDiary(_ entry: DiaryEntry) async throws {}
    func pruneRecallTraces(olderThan _: Date) async throws -> Int { 0 }
}

/// Growth probe with a settable vocab count. THETA reads vocabAnchor() only;
/// reindex() is the hook's job, not the probe's.
private actor BPGrowthProbe: CorpusGrowthProbe {
    private(set) var vocab: Int
    init(vocab: Int) { self.vocab = vocab }
    func vocabAnchor() async throws -> Int { vocab }
    @discardableResult
    func reindex(now: Date) async throws -> Bool { true }
    func setVocab(_ v: Int) { vocab = v }
}

/// Reader for the consolidation path: returns two used traces so runThetaCycle
/// takes the main consolidation branch (usedSet.count >= 2).
private actor BPConsolidationReader: DreamingSubstrateReader {
    func recentRecallTraces(since _: Date, now _: Date) async throws -> [RecallTraceItem] {
        [
            RecallTraceItem(target: "drawer-X", recalledAt: Date(),
                            operationalBitmap: RecallTraceItem.flagUsed),
            RecallTraceItem(target: "drawer-Y", recalledAt: Date(),
                            operationalBitmap: RecallTraceItem.flagUsed),
        ]
    }
    func drainDreamingWindow() async throws -> [[String]] { [] }
    func existingTunnels() async throws -> [Tunnel] { [] }
}

/// Reader for the early-return / no-data path: returns no traces so
/// usedSet.count < 2 and runThetaCycle returns nil without consolidating.
private actor BPNoDataReader: DreamingSubstrateReader {
    func recentRecallTraces(since _: Date, now _: Date) async throws -> [RecallTraceItem] { [] }
    func drainDreamingWindow() async throws -> [[String]] { [] }
    func existingTunnels() async throws -> [Tunnel] { [] }
}

// MARK: - Helpers

/// Build daemon #1 on the consolidation path (2 used traces).
private func makeConsolidationDaemon(
    store: InMemoryDreamingPolicyStore,
    probe: any CorpusGrowthProbe,
    hook: any ThetaBasisRetrainHook
) -> DreamingDaemon {
    DreamingDaemon(
        reader: BPConsolidationReader(),
        sink: BPSink(),
        rewardSource: RecallTraceRewardSource(),
        policyStore: store,
        growthProbe: probe,
        thetaRetrainHook: hook
    )
}

/// Build daemon #1 on the no-data / early-return path (0 used traces).
private func makeNoDataDaemon(
    store: InMemoryDreamingPolicyStore,
    probe: any CorpusGrowthProbe,
    hook: any ThetaBasisRetrainHook
) -> DreamingDaemon {
    DreamingDaemon(
        reader: BPNoDataReader(),
        sink: BPSink(),
        rewardSource: RecallTraceRewardSource(),
        policyStore: store,
        growthProbe: probe,
        thetaRetrainHook: hook
    )
}

/// Build daemon #2 — a "restarted" daemon sharing the same policy store.
/// After construction the caller calls loadPersistedPolicy() to simulate restart.
private func makeRestartedDaemon(
    store: InMemoryDreamingPolicyStore,
    probe: any CorpusGrowthProbe,
    hook: any ThetaBasisRetrainHook,
    reader: DreamingSubstrateReader
) -> DreamingDaemon {
    DreamingDaemon(
        reader: reader,
        sink: BPSink(),
        rewardSource: RecallTraceRewardSource(),
        policyStore: store,
        growthProbe: probe,
        thetaRetrainHook: hook
    )
}

// MARK: - Tests

@Suite("THETA baseline persistence across restart")
struct ThetaBaselinePersistenceTests {

    // BP-1: consolidation path — lastReindexVocab in the store reflects the
    // post-retrain vocab, not the pre-retrain sentinel, after runThetaCycle.
    //
    // Discriminates the bug: without the second saveDaemonState call the stored
    // state captures lastReindexVocab BEFORE fireTheta advances it, so daemon #2
    // reloads -1 (the sentinel) instead of the post-retrain count.
    @Test("BP-1: consolidation path persists post-retrain lastReindexVocab across restart")
    func bp1_consolidationPathPersistsBaselineAcrossRestart() async throws {
        let store = InMemoryDreamingPolicyStore(.default)
        let probe = BPGrowthProbe(vocab: 500)
        let hook = BPHook()

        // Daemon #1: run one THETA cycle on the consolidation path.
        // Sentinel (-1) fires the retrain immediately; lastReindexVocab advances to 500.
        let daemon1 = makeConsolidationDaemon(store: store, probe: probe, hook: hook)
        let now = Date(timeIntervalSinceReferenceDate: 100_000_000)
        _ = try await daemon1.runThetaCycle(now: now)

        let hookCallsAfterFirst = await hook.callCount
        #expect(hookCallsAfterFirst == 1, "precondition: retrain fired on sentinel path")

        // Daemon #2: fresh instance, same store — simulates a process restart.
        let hook2 = BPHook()
        let daemon2 = makeRestartedDaemon(
            store: store, probe: probe, hook: hook2,
            reader: BPConsolidationReader())
        try await daemon2.loadPersistedPolicy()

        // Verify the reloaded lastReindexVocab is the post-retrain vocab (500),
        // NOT the pre-retrain sentinel (-1).
        let reloadedState = await daemon2.currentDaemonState_testOnly()
        #expect(reloadedState.lastReindexVocab == 500,
                "reloaded lastReindexVocab must equal post-retrain vocab (500), not -1")
    }

    // BP-2: consolidation path — after restart, unchanged vocab does NOT trigger
    // a second retrain. This is the observable consequence of the persistence bug:
    // on a buggy build the restarted daemon sees -1 and fires unconditionally.
    //
    // Discriminates the bug: without the fix, daemon #2 reloads lastReindexVocab == -1
    // and runThetaCycle fires retrain (sentinel path), incrementing hook2.callCount.
    @Test("BP-2: consolidation path — restarted daemon skips retrain when vocab unchanged")
    func bp2_consolidationPathRestartedDaemonSkipsRetrain() async throws {
        let store = InMemoryDreamingPolicyStore(.default)
        let probe = BPGrowthProbe(vocab: 500)
        let hook = BPHook()

        // Daemon #1: fire the first THETA cycle; lastReindexVocab advances to 500.
        let daemon1 = makeConsolidationDaemon(store: store, probe: probe, hook: hook)
        let t1 = Date(timeIntervalSinceReferenceDate: 200_000_000)
        _ = try await daemon1.runThetaCycle(now: t1)

        // Daemon #2: restart; vocab is still 500 (unchanged since the retrain).
        let hook2 = BPHook()
        let daemon2 = makeRestartedDaemon(
            store: store, probe: probe, hook: hook2,
            reader: BPConsolidationReader())
        try await daemon2.loadPersistedPolicy()

        // Drive the drift gate: vocab unchanged → delta = 0 < trigger → skip.
        let t2 = Date(timeIntervalSinceReferenceDate: 200_000_001)
        _ = try await daemon2.runThetaCycle(now: t2)

        let callsAfterRestart = await hook2.callCount
        #expect(callsAfterRestart == 0,
                "restarted daemon must NOT fire retrain when vocab is unchanged since last retrain")
    }

    // BP-3: early-return / no-data path — lastReindexVocab persists across restart.
    // The early-return path (fewer than 2 used drawers) is a separate code branch;
    // a fix applied only to the consolidation path would not cover it.
    //
    // Discriminates the bug: without the second saveDaemonState on the early-return
    // branch the stored state keeps lastReindexVocab == -1 after fireTheta fires.
    @Test("BP-3: early-return path persists post-retrain lastReindexVocab across restart")
    func bp3_earlyReturnPathPersistsBaselineAcrossRestart() async throws {
        let store = InMemoryDreamingPolicyStore(.default)
        let probe = BPGrowthProbe(vocab: 300)
        let hook = BPHook()

        // Daemon #1: run one THETA cycle on the no-data / early-return path.
        // Sentinel (-1) fires the retrain immediately; lastReindexVocab advances to 300.
        let daemon1 = makeNoDataDaemon(store: store, probe: probe, hook: hook)
        let now = Date(timeIntervalSinceReferenceDate: 300_000_000)
        let result = try await daemon1.runThetaCycle(now: now)
        #expect(result == nil, "precondition: early-return path returns nil")

        let hookCallsAfterFirst = await hook.callCount
        #expect(hookCallsAfterFirst == 1, "precondition: retrain fired on sentinel path")

        // Daemon #2: fresh instance, same store — simulates a process restart.
        let hook2 = BPHook()
        let daemon2 = makeRestartedDaemon(
            store: store, probe: probe, hook: hook2,
            reader: BPNoDataReader())
        try await daemon2.loadPersistedPolicy()

        // Verify reloaded lastReindexVocab is the post-retrain vocab (300), not -1.
        let reloadedState = await daemon2.currentDaemonState_testOnly()
        #expect(reloadedState.lastReindexVocab == 300,
                "reloaded lastReindexVocab must equal post-retrain vocab (300), not -1")
    }

    // BP-4: early-return / no-data path — restarted daemon skips retrain when
    // vocab is unchanged. Mirrors BP-2 for the early-return branch.
    //
    // Discriminates the bug: without the fix daemon #2 reloads lastReindexVocab == -1
    // and fires the retrain unconditionally on the second cycle.
    @Test("BP-4: early-return path — restarted daemon skips retrain when vocab unchanged")
    func bp4_earlyReturnPathRestartedDaemonSkipsRetrain() async throws {
        let store = InMemoryDreamingPolicyStore(.default)
        let probe = BPGrowthProbe(vocab: 300)
        let hook = BPHook()

        // Daemon #1: run on no-data path; retrain fires; lastReindexVocab = 300.
        let daemon1 = makeNoDataDaemon(store: store, probe: probe, hook: hook)
        let t1 = Date(timeIntervalSinceReferenceDate: 400_000_000)
        _ = try await daemon1.runThetaCycle(now: t1)

        // Daemon #2: restart; vocab is still 300 (unchanged since the retrain).
        let hook2 = BPHook()
        let daemon2 = makeRestartedDaemon(
            store: store, probe: probe, hook: hook2,
            reader: BPNoDataReader())
        try await daemon2.loadPersistedPolicy()

        // Drive drift gate on no-data path: vocab unchanged → delta = 0 < trigger → skip.
        let t2 = Date(timeIntervalSinceReferenceDate: 400_000_001)
        _ = try await daemon2.runThetaCycle(now: t2)

        let callsAfterRestart = await hook2.callCount
        #expect(callsAfterRestart == 0,
                "restarted daemon must NOT fire retrain when vocab is unchanged since last retrain")
    }

    // BP-5 (F11): a DEGRADED THETA retrain (a document/time backstop reached,
    // serving basis kept) must not advance lastReindexVocab. Before the fix
    // `ThetaBasisRetrainHook.retrain(now:)` returned Void, so a degraded
    // retrain was indistinguishable from a full one and the baseline
    // advanced regardless — the vocabulary drift that hit the backstop was
    // never revisited by a later cycle.
    @Test("BP-5 (F11): a degraded THETA retrain does not advance lastReindexVocab")
    func bp5_degradedRetrainDoesNotAdvanceBaseline() async throws {
        let store = InMemoryDreamingPolicyStore(.default)
        let probe = BPGrowthProbe(vocab: 700)
        let hook = BPHook(shouldDegrade: true)

        // First-ever cycle: sentinel (-1) fires the retrain, but it comes
        // back DEGRADED, so the baseline must stay at the sentinel.
        let daemon1 = makeConsolidationDaemon(store: store, probe: probe, hook: hook)
        let now = Date(timeIntervalSinceReferenceDate: 500_000_000)
        _ = try await daemon1.runThetaCycle(now: now)

        let callsAfterFirst = await hook.callCount
        #expect(callsAfterFirst == 1, "precondition: retrain fired on sentinel path")

        let state = await daemon1.currentDaemonState_testOnly()
        #expect(state.lastReindexVocab == -1,
                "a DEGRADED retrain must leave lastReindexVocab at the sentinel, not advance to the live vocab")

        // The next cycle must retry — the sentinel never cleared — rather
        // than silently accepting the degraded basis as caught up.
        await hook.setShouldDegrade(false)
        let t2 = Date(timeIntervalSinceReferenceDate: 500_000_001)
        _ = try await daemon1.runThetaCycle(now: t2)
        let callsAfterSecond = await hook.callCount
        #expect(callsAfterSecond == 2, "the next cycle must retry the retrain since the baseline never advanced")

        let stateAfterSecond = await daemon1.currentDaemonState_testOnly()
        #expect(stateAfterSecond.lastReindexVocab == 700,
                "a full retrain on the retry must advance the baseline normally")
    }
}
