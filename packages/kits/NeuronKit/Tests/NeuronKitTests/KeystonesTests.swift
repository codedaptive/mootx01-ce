import Testing
@testable import NeuronKit

// Keystones lens (SPEC § 7.1). Tests assert the behavioral claims the
// spec makes — not any implementation. The internal StructureGraph
// shaping (self-loop / absent-endpoint filtering) is asserted here
// through the noise-edge test. Keystones ranks the load-bearing
// nodes of the drawer/tunnel graph. Pure, deterministic, and total over
// edge inputs (B-5, B-8, C-16). Peer to Lenses/Keystones.swift.

@Suite("Keystones lens (SPEC § 7.1)")
struct KeystonesTests {

    // The spec's defining claim: a node the rest of the graph hangs off ranks
    // highest. A star's hub is exactly that — every other node attaches only
    // through it.
    @Test("Keystones: the hub of a star is the top keystone")
    func keystonesHubDominates() {
        let nodes = ["hub", "s1", "s2", "s3", "s4"]
        let edges = [("hub", "s1"), ("hub", "s2"), ("hub", "s3"), ("hub", "s4")]
        let ranked = NeuronKit.keystones(nodeIDs: nodes, edges: edges, topK: 5)
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
        let ranked = NeuronKit.keystones(nodeIDs: nodes, edges: edges, topK: 5)
        #expect(ranked.first?.id == "bridge")
    }

    // Result is ranked descending and capped to topK.
    @Test("Keystones: result is descending and capped to topK")
    func keystonesRankedAndCapped() {
        let nodes = ["hub", "s1", "s2", "s3"]
        let edges = [("hub", "s1"), ("hub", "s2"), ("hub", "s3"), ("s1", "s2")]
        let ranked = NeuronKit.keystones(nodeIDs: nodes, edges: edges, topK: 2)
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
        #expect(NeuronKit.keystones(nodeIDs: nodes, edges: clean, topK: 5)
                == NeuronKit.keystones(nodeIDs: nodes, edges: noisy, topK: 5))
    }

    // Edge totality (C-16): no nodes ⇒ empty; nodes-no-edges still bounded by topK.
    @Test("Keystones: total over edge inputs")
    func keystonesEdgeTotality() {
        #expect(NeuronKit.keystones(nodeIDs: [], edges: [], topK: 5).isEmpty)
        #expect(NeuronKit.keystones(nodeIDs: ["x", "y", "z"], edges: [], topK: 2).count == 2)
        #expect(NeuronKit.keystones(nodeIDs: ["x", "y"], edges: [("x", "y")], topK: 0).isEmpty)
    }
}
