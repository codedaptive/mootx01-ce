// DreamingDaemonTests.swift
//
// Conformance tests for the dreaming daemon (NEURONKIT_SPEC § 3.1).
// Covers (peer-file mirror): Dreaming/DreamingDaemon.swift,
// Dreaming/DreamingDecision.swift, Dreaming/DreamingPolicy.swift,
// Dreaming/DreamingTriggerMode.swift, Dreaming/RewardSource.swift —
// the decision core, policy, trigger mode, and reward seam are
// exercised through the daemon over the shared seam fakes below.
// Covers C-1 (tick cadence), C-2 (confidence gate), C-6 (one diary
// entry per cycle), C-15 (reads RecallTraceItem.used as reward via the
// RewardSource seam), B-4 (idempotency), and the never-create-Tunnels
// invariant.
//
// All substrate interaction is through NeuronKit-owned seams; these
// tests inject in-memory fakes. They import GeniusLocusKit and LocusKit
// only for the value types (ProposeFrame, RecallTraceItem, DiaryEntry,
// Tunnel) — never for a write path (B-1). The clock is injected by
// passing `now` into every cycle/pump; there are no wall-clock sleeps.
//
// ── Drain model (v2) ─────────────────────────────────────────────────
// FakeReader's drainDreamingWindow() is a queue of window batches: each
// call pops the next batch. Once the queue is empty it returns [] —
// simulating the dreaming queue's drain-once semantics (jobs don't
// reappear after being replied Done). Tests that need N co-recall events
// for pair (a,b) seed windowBatches with N windows each containing [a,b].
// Reward targets are drawer IDs, matching the v2 evidenceTargets=[a,b]
// convention where the co-recalled drawers are their own evidence.

import Testing
import Foundation
import GeniusLocusKit
@testable import NeuronKit

// MARK: - In-memory seam fakes

/// Records every write the daemon makes. The presence of exactly two
/// methods — and the absence of any Tunnel-creation method — is itself
/// the structural proof of the never-create-Tunnels invariant.
private actor RecordingSink: DreamingProposalSink {
    private(set) var proposals: [ProposeFrame] = []
    private(set) var diaryEntries: [DiaryEntry] = []

    func propose(_ frame: ProposeFrame) async throws { proposals.append(frame) }
    func recordCycleDiary(_ entry: DiaryEntry) async throws { diaryEntries.append(entry) }
    func pruneRecallTraces(olderThan cutoff: Date) async throws -> Int { 0 }

    func proposalCount() -> Int { proposals.count }
    func diaryCount() -> Int { diaryEntries.count }
}

/// Drain-queue fake for DreamingSubstrateReader. Each call to
/// drainDreamingWindow() pops the next pre-seeded window batch from the
/// queue. When the queue is exhausted, returns [] — matching the real
/// dreaming-queue drain semantics (consumed jobs do not reappear).
///
/// Tests that need N co-recall events for pair (a, b) seed windowBatches
/// with N inner arrays each containing the string IDs of that pair.
///
/// Two separate tunnel lists separate the two suppression sources:
///   - `tunnels` — returned by existingTunnels(); used when the test
///     exercises the full existing-tunnel protocol (not ALPHA duplicate
///     suppression, which uses dreamedActiveTunnels()).
///   - `dreamedTunnels` — returned by dreamedActiveTunnels(); used by
///     ALPHA's retired-tunnel fix (Part 5). Represents non-tombstoned
///     dreamed tunnels. Defaults to [] so all existing tests continue
///     to see an empty dreamed-tunnel set.
private actor FakeReader: DreamingSubstrateReader {
    var traces: [RecallTraceItem]
    /// Each element is one call's complete return value. Drained FIFO.
    private var windowBatches: [[[String]]]
    var tunnels: [Tunnel]
    /// Non-tombstoned dreamed tunnels for ALPHA duplicate suppression.
    var dreamedTunnels: [Tunnel]

    init(
        traces: [RecallTraceItem] = [],
        windowBatches: [[[String]]] = [],
        tunnels: [Tunnel] = [],
        dreamedTunnels: [Tunnel] = []
    ) {
        self.traces = traces
        self.windowBatches = windowBatches
        self.tunnels = tunnels
        self.dreamedTunnels = dreamedTunnels
    }

    func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem] { traces }

    func drainDreamingWindow() async throws -> [[String]] {
        guard !windowBatches.isEmpty else { return [] }
        return windowBatches.removeFirst()
    }

    func existingTunnels() async throws -> [Tunnel] { tunnels }

    // Returns only non-tombstoned dreamed tunnels, matching the real
    // substrate's dreamedActiveTunnels() semantics. ALPHA uses this
    // for duplicate suppression so that retired (tombstoned) tunnels
    // do NOT block re-formation of the same pair.
    func dreamedActiveTunnels() async throws -> [Tunnel] { dreamedTunnels }

    func setTraces(_ t: [RecallTraceItem]) { traces = t }
}

