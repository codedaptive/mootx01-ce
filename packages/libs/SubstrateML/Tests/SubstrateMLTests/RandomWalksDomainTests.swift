// RandomWalksDomainTests.swift
//
// Domain enforcement tests for RandomWalks.
//
// RandomWalks requires a valid Markov kernel:
//   - Every neighbor index must be in [0, N) where N = adjacency.count.
//   - Every edge weight must be finite and >= 0.
//   - sampleWeighted requires a non-empty neighbor list.
//
// Violations trigger precondition failures (process-terminating,
// consistent with sibling engine convention in this package). The
// tests below verify:
//   - Valid Markov kernels pass through and produce correct walks.
//   - Edge cases: all-zero weights (uniform fallback), single-node
//     graph (only self-restart), zero-weight edges co-existing with
//     positive-weight edges.
//
// Precondition paths (invalid neighbor index, negative weight, NaN
// weight, Inf weight, empty neighbor list) are verified by code
// inspection of RandomWalks.swift and are documented below.
//
// Conformance vector: docs/engineering/substrate_reference/test-harness/
//   vectors/random_walks_domain.json

import Testing
@testable import SubstrateML

@Suite("RandomWalks domain enforcement")
struct RandomWalksDomainTests {

    typealias Adjacency = [[(neighbor: Int, weight: Double)]]

    // MARK: - Valid kernels accepted

    @Test("symmetric graph with positive weights produces valid walk")
    func symmetricPositiveWeightsAccepted() {
        // 4-node symmetric chain: 0—1—2—3
        let adj: Adjacency = [
            [(neighbor: 1, weight: 1.0)],
            [(neighbor: 0, weight: 1.0), (neighbor: 2, weight: 1.0)],
            [(neighbor: 1, weight: 1.0), (neighbor: 3, weight: 1.0)],
            [(neighbor: 2, weight: 1.0)]
        ]
        let w = RandomWalks.walk(adjacency: adj, start: 0, length: 10,
                                 restartProb: 0.15, seed: 0xDEADBEEF)
        #expect(w.count == 10)
        #expect(w[0] == 0)
        for node in w { #expect(node >= 0 && node < 4) }
    }

    @Test("single-node graph (self-loop) produces walk of all start nodes")
    func singleNodeGraphAccepted() {
        // Node 0 with no out-edges — every step restarts to start.
        let adj: Adjacency = [[]]
        let w = RandomWalks.walk(adjacency: adj, start: 0, length: 5,
                                 restartProb: 0.0, seed: 42)
        #expect(w.count == 5)
        for node in w { #expect(node == 0) }
    }

    @Test("all-zero weights fall back to uniform sampling without crash")
    func allZeroWeightsAccepted() {
        // Two nodes connected by zero-weight edges; uniform fallback expected.
        let adj: Adjacency = [
            [(neighbor: 1, weight: 0.0)],
            [(neighbor: 0, weight: 0.0)]
        ]
        let w = RandomWalks.walk(adjacency: adj, start: 0, length: 10,
                                 restartProb: 0.0, seed: 7)
        #expect(w.count == 10)
        for node in w { #expect(node == 0 || node == 1) }
    }

    @Test("mixed zero and positive weights accepted")
    func mixedZeroPositiveWeightsAccepted() {
        let adj: Adjacency = [
            [(neighbor: 1, weight: 0.0), (neighbor: 2, weight: 2.0)],
            [(neighbor: 0, weight: 1.0)],
            [(neighbor: 0, weight: 1.0)]
        ]
        let w = RandomWalks.walk(adjacency: adj, start: 0, length: 8,
                                 restartProb: 0.0, seed: 99)
        #expect(w.count == 8)
        for node in w { #expect(node >= 0 && node < 3) }
    }

    @Test("walk is deterministic for the same seed")
    func deterministicSameSeed() {
        let adj: Adjacency = [
            [(neighbor: 1, weight: 1.0), (neighbor: 2, weight: 1.0)],
            [(neighbor: 0, weight: 1.0)],
            [(neighbor: 0, weight: 1.0)]
        ]
        let w1 = RandomWalks.walk(adjacency: adj, start: 0, length: 20,
                                  restartProb: 0.15, seed: 0xCAFEBABE)
        let w2 = RandomWalks.walk(adjacency: adj, start: 0, length: 20,
                                  restartProb: 0.15, seed: 0xCAFEBABE)
        #expect(w1 == w2)
    }

    @Test("sampleWeighted on non-empty list with positive weights returns valid index")
    func sampleWeightedNonEmptyPositiveAccepted() {
        var rng = SplitMix64(seed: 1234)
        let neighbors: [(neighbor: Int, weight: Double)] = [
            (neighbor: 0, weight: 1.0),
            (neighbor: 1, weight: 3.0),
            (neighbor: 2, weight: 0.5)
        ]
        let pick = RandomWalks.sampleWeighted(neighbors, rng: &rng)
        #expect(pick == 0 || pick == 1 || pick == 2)
    }

    // MARK: - Domain precondition coverage (code inspection)
    //
    // The following invalid inputs trigger precondition failures. They
    // cannot be exercised as runnable tests (precondition terminates
    // the process), but the precondition block at the entry of `walk()`
    // and at the entry of `sampleWeighted()` explicitly covers each case:
    //
    //   Invalid neighbor index:
    //     adjacency = [[(neighbor: 99, weight: 1.0)]]  (N=1, index 99 >= N)
    //     → "adjacency[0][0].neighbor 99 is out of range [0, 1)"
    //
    //   Negative weight:
    //     adjacency = [[(neighbor: 0, weight: -1.0)]]
    //     → "adjacency[0][0].weight is negative (-1.0)"
    //
    //   NaN weight:
    //     adjacency = [[(neighbor: 0, weight: Double.nan)]]
    //     → "adjacency[0][0].weight is not finite (nan)"
    //
    //   Inf weight:
    //     adjacency = [[(neighbor: 0, weight: Double.infinity)]]
    //     → "adjacency[0][0].weight is not finite (inf)"
    //
    //   Empty neighbor list to sampleWeighted:
    //     RandomWalks.sampleWeighted([], rng: &rng)
    //     → "sampleWeighted requires a non-empty neighbor list"
}
