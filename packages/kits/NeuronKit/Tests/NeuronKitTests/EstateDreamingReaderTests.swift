import Foundation
import Testing
import GeniusLocusKit
// LocusKit imported for OwnerCredentials and Drawer construction helpers.
// This file does not reference ProposeFrame by name so the GeniusLocusKit /
// LocusKit ProposeFrame ambiguity does not arise here.
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import NeuronKit

/// Tests for EstateDreamingReader — the production adapter that binds
/// DreamingSubstrateReader to a live GeniusLocusKit estate.
///
/// Coverage plan:
///   §1  buildObservations (static, no estate) — v1 room-grouping algorithm
///   §2  coOccurrenceObservations via live estate (drawers captured through GLK)
///   §3  existingTunnels via live estate (empty and non-empty via GLK INTERFACE)
///   §4  recentRecallTraces via live estate (empty case; trace insertion is
///       a GLK-internal operation not yet surfaced publicly, so the non-empty
///       case is covered by the LocusKit DrawerStore tests in RecallTraceItemTests)
///   §5  Protocol conformance — adapter constructs cleanly over a real estate
@Suite("EstateDreamingReader — production adapter integration")
struct EstateDreamingReaderTests {

    // MARK: - Infrastructure

    private func makeKit() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dreaming-reader-test")
        // In-memory estate: create the schema first, then open via the GLK coordinator.
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func makeDrawer(id: String, wing: String, room: String) -> Drawer {
        Drawer(
            id: id, content: "content-\(id)",
            wing: wing, room: room,
            addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: ""
        )
    }

    // MARK: - § 1  buildObservations (unit, no estate needed)

    @Test("buildObservations groups same-room drawers into pairs")
    func buildObservationsSameRoom() {
        let drawers = [
            makeDrawer(id: "a", wing: "w1", room: "r1"),
            makeDrawer(id: "b", wing: "w1", room: "r1"),
            makeDrawer(id: "c", wing: "w1", room: "r1"),
            makeDrawer(id: "x", wing: "w2", room: "r2"),  // solo — no pair
        ]
        let obs = EstateDreamingReader.buildObservations(from: drawers)
        // C(3,2) = 3 pairs from r1; solo x in r2 emits none.
        #expect(obs.count == 3)
        let pairs = obs.map { ($0.endpointA, $0.endpointB) }
        #expect(pairs.contains { $0 == ("a", "b") })
        #expect(pairs.contains { $0 == ("a", "c") })
        #expect(pairs.contains { $0 == ("b", "c") })
    }

    @Test("buildObservations attempts equals room drawer count")
    func buildObservationsAttemptsIsCount() {
        let drawers = [
            makeDrawer(id: "a", wing: "w", room: "r"),
            makeDrawer(id: "b", wing: "w", room: "r"),
            makeDrawer(id: "c", wing: "w", room: "r"),
        ]
        let obs = EstateDreamingReader.buildObservations(from: drawers)
        #expect(obs.allSatisfy { $0.attempts == 3 })
    }

    @Test("buildObservations output is deterministically sorted")
    func buildObservationsDeterministicOrder() {
        let drawers = [
            makeDrawer(id: "z", wing: "w", room: "r"),
            makeDrawer(id: "a", wing: "w", room: "r"),
            makeDrawer(id: "m", wing: "w", room: "r"),
        ]
        let obs = EstateDreamingReader.buildObservations(from: drawers)
        for i in 0..<(obs.count - 1) {
            if obs[i].endpointA == obs[i + 1].endpointA {
                #expect(obs[i].endpointB <= obs[i + 1].endpointB)
            } else {
                #expect(obs[i].endpointA <= obs[i + 1].endpointA)
            }
        }
    }

    @Test("buildObservations returns empty when no room has ≥ 2 drawers")
    func buildObservationsEmptyWhenNoRoomPairs() {
        let drawers = [
            makeDrawer(id: "a", wing: "w1", room: "r1"),
            makeDrawer(id: "b", wing: "w2", room: "r2"),
        ]
        let obs = EstateDreamingReader.buildObservations(from: drawers)
        #expect(obs.isEmpty)
    }

