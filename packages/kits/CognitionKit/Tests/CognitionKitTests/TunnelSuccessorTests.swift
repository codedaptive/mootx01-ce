import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// TunnelSuccessor — prediction lens (category 8, SPEC § 4.2). From an
/// anchor drawer in a wing, read the explicit tunnel graph and return
/// the drawers that tend to follow it by explicit link, ranked by how
/// many tunnels lead there (ties by ascending id), top k. "What tends
/// to follow this, by explicit links." A pure graph read — it sequences
/// no reasoning surface. Read-only. Swift peer of run_tunnel_successor.
@Suite("TunnelSuccessorTests")
struct TunnelSuccessorTests {

    private static let wing = "study"

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "tunnel-successor-test"))
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
            label: "leads-to", addedBy: "user",
            sourceDrawerId: src, targetDrawerId: tgt, kind: .references)
        _ = try await estate.capture(frame)
    }

    // CK-TS-1: from the anchor, the more-frequently-tunneled target is
    // the stronger prediction; an edge from an unrelated drawer is ignored.
    @Test("frequent successor ranks first; unrelated edges ignored")
    func frequentSuccessorRanksFirst() async throws {
        let (kit, handle) = try await openEstate()
        try await addEdge(kit, handle, src: "anchor", tgt: "X")
        try await addEdge(kit, handle, src: "anchor", tgt: "X") // X twice
        try await addEdge(kit, handle, src: "anchor", tgt: "Y") // Y once
        try await addEdge(kit, handle, src: "other", tgt: "Z")  // unrelated

        let out = try await TunnelSuccessor.run(
            kit: kit, handle: handle, wing: Self.wing, anchorID: "anchor", k: 5)

        #expect(out.count == 2, "only the anchor's successors")
        #expect(out[0] == Successor(id: "X", weight: 2), "the frequent successor leads")
        #expect(out[1] == Successor(id: "Y", weight: 1))
    }

    // CK-TS-2: an anchor with no outgoing tunnels predicts nothing.
    @Test("anchor with no outgoing tunnels predicts nothing")
    func noSuccessorsIsEmpty() async throws {
        let (kit, handle) = try await openEstate()
        try await addEdge(kit, handle, src: "other", tgt: "Z")

        let out = try await TunnelSuccessor.run(
            kit: kit, handle: handle, wing: Self.wing, anchorID: "anchor", k: 5)

        #expect(out.isEmpty)
    }

    // CK-TS-3: equal weights rank by ascending id, and k truncates the
    // ranking after the order is fixed.
    @Test("ties break by ascending id and k truncates")
    func tiesBreakByIDAndKTruncates() async throws {
        let (kit, handle) = try await openEstate()
        try await addEdge(kit, handle, src: "anchor", tgt: "b")
        try await addEdge(kit, handle, src: "anchor", tgt: "a")
        try await addEdge(kit, handle, src: "anchor", tgt: "c")

        let all = try await TunnelSuccessor.run(
            kit: kit, handle: handle, wing: Self.wing, anchorID: "anchor", k: 5)
        #expect(all.map(\.id) == ["a", "b", "c"], "equal weights rank by id")

        let capped = try await TunnelSuccessor.run(
            kit: kit, handle: handle, wing: Self.wing, anchorID: "anchor", k: 2)
        #expect(capped.map(\.id) == ["a", "b"], "k truncates the fixed order")
    }

    // CK-TS-4: a self-loop (anchor → anchor) is not a successor.
    @Test("self-loop is not a successor")
    func selfLoopIsNotASuccessor() async throws {
        let (kit, handle) = try await openEstate()
        try await addEdge(kit, handle, src: "anchor", tgt: "anchor")
        try await addEdge(kit, handle, src: "anchor", tgt: "X")

        let out = try await TunnelSuccessor.run(
            kit: kit, handle: handle, wing: Self.wing, anchorID: "anchor", k: 5)

        #expect(out.map(\.id) == ["X"])
    }
}
