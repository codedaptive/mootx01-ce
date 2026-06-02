import SubstrateML

// Shared graph construction for the structure lenses (SPEC § 7.1). Keystones
// and Constellation both read "the undirected graph formed by drawer-id edge
// pairs (weight 1; self-loops and absent-endpoint edges ignored)" — that one
// transformation lives here so both surface the same graph to their gated
// primitive. The lens owns no math (I-17); this is pure shaping.

enum StructureGraph {
    /// The adjacency shape every SubstrateML structure primitive consumes:
    /// `adjacency[i]` = the weighted out-edges of node `i`.
    typealias Adjacency = [[(neighbor: Int, weight: Double)]]

    /// Build the undirected, unit-weight adjacency over `nodeIDs` from drawer-id
    /// `edges`. Node `i` is the node at `nodeIDs[i]` (input order fixes the
    /// index space deterministically, so the result is version-stable). A self-loop
    /// (both endpoints the same node) and an edge with an endpoint not in
    /// `nodeIDs` contribute nothing. Each surviving pair adds a symmetric edge.
    static func build(nodeIDs: [String], edges: [(String, String)]) -> Adjacency {
        var indexOf = [String: Int](minimumCapacity: nodeIDs.count)
        for (i, id) in nodeIDs.enumerated() { indexOf[id] = i }

        var adjacency: Adjacency = Array(repeating: [], count: nodeIDs.count)
        for (endpointA, endpointB) in edges {
            guard let i = indexOf[endpointA],
                  let j = indexOf[endpointB],
                  i != j                                  // self-loops ignored
            else { continue }                             // absent endpoints ignored
            adjacency[i].append((neighbor: j, weight: 1.0))
            adjacency[j].append((neighbor: i, weight: 1.0))   // undirected
        }
        return adjacency
    }
}
