import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// Keystones — structure lens (category 1). Reads a wing's
/// drawer-to-drawer tunnel graph and ranks the load-bearing memories by
/// surfacing NeuronKit's eigenvalue-centrality keystones. Read-only;
/// "the spine of your thinking." Swift peer of run_keystones.
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

    // CK-KS-1: a star graph — the hub is the load-bearing memory; topK bounds.
    @Test("star hub is the keystone")
    func starHubIsTheKeystone() async throws {
        let (kit, handle) = try await openEstate()
        try await addEdge(kit, handle, src: "hub", tgt: "s1")
        try await addEdge(kit, handle, src: "hub", tgt: "s2")
        try await addEdge(kit, handle, src: "hub", tgt: "s3")
        try await addEdge(kit, handle, src: "hub", tgt: "s4")

        // now: explicit sentinel — unit tests have no real estate clock context.
        let top = try await Keystones.run(
            kit: kit, handle: handle, wing: Self.wing, topK: 3,
            now: Date(timeIntervalSince1970: 0))

        #expect(!top.isEmpty)
        #expect(top[0].id == "hub", "the hub is the load-bearing memory")
        #expect(top.count <= 3, "topK bounds the result")
    }

    // CK-KS-2: a wing with no tunnels yields an empty result — no graph.
    @Test("empty wing has no keystones")
    func emptyWingHasNoKeystones() async throws {
        let (kit, handle) = try await openEstate()
        // now: explicit sentinel — unit tests have no real estate clock context.
        let top = try await Keystones.run(
            kit: kit, handle: handle, wing: Self.wing, topK: 5,
            now: Date(timeIntervalSince1970: 0))
        #expect(top.isEmpty)
    }
}
