import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// Keystones — the conscious "spine of your thinking" recipe (Lens 1,
/// Structure). Reads a wing's drawer-to-drawer tunnel graph from the estate
/// and ranks the load-bearing memories by eigenvalue centrality, returning
/// the top-K.
///
/// Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): the recipe only SEQUENCES —
/// it reads the graph via GLK (`recallTunnels`) and ranks via NeuronKit
/// (`keystones`, which surfaces SubstrateML's eigenvalue centrality). It
/// implements no algorithm and reaches no substrate kit directly. No
/// capability gate: it composes a structural graph read, not one of the
/// declared `NeuronKitCapability` reasoning functions. Read-only — no
/// estate write (B-6, I-6).
public enum Keystones {

    /// Rank the load-bearing memories in `wing` by eigenvalue centrality over
    /// its drawer-to-drawer tunnel graph; return the top `topK` keystones
    /// (descending centrality, deterministic tie-break). A recall-tunnels
    /// failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        wing: String,
        topK: Int
    ) async throws -> [Keystone] {
        let tunnels = try await kit.recallTunnels(handle, wing: wing)

        // Edges: drawer-to-drawer tunnels only — room/wing-level tunnels are
        // not edges between individual memories.
        let edges: [(String, String)] = tunnels.compactMap { t in
            guard let a = t.sourceDrawerId, let b = t.targetDrawerId else { return nil }
            return (a, b)
        }

        // Nodes: the union of edge endpoints, sorted for a deterministic node
        // ordering. An isolated drawer has zero centrality and is never
        // load-bearing, so the edge set defines the graph.
        var nodeSet = Set<String>()
        for (a, b) in edges {
            nodeSet.insert(a)
            nodeSet.insert(b)
        }
        let nodes = nodeSet.sorted()

        return NeuronKit.keystones(nodeIDs: nodes, edges: edges, topK: topK)
    }
}
