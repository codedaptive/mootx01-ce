import Foundation
import Testing
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import IntellectusLib
import SubstrateTypes
@testable import NeuronKit

// MARK: - Capturing sink (local to this file, mirrors NeuronKitTelemetryTests pattern)

/// Records every received StatSample. Thread-safe via NSLock.
private final class CapturingSink: StatsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [StatSample] = []

    func receive(_ sample: StatSample) {
        lock.lock(); defer { lock.unlock() }
        _samples.append(sample)
    }

    var samples: [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples
    }
}

/// Restore global Intellectus state to (disabled, NoOpSink).
private func resetIntellectus() {
    Intellectus.setEnabled(false)
    Intellectus.install(sink: NoOpSink.shared)
}

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
///   § 5  Think-event emission: propose() emits StatSample.event(.think) via Intellectus
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
        // propose() now emits a telemetry event via Intellectus (TEL-02).
        // All callers of emitting functions must hold the process-wide lock
        // to prevent concurrent telemetry tests from observing phantom counts
        // (matches the pattern in IntellectusTestLock.swift).
        try await withIntellectusLock {
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

    // MARK: - § 5  Think-event emission (TEL-02)

    // propose() must emit exactly one StatSample.event(.think) via Intellectus
    // after a successful write. Acquires the process-wide lock to prevent races
    // with concurrent telemetry tests that share the Intellectus singleton.
    @Test("propose emits a StatSample.event(.think) via Intellectus — TEL-02")
    func propose_emits_think_event() async throws {
        try await withIntellectusLock {
            let (kit, handle) = try await makeKit()
            let sink = EstateDreamingSink(handle: handle, kit: kit)

            // Capture a row so the proposal has a valid target.
            let captured = try await kit.capture(handle, captureFrame(content: "tel-02 emission test"))
            let frame = ProposeFrame(
                target: captured.id,
                kind: .miningPattern,
                justification: "tel-02 think-event test"
            )

            let capturingSink = CapturingSink()
            Intellectus.install(sink: capturingSink)
            Intellectus.setEnabled(true)
            defer { resetIntellectus() }

            try await sink.propose(frame)

            // Retrieve the stored proposal to obtain its row ID.
            let proposals = try await kit.recallProposals(handle)
            let storedProposal = try #require(proposals.first,
                "propose must persist a Proposal row")

            let events = capturingSink.samples.filter {
                if case .event = $0 { return true }
                return false
            }
            #expect(events.count == 1,
                "propose must emit exactly one .event sample; got \(events.count)")
            guard let sample = events.first,
                  case let .event(kind, nounType, rowID, estate, _) = sample else {
                Issue.record("no .event sample emitted"); return
            }
            #expect(kind == .think, "event kind must be .think; got \(kind)")
            #expect(nounType == Int(NounType.proposal.rawValue),
                "nounType must be \(Int(NounType.proposal.rawValue)) (NounType.proposal); got \(nounType)")
            #expect(rowID == storedProposal.id,
                "rowID must equal stored proposal id \(storedProposal.id); got \(rowID)")
            #expect(estate == handle.estateUUID.uuidString,
                "estate must equal handle.estateUUID.uuidString; got \(estate)")
        }
    }

    // MARK: - § 3  Integration: DreamingDaemon with real sink + real reader

    // triggerDreamingCycle() emits to the global Intellectus singleton.
    // Acquires the process-wide lock to prevent races with concurrent
    // telemetry tests that have enabled monitoring.
    @Test("integration: DreamingDaemon with EstateDreamingSink triggers a cycle and lands data")
    func integrationDaemonCycleLandsData() async throws {
        try await withIntellectusLock {
            let (kit, handle) = try await makeKit()

            // Capture two drawers so the external-origin recall can surface them.
            let room = "dreaming-test-room"
            _ = try await kit.capture(handle, captureFrame(content: "dreaming test drawer A", room: room))
            _ = try await kit.capture(handle, captureFrame(content: "dreaming test drawer B", room: room))

            // Fire an external-origin recall to enqueue a DreamingItem.
            // B-10a: dreaming enqueue fires ONLY on external-origin requests.
            // Filter: `currentlyBelieve` — returns all live drawers in the estate.
            // Both captured drawers surface, so enqueueDreamingItem is called
            // with ≥ 2 distinct ids and a DreamingItem lands in the queue.
            let recallRequest = GLKRecallRequest(
                frame: RecallFrame(
                    filterChain: [.currentlyBelieve],
                    limit: 10
                ),
                mode: .locusOnly,
                scoring: .raw,
                limit: 10,
                fallback: .failClosed,
                origin: .external
            )
            _ = try await kit.recall(handle, recallRequest)

            // Build the production adapter pair (reader drains the enqueued item).
            let reader = EstateDreamingReader(handle: handle, kit: kit)
            let sink = EstateDreamingSink(handle: handle, kit: kit)
            let policyStore = InMemoryDreamingPolicyStore()
            let daemon = NeuronKit.dreamingDaemon(
                reader: reader,
                sink: sink,
                policyStore: policyStore
            )

            // Lenient policy: min_attempts=1 so one co-recall event is sufficient.
            try await daemon.registerDreamingPolicy(
                minSuccessRate: 0.0,
                minConfidence: 0.0,
                minAttempts: 1
            )

            let report = try await daemon.triggerDreamingCycle(now: testNow)

            // The cycle must have drained the enqueued window, considered the
            // pair, and emitted exactly one diary entry.
            #expect(report.candidatesConsidered >= 1, "should consider the drained drawer pair")
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
}
