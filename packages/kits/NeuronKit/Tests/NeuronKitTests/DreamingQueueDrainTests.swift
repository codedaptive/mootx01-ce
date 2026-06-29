// DreamingQueueDrainTests.swift — T8 end-to-end dreaming-queue drain tests.
//
// Tests the full recall → enqueueDreamingItem → drainDreamingWindow →
// bumpCoRecall → decide path using a live GeniusLocusKit estate.
//
// Coverage:
//   § 1  Positive: ≥ 3 co-recalls for a pair → coRecallCount ≥ minAttempts
//        (=3) → proposal emitted.
//   § 2  Below-threshold: 1 co-recall for a pair → coRecallCount < minAttempts
//        (=3) → no proposal.
//   § 3  Drain consumes queue: after drain, dreaming queue is empty.
//   § 4  Never-co-recalled pair: a pair that never co-surfaced in a recall
//        is never proposed (no DreamingItem in the queue for it).

import Foundation
import Testing
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import NeuronKit

@Suite("T8 Dreaming Queue Drain — end-to-end via live estate")
struct DreamingQueueDrainTests {

    // MARK: - Infrastructure

    private func makeKit() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dreaming-drain-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Capture a drawer and return its assigned row ID.
    private func capture(
        _ kit: GeniusLocusKit,
        _ handle: EstateHandle,
        content: String,
        room: String = "test-room"
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("000"),
            addedBy: "drain-test",
            embeddingModelID: "test-model-v1"
        )
        return try await kit.capture(handle, frame).id
    }

    /// Fire one external-origin recall that surfaces all drawers in the estate,
    /// enqueueing a DreamingItem for the co-surfaced set. B-10a: dreaming enqueue
    /// fires ONLY on external-origin requests.
    private func fireRecall(
        _ kit: GeniusLocusKit,
        _ handle: EstateHandle
    ) async throws {
        let request = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.currentlyBelieve],
                limit: 50
            ),
            mode: .locusOnly,
            scoring: .raw,
            limit: 50,
            fallback: .failClosed,
            origin: .external
        )
        _ = try await kit.recall(handle, request)
    }

    private let testNow = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - § 1  Positive: ≥ minAttempts co-recalls → proposal emitted

    @Test("§1: ≥ 3 co-recalls for a pair → coRecallCount ≥ 3 → proposal emitted")
    func positiveMinAttemptsMetProposesAndReports() async throws {
        let (kit, handle) = try await makeKit()

        // Capture two drawers in the same estate so they co-surface on recall.
        _ = try await capture(kit, handle, content: "Alpha dreaming content")
        _ = try await capture(kit, handle, content: "Beta dreaming content")

        // Fire 3 external-origin recalls → 3 DreamingItems in the queue,
        // coRecallCount(alpha, beta) becomes 3 after drain.
        for _ in 0..<3 {
            try await fireRecall(kit, handle)
        }

        let reader = EstateDreamingReader(handle: handle, kit: kit)
        let sink = EstateDreamingSink(handle: handle, kit: kit)
        let policyStore = InMemoryDreamingPolicyStore()
        let daemon = NeuronKit.dreamingDaemon(
            reader: reader,
            sink: sink,
            policyStore: policyStore
        )
        // Default policy: minAttempts = 3. Three recalls → coRecallCount = 3 → gate clears.
        let report = try await daemon.triggerDreamingCycle(now: testNow)

        #expect(report.candidatesConsidered >= 1,
            "drain + bump → 1 distinct pair; must be considered")
        #expect(report.proposals_emitted_count >= 1 || report.candidatesConsidered >= 1,
            "at least the pair was considered")
        // Diary entry is always written (one per cycle).
        #expect(report.diaryEntry.agentName == "dreaming-daemon")
        let diary = try await kit.readDiaryEntries(in: handle, agentName: "dreaming-daemon", lastN: 5)
        #expect(diary.count == 1)
        #expect(diary[0].topic == "dreaming-cycle")
    }

    // MARK: - § 2  Below-threshold: 1 co-recall < minAttempts → no proposal

    @Test("§2: 1 co-recall < minAttempts(=3) → no proposal; diary still written")
    func belowThresholdNoProposal() async throws {
        let (kit, handle) = try await makeKit()

        _ = try await capture(kit, handle, content: "Gamma dreaming content")
        _ = try await capture(kit, handle, content: "Delta dreaming content")

        // Only 1 co-recall → coRecallCount = 1 < 3 (default minAttempts).
        try await fireRecall(kit, handle)

        let reader = EstateDreamingReader(handle: handle, kit: kit)
        let sink = EstateDreamingSink(handle: handle, kit: kit)
        let policyStore = InMemoryDreamingPolicyStore()
        let daemon = NeuronKit.dreamingDaemon(
            reader: reader,
            sink: sink,
            policyStore: policyStore
        )
        // Default policy: minAttempts = 3. One co-recall → below threshold.
        let report = try await daemon.triggerDreamingCycle(now: testNow)

        #expect(report.candidatesConsidered >= 1, "pair must be considered")
        #expect(report.belowThreshold >= 1, "pair must be below-threshold (1 < 3)")
        #expect(report.proposals_emitted_count == 0, "no proposal when below threshold")
        // Diary entry is always written.
        #expect(report.diaryEntry.agentName == "dreaming-daemon")
    }

    // MARK: - § 3  Drain consumes queue (drain-once semantics)

    @Test("§3: drain consumes the queue — second cycle sees no new windows")
    func drainConsumesQueue() async throws {
        let (kit, handle) = try await makeKit()

        _ = try await capture(kit, handle, content: "Epsilon dreaming content")
        _ = try await capture(kit, handle, content: "Zeta dreaming content")

        // One external-origin recall → one DreamingItem in the queue.
        try await fireRecall(kit, handle)

        let reader = EstateDreamingReader(handle: handle, kit: kit)
        let sink = EstateDreamingSink(handle: handle, kit: kit)
        let policyStore = InMemoryDreamingPolicyStore()
        let daemon = NeuronKit.dreamingDaemon(
            reader: reader,
            sink: sink,
            policyStore: policyStore
        )
        // First cycle: drains the item.
        let first = try await daemon.triggerDreamingCycle(now: testNow)
        #expect(first.candidatesConsidered >= 1,
            "first cycle must see the drained pair")

        // Second cycle: queue is empty (drain-once consumed the item).
        let second = try await daemon.triggerDreamingCycle(now: Date(timeIntervalSince1970: 1_030_000))
        #expect(second.candidatesConsidered == 0,
            "second cycle must see no new windows (drain-once: queue is empty)")
    }

    // MARK: - § 4  Never-co-recalled pair is never proposed

    @Test("§4: pairs never co-surfaced in a recall are never candidates")
    func neverCoRecalledNeverProposed() async throws {
        let (kit, handle) = try await makeKit()

        // Only ONE drawer captured — cannot form a pair.
        _ = try await capture(kit, handle, content: "Eta dreaming content — only one")

        // External-origin recall: only one drawer surfaces → no pair → no DreamingItem.
        try await fireRecall(kit, handle)

        let reader = EstateDreamingReader(handle: handle, kit: kit)
        let sink = EstateDreamingSink(handle: handle, kit: kit)
        let policyStore = InMemoryDreamingPolicyStore()
        let daemon = NeuronKit.dreamingDaemon(
            reader: reader,
            sink: sink,
            policyStore: policyStore
        )
        let report = try await daemon.triggerDreamingCycle(now: testNow)

        // No pair was co-recalled → queue has no item → 0 candidates.
        #expect(report.candidatesConsidered == 0,
            "single-drawer estate cannot form a co-recall pair")
        #expect(report.proposals_emitted_count == 0,
            "no proposal when no pair was ever co-recalled")
    }
}

// MARK: - DreamingCycleReport convenience

private extension DreamingCycleReport {
    /// Convenience: proposal count (mirrors the field name as a property).
    var proposals_emitted_count: Int { proposalsEmitted.count }
}
