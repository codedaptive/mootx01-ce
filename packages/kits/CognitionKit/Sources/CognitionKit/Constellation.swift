import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// Constellation — the conscious "clusters I never named" recipe (Lens 2,
/// Structure). Reads a wing's drawer-to-drawer tunnel graph from the estate
/// and recovers its emergent communities.
///
/// The recipe entry point is `ConstellationLens` (the reasoning result type
/// `Constellation` is NeuronKit's, surfaced unchanged; the recipe namespace
/// is named to avoid shadowing it).
///
/// Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): the recipe only SEQUENCES —
/// it reads the graph via GLK (`recallTunnels`) and groups via NeuronKit
/// (`constellations`, which surfaces SubstrateML's community detection). It
/// implements no algorithm and reaches no substrate kit directly. No
/// capability gate: it composes a structural graph read, not a declared
/// `NeuronKitCapability` reasoning function. Read-only — no estate write
/// (B-6, I-6).
public enum ConstellationLens {

    /// The community-detection pass budget. Matches the Rust version's
    /// `DEFAULT_MAX_PASSES`, so both versions converge on the same partition
    /// for a shared graph (C-Det).
    private static let maxPasses = 10

    /// Recover the emergent communities in `wing` over its drawer-to-drawer
    /// tunnel graph. Each community is an ascending-sorted group of drawer
    /// ids; groups are ordered by their smallest member (id-derived, so the
    /// result is independent of the primitive's label numbering). A
    /// recall-tunnels failure propagates.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        wing: String
    ) async throws -> Constellation {
        let tunnels = try await kit.recallTunnels(handle, wing: wing)

        // Edges: drawer-to-drawer tunnels only — room/wing-level tunnels are
        // not edges between individual memories.
        let edges: [(String, String)] = tunnels.compactMap { t in
            guard let a = t.sourceDrawerId, let b = t.targetDrawerId else { return nil }
            return (a, b)
        }

        // Nodes: the union of edge endpoints, sorted for a deterministic node
        // ordering.
        var nodeSet = Set<String>()
        for (a, b) in edges {
            nodeSet.insert(a)
            nodeSet.insert(b)
        }
        let nodes = nodeSet.sorted()

        return NeuronKit.constellations(nodeIDs: nodes, edges: edges, maxPasses: maxPasses)
    }
}
