import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// Constellation — structure lens (category 1). Reads a wing's
/// drawer-to-drawer tunnel graph and recovers its emergent communities by
/// surfacing NeuronKit's Louvain community detection. Read-only; "the
/// clusters I never named." Swift peer of run_constellation.
@Suite("ConstellationTests")
struct ConstellationTests {

    private static let wing = "study"

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "constellation-test"))
        return (kit, handle)
    }

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

    // CK-CS-1: two disjoint cliques resolve into two emergent communities.
    @Test("two cliques, two communities")
    func twoCliquesTwoCommunities() async throws {
        let (kit, handle) = try await openEstate()
        // Clique A: A1-A2-A3 fully connected.
        try await addEdge(kit, handle, src: "A1", tgt: "A2")
        try await addEdge(kit, handle, src: "A2", tgt: "A3")
        try await addEdge(kit, handle, src: "A1", tgt: "A3")
        // Clique B: B1-B2-B3 fully connected.
        try await addEdge(kit, handle, src: "B1", tgt: "B2")
        try await addEdge(kit, handle, src: "B2", tgt: "B3")
        try await addEdge(kit, handle, src: "B1", tgt: "B3")

        let c = try await ConstellationLens.run(
            kit: kit, handle: handle, wing: Self.wing)

        #expect(c.communities.count == 2, "two cliques ⇒ two emergent themes")
    }

    // CK-CS-2: a wing with no tunnels yields no communities.
    @Test("empty wing has no communities")
    func emptyWingHasNoCommunities() async throws {
        let (kit, handle) = try await openEstate()
        let c = try await ConstellationLens.run(
            kit: kit, handle: handle, wing: Self.wing)
        #expect(c.communities.isEmpty)
    }
}
