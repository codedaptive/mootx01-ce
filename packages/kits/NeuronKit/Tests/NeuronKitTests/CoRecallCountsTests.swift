// CoRecallCountsTests.swift
//
// Tests for the per-pair co-recall counts store on DreamingDaemon
// (NEURONKIT_SPEC § 12.4). The store tracks how many distinct recall
// events have paired (a, b). T8 drain bumps it; T8 decide reads it for
// the minAttempts gate. This module owns the store and its persistence.
//
// The tests mirror the Rust CR-1 through CR-5 tests in dreaming_cycle.rs
// so cross-port parity is structurally enforced: the same inputs must
// produce the same key strings and the same counts in both ports.

import Foundation
import Testing
import GeniusLocusKit
@testable import NeuronKit

// Minimal fakes — same shape as the other DreamingDaemon test files.

private actor FakeReader: DreamingSubstrateReader {
    func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem] { [] }
    func drainDreamingWindow() async throws -> [[String]] { [] }
    func existingTunnels() async throws -> [Tunnel] { [] }
}

private actor FakeSink: DreamingProposalSink {
    func propose(_ frame: ProposeFrame) async throws {}
    func recordCycleDiary(_ entry: DiaryEntry) async throws {}
    @discardableResult
    func pruneRecallTraces(olderThan cutoff: Date) async throws -> Int { 0 }
}

private actor InMemoryStoreWithState: DreamingPolicyStore {
    private var storedState: DreamingDaemonState?

    func loadPolicy() async throws -> DreamingPolicy? { nil }
    func savePolicy(_ policy: DreamingPolicy) async throws {}
    func loadBandit() async throws -> SolverBandit? { nil }
    func saveBandit(_ bandit: SolverBandit) async throws {}
    func loadDaemonState() async throws -> DreamingDaemonState? { storedState }
    func saveDaemonState(_ state: DreamingDaemonState) async throws { storedState = state }
}

/// Build a daemon with the given policy store. Growth probe is nil (auto-reindex
/// disabled) so the tests are purely about co-recall mechanics.
private func makeDaemon(store: some DreamingPolicyStore) -> DreamingDaemon {
    DreamingDaemon(
        reader: FakeReader(),
        sink: FakeSink(),
        policyStore: store
    )
}

@Suite("DreamingDaemon — co-recall counts (NEURONKIT_SPEC § 12.4)")
struct CoRecallCountsTests {

    // CR-1: increment semantics — N bumps of the same pair → count N;
    // absent pair returns 0.
    @Test("CR-1: bump increments count; absent pair returns 0")
    func cr1_bumpIncrements() async {
        let store = InMemoryDreamingPolicyStore()
        let daemon = makeDaemon(store: store)
        let a = "drawer-alpha"
        let b = "drawer-beta"

        await #expect(daemon.coRecallCount(a, b) == 0, "absent pair must return 0")
        await daemon.bumpCoRecall(a, b)
        await #expect(daemon.coRecallCount(a, b) == 1)
        await daemon.bumpCoRecall(a, b)
        await #expect(daemon.coRecallCount(a, b) == 2)
        await daemon.bumpCoRecall(a, b)
        await #expect(daemon.coRecallCount(a, b) == 3)
    }

    // CR-2: canonical key order-independence — bump(a, b) is readable as
    // coRecallCount(b, a); the canonical key is the same regardless of
    // endpoint order.
    @Test("CR-2: co-recall count is order-independent")
    func cr2_orderIndependentKey() async {
        let store = InMemoryDreamingPolicyStore()
        let daemon = makeDaemon(store: store)

        await daemon.bumpCoRecall("alpha", "beta")
        // Reading with reversed order must return the same count.
        await #expect(daemon.coRecallCount("beta", "alpha") == 1)
        // Bumping with reversed order increments the same counter.
        await daemon.bumpCoRecall("beta", "alpha")
        await #expect(daemon.coRecallCount("alpha", "beta") == 2)
    }

    // CR-3: distinct pairs are independent — bumping (a, b) does not
    // affect (a, c) or any other pair.
    @Test("CR-3: distinct pairs are independent")
    func cr3_distinctPairsAreIndependent() async {
        let store = InMemoryDreamingPolicyStore()
        let daemon = makeDaemon(store: store)

        await daemon.bumpCoRecall("x", "y")
        await daemon.bumpCoRecall("x", "y")
        await daemon.bumpCoRecall("x", "z")

        await #expect(daemon.coRecallCount("x", "y") == 2)
        await #expect(daemon.coRecallCount("x", "z") == 1)
        await #expect(daemon.coRecallCount("y", "z") == 0, "unseen pair returns 0")
    }

