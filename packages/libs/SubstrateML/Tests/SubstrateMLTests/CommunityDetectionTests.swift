// CommunityDetectionTests.swift
//
// Louvain phase-1 community detection per cookbook § 7.3.
// swift-testing peer suite for Sources/SubstrateML/CommunityDetection.swift,
// mirroring rust/src/community_detection.rs (5 #[test]) case-for-case.

import Testing
@testable import SubstrateML

@Suite("CommunityDetection")
struct CommunityDetectionTests {

    /// Build a symmetric adjacency from (a, b, w) edges — mirrors
    /// the Rust `symmetric_edges` helper.
    private func symmetricEdges(_ n: Int, _ edges: [(Int, Int, Double)]) -> CommunityDetection.Adjacency {
        var adj: CommunityDetection.Adjacency = Array(repeating: [], count: n)
        for (a, b, w) in edges {
            adj[a].append((neighbor: b, weight: w))
            adj[b].append((neighbor: a, weight: w))
        }
        return adj
    }

    @Test("an empty graph yields an empty labeling")
    func emptyGraph() {
        #expect(CommunityDetection.detect(adjacency: [], maxPasses: 10).isEmpty)
    }

    @Test("a disconnected graph gives one community per node")
    func disconnectedGraphOneCommunityPerNode() {
        let adj: CommunityDetection.Adjacency = Array(repeating: [], count: 4)
        #expect(CommunityDetection.detect(adjacency: adj, maxPasses: 10) == [0, 1, 2, 3])
    }

    @Test("two cliques with a weak bridge split into two communities")
    func twoCliquesSplitIntoTwoCommunities() {
        let edges: [(Int, Int, Double)] = [
            (0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0),
            (3, 4, 1.0), (3, 5, 1.0), (4, 5, 1.0),
            (0, 3, 0.01),
        ]
        let result = CommunityDetection.detect(adjacency: symmetricEdges(6, edges), maxPasses: 20)
        #expect(result[0] == result[1])
        #expect(result[1] == result[2])
        #expect(result[3] == result[4])
        #expect(result[4] == result[5])
        #expect(result[0] != result[3])
    }

    @Test("canonical labels start at zero and stay in range")
    func canonicalLabelsStartAtZero() {
        let edges: [(Int, Int, Double)] = [(0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0)]
        let result = CommunityDetection.detect(adjacency: symmetricEdges(3, edges), maxPasses: 20)
        #expect(result[0] == 0)
        let maxLabel = result.max() ?? 0
        #expect(maxLabel < result.count)
    }

    @Test("canonicalize renumbers in order of first appearance")
    func canonicalizeRenumbersInOrder() {
        let labels = [17, 3, 17, 99, 3, 17]
        // 17 -> 0, 3 -> 1, 99 -> 2.
        #expect(CommunityDetection.canonicalize(labels) == [0, 1, 0, 2, 1, 0])
    }
}
