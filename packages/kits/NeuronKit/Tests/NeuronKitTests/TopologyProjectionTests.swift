import Foundation
import LocusKit
import Testing
@testable import NeuronKit

@Suite("Topology V3 persistent projection")
struct TopologyProjectionTests {
    private func node(_ id: String, community: Int, centrality: Double = 0.5,
                      code: String? = nil) -> GraphTopologyNode {
        GraphTopologyNode(
            id: id, communityId: community, centrality: centrality,
            lastActiveTs: nil, createdTs: "2026-01-01T00:00:00Z",
            tombstonedTs: nil, udcCode: code)
    }

    private func edge(_ source: String, _ target: String, type: String = "tunnel") -> GraphTopologyEdge {
        GraphTopologyEdge(
            source: source, target: target, edgeType: type,
            weight: type == "tunnel" ? 1 : 0.3,
            createdTs: type == "tunnel" ? "2026-01-01T00:00:00Z" : nil,
            tombstonedTs: nil)
    }

    @Test("classification changes do not move or regroup structural topology")
    func fdcInvariant() {
        let nodesA = [node("a", community: 0, code: "362.4"),
                      node("b", community: 0, code: "362.4"),
                      node("c", community: 1, code: "900")]
        let nodesB = [node("a", community: 0, code: "001"),
                      node("b", community: 0, code: "700"),
                      node("c", community: 1, code: nil)]
        let edges = [edge("a", "b"), edge("b", "c", type: "kgFact"), edge("a", "c", type: "lattice")]
        let communities = [
            GraphTopologyCommunity(id: 0, size: 2, dominantUdcCode: "362.4"),
            GraphTopologyCommunity(id: 1, size: 1, dominantUdcCode: "900"),
        ]
        let a = TopologyProjector.project(
            GraphTopology(nodes: nodesA, edges: edges, communityCount: 2, communities: communities),
            previousSnapshot: nil)
        let b = TopologyProjector.project(
            GraphTopology(nodes: nodesB, edges: edges, communityCount: 2, communities: communities),
            previousSnapshot: nil)

        #expect(a.communities.map(\.stableKey) == b.communities.map(\.stableKey))
        #expect(a.folds.map(\.stableKey) == b.folds.map(\.stableKey))
        #expect(a.nodesByID["a"]?.x == b.nodesByID["a"]?.x)
        #expect(a.bridges.allSatisfy { $0.edgeType == "kgFact" })
        #expect(Set(a.bridges.map(\.level)) == Set(["community", "fold"]))
    }

    @Test("local coordinates respond to structural relationships")
    func relationshipAwareCoordinates() {
        let nodes = [node("a", community: 0), node("b", community: 0), node("c", community: 0)]
        let communities = [GraphTopologyCommunity(id: 0, size: 3, dominantUdcCode: "")]
        let first = TopologyProjector.project(
            GraphTopology(nodes: nodes, edges: [edge("a", "b")],
                          communityCount: 1, communities: communities),
            previousSnapshot: nil)
        let second = TopologyProjector.project(
            GraphTopology(nodes: nodes, edges: [edge("b", "c")],
                          communityCount: 1, communities: communities),
            previousSnapshot: nil)

        #expect(first.nodesByID["a"]?.x == -0.34372757293757106)
        #expect(first.nodesByID["a"]?.y == -0.44612174568373836)
        #expect(first.nodesByID["b"]?.x == -0.3630845216131912)
        #expect(first.nodesByID["b"]?.y == -0.45488673264244267)
        #expect(first.nodesByID["a"]?.x != second.nodesByID["a"]?.x)
        #expect(first.nodesByID["b"]?.y != second.nodesByID["b"]?.y)
    }

