import Foundation
import Testing
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import NeuronKit

/// Tests for EstateMaintenanceSink — the production adapter that binds
/// `MaintenanceProposalSink` to a live GeniusLocusKit estate.
///
/// Coverage plan:
///   § 1  propose round-trip: adapter creates a real Proposal via Estate.propose
///   § 2  recordCycleDiary round-trip: adapter creates a real DiaryEntry
///   § 3  Protocol conformance: EstateMaintenanceSink constructs cleanly
@Suite("EstateMaintenanceSink — production adapter integration")
struct EstateMaintenanceSinkTests {

    // MARK: - Infrastructure

    private func makeKit() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "maintenance-sink-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func captureFrame(content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "sink-test",
            latticeAnchor: .udc("547"),
            addedBy: "sink-test",
            embeddingModelID: "test-model-v1"
        )
    }

    private let testNow = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - § 3  Protocol conformance

    @Test("EstateMaintenanceSink conforms to MaintenanceProposalSink")
    func conformance() async throws {
        let (kit, handle) = try await makeKit()
        let sink: any MaintenanceProposalSink = EstateMaintenanceSink(handle: handle, kit: kit)
        _ = sink
    }

    // MARK: - § 1  propose round-trip

    @Test("propose creates a real Proposal via Estate.propose")
    func proposeCreatesRealProposal() async throws {
        let (kit, handle) = try await makeKit()
        let captured = try await kit.capture(handle, captureFrame(content: "maintenance test content"))
        let frame = ProposeFrame(
            target: captured.id,
            kind: .mutateCandidate,
            justification: "maintenance: decay candidate for testing"
        )
        let sink = EstateMaintenanceSink(handle: handle, kit: kit)
        // propose must not throw — this verifies the adapter routes through
        // the GLK verb surface (B-1) successfully.
        try await sink.propose(frame)
    }

    // MARK: - § 2  recordCycleDiary round-trip

    @Test("recordCycleDiary creates a real DiaryEntry via addDiaryEntry")
    func recordCycleDiaryCreatesRealEntry() async throws {
        let (kit, handle) = try await makeKit()
        let sink = EstateMaintenanceSink(handle: handle, kit: kit)
        // embeddingModelID is empty — GLK.addDiaryEntry substitutes "no-embedding"
        // for autonomic daemon diary entries that carry no vector.
        let entry = DiaryEntry(
            agentName: "maintenance-daemon",
            entry: "maintenance cycle 1: audit-checked false, forbidden 0, "
                + "decay 0, tombstone 0, fingerprint-drift 0, byReference-drift 0, "
                + "proposed 0, suppressed 0",
            topic: "maintenance-cycle",
            wing: "wing_maintenance-daemon",
            room: "diary",
            filedAt: testNow,
            embeddingModelID: ""
        )
        try await sink.recordCycleDiary(entry)
        // Read back via the GLK diary surface.
        let entries = try await kit.readDiaryEntries(
            in: handle,
            agentName: "maintenance-daemon",
            lastN: 10
        )
        #expect(entries.count == 1)
        let stored = try #require(entries.first)
        #expect(stored.agentName == "maintenance-daemon")
        #expect(stored.topic == "maintenance-cycle")
        #expect(stored.wing == "wing_maintenance-daemon")
    }
}
