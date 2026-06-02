import Testing
@testable import NeuronKit

// Constellation lens (SPEC § 7.1). Tests assert the behavioral claims
// the spec makes — not any implementation. Constellation recovers the
// drawer/tunnel graph's emergent clusters. Pure, deterministic, and
// total over edge inputs (B-5, B-8, C-16). Peer to
// Lenses/Constellation.swift.

@Suite("Constellation lens (SPEC § 7.1)")
struct ConstellationTests {

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
        let c = NeuronKit.constellations(nodeIDs: nodes, edges: edges, maxPasses: 10)
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
        let forward = NeuronKit.constellations(
            nodeIDs: ["A1", "A2", "A3", "B1", "B2", "B3"], edges: edges, maxPasses: 10)
        let shuffled = NeuronKit.constellations(
            nodeIDs: ["B3", "A2", "B1", "A3", "A1", "B2"], edges: edges, maxPasses: 10)
        #expect(forward == shuffled, "result independent of input id order")
        for grp in forward.communities { #expect(grp == grp.sorted()) }
        let firsts = forward.communities.map { $0[0] }
        #expect(firsts == firsts.sorted())
    }

    // Edge totality (C-16).
    @Test("Constellation: total over edge inputs")
    func constellationEdgeTotality() {
        #expect(NeuronKit.constellations(nodeIDs: [], edges: [], maxPasses: 10).communities.isEmpty)
    }
}