// MARK: - Builders

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A recall-trace row with `used` set or clear (bit 0 of the bitmap).
/// In v2, `target` is the drawer ID — the same string used as the window
/// endpoint — so the reward map is keyed by drawer ID, matching
/// evidenceTargets = [endpointA, endpointB].
private func trace(_ target: String, used: Bool) -> RecallTraceItem {
    RecallTraceItem(
        target: target,
        recalledAt: t0,
        operationalBitmap: used ? RecallTraceItem.flagUsed : 0
    )
}

private func daemon(
    reader: FakeReader,
    sink: RecordingSink,
    policyStore: DreamingPolicyStore = InMemoryDreamingPolicyStore()
) -> DreamingDaemon {
    NeuronKit.dreamingDaemon(reader: reader, sink: sink, policyStore: policyStore)
}

// ISOLATION NOTE
// Every test that calls triggerDreamingCycle() or pump() acquires the
// process-wide intellectusTestMutex (IntellectusTestLock.swift) because
// those methods emit to the global Intellectus singleton. A concurrent
// telemetry test that has enabled monitoring and installed a capturing
// sink would see extra dreaming metrics, corrupting its exact-count
// assertions. The mutex serialises singleton-emitting tests across all
// suite boundaries via cooperative async suspension (no thread blocked).
// Tests that do not call an emitting function (policy round-trip,
// trigger-mode default) do not hold the mutex.

@Suite("Dreaming daemon conformance")
struct DreamingDaemonTests {

    // MARK: - C-1: tick cadence (injectable clock, no wall-clock sleeps)

    @Test("C-1: tick fires on configured interval within tolerance")
    func c1TickFiresOnConfiguredIntervalWithinTolerance() async throws {
        try await withIntellectusLock {
            let reader = FakeReader()
            let sink = RecordingSink()
            let d = daemon(reader: reader, sink: sink)
            try await d.registerDreamingPolicy(tickIntervalMs: 30_000)

            // First pump always fires (no prior tick).
            let first = try await d.pump(now: t0)
            #expect(first != nil)

            // Mid-interval: not yet due.
            let early = try await d.pump(now: t0.addingTimeInterval(29))
            #expect(early == nil, "tick must not fire before the interval elapses")

            // At the interval: fires.
            let second = try await d.pump(now: t0.addingTimeInterval(30))
            let secondReport = try #require(second)

            // Realised spacing must be within ±10% of the 30_000ms cadence.
            let spacingMs = secondReport.tickedAt.timeIntervalSince(first!.tickedAt) * 1000
            #expect(spacingMs >= 27_000)
            #expect(spacingMs <= 33_000)
        }
    }

    // MARK: - C-2: confidence (and attempts) gate

    // In v2 the FakeReader seeds three classes of drain window, one per pair:
    //   Strong (a, b):      3 windows; traces a+b used → attempts=3, confidence≈0.88
    //   LowConf (c, d):     5 windows; traces c+d unused → attempts=5, confidence≈0.05
    //   FewAttempts (e, f): 1 window;  traces e+f used → attempts=1 < minAttempts(3)
    // Only the strong candidate clears both gates (confidence ≥ 0.7 AND attempts ≥ 3).
    @Test("C-2: proposes only above confidence and attempts")
    func c2ProposesOnlyAboveConfidenceAndAttempts() async throws {
        try await withIntellectusLock {
            let reader = FakeReader(
                traces: [
                    trace("a", used: true),  trace("b", used: true),
                    trace("c", used: false), trace("d", used: false),
                    trace("e", used: true),  trace("f", used: true),
                ],
                windowBatches: [[
                    // Strong: 3 co-recall events for (a, b).
                    ["a", "b"], ["a", "b"], ["a", "b"],
                    // LowConf: 5 co-recall events for (c, d).
                    ["c", "d"], ["c", "d"], ["c", "d"], ["c", "d"], ["c", "d"],
                    // FewAttempts: 1 co-recall event for (e, f).
                    ["e", "f"],
                ]]
            )
            let sink = RecordingSink()
            let d = daemon(reader: reader, sink: sink)

            let report = try await d.triggerDreamingCycle(now: t0)

            #expect(report.proposalsEmitted.count == 1, "only the strong candidate clears both gates")
            #expect(report.belowThreshold == 2, "low-confidence and few-attempts candidates are gated out")
            #expect(report.proposalsEmitted.first?.target == "a")
            #expect(report.proposalsEmitted.first?.kind == .miningPattern)
        }
    }