    @Test("buildObservations evidenceTargets contains both drawer IDs")
    func buildObservationsEvidenceTargets() throws {
        let drawers = [
            makeDrawer(id: "left",  wing: "w", room: "r"),
            makeDrawer(id: "right", wing: "w", room: "r"),
        ]
        let obs = EstateDreamingReader.buildObservations(from: drawers)
        let obs0 = try #require(obs.first)
        #expect(Set(obs0.evidenceTargets) == ["left", "right"])
    }

    // MARK: - § 2  coOccurrenceObservations — live estate

    @Test("coOccurrenceObservations returns pairs for same-room drawers")
    func coOccurrenceObservationsLiveEstate() async throws {
        let (kit, handle) = try await makeKit()
        let reader = EstateDreamingReader(handle: handle, kit: kit)

        // CaptureFrame.room is a RoomID (String). All drawers land in the
        // estate's default wing — grouping is by (defaultWing, room).
        // Two drawers in "pantry" → 1 pair; one in "tools" → 0 pairs.
        _ = try await kit.capture(handle, CaptureFrame(
            content: "apple", channel: .typed,
            room: "pantry",
            latticeAnchor: .udc("004"),
            addedBy: "test", embeddingModelID: "model-v1"))
        _ = try await kit.capture(handle, CaptureFrame(
            content: "banana", channel: .typed,
            room: "pantry",
            latticeAnchor: .udc("004"),
            addedBy: "test", embeddingModelID: "model-v1"))
        _ = try await kit.capture(handle, CaptureFrame(
            content: "spanner", channel: .typed,
            room: "tools",
            latticeAnchor: .udc("004"),
            addedBy: "test", embeddingModelID: "model-v1"))

        let obs = try await reader.coOccurrenceObservations()
        // "pantry" has 2 drawers → 1 pair; "tools" has 1 → no pair.
        #expect(obs.count == 1)
        #expect(obs.first?.attempts == 2)
    }

    @Test("coOccurrenceObservations returns empty for a fresh estate")
    func coOccurrenceObservationsEmpty() async throws {
        let (kit, handle) = try await makeKit()
        let reader = EstateDreamingReader(handle: handle, kit: kit)
        // No drawers → no pairs.
        let obs = try await reader.coOccurrenceObservations()
        #expect(obs.isEmpty)
    }

    // MARK: - § 3  existingTunnels — live estate

    @Test("existingTunnels returns empty for a fresh estate")
    func existingTunnelsEmpty() async throws {
        let (kit, handle) = try await makeKit()
        let reader = EstateDreamingReader(handle: handle, kit: kit)
        let tunnels = try await reader.existingTunnels()
        #expect(tunnels.isEmpty)
    }

    // MARK: - § 4  recentRecallTraces — live estate

    @Test("recentRecallTraces returns empty for a fresh estate")
    func recentRecallTracesEmpty() async throws {
        let (kit, handle) = try await makeKit()
        let reader = EstateDreamingReader(handle: handle, kit: kit)
        let traces = try await reader.recentRecallTraces(
            since: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 9_999_999)
        )
        #expect(traces.isEmpty)
    }

    // MARK: - § 5  Protocol conformance

    @Test("EstateDreamingReader conforms to DreamingSubstrateReader")
    func conformsToProtocol() async throws {
        let (kit, handle) = try await makeKit()
        // Type-check: assigning to the protocol type must compile.
        let reader: any DreamingSubstrateReader = EstateDreamingReader(handle: handle, kit: kit)
        // Call all three reads to confirm delegation compiles and returns.
        _ = try await reader.recentRecallTraces(
            since: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 1))
        _ = try await reader.coOccurrenceObservations()
        _ = try await reader.existingTunnels()
    }
}
