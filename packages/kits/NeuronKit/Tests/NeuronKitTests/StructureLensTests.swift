import Foundation
import Testing
@testable import NeuronKit

// Structure lenses (SPEC § 7.1). Tests assert the behavioral claims the spec
// makes about each lens — not any implementation. Keystones ranks the
// load-bearing nodes of the drawer/tunnel graph; Constellation recovers its
// emergent clusters; Spreading activation ranks what a seed reaches. All three
// are pure, deterministic, and total over edge inputs (B-5, B-8, C-16).

@Suite("Structure lenses (SPEC § 7.1)")
struct StructureLensTests {

    // MARK: Keystones — "the spine of your thinking"

    // The spec's defining claim: a node the rest of the graph hangs off ranks
    // highest. A star's hub is exactly that — every other node attaches only
    // through it.
    @Test("Keystones: the hub of a star is the top keystone")
    func keystonesHubDominates() {
        let nodes = ["hub", "s1", "s2", "s3", "s4"]
        let edges = [("hub", "s1"), ("hub", "s2"), ("hub", "s3"), ("hub", "s4")]
        // estate/ts: explicit sentinels — tests have no estate context.
        let ranked = NeuronKit.keystones(nodeIDs: nodes, edges: edges, topK: 5,
                                         estate: "", now: Date(timeIntervalSince1970: 0))
        #expect(ranked.first?.id == "hub")
        #expect(ranked[0].centrality > ranked[1].centrality)
    }

    // A node that joins two otherwise-separate clusters carries more of the
    // graph than any node inside one cluster — more than one-hop degree alone
    // would suggest. (Two triangles sharing a single bridge node.)
    @Test("Keystones: a bridge between clusters ranks above cluster-interior nodes")
    func keystonesBridgeRanksHighest() {
        let nodes = ["a", "b", "bridge", "c", "d"]
        let edges = [
            ("a", "b"), ("a", "bridge"), ("b", "bridge"),
            ("bridge", "c"), ("bridge", "d"), ("c", "d"),
        ]
        // estate/ts: explicit sentinels — tests have no estate context.
        let ranked = NeuronKit.keystones(nodeIDs: nodes, edges: edges, topK: 5,
                                         estate: "", now: Date(timeIntervalSince1970: 0))
        #expect(ranked.first?.id == "bridge")
    }

    // Result is ranked descending and capped to topK.
    @Test("Keystones: result is descending and capped to topK")
    func keystonesRankedAndCapped() {
        let nodes = ["hub", "s1", "s2", "s3"]
        let edges = [("hub", "s1"), ("hub", "s2"), ("hub", "s3"), ("s1", "s2")]
        // estate/ts: explicit sentinels — tests have no estate context.
        let ranked = NeuronKit.keystones(nodeIDs: nodes, edges: edges, topK: 2,
                                         estate: "", now: Date(timeIntervalSince1970: 0))
        #expect(ranked.count == 2)
        #expect(ranked.first?.id == "hub")
        #expect(ranked[0].centrality >= ranked[1].centrality)
    }

    // Spec: self-loops and edges with an endpoint absent from nodeIDs are
    // ignored — they describe the same graph as without them.
    @Test("Keystones: self-loops and absent-endpoint edges are ignored")
    func keystonesIgnoresNoiseEdges() {
        let nodes = ["hub", "s1", "s2", "s3", "s4"]
        let clean = [("hub", "s1"), ("hub", "s2"), ("hub", "s3"), ("hub", "s4")]
        let noisy = clean + [("hub", "hub"), ("hub", "ghost"), ("ghost", "s1")]
        // estate/ts: explicit sentinels — tests have no estate context.
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(NeuronKit.keystones(nodeIDs: nodes, edges: clean, topK: 5, estate: "", now: t0)
                == NeuronKit.keystones(nodeIDs: nodes, edges: noisy, topK: 5, estate: "", now: t0))
    }

    // Edge totality (C-16): no nodes ⇒ empty; nodes-no-edges still bounded by topK.
    @Test("Keystones: total over edge inputs")
    func keystonesEdgeTotality() {
        // estate/ts: explicit sentinels — tests have no estate context.
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(NeuronKit.keystones(nodeIDs: [], edges: [], topK: 5, estate: "", now: t0).isEmpty)
        #expect(NeuronKit.keystones(nodeIDs: ["x", "y", "z"], edges: [], topK: 2,
                                    estate: "", now: t0).count == 2)
        #expect(NeuronKit.keystones(nodeIDs: ["x", "y"], edges: [("x", "y")], topK: 0,
                                    estate: "", now: t0).isEmpty)
    }

    // MARK: Constellation — emergent clusters

    // Spec's defining claim: clusters are recovered from raw connectivity with
    // no labels supplied. Two disjoint triangles are two communities, and each
    // recovered community is exactly one triangle.
    @Test("Constellation: disjoint cliques are recovered as separate communities")
    func constellationRecoversCliques() {
        let nodes = ["A1", "A2", "A3", "B1", "B2", "B3"]
        let edges = [
            ("A1", "A2"), ("A1", "A3"), ("A2", "A3"),
            ("B1", "B2"), ("B1", "B3"), ("B2", "B3"),
        ]
        // estate/ts: explicit sentinels — tests have no estate context.
        let c = NeuronKit.constellations(nodeIDs: nodes, edges: edges, maxPasses: 10,
                                         estate: "", now: Date(timeIntervalSince1970: 0))
        #expect(c.communities.count == 2)
        #expect(c.communities.contains(["A1", "A2", "A3"]))
        #expect(c.communities.contains(["B1", "B2", "B3"]))
    }

    // C-Det: the result must be deterministic regardless of input id order —
    // each community ascending, communities ordered by smallest member.
    @Test("Constellation: deterministic ordering independent of input order")
    func constellationDeterministicOrdering() {
        let edges = [
            ("A1", "A2"), ("A1", "A3"), ("A2", "A3"),
            ("B1", "B2"), ("B1", "B3"), ("B2", "B3"),
        ]
        // estate/ts: explicit sentinels — tests have no estate context.
        let t0 = Date(timeIntervalSince1970: 0)
        let forward = NeuronKit.constellations(
            nodeIDs: ["A1", "A2", "A3", "B1", "B2", "B3"], edges: edges, maxPasses: 10,
            estate: "", now: t0)
        let shuffled = NeuronKit.constellations(
            nodeIDs: ["B3", "A2", "B1", "A3", "A1", "B2"], edges: edges, maxPasses: 10,
            estate: "", now: t0)
        #expect(forward == shuffled, "result independent of input id order")
        for grp in forward.communities { #expect(grp == grp.sorted()) }
        let firsts = forward.communities.map { $0[0] }
        #expect(firsts == firsts.sorted())
    }

    // Edge totality (C-16).
    @Test("Constellation: total over edge inputs")
    func constellationEdgeTotality() {
        // estate/ts: explicit sentinels — tests have no estate context.
        #expect(NeuronKit.constellations(nodeIDs: [], edges: [], maxPasses: 10,
                                         estate: "", now: Date(timeIntervalSince1970: 0)).communities.isEmpty)
    }

    // MARK: Spreading activation — free association from a seed

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
