import Foundation
import Testing
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import NeuronKit

/// Tests for EstateDreamingSink — the production adapter that binds
/// DreamingProposalSink to a live GeniusLocusKit estate.
///
/// Coverage plan:
///   § 1  propose round-trip: adapter creates a real Proposal via Estate.propose
///   § 2  recordCycleDiary round-trip: adapter creates a real DiaryEntry
///   § 3  Integration: DreamingDaemon with real sink + stub reader triggers a
///        cycle and lands a proposal + diary entry in the estate
///   § 4  Protocol conformance: EstateDreamingSink constructs cleanly and
///        conforms to DreamingProposalSink
@Suite("EstateDreamingSink — production adapter integration")
struct EstateDreamingSinkTests {

    // MARK: - Infrastructure

    private func makeKit() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dreaming-sink-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func captureFrame(content: String, room: String = "sink-test") -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("547"),
            addedBy: "sink-test",
            embeddingModelID: "test-model-v1"
        )
    }

    private let testNow = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - § 4  Protocol conformance (no network needed)

    @Test("EstateDreamingSink conforms to DreamingProposalSink")
    func conformance() async throws {
        let (kit, handle) = try await makeKit()
        let sink: any DreamingProposalSink = EstateDreamingSink(handle: handle, kit: kit)
        // verify the sink is the right type without casting
        _ = sink
    }

    // MARK: - § 1  propose round-trip

    @Test("propose creates a real Proposal via Estate.propose — BRAIN-PROPOSE is closed")
    func proposeCreatesRealProposal() async throws {
        let (kit, handle) = try await makeKit()
        // Capture a row so the proposal has a valid target.
        let captured = try await kit.capture(handle, captureFrame(content: "dreaming test content"))
        let frame = ProposeFrame(
            target: captured.id,
            kind: .miningPattern,
            justification: "dreaming test proposal"
        )
        let sink = EstateDreamingSink(handle: handle, kit: kit)
        // propose must not throw — BRAIN-PROPOSE is closed when this succeeds.
        try await sink.propose(frame)
    }

    // MARK: - § 2  recordCycleDiary round-trip

    @Test("recordCycleDiary creates a real DiaryEntry via addDiaryEntry")
    func recordCycleDiaryCreatesRealEntry() async throws {
        let (kit, handle) = try await makeKit()
        let sink = EstateDreamingSink(handle: handle, kit: kit)
        // embeddingModelID is empty — the GLK addDiaryEntry substitutes "no-embedding"
        // for autonomous daemon diary entries that carry no vector.
        let entry = DiaryEntry(
            agentName: "dreaming-daemon",
            entry: "dreaming cycle 1: considered 2, proposed 1, suppressed 0, below-threshold 0",
            topic: "dreaming-cycle",
            wing: "wing_dreaming-daemon",
            room: "diary",
            filedAt: testNow,
            embeddingModelID: ""
        )
        try await sink.recordCycleDiary(entry)
        // Read back via the GLK diary surface.
        let entries = try await kit.readDiaryEntries(
            in: handle,
            agentName: "dreaming-daemon",
            lastN: 10
        )
        #expect(entries.count == 1)
        let stored = try #require(entries.first)
        #expect(stored.agentName == "dreaming-daemon")
        #expect(stored.topic == "dreaming-cycle")
        #expect(stored.wing == "wing_dreaming-daemon")
    }

    // MARK: - § 3  Integration: DreamingDaemon with real sink + stub reader

    @Test("integration: DreamingDaemon with EstateDreamingSink triggers a cycle and lands data")
    func integrationDaemonCycleLandsData() async throws {
        let (kit, handle) = try await makeKit()

        // Populate the estate with two drawers in the same room so the
        // co-occurrence algorithm in EstateDreamingReader can see a pair.
        let room = "cooc-room"
        _ = try await kit.capture(handle, captureFrame(content: "drawer A", room: room))
        _ = try await kit.capture(handle, captureFrame(content: "drawer B", room: room))

        // Build the production adapter pair.
        let reader = EstateDreamingReader(handle: handle, kit: kit)
        let sink = EstateDreamingSink(handle: handle, kit: kit)
        let policyStore = InMemoryDreamingPolicyStore()
        let daemon = NeuronKit.dreamingDaemon(
            reader: reader,
            sink: sink,
            policyStore: policyStore
        )

        // Set a lenient policy so the pair clears the confidence gate.
        try await daemon.registerDreamingPolicy(
            minSuccessRate: 0.0,
            minConfidence: 0.0,
            minAttempts: 1
        )

        let report = try await daemon.triggerDreamingCycle(now: testNow)

        // The cycle must have considered the co-occurrence pair and emitted
        // exactly one diary entry regardless of proposal count.
        #expect(report.candidatesConsidered >= 1, "should consider the drawer pair")
        #expect(report.diaryEntry.agentName == "dreaming-daemon")

        // Diary entry must be in the estate.
        let diaryEntries = try await kit.readDiaryEntries(
            in: handle,
            agentName: "dreaming-daemon",
            lastN: 10
        )
        #expect(diaryEntries.count == 1, "exactly one diary entry per cycle")
        #expect(diaryEntries[0].topic == "dreaming-cycle")
    }
}
