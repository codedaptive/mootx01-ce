import SubstrateML

// Constellation — emergent communities (SPEC § 7.1). Surfaces SubstrateML's
// gated Louvain CommunityDetection over the same structure graph Keystones
// reads, then groups drawer-ids by the community label the primitive assigns.
// Finds the CLUSTERS the user never named. Owns no math (I-17).

/// The emergent communities of a graph.
public struct Constellation: Sendable, Equatable, Codable {
    /// Each community is an ascending-sorted group of drawer ids; the groups are
    /// ordered by their smallest member. Both orderings are derived purely from
    /// the ids, so the result is independent of how the primitive happened to
    /// number its labels — the determinism C-Det requires.
    public let communities: [[String]]
    public init(communities: [[String]]) {
        self.communities = communities
    }
}

extension NeuronKit {
    /// Detect communities over the undirected graph formed by `edges`, grouping
    /// `nodeIDs` by community. Self-loops and absent-endpoint edges are ignored.
    /// Empty `nodeIDs` ⇒ no communities (C-16).
    public static func constellations(nodeIDs: [String], edges: [(String, String)],
                                      maxPasses: Int) -> Constellation {
        guard !nodeIDs.isEmpty else { return Constellation(communities: []) }

        let adjacency = StructureGraph.build(nodeIDs: nodeIDs, edges: edges)
        // Full Louvain at the shared lens resolution (see
        // NeuronKit.topologyResolution for the derivation): §7.3's
        // auto-rooming consumer is this lens, and phase-1-only results
        // fragment pair-bonded clusters.
        let labels = SubstrateML.CommunityDetection.detectFull(
            adjacency: adjacency, maxLevels: topologyMaxLevels,
            maxPasses: maxPasses, resolution: topologyResolution)

        // Group ids by their assigned label, then impose an id-derived canonical
        // ordering so the result does not depend on the label integers.
        var byLabel = [Int: [String]]()
        for (i, label) in labels.enumerated() {
            byLabel[label, default: []].append(nodeIDs[i])
        }
        let communities = byLabel.values
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
        return Constellation(communities: communities)
    }
}
