import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// Free association — structural reasoning lens (Lens 3). Spreads activation
/// from a seed drawer over a wing's drawer-to-drawer tunnel graph (a
/// restart random walk, NeuronKit `spreadingActivation`) and returns the
/// top-k most-activated memories. Read-only; "what this reminds me of."
/// Swift peer of `run_free_association`.
@Suite("FreeAssociationTests")
struct FreeAssociationTests {

    private static let wing = "study"

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "free-assoc-test"))
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

    // Long deterministic walk so visit frequencies are stable to assert on.
    private static let walkLength = 5000

    // CK-FA-1: associations surface the reachable graph, ranked by proximity —
    // direct neighbour outranks the two-hop memory, the seed is excluded from
    // its own associations, and a disconnected component never surfaces.
    @Test("associates reachable, excludes unreachable")
    func associatesReachableExcludesUnreachable() async throws {
        let (kit, handle) = try await openEstate()
        // Reachable from S: S<->A, A<->C  (S-A direct, S..C two hops)
        try await addEdge(kit, handle, src: "S", tgt: "A")
        try await addEdge(kit, handle, src: "A", tgt: "S")
        try await addEdge(kit, handle, src: "A", tgt: "C")
        try await addEdge(kit, handle, src: "C", tgt: "A")
        // Disconnected component: D<->E (never reachable from S)
        try await addEdge(kit, handle, src: "D", tgt: "E")
        try await addEdge(kit, handle, src: "E", tgt: "D")

        let assoc = try await FreeAssociationLens.run(
            kit: kit, handle: handle, wing: Self.wing,
            seedDrawerID: "S", walkLength: Self.walkLength, k: 10)

        let ids = assoc.map(\.drawerID)
        #expect(ids.contains("A"), "the directly-tunneled memory surfaces")
        #expect(ids.contains("C"), "the two-hop memory surfaces, weaker")
        #expect(!ids.contains("S"), "the seed is not its own association")
        #expect(!ids.contains("D") && !ids.contains("E"),
                "the disconnected component never surfaces")

        // Direct neighbour outranks the two-hop memory.
        let a = assoc.first { $0.drawerID == "A" }?.activation ?? 0
        let c = assoc.first { $0.drawerID == "C" }?.activation ?? 0
        #expect(a > c, "direct neighbor outranks the two-hop memory")
    }

    // CK-FA-2: a seed absent from the graph (no tunnel touches it) yields no
    // associations.
    @Test("seed absent from graph is empty")
    func seedAbsentFromGraphIsEmpty() async throws {
        let (kit, handle) = try await openEstate()
        try await addEdge(kit, handle, src: "A", tgt: "B")
        let assoc = try await FreeAssociationLens.run(
            kit: kit, handle: handle, wing: Self.wing,
            seedDrawerID: "S", walkLength: Self.walkLength, k: 10)
        #expect(assoc.isEmpty)
    }
}
