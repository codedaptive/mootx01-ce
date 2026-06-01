import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import SubstrateTypes

/// One associated memory: the drawer the walk reached and its activation
/// (the fraction of walk steps that landed there). Strongest first. The
/// recipe-layer result type — NeuronKit surfaces the raw `Activation` over
/// integer node indices, which the recipe relabels back to drawer ids.
public struct Association: Sendable, Equatable, Codable {
    public let drawerID: String
    public let activation: Double
    public init(drawerID: String, activation: Double) {
        self.drawerID = drawerID
        self.activation = activation
    }
}

/// Free association — the conscious "what this reminds me of" recipe (Lens 3,
/// Structure). Spreads activation from a seed drawer over a wing's
/// drawer-to-drawer tunnel graph and returns the top-k most-activated
/// memories.
///
/// The recipe entry point is `FreeAssociationLens` (the result type
/// `Association` is bare; the recipe namespace is suffixed to avoid
/// shadowing it, per the lens naming convention).
///
/// Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): the recipe only SEQUENCES.
/// It reads the graph via GLK (`recallTunnels`) and walks via NeuronKit
/// (`spreadingActivation`, which surfaces SubstrateML's restart random
/// walk). It implements no algorithm and reaches no substrate kit directly.
/// No capability gate: a structural graph read, not a declared
/// `NeuronKitCapability` reasoning function. Read-only — no estate write
/// (B-6, I-6).
public enum FreeAssociationLens {

    /// Teleport-home probability for the restart walk. Matches the Rust
    /// version's `RESTART_PROB` (SubstrateML's cookbook § 7.4 default), so
    /// both versions converge on the same activation profile for a shared
    /// graph (C-Det).
    private static let restartProb = 0.15

    /// Free-associate from `seedDrawerID` over `wing`'s tunnel graph: walk
    /// `walkLength` steps with restart and return the top `k` most-activated
    /// drawers (strongest first). A seed absent from the graph yields no
    /// associations. A recall-tunnels failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        wing: String,
        seedDrawerID: String,
        walkLength: Int,
        k: Int
    ) async throws -> [Association] {
        let tunnels = try await kit.recallTunnels(handle, wing: wing)

        // Edges: drawer-to-drawer tunnels only (an absent endpoint is dropped).
        let edges: [(String, String)] = tunnels.compactMap { t in
            guard let a = t.sourceDrawerId, let b = t.targetDrawerId else { return nil }
            return (a, b)
        }

        // Node set ⇒ deterministic, sorted (stable index assignment; same
        // discipline across the structure lenses).
        var nodeSet = Set<String>()
        for (a, b) in edges {
            nodeSet.insert(a)
            nodeSet.insert(b)
        }
        let nodes = nodeSet.sorted()

        // Seed not in the graph ⇒ no associations.
        guard let seedIdx = nodes.firstIndex(of: seedDrawerID) else {
            return []
        }

        // Directed weighted adjacency; each tunnel is one unit-weight out-edge.
        var index = [String: Int]()
        for (i, n) in nodes.enumerated() { index[n] = i }
        var adjacency: [[(node: Int, weight: Double)]] =
            Array(repeating: [], count: nodes.count)
        for (a, b) in edges {
            adjacency[index[a]!].append((node: index[b]!, weight: 1.0))
        }

        // Deterministic walk seed from the seed drawer id (no clock).
        let rngSeed = FNV.hash64(seedDrawerID)
        let activated = NeuronKit.spreadingActivation(
            adjacency: adjacency, seed: seedIdx, walkLength: walkLength,
            restartProb: restartProb, rngSeed: rngSeed, k: k)

        return activated.map {
            Association(drawerID: nodes[$0.node], activation: $0.activation)
        }
    }
}