    // MARK: - C-6: exactly one diary entry per cycle

    @Test("C-6: exactly one diary entry per cycle")
    func c6OneDiaryEntryPerCycle() async throws {
        try await withIntellectusLock {
            let reader = FakeReader()
            let sink = RecordingSink()
            let d = daemon(reader: reader, sink: sink)

            _ = try await d.triggerDreamingCycle(now: t0)
            let afterOne = await sink.diaryCount()
            #expect(afterOne == 1)

            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))
            _ = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(120))
            let afterThree = await sink.diaryCount()
            #expect(afterThree == 3, "every cycle writes exactly one DiaryEntry")
        }
    }

    // MARK: - C-15: reward source reads RecallTraceItem.used

    @Test("C-15: reward derived from RecallTraceItem.used")
    func c15RewardDerivedFromRecallTraceUsed() async throws {
        try await withIntellectusLock {
            let reader = FakeReader(
                traces: [trace("r1", used: true), trace("r2", used: false)]
            )
            let sink = RecordingSink()
            let d = daemon(reader: reader, sink: sink)

            let report = try await d.triggerDreamingCycle(now: t0)

            // used → 1.0, unused → 0.0 (the live single-source reward).
            #expect(report.rewardByTarget["r1"] == 1.0)
            #expect(report.rewardByTarget["r2"] == 0.0)

            // The RewardSource seam is present and defaulted to the
            // recall-trace source; the explicit DiaryEntry.reward source is
            // seamed but not read (the field does not exist on the substrate).
            let kind = await d.rewardSourceKind()
            #expect(kind == .recallTrace)
        }
    }

    // MARK: - B-4: idempotency

    // Cycle 1: 3 windows for (a, b) → propose. Cycle 2: 3 more windows for the
    // SAME pair → daemon has already proposed it → suppressedDuplicates ≥ 1.
    // The proposedKeys set is the structural idempotency guard (B-4): the same
    // candidate key is never proposed twice, even when the drain supplies new
    // evidence for an already-proposed pair.
    @Test("B-4: second cycle over same pair proposes nothing new")
    func b4SecondCycleOverSamePairProposesNothingNew() async throws {
        try await withIntellectusLock {
            let reader = FakeReader(
                traces: [trace("a", used: true), trace("b", used: true)],
                windowBatches: [
                    // Cycle 1: 3 windows — pair clears both gates → propose.
                    [["a", "b"], ["a", "b"], ["a", "b"]],
                    // Cycle 2: 3 more windows — same pair, already proposed → suppress.
                    [["a", "b"], ["a", "b"], ["a", "b"]],
                ]
            )
            let sink = RecordingSink()
            let d = daemon(reader: reader, sink: sink)

            let first = try await d.triggerDreamingCycle(now: t0)
            #expect(first.proposalsEmitted.count == 1)

            let second = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))
            #expect(second.proposalsEmitted.count == 0, "already-proposed candidate is suppressed")
            #expect(second.suppressedDuplicates >= 1)

            // Two cycles produced the same proposals as one.
            let total = await sink.proposalCount()
            #expect(total == 1)
        }
    }

    // MARK: - Invariant: never creates a Tunnel; only proposes

    @Test("invariant: never creates a Tunnel, only proposes")
    func invariantNeverCreatesTunnelOnlyProposes() async throws {
        try await withIntellectusLock {
            // 3 windows for (a, b); traces a+b used → 3 attempts, high confidence.
            let reader = FakeReader(
                traces: [trace("a", used: true), trace("b", used: true)],
                windowBatches: [[["a", "b"], ["a", "b"], ["a", "b"]]]
            )
            let sink = RecordingSink()
            let d = daemon(reader: reader, sink: sink)

            let report = try await d.triggerDreamingCycle(now: t0)

            // The only writes are proposals + the cycle diary entry. The sink
            // exposes no Tunnel-creation method, so the daemon structurally
            // cannot create a Tunnel — it can only propose one.
            #expect(report.proposalsEmitted.count == 1)
            for frame in report.proposalsEmitted {
                #expect(frame.kind == .miningPattern, "emissions are proposals, not tunnels")
            }
            let diaryCount = await sink.diaryCount()
            #expect(diaryCount == 1)
        }
    }

    // MARK: - Step 5: active dreamed Tunnel suppresses a duplicate candidate

    // ALPHA uses dreamedActiveTunnels() (not existingTunnels()) so that
    // only non-tombstoned dreamed tunnels participate in duplicate suppression.
    // An active dreamed tunnel for pair (a, b) must block a new proposal for
    // the same pair.
    @Test("duplicate of an active dreamed Tunnel is suppressed")
    func duplicateOfActiveDreamedTunnelIsSuppressed() async throws {
        try await withIntellectusLock {
            let existing = Tunnel(
                id: "tun-1",
                sourceWing: "w", sourceRoom: "r", sourceDrawerId: "a",
                targetWing: "w", targetRoom: "r", targetDrawerId: "b",
                label: "related", addedBy: "user", filedAt: t0
            )
            // 9 windows → high attempts; traces a+b used → high confidence.
            // But the pair duplicates the active dreamed Tunnel → suppressed.
            // dreamedTunnels feeds dreamedActiveTunnels() — the ALPHA dedup path.
            let reader = FakeReader(
                traces: [trace("a", used: true), trace("b", used: true)],
                windowBatches: [[
                    ["a", "b"], ["a", "b"], ["a", "b"],
                    ["a", "b"], ["a", "b"], ["a", "b"],
                    ["a", "b"], ["a", "b"], ["a", "b"],
                ]],
                dreamedTunnels: [existing]
            )
            let sink = RecordingSink()
            let d = daemon(reader: reader, sink: sink)

            let report = try await d.triggerDreamingCycle(now: t0)
            #expect(report.proposalsEmitted.count == 0, "candidate duplicates an active dreamed Tunnel")
            #expect(report.suppressedDuplicates >= 1)
        }
    }

    // MARK: - Step 5 (Part 5 fix): retired Tunnel does NOT suppress re-formation

    // A tunnel that has been retired (tombstoned by OMEGA) must NOT appear in
    // dreamedActiveTunnels(), so ALPHA must not suppress a new proposal for the
    // same pair. This test verifies the fix: with dreamedTunnels=[] (simulating
    // a tombstoned tunnel absent from the active set), the pair re-forms.
    @Test("retired (tombstoned) Tunnel does not block re-formation of same pair")
    func retiredTunnelDoesNotSuppressReformation() async throws {
        try await withIntellectusLock {
            // 9 windows → high attempts; traces used → high confidence.
            // dreamedTunnels is empty, simulating: the tunnel for (a, b) was
            // retired by OMEGA so it is no longer in dreamedActiveTunnels().
            // existingTunnels() is also empty — this test focuses purely on
            // the dreamed-active suppression path used by ALPHA.
            let reader = FakeReader(
                traces: [trace("a", used: true), trace("b", used: true)],
                windowBatches: [[
                    ["a", "b"], ["a", "b"], ["a", "b"],
                    ["a", "b"], ["a", "b"], ["a", "b"],
                    ["a", "b"], ["a", "b"], ["a", "b"],
                ]],
                dreamedTunnels: []
            )
            let sink = RecordingSink()
            let d = daemon(reader: reader, sink: sink)

            let report = try await d.triggerDreamingCycle(now: t0)
            // Retired tunnel absent from active set → pair is NOT suppressed → 1 proposal.
            #expect(report.proposalsEmitted.count == 1,
                "retired tunnel must not suppress re-formation of the same pair")
            #expect(report.proposalsEmitted.first?.target == "a")
        }
    }

    // MARK: - Step 4: EWC++ does not catastrophically overwrite priors

    // Cycle 1: 3 windows for (a, b); traces a+b used → confidence≈0.88,
    // consolidated[a|b] ≈ 0.88. Cycle 2: 3 more windows for same pair;
    // traces a+b now unused → fresh score≈0.05. EWC++ retention:
    // max(0.05, 0.88 × 0.9) = 0.792 ≥ 0.7 — prior association preserved.
    @Test("EWC++: prior association not catastrophically overwritten")
    func ewcPriorAssociationNotCatastrophicallyOverwritten() async throws {
        try await withIntellectusLock {
            let reader = FakeReader(
                traces: [trace("a", used: true), trace("b", used: true)],
                windowBatches: [
                    // Cycle 1: used traces → high confidence, consolidates.
                    [["a", "b"], ["a", "b"], ["a", "b"]],
                    // Cycle 2: same pair, but traces flipped to unused — fresh
                    // score collapses. EWC++ retention must preserve the prior.
                    [["a", "b"], ["a", "b"], ["a", "b"]],
                ]
            )
            let sink = RecordingSink()
            let d = daemon(reader: reader, sink: sink)

            // Cycle 1: strong evidence consolidates a high confidence.
            let first = try await d.triggerDreamingCycle(now: t0)
            let key = DreamingDaemon.candidateKey("a", "b")
            let firstScore = try #require(first.candidateScores[key])
            #expect(firstScore >= 0.7)

            // Cycle 2: the SAME candidate now has only unused evidence — its
            // fresh contrastive score collapses toward 0. EWC++ retention must
            // keep the consolidated confidence from being wiped out.
            await reader.setTraces([trace("a", used: false), trace("b", used: false)])
            let second = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))
            let secondScore = try #require(second.candidateScores[key])

            let freshRaw = DreamingDaemon.contrastiveConfidence(
                evidenceTargets: ["a", "b"],
                rewardByTarget: ["a": 0.0, "b": 0.0],
                baseline: 0.6
            )
            #expect(freshRaw < 0.1, "fresh score collapsed without retention")
            #expect(secondScore >= 0.7, "prior association preserved by EWC++ retention")
            #expect(secondScore > freshRaw)
        }
    }

    // MARK: - Part 2: policy round-trips through the manifest seam
    // No emitting call — lock not required.

    @Test("policy round-trips through the manifest seam")
    func policyRoundTripsThroughManifestSeam() async throws {
        let store = InMemoryDreamingPolicyStore()
        let reader = FakeReader()
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink, policyStore: store)

        try await d.registerDreamingPolicy(
            minSuccessRate: 0.5, minConfidence: 0.8, minAttempts: 5, tickIntervalMs: 10_000
        )

        // A fresh daemon over the same store loads the persisted policy.
        let d2 = daemon(reader: reader, sink: sink, policyStore: store)
        try await d2.loadPersistedPolicy()
        let loaded = await d2.currentPolicy()
        #expect(loaded == DreamingPolicy(
            minSuccessRate: 0.5, minConfidence: 0.8, minAttempts: 5, tickIntervalMs: 10_000
        ))
    }

    // MARK: - Part 2: trigger mode initial default is .timer
    // The bandit re-selects each cycle; the initial default before any
    // cycle has run is still .timer. No emitting call — lock not required.

    @Test("trigger mode defaults to timer")
    func triggerModeDefaultsToTimer() async throws {
        let d = daemon(reader: FakeReader(), sink: RecordingSink())
        let mode = await d.currentTriggerMode()
        #expect(mode == .timer)
        #expect(DreamingTriggerMode.default == .timer)
    }

    // MARK: - Trigger-source tests (Board item 13)
    // These tests verify the three modes behave as named:
    //   .timer  — timer path fires; event path inactive
    //   .event  — event path fires on threshold; timer path inactive
    //   .hybrid — both paths active independently

    // TS-1: .timer mode — pump fires on cadence; pumpOnEvent returns nil even
    // when observation count is above threshold.
    @Test("TS-1: timer mode fires on cadence and NOT on event")
    func ts1TimerModeFiresOnCadenceNotOnEvent() async throws {
        try await withIntellectusLock {
            let reader = FakeReader()
            let sink = RecordingSink()
            // Construct a .timer-mode daemon with a short interval.
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                triggerMode: .timer
            )
            // First pump always fires in timer mode (no prior tick).
            let first = try await d.pump(now: t0)
            #expect(first != nil, ".timer: first pump must fire")

            // pumpOnEvent must return nil regardless of observation count —
            // the event path is inactive in timer mode.
            let eventResult = try await d.pumpOnEvent(observationCount: 100, now: t0.addingTimeInterval(1))
            #expect(eventResult == nil, ".timer: pumpOnEvent must return nil (event path inactive)")

            // Timer fires after the cadence elapses.
            let second = try await d.pump(now: t0.addingTimeInterval(30))
            #expect(second != nil, ".timer: pump fires after interval")
        }
    }

    // TS-2: .event mode — pumpOnEvent fires when observation count meets
    // threshold; pump returns nil (timer path inactive).
    @Test("TS-2: event mode fires on observation threshold and NOT on timer")
    func ts2EventModeFiresOnEventNotOnTimer() async throws {
        try await withIntellectusLock {
            let reader = FakeReader()
            let sink = RecordingSink()
            // Construct a .event-mode daemon with threshold = 2.
            // The policy is injected directly so the daemon starts with the
            // configured threshold without requiring a loadPersistedPolicy call.
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                triggerMode: .event,
                policy: DreamingPolicy(eventObservationThreshold: 2)
            )

            // pump must return nil — timer path is inactive in event mode.
            // The first pump would normally fire (no prior tick), but event
            // mode overrides that: the timer path is fully inactive.
            let timerResult = try await d.pump(now: t0)
            #expect(timerResult == nil, ".event: pump must return nil (timer path inactive)")

            // pumpOnEvent below threshold returns nil.
            let belowThreshold = try await d.pumpOnEvent(observationCount: 1, now: t0)
            #expect(belowThreshold == nil, ".event: pumpOnEvent below threshold must return nil")

            // pumpOnEvent at or above threshold fires.
            let atThreshold = try await d.pumpOnEvent(observationCount: 2, now: t0)
            #expect(atThreshold != nil, ".event: pumpOnEvent at threshold must fire")

            let aboveThreshold = try await d.pumpOnEvent(observationCount: 5, now: t0.addingTimeInterval(1))
            #expect(aboveThreshold != nil, ".event: pumpOnEvent above threshold must fire")
        }
    }

    // TS-3: .hybrid mode — both pump (timer) AND pumpOnEvent (event) are
    // active independently. Neither path blocks the other.
    @Test("TS-3: hybrid mode fires on BOTH timer and event independently")
    func ts3HybridModeFiresOnBothTimerAndEvent() async throws {
        try await withIntellectusLock {
            let reader = FakeReader()
            let sink = RecordingSink()
            // Construct a .hybrid-mode daemon with threshold = 1.
            // The policy is injected directly so the daemon starts with the
            // configured thresholds without requiring a loadPersistedPolicy call.
            let d = DreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: InMemoryDreamingPolicyStore(),
                triggerMode: .hybrid,
                policy: DreamingPolicy(tickIntervalMs: 30_000, eventObservationThreshold: 1)
            )

            // Timer path: first pump fires (no prior tick).
            let timerFire = try await d.pump(now: t0)
            #expect(timerFire != nil, ".hybrid: first pump (timer) must fire")

            // Event path fires independently even when timer has not elapsed.
            // t0 + 1s is before the 30s timer interval — pump would return nil.
            let timerBlocked = try await d.pump(now: t0.addingTimeInterval(1))
            #expect(timerBlocked == nil, ".hybrid: pump returns nil before interval elapses")

            // pumpOnEvent fires independently of the timer.
            let eventFire = try await d.pumpOnEvent(observationCount: 1, now: t0.addingTimeInterval(1))
            #expect(eventFire != nil, ".hybrid: pumpOnEvent must fire independently of timer")

            // Timer path fires again after cadence elapses.
            let timerSecond = try await d.pump(now: t0.addingTimeInterval(30))
            #expect(timerSecond != nil, ".hybrid: pump fires after interval")
        }
    }

    // TS-4: event threshold round-trips through the policy seam so the host
    // can configure it persistently. No emitting call — lock not required.
    @Test("TS-4: eventObservationThreshold round-trips through policy seam")
    func ts4EventObservationThresholdRoundTrips() async throws {
        let store = InMemoryDreamingPolicyStore()
        let reader = FakeReader()
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink, policyStore: store)

        try await d.registerDreamingPolicy(
            minSuccessRate: 0.5,
            minConfidence: 0.8,
            minAttempts: 5,
            tickIntervalMs: 10_000,
            eventObservationThreshold: 7
        )

        let d2 = daemon(reader: reader, sink: sink, policyStore: store)
        try await d2.loadPersistedPolicy()
        let loaded = await d2.currentPolicy()
        #expect(loaded.eventObservationThreshold == 7, "eventObservationThreshold must round-trip")
    }
}