    // CR-4 (anti-inert / persistence round-trip): bump several pairs to
    // distinct counts → snapshot via currentDaemonState (which the governor
    // persists) → loadPersistedPolicy on a fresh daemon from the same store
    // → assert every coRecallCount is preserved exactly.
    //
    // This test fails if the field was added to the daemon but NOT threaded
    // through currentDaemonState() / loadPersistedPolicy() — the class of
    // inert-wiring bug caught in prior missions.
    @Test("CR-4: co-recall counts survive a daemon state snapshot/restore cycle")
    func cr4_persistenceRoundTrip() async throws {
        let store = InMemoryStoreWithState()
        let original = makeDaemon(store: store)

        await original.bumpCoRecall("a", "b") // → 1
        await original.bumpCoRecall("a", "b") // → 2
        await original.bumpCoRecall("a", "b") // → 3
        await original.bumpCoRecall("c", "d") // → 1
        await original.bumpCoRecall("d", "c") // → 2 (same canonical key "c|d")
        await original.bumpCoRecall("m", "z") // → 1

        // Trigger a save to the store (mirrors what the governor does after
        // each cycle: saveDaemonState). The daemon's saveDaemonState is
        // called inside runCycle; we call loadPersistedPolicy on a fresh
        // daemon to simulate a restart restoring from the saved snapshot.
        // To get the state into the store without running a full cycle, we
        // drive through the public loadPersistedPolicy/saveDaemonState
        // round-trip by asking the store directly.
        let snapshot = await original.currentDaemonState_testOnly()
        try await store.saveDaemonState(snapshot)

        // A fresh daemon over the SAME store (the "restart").
        let restored = makeDaemon(store: store)
        try await restored.loadPersistedPolicy()

        await #expect(restored.coRecallCount("a", "b") == 3, "a|b must be 3 after restore")
        await #expect(restored.coRecallCount("c", "d") == 2, "c|d must be 2 after restore")
        await #expect(restored.coRecallCount("m", "z") == 1, "m|z must be 1 after restore")
        await #expect(restored.coRecallCount("x", "y") == 0, "unseen pair is 0 after restore")
    }

    // CR-5: key format parity — the canonical key produced by bumpCoRecall /
    // coRecallCount must match DreamingDecision.candidateKey exactly, which is
    // the same format as the Rust candidate_key ("min|max" lexicographic).
    // Assert the key string for a known pair so cross-port drift is detectable.
    @Test("CR-5: key format matches DreamingDecision.candidateKey — 'min|max' lexicographic")
    func cr5_keyFormatMatchesCandidateKey() async {
        let store = InMemoryDreamingPolicyStore()
        let daemon = makeDaemon(store: store)

        // "alpha" < "omega" → canonical key is "alpha|omega".
        let expectedKey = DreamingDecision.candidateKey("omega", "alpha")
        #expect(expectedKey == "alpha|omega", "candidateKey must produce 'min|max'")

        await daemon.bumpCoRecall("omega", "alpha")
        let snapshot = await daemon.currentDaemonState_testOnly()
        #expect(snapshot.coRecallCounts["alpha|omega"] == 1,
            "state must store the count under the canonical key 'alpha|omega'")
        #expect(snapshot.coRecallCounts.count == 1, "exactly one entry in the map")
    }

    // CR-6: forward-compat decode — persisted DreamingDaemonState written
    // before coRecallCounts existed (T7) must still decode, with the missing
    // key defaulting to an empty map rather than throwing keyNotFound and
    // discarding the rest of the daemon state on a version upgrade. This is
    // the cross-version "old data still loads" guard; the matching Rust test
    // (cr6_pre_t7_state_decodes_with_empty_counts) asserts the same via
    // #[serde(default)]. Without the custom init(from:) the synthesized
    // decoder would reject this JSON (the `= [:]` init default does NOT apply
    // to decoding).
    @Test("CR-6: pre-T7 persisted state decodes with empty coRecallCounts")
    func cr6_preT7StateDecodesWithEmptyCounts() throws {
        // A DreamingDaemonState JSON with NO coRecallCounts key (the shape
        // persisted before T7). lastTickAt omitted too (optional → nil).
        let preT7 = """
        {
            "proposedKeys": ["alpha|beta"],
            "lastReindexVocab": -1,
            "consolidated": {"alpha|beta": 0.8},
            "cycleCount": 4
        }
        """
        let data = Data(preT7.utf8)
        let state = try JSONDecoder().decode(DreamingDaemonState.self, from: data)
        #expect(state.coRecallCounts.isEmpty, "missing coRecallCounts defaults to empty")
        // The pre-existing fields survive intact.
        #expect(state.cycleCount == 4)
        #expect(state.consolidated["alpha|beta"] == 0.8)
        #expect(state.proposedKeys == ["alpha|beta"])
        #expect(state.lastTickAt == nil)
    }
}
