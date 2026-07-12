import SubstrateML

// Spreading activation — free association from a seed (SPEC § 7.1). Surfaces
// SubstrateML's gated random-walk-with-restart: wander from the seed, and the
// fraction of steps spent on each other node IS its activation — how strongly
// the seed reaches it. The transitive companion to Keystones (global
// centrality) and Constellation (clusters). Deterministic for a fixed rngSeed
// (B-5). Owns no math (I-17).

/// One node's activation: the fraction of walk steps that landed on it, in
/// `[0, 1]`. Higher = more strongly associated with the seed.
public struct Activation: Sendable, Equatable, Codable {
    public let node: Int
    public let activation: Double
    public init(node: Int, activation: Double) {
        self.node = node
        self.activation = activation
    }
}

extension NeuronKit {
    /// Walk `walkLength` steps from `seed` over `adjacency` (`adjacency[i]` =
    /// node `i`'s weighted out-edges), teleporting home with probability
    /// `restartProb`, and return the top `k` nodes by visit frequency —
    /// descending, ties by ascending node index. The seed is excluded
    /// (association is what the seed reaches, not the seed). An out-of-range
    /// seed or a zero-length walk yields nothing (C-16).
    public static func spreadingActivation(adjacency: [[(node: Int, weight: Double)]],
                                           seed: Int, walkLength: Int, restartProb: Double,
                                           rngSeed: UInt64, k: Int) -> [Activation] {
        // restartProb is forwarded to RandomWalks.walk, whose precondition
        // aborts for anything outside [0, 1). Validate at this public boundary
        // rather than trap: the substrate is the trusted layer, the lens is the
        // untrusted-caller edge.
        guard adjacency.indices.contains(seed), walkLength > 0, k > 0,
              restartProb >= 0.0, restartProb < 1.0 else { return [] }

        // The gated walk consumes `(neighbor, weight)` tuples; the lens surface
        // names the field `node`. Relabel and drop structurally-invalid edges:
        // RandomWalks.walk preconditions every neighbor index into [0, n), so an
        // out-of-range node from a caller would abort the process. Filtering
        // (not rejecting the whole call) keeps every valid edge.
        let n = adjacency.count
        let walkGraph: SubstrateML.RandomWalks.Adjacency =
            adjacency.map { row in
                row.compactMap { edge in
                    (edge.node >= 0 && edge.node < n)
                        ? (neighbor: edge.node, weight: edge.weight)
                        : nil
                }
            }

        let visits = SubstrateML.RandomWalks.walk(
            adjacency: walkGraph, start: seed, length: walkLength,
            restartProb: restartProb, seed: rngSeed)

        // Visit frequency, normalised to a fraction of the walk.
        var visitCount = [Int: Int]()
        for node in visits where node != seed { visitCount[node, default: 0] += 1 }
        let steps = Double(walkLength)

        let ranked = visitCount
            .map { Activation(node: $0.key, activation: Double($0.value) / steps) }
            .sorted { lhs, rhs in
                lhs.activation == rhs.activation
                    ? lhs.node < rhs.node               // ties: ascending node index
                    : lhs.activation > rhs.activation   // primary: descending activation
            }
        return Array(ranked.prefix(k))
    }
}