    @Test("overlap matching preserves identity and coordinates after growth and label renumbering")
    func overlapContinuity() throws {
        let original = GraphTopology(
            nodes: [node("a", community: 0, centrality: 1), node("b", community: 0)],
            edges: [edge("a", "b")], communityCount: 1,
            communities: [GraphTopologyCommunity(id: 0, size: 2, dominantUdcCode: "")])
        let first = TopologyProjector.project(original, previousSnapshot: nil)
        let community = first.communities[0]
        let fold = first.folds[0]
        #expect(community.stableKey == "c-e5d6bb19042a894f")
        #expect(fold.stableKey == "f-e5d6bb19042a894f")
        let previous = try JSONSerialization.data(withJSONObject: [
            "coordinateFrameVersion": TopologyProjector.coordinateFrameVersion,
            "nodes": first.nodesByID.map { id, value in [
                "id": id, "communityKey": value.communityKey ?? "",
                "foldKey": value.foldKey ?? "", "x": value.x, "y": value.y, "z": value.z,
            ] },
            "communities": [["stableKey": community.stableKey,
                              "x": community.x, "y": community.y, "z": community.z]],
            "folds": [["stableKey": fold.stableKey, "x": fold.x, "y": fold.y, "z": fold.z]],
        ])
        let grown = GraphTopology(
            nodes: [node("a", community: 9, centrality: 1), node("b", community: 9),
                    node("new", community: 9)],
            edges: [edge("a", "b"), edge("b", "new")], communityCount: 1,
            communities: [GraphTopologyCommunity(id: 9, size: 3, dominantUdcCode: "")])
        let second = TopologyProjector.project(grown, previousSnapshot: previous)

        #expect(second.communities[0].stableKey == community.stableKey)
        #expect(second.folds[0].stableKey == fold.stableKey)
        #expect(second.communities[0].x == community.x)
        #expect(second.nodesByID["a"]?.x == first.nodesByID["a"]?.x)
        #expect(second.nodesByID["new"]?.foldKey == fold.stableKey)
    }

    @Test("minor overlap does not let replacement structure steal an old identity")
    func replacementGetsNewIdentity() throws {
        let original = GraphTopology(
            nodes: [node("a", community: 0), node("b", community: 0), node("c", community: 0)],
            edges: [edge("a", "b"), edge("b", "c")], communityCount: 1,
            communities: [GraphTopologyCommunity(id: 0, size: 3, dominantUdcCode: "")])
        let first = TopologyProjector.project(original, previousSnapshot: nil)
        let previous = try JSONSerialization.data(withJSONObject: [
            "coordinateFrameVersion": TopologyProjector.coordinateFrameVersion,
            "nodes": first.nodesByID.map { id, value in [
                "id": id, "communityKey": value.communityKey ?? "",
                "foldKey": value.foldKey ?? "", "x": value.x, "y": value.y, "z": value.z,
            ] },
            "communities": first.communities.map { [
                "stableKey": $0.stableKey, "x": $0.x, "y": $0.y, "z": $0.z,
            ] },
            "folds": first.folds.map { [
                "stableKey": $0.stableKey, "x": $0.x, "y": $0.y, "z": $0.z,
            ] },
        ])
        let replacement = GraphTopology(
            nodes: [node("a", community: 9), node("new-1", community: 9),
                    node("new-2", community: 9), node("new-3", community: 9)],
            edges: [edge("a", "new-1"), edge("new-1", "new-2"), edge("new-2", "new-3")],
            communityCount: 1,
            communities: [GraphTopologyCommunity(id: 9, size: 4, dominantUdcCode: "")])
        let second = TopologyProjector.project(replacement, previousSnapshot: previous)

        #expect(second.communities[0].stableKey != first.communities[0].stableKey)
        #expect(second.folds[0].stableKey != first.folds[0].stableKey)
    }

    @Test("large structural communities split into bounded folds")
    func createsFolds() {
        let nodes = (0..<400).map { node(String(format: "n%03d", $0), community: 0) }
        let edges = (1..<400).map {
            edge(String(format: "n%03d", $0 - 1), String(format: "n%03d", $0))
        }
        let topology = GraphTopology(
            nodes: nodes, edges: edges, communityCount: 1,
            communities: [GraphTopologyCommunity(id: 0, size: nodes.count, dominantUdcCode: "")])
        let projection = TopologyProjector.project(topology, previousSnapshot: nil)

        #expect(projection.folds.count == 3)
        #expect(projection.folds.reduce(0) { $0 + $1.size } == nodes.count)
        #expect(Set(projection.nodesByID.values.compactMap(\.foldKey)).count == 3)
    }

