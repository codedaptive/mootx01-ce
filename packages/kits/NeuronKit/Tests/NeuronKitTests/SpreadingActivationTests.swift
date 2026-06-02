import Testing
@testable import NeuronKit

// Spreading-activation lens (SPEC § 7.1). Tests assert the behavioral
// claims the spec makes — not any implementation. Spreading activation
// ranks what a seed reaches. Pure, deterministic, and total over edge
// inputs (B-5, B-8, C-16). Peer to Lenses/SpreadingActivation.swift.

@Suite("Spreading-activation lens (SPEC § 7.1)")
struct SpreadingActivationTests {

    private static let restart = 0.15
    private static let walkLength = 20_000      // long & deterministic ⇒ stable, not flaky
    private static let rngSeed: UInt64 = 0xABCDEF

    // Spec's defining claims, all in one fixture: the seed is excluded; a node
    // the seed reaches directly activates more than one reached only
    // transitively; a node in a disconnected component never activates.
    @Test("Spreading activation: ranks reachability, excludes seed and unreachable nodes")
    func spreadingActivationRanksReachability() {
        // Seed component: 0—1—2 (2 is two hops from 0). Separate: 3—4.
        let adj: [[(node: Int, weight: Double)]] = [
            [(1, 1.0)],
            [(0, 1.0), (2, 1.0)],
            [(1, 1.0)],
            [(4, 1.0)],
            [(3, 1.0)],
        ]
        let act = NeuronKit.spreadingActivation(
            adjacency: adj, seed: 0, walkLength: Self.walkLength,
            restartProb: Self.restart, rngSeed: Self.rngSeed, k: 10)
        #expect(act.allSatisfy { $0.node != 0 }, "seed excluded")
        let a1 = act.first { $0.node == 1 }?.activation ?? 0
        let a2 = act.first { $0.node == 2 }?.activation ?? 0
        #expect(a1 > a2, "direct neighbor outranks two-hop node")
        #expect(act.allSatisfy { $0.node != 3 && $0.node != 4 }, "disconnected component never activates")
        #expect(act.allSatisfy { $0.activation >= 0 && $0.activation <= 1 }, "activation is a fraction")
    }

    // Result is descending and capped to k.
    @Test("Spreading activation: result is descending and capped to k")
    func spreadingActivationRankedAndCapped() {
        let adj: [[(node: Int, weight: Double)]] = [
            [(1, 1.0), (2, 1.0), (3, 1.0)],
            [(0, 1.0)], [(0, 1.0)], [(0, 1.0)],
        ]
        let act = NeuronKit.spreadingActivation(
            adjacency: adj, seed: 0, walkLength: Self.walkLength,
            restartProb: Self.restart, rngSeed: Self.rngSeed, k: 2)
        #expect(act.count == 2)
        #expect(act[0].activation >= act[1].activation)
    }

    // B-5: deterministic for a fixed rngSeed.
    @Test("Spreading activation: deterministic for a fixed seed")
    func spreadingActivationDeterministic() {
        let adj: [[(node: Int, weight: Double)]] = [
            [(1, 1.0), (2, 1.0)], [(0, 1.0), (2, 1.0)], [(0, 1.0), (1, 1.0)],
        ]
        let a = NeuronKit.spreadingActivation(
            adjacency: adj, seed: 0, walkLength: 5_000,
            restartProb: Self.restart, rngSeed: 42, k: 10)
        let b = NeuronKit.spreadingActivation(
            adjacency: adj, seed: 0, walkLength: 5_000,
            restartProb: Self.restart, rngSeed: 42, k: 10)
        #expect(a == b)
    }

    // Edge totality (C-16): out-of-range seed and zero-length walk yield nothing.
    @Test("Spreading activation: total over edge inputs")
    func spreadingActivationEdgeTotality() {
        let adj: [[(node: Int, weight: Double)]] = [[(1, 1.0)], [(0, 1.0)]]
        #expect(NeuronKit.spreadingActivation(
            adjacency: adj, seed: 5, walkLength: Self.walkLength,
            restartProb: Self.restart, rngSeed: Self.rngSeed, k: 10).isEmpty)
        #expect(NeuronKit.spreadingActivation(
            adjacency: adj, seed: 0, walkLength: 0,
            restartProb: Self.restart, rngSeed: Self.rngSeed, k: 10).isEmpty)
    }
}
