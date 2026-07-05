import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// Constellation — the conscious "clusters I never named" recipe (Lens 2,
/// Structure). Reads a wing's drawer-to-drawer tunnel graph and recovers
/// its emergent communities by surfacing NeuronKit's Louvain community
/// detection.
///
/// The recipe entry point is `ConstellationLens` (the result type
/// `Constellation` is the bare NeuronKit type; the recipe namespace is
/// suffixed to avoid shadowing it, per the lens naming convention).
///
/// Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): the recipe only SEQUENCES.
/// It reads the graph via GLK (`recallTunnels`) and clusters via NeuronKit
/// (`constellations`, which surfaces SubstrateML's community detection). It
/// implements no algorithm and reaches no substrate kit directly. No
/// capability gate: a structural graph read, not a declared
/// `NeuronKitCapability` reasoning function. Read-only — no estate write
/// (B-6, I-6).
public enum ConstellationLens {

    /// The community-detection pass budget. Matches the Rust version's
    /// `DEFAULT_MAX_PASSES` (and SubstrateML's own default), so both
    /// versions converge on the same partition for a shared graph (C-Det).
    private static let maxPasses = 10

    /// Recover the emergent communities of `wing`'s drawer-to-drawer tunnel
    /// graph. A wing with no tunnels yields no communities. A recall-tunnels
    /// failure propagates.
    ///
    /// - Parameters:
    ///   - now: Caller-supplied timestamp for VizGraph telemetry. Threaded
    ///          down to SubstrateML so analytics rows carry the correct ts.
    ///          Never call Date() inside a kit — the caller provides `now`.
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        wing: String,
        now: Date
    ) async throws -> Constellation {
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
        let nodeIDs = nodeSet.sorted()

        // Thread estate and now so VizGraph analytics carry the correct estate
        // tag and timestamp instead of the empty defaults.
        return NeuronKit.constellations(nodeIDs: nodeIDs, edges: edges, maxPasses: maxPasses,
                                        estate: handle.estateUUID.uuidString, now: now)
    }
}
