import SubstrateML

// Keystones — load-bearing memory (SPEC § 7.1). Surfaces SubstrateML's gated
// EigenvalueCentrality over the structure graph and ranks the nodes the rest
// of the graph hangs off. "The spine of your thinking." Owns no math (I-17).

/// One ranked memory: its drawer id and eigenvalue-centrality score.
public struct Keystone: Sendable, Equatable, Codable {
    public let id: String
    public let centrality: Double
    public init(id: String, centrality: Double) {
        self.id = id
        self.centrality = centrality
    }
}

extension NeuronKit {
    /// Rank `nodeIDs` by eigenvalue centrality over the undirected graph formed
    /// by `edges`, returning the top `topK` keystones — descending by
    /// centrality, ties by ascending id. Self-loops and edges with an absent
    /// endpoint are ignored. Empty `nodeIDs` or `topK <= 0` ⇒ empty (C-16).
    public static func keystones(nodeIDs: [String], edges: [(String, String)],
                                 topK: Int) -> [Keystone] {
        guard !nodeIDs.isEmpty, topK > 0 else { return [] }

        let adjacency = StructureGraph.build(nodeIDs: nodeIDs, edges: edges)
        let centralities = SubstrateML.EigenvalueCentrality.compute(adjacency: adjacency)

        let ranked = zip(nodeIDs, centralities)
            .map { Keystone(id: $0, centrality: $1) }
            .sorted { lhs, rhs in
                lhs.centrality == rhs.centrality
                    ? lhs.id < rhs.id            // ties: ascending id
                    : lhs.centrality > rhs.centrality   // primary: descending centrality
            }
        return Array(ranked.prefix(topK))
    }
}
