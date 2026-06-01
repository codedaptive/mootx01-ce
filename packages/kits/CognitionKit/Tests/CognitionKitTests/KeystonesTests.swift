import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// Keystones — structural reasoning lens (Lens 1). Reads a wing's
/// drawer-to-drawer tunnel graph through GLK and ranks the load-bearing
/// memories by eigenvalue centrality (NeuronKit `keystones`). Read-only;
/// the conscious "spine of your thinking." Swift peer of `run_keystones`.
@Suite("KeystonesTests")
struct KeystonesTests {

    private static let wing = "study"

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "keystones-test"))
        return (kit, handle)
    }

    /// Seed one drawer-to-drawer tunnel in the wing (the graph the lens reads).
    private func addEdge(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        src: String, tgt: String
    ) async throws {
        let estate = try await kit.estate(for: handle)
        let frame = TunnelCaptureFrame(
            sourceWing: Self.wing, sourceRoom: "r",
            targetWing: Self.wing, targetRoom: "r",
            label: "relates", addedBy: "user",
            sourceDrawerId: src, targetDrawerId: tgt, kind: .references)
        _ = try await estate.capture(frame)
    }

    // CK-KS-1: a star graph's hub surfaces as the top keystone end-to-end
    // over a real estate — "the spine of your thinking."
    @Test("star hub is the keystone")
    func starHubIsTheKeystone() async throws {
        let (kit, handle) = try await openEstate()
        try await addEdge(kit, handle, src: "hub", tgt: "s1")
        try await addEdge(kit, handle, src: "hub", tgt: "s2")
        try await addEdge(kit, handle, src: "hub", tgt: "s3")
        try await addEdge(kit, handle, src: "hub", tgt: "s4")

        let top = try await Keystones.run(kit: kit, handle: handle, wing: Self.wing, topK: 3)
        #expect(!top.isEmpty)
        #expect(top.first?.id == "hub")
        #expect(top.count <= 3)
    }

    // CK-KS-2: a wing with no tunnels yields an empty result — no graph,
    // no keystones, no throw.
    @Test("empty wing has no keystones")
    func emptyWingHasNoKeystones() async throws {
        let (kit, handle) = try await openEstate()
        let top = try await Keystones.run(kit: kit, handle: handle, wing: Self.wing, topK: 5)
        #expect(top.isEmpty)
    }
}
