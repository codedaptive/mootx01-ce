import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// Constellation — structural reasoning lens (Lens 2). Reads a wing's
/// drawer-to-drawer tunnel graph through GLK and recovers its emergent
/// communities (NeuronKit `constellations`). Read-only; "the clusters I
/// never named." Swift peer of `run_constellation`.
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

    // CK-CN-1: two disjoint triangles recover as two communities — the
    // clusters emerge from the graph structure alone.
    @Test("two cliques recover as two communities")
    func twoCliquesTwoCommunities() async throws {
        let (kit, handle) = try await openEstate()
        // Clique A: a1-a2-a3
        try await addEdge(kit, handle, src: "a1", tgt: "a2")
        try await addEdge(kit, handle, src: "a2", tgt: "a3")
        try await addEdge(kit, handle, src: "a3", tgt: "a1")
        // Clique B: b1-b2-b3
        try await addEdge(kit, handle, src: "b1", tgt: "b2")
        try await addEdge(kit, handle, src: "b2", tgt: "b3")
        try await addEdge(kit, handle, src: "b3", tgt: "b1")

        let result = try await ConstellationLens.run(kit: kit, handle: handle, wing: Self.wing)
        #expect(result.communities.count == 2)
        // Each community is one clique; communities ordered by smallest member.
        #expect(result.communities[0] == ["a1", "a2", "a3"])
        #expect(result.communities[1] == ["b1", "b2", "b3"])
    }

    // CK-CN-2: a wing with no tunnels yields no communities — no graph,
    // no clusters, no throw.
    @Test("empty wing has no communities")
    func emptyWingHasNoCommunities() async throws {
        let (kit, handle) = try await openEstate()
        let result = try await ConstellationLens.run(kit: kit, handle: handle, wing: Self.wing)
        #expect(result.communities.isEmpty)
    }
}
