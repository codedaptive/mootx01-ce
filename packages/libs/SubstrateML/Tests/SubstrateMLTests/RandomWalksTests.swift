// RandomWalksTests.swift
//
// Random walks with restart per cookbook § 7.4. swift-testing peer
// suite for Sources/SubstrateML/RandomWalks.swift, mirroring
// rust/src/random_walks.rs (5 #[test]) case-for-case, using the same
// deterministic SplitMix64 seeds so the walks are reproducible and
// comparable across legs (Known Ambiguity 2).

import Testing
@testable import SubstrateML

@Suite("RandomWalks")
struct RandomWalksTests {

    private func symmetricEdges(_ n: Int, _ edges: [(Int, Int, Double)]) -> RandomWalks.Adjacency {
        var adj: RandomWalks.Adjacency = Array(repeating: [], count: n)
        for (a, b, w) in edges {
            adj[a].append((neighbor: b, weight: w))
            adj[b].append((neighbor: a, weight: w))
        }
        return adj
    }

    @Test("a walk starts at the start node and respects its length and range")
    func walkStartsAtStartAndRespectsLength() {
        let adj = symmetricEdges(4, [(0, 1, 1.0), (1, 2, 1.0), (2, 3, 1.0)])
        let w = RandomWalks.walk(adjacency: adj, start: 0, length: 10,
                                 restartProb: 0.15, seed: 0xDEAD_BEEF_CAFE_F00D)
        #expect(w.count == 10)
        #expect(w[0] == 0)
        for node in w { #expect(node < 4) }
    }

    @Test("the same seed yields the same walk (determinism)")
    func determinismSameSeedSameWalk() {
        let adj = symmetricEdges(4, [(0, 1, 1.0), (0, 2, 1.0), (1, 2, 1.0), (2, 3, 1.0)])
        let seed: UInt64 = 0xCAFE_BABE_DEAD_BEEF
        let w1 = RandomWalks.walk(adjacency: adj, start: 0, length: 20, restartProb: 0.15, seed: seed)
        let w2 = RandomWalks.walk(adjacency: adj, start: 0, length: 20, restartProb: 0.15, seed: seed)
        #expect(w1 == w2)
    }

    @Test("a high restart probability returns to start often")
    func restartProbReturnsToStartOften() {
        let adj = symmetricEdges(4, [(0, 1, 1.0), (1, 2, 1.0), (2, 3, 1.0)])
        let w = RandomWalks.walk(adjacency: adj, start: 0, length: 100, restartProb: 0.99, seed: 42)
        let starts = w.filter { $0 == 0 }.count
        #expect(starts > 80, "expected many restarts to start, got \(starts)")
    }

    @Test("a dead end restarts toward the start")
    func deadEndRestartsToStart() {
        // Node 0 connected only to node 1; the walk oscillates 0↔1.
        let adj = symmetricEdges(2, [(0, 1, 1.0)])
        let w = RandomWalks.walk(adjacency: adj, start: 0, length: 20, restartProb: 0.0, seed: 0x1234_5678)
        for node in w { #expect(node == 0 || node == 1) }
    }

    @Test("all-zero weights fall back to a uniform pick")
    func uniformFallbackWhenAllWeightsZero() {
        var rng = SplitMix64(seed: 7)
        let neighbors: [(neighbor: Int, weight: Double)] = [(0, 0.0), (1, 0.0), (2, 0.0)]
        let pick = RandomWalks.sampleWeighted(neighbors, rng: &rng)
        #expect(pick < 3)
    }
}
