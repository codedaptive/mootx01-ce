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

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
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

    func proposalCount() -> Int { proposals.count }
    func diaryCount() -> Int { diaryEntries.count }
}

/// Returns whatever substrate state the test configures. Mutable so the
/// EWC++ test can change the evidence between cycles.
private actor FakeReader: DreamingSubstrateReader {
    var traces: [RecallTraceItem]
    var observations: [CoOccurrenceObservation]
    var tunnels: [Tunnel]

    init(
        traces: [RecallTraceItem] = [],
        observations: [CoOccurrenceObservation] = [],
        tunnels: [Tunnel] = []
    ) {
        self.traces = traces
        self.observations = observations
        self.tunnels = tunnels
    }

    func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem] { traces }
    func coOccurrenceObservations() async throws -> [CoOccurrenceObservation] { observations }
    func existingTunnels() async throws -> [Tunnel] { tunnels }

    func setTraces(_ t: [RecallTraceItem]) { traces = t }
    func setObservations(_ o: [CoOccurrenceObservation]) { observations = o }
}

// MARK: - Builders

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A recall-trace row with `used` set or clear (bit 0 of the bitmap).
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

@Suite("Dreaming daemon conformance")
struct DreamingDaemonTests {

    // MARK: - C-1: tick cadence (injectable clock, no wall-clock sleeps)

    @Test("C-1: tick fires on configured interval within tolerance")
    func c1TickFiresOnConfiguredIntervalWithinTolerance() async throws {
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

    // MARK: - C-2: confidence (and attempts) gate

    @Test("C-2: proposes only above confidence and attempts")
    func c2ProposesOnlyAboveConfidenceAndAttempts() async throws {
        // Strong: used evidence (reward 1.0) → confidence ≈ 0.88; 3 attempts.
        // LowConf: unused evidence (reward 0.0) → confidence ≈ 0.05.
        // FewAttempts: used evidence but only 1 attempt (< minAttempts 3).
        let reader = FakeReader(
            traces: [trace("r1", used: true), trace("r2", used: true),
                     trace("r3", used: false), trace("r4", used: true)],
            observations: [
                CoOccurrenceObservation(endpointA: "a", endpointB: "b", attempts: 3, evidenceTargets: ["r1", "r2"]),
                CoOccurrenceObservation(endpointA: "c", endpointB: "d", attempts: 5, evidenceTargets: ["r3"]),
                CoOccurrenceObservation(endpointA: "e", endpointB: "f", attempts: 1, evidenceTargets: ["r4"]),
            ]
        )
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerDreamingCycle(now: t0)

        #expect(report.proposalsEmitted.count == 1, "only the strong candidate clears both gates")
        #expect(report.belowThreshold == 2, "low-confidence and few-attempts candidates are gated out")
        #expect(report.proposalsEmitted.first?.target == "a")
        #expect(report.proposalsEmitted.first?.kind == .miningPattern)
    }

    // MARK: - C-6: exactly one diary entry per cycle

    @Test("C-6: exactly one diary entry per cycle")
    func c6OneDiaryEntryPerCycle() async throws {
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

    // MARK: - C-15: reward source reads RecallTraceItem.used

    @Test("C-15: reward derived from RecallTraceItem.used")
    func c15RewardDerivedFromRecallTraceUsed() async throws {
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

    // MARK: - B-4: idempotency

    @Test("B-4: second cycle over unchanged state proposes nothing new")
    func b4SecondCycleOverUnchangedStateProposesNothingNew() async throws {
        let reader = FakeReader(
            traces: [trace("r1", used: true), trace("r2", used: true)],
            observations: [
                CoOccurrenceObservation(endpointA: "a", endpointB: "b", attempts: 3, evidenceTargets: ["r1", "r2"]),
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

    // MARK: - Invariant: never creates a Tunnel; only proposes

    @Test("invariant: never creates a Tunnel, only proposes")
    func invariantNeverCreatesTunnelOnlyProposes() async throws {
        let reader = FakeReader(
            traces: [trace("r1", used: true), trace("r2", used: true)],
            observations: [
                CoOccurrenceObservation(endpointA: "a", endpointB: "b", attempts: 4, evidenceTargets: ["r1", "r2"]),
            ]
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

    // MARK: - Step 5: existing Tunnel suppresses a duplicate candidate

    @Test("duplicate of an existing Tunnel is suppressed")
    func duplicateOfExistingTunnelIsSuppressed() async throws {
        let existing = Tunnel(
            id: "tun-1",
            sourceWing: "w", sourceRoom: "r", sourceDrawerId: "a",
            targetWing: "w", targetRoom: "r", targetDrawerId: "b",
            label: "related", addedBy: "user", filedAt: t0
        )
        let reader = FakeReader(
            traces: [trace("r1", used: true), trace("r2", used: true)],
            observations: [
                CoOccurrenceObservation(endpointA: "a", endpointB: "b", attempts: 9, evidenceTargets: ["r1", "r2"]),
            ],
            tunnels: [existing]
        )
        let sink = RecordingSink()
        let d = daemon(reader: reader, sink: sink)

        let report = try await d.triggerDreamingCycle(now: t0)
        #expect(report.proposalsEmitted.count == 0, "candidate duplicates an existing Tunnel")
        #expect(report.suppressedDuplicates >= 1)
    }

    // MARK: - Step 4: EWC++ does not catastrophically overwrite priors

    @Test("EWC++: prior association not catastrophically overwritten")
    func ewcPriorAssociationNotCatastrophicallyOverwritten() async throws {
        let reader = FakeReader(
            traces: [trace("r1", used: true), trace("r2", used: true)],
            observations: [
                CoOccurrenceObservation(endpointA: "a", endpointB: "b", attempts: 3, evidenceTargets: ["r1", "r2"]),
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
        await reader.setTraces([trace("r1", used: false), trace("r2", used: false)])
        let second = try await d.triggerDreamingCycle(now: t0.addingTimeInterval(60))
        let secondScore = try #require(second.candidateScores[key])

        let freshRaw = DreamingDaemon.contrastiveConfidence(
            evidenceTargets: ["r1", "r2"],
            rewardByTarget: ["r1": 0.0, "r2": 0.0],
            baseline: 0.6
        )
        #expect(freshRaw < 0.1, "fresh score collapsed without retention")
        #expect(secondScore >= 0.7, "prior association preserved by EWC++ retention")
        #expect(secondScore > freshRaw)
    }

    // MARK: - Part 2: policy round-trips through the manifest seam

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

    // MARK: - Part 2: trigger mode defaults to timer, no SolverBandit

    @Test("trigger mode defaults to timer")
    func triggerModeDefaultsToTimer() async throws {
        let d = daemon(reader: FakeReader(), sink: RecordingSink())
        let mode = await d.currentTriggerMode()
        #expect(mode == .timer)
        #expect(DreamingTriggerMode.default == .timer)
    }
}