    @Test("coordinate frame upgrade preserves identities and replaces stale positions")
    func coordinateFrameUpgrade() throws {
        let topology = GraphTopology(
            nodes: [node("a", community: 0), node("b", community: 0)],
            edges: [edge("a", "b")], communityCount: 1,
            communities: [GraphTopologyCommunity(id: 0, size: 2, dominantUdcCode: "")])
        let first = TopologyProjector.project(topology, previousSnapshot: nil)
        let community = first.communities[0]
        let fold = first.folds[0]
        func snapshot(version: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "coordinateFrameVersion": version,
                "nodes": first.nodesByID.map { id, value in [
                    "id": id, "communityKey": value.communityKey ?? "",
                    "foldKey": value.foldKey ?? "", "x": 0.21, "y": 0.22, "z": 0.23,
                ] },
                "communities": [["stableKey": community.stableKey, "x": 0.31, "y": 0.32, "z": 0.33]],
                "folds": [["stableKey": fold.stableKey, "x": 0.41, "y": 0.42, "z": 0.43]],
            ])
        }

        let upgraded = TopologyProjector.project(topology, previousSnapshot: try snapshot(version: 1))
        #expect(upgraded.communities[0].stableKey == community.stableKey)
        #expect(upgraded.folds[0].stableKey == fold.stableKey)
        #expect(upgraded.communities[0].x != 0.31)
        #expect(upgraded.nodesByID["a"]?.x != 0.21)

        let currentData = try snapshot(version: TopologyProjector.coordinateFrameVersion)
        let current = TopologyProjector.project(topology, previousSnapshot: currentData)
        #expect(current.communities[0].x == 0.31)
        #expect(current.nodesByID["a"]?.x == 0.21)
    }

    @Test("coordinate axes remain decorrelated across an estate")
    func coordinateAxesAreDecorrelated() {
        let count = 512
        let nodes = (0..<count).map { node("axis-\($0)", community: $0) }
        let communities = (0..<count).map {
            GraphTopologyCommunity(id: $0, size: 1, dominantUdcCode: "")
        }
        let projection = TopologyProjector.project(
            GraphTopology(nodes: nodes, edges: [], communityCount: count, communities: communities),
            previousSnapshot: nil)
        func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
            let n = Double(lhs.count)
            let lMean = lhs.reduce(0, +) / n
            let rMean = rhs.reduce(0, +) / n
            let covariance = zip(lhs, rhs).reduce(0) { $0 + ($1.0 - lMean) * ($1.1 - rMean) }
            let lVariance = lhs.reduce(0) { $0 + ($1 - lMean) * ($1 - lMean) }
            let rVariance = rhs.reduce(0) { $0 + ($1 - rMean) * ($1 - rMean) }
            return covariance / sqrt(lVariance * rVariance)
        }
        let x = projection.communities.map(\.x)
        let y = projection.communities.map(\.y)
        let z = projection.communities.map(\.z)
        #expect(abs(correlation(x, y)) < 0.12)
        #expect(abs(correlation(x, z)) < 0.12)
        #expect(abs(correlation(y, z)) < 0.12)
    }
}

@Suite("Topology V3 dirty fingerprint")
struct TopologyInputsTokenTests {
    @Test("same-count fact replacement changes the topology fingerprint")
    func factReplacementChangesFingerprint() {
        let filedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = KGFact(
            id: "fact", subject: "alpha", predicate: "relates", object: "value",
            sourceDrawerID: "drawer-a", filedAt: filedAt)
        let replacement = KGFact(
            id: "fact", subject: "beta", predicate: "relates", object: "value",
            sourceDrawerID: "drawer-b", filedAt: filedAt)
        let firstToken = TopologyInputsToken(drawers: [], tunnels: [], facts: [first])
        let replacementToken = TopologyInputsToken(drawers: [], tunnels: [], facts: [replacement])

        #expect(firstToken.factCount == replacementToken.factCount)
        #expect(firstToken.fingerprint != replacementToken.fingerprint)
    }

    @Test("fingerprint carries the coordinate-frame recalculation floor")
    func fingerprintCarriesCoordinateFloor() {
        let token = TopologyInputsToken(drawers: [], tunnels: [], facts: [])
        #expect(token.fingerprint.hasPrefix("cf\(TopologyProjector.coordinateFrameVersion):"))
        #expect(!token.fingerprint.hasPrefix("cf1:"))
    }
}
