import Testing
import Foundation
@testable import WorkPacketKit

// LineageGraphTests — lineage trace: packet → antecedents.
//
// Verifies: trace returns antecedent IDs in breadth-first order;
// cycle detection prevents infinite loops; depth limit is respected;
// antecedents() returns decoded packets.

@Suite("LineageGraph")
struct LineageGraphTests {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePacket(
        id: String,
        links: [LineageLink] = []
    ) -> WorkPacket {
        WorkPacket(
            id: id,
            objective: "Packet \(id)",
            provenance: WorkPacketProvenance(
                model: "m", agent: "a",
                createdAt: fixedDate, updatedAt: fixedDate
            ),
            lineageLinks: links
        )
    }

    // MARK: - trace

    @Test("trace on a packet with no lineage links returns empty")
    func traceWithNoLinks() async throws {
        let client = MockEstateClient()
        let root = makePacket(id: "root-no-links")
        try client.plant(root)
        let graph = LineageGraph(client: client)
        let antecedents = try await graph.trace(from: root.id)
        #expect(antecedents.isEmpty)
    }

    @Test("trace walks one hop to a single antecedent")
    func traceOneHop() async throws {
        let client = MockEstateClient()
        let parent = makePacket(id: "parent-001")
        let child = makePacket(id: "child-001", links: [
            LineageLink(kind: .derivesFrom, targetPacketID: parent.id)
        ])
        try client.plant(parent)
        try client.plant(child)
        let graph = LineageGraph(client: client)
        let antecedents = try await graph.trace(from: child.id)
        #expect(antecedents == ["parent-001"])
    }

    @Test("trace walks two hops breadth-first")
    func traceTwoHops() async throws {
        let client = MockEstateClient()
        let grandparent = makePacket(id: "gp-001")
        let parent = makePacket(id: "p-001", links: [
            LineageLink(kind: .derivesFrom, targetPacketID: grandparent.id)
        ])
        let child = makePacket(id: "c-001", links: [
            LineageLink(kind: .derivesFrom, targetPacketID: parent.id)
        ])
        try client.plant(grandparent)
        try client.plant(parent)
        try client.plant(child)
        let graph = LineageGraph(client: client)
        let antecedents = try await graph.trace(from: child.id)
        // Breadth-first: parent first, then grandparent.
        #expect(antecedents.first == "p-001")
        #expect(antecedents.last == "gp-001")
        #expect(antecedents.count == 2)
    }

    @Test("trace respects maxDepth limit")
    func traceRespectsMaxDepth() async throws {
        let client = MockEstateClient()
        // Chain: c → b → a (depth 2)
        let a = makePacket(id: "a")
        let b = makePacket(id: "b", links: [LineageLink(kind: .derivesFrom, targetPacketID: a.id)])
        let c = makePacket(id: "c", links: [LineageLink(kind: .derivesFrom, targetPacketID: b.id)])
        try client.plant(a); try client.plant(b); try client.plant(c)
        let graph = LineageGraph(client: client)
        // maxDepth=1 should stop after finding "b" — does not follow b→a.
        let antecedents = try await graph.trace(from: c.id, maxDepth: 1)
        #expect(antecedents == ["b"])
    }

    @Test("trace handles cycle without infinite loop")
    func traceHandlesCycle() async throws {
        let client = MockEstateClient()
        // Cycle: x references y, y references x.
        let x = makePacket(id: "x", links: [LineageLink(kind: .respondsTo, targetPacketID: "y")])
        let y = makePacket(id: "y", links: [LineageLink(kind: .respondsTo, targetPacketID: "x")])
        try client.plant(x); try client.plant(y)
        let graph = LineageGraph(client: client)
        // Trace from x: finds y (hop 1), x is already visited so terminates.
        let antecedents = try await graph.trace(from: x.id)
        #expect(antecedents == ["y"])
    }

    @Test("trace with derivesFrom and respondsTo links collects both")
    func traceBothLinkKinds() async throws {
        let client = MockEstateClient()
        let source1 = makePacket(id: "src-001")
        let source2 = makePacket(id: "src-002")
        let packet = makePacket(id: "combined", links: [
            LineageLink(kind: .derivesFrom, targetPacketID: source1.id),
            LineageLink(kind: .respondsTo, targetPacketID: source2.id),
        ])
        try client.plant(source1); try client.plant(source2); try client.plant(packet)
        let graph = LineageGraph(client: client)
        let antecedents = try await graph.trace(from: packet.id)
        #expect(antecedents.count == 2)
        #expect(antecedents.contains("src-001"))
        #expect(antecedents.contains("src-002"))
    }

    // MARK: - antecedents

    @Test("antecedents returns decoded WorkPackets in traversal order")
    func antecedentsReturnsDecodedPackets() async throws {
        let client = MockEstateClient()
        let parent = makePacket(id: "decoded-parent", links: [])
        let child = makePacket(id: "decoded-child", links: [
            LineageLink(kind: .derivesFrom, targetPacketID: parent.id)
        ])
        try client.plant(parent); try client.plant(child)
        let graph = LineageGraph(client: client)
        let packets = try await graph.antecedents(of: child.id)
        #expect(packets.count == 1)
        #expect(packets.first?.id == parent.id)
        #expect(packets.first?.objective == "Packet decoded-parent")
    }

    @Test("antecedents returns empty for a packet with no links")
    func antecedentsEmptyForNoLinks() async throws {
        let client = MockEstateClient()
        let lone = makePacket(id: "lone-wolf")
        try client.plant(lone)
        let graph = LineageGraph(client: client)
        let packets = try await graph.antecedents(of: lone.id)
        #expect(packets.isEmpty)
    }
}
