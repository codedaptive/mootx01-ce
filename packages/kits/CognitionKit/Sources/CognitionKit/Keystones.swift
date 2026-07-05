import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// Keystones — the conscious "spine of your thinking" recipe (Lens 1,
/// Structure). Reads a wing's drawer-to-drawer tunnel graph and ranks the
/// load-bearing memories by surfacing NeuronKit's eigenvalue-centrality
/// keystones.
///
/// The recipe entry point is `Keystones`; the result type is the bare
/// `NeuronKit.Keystone` (no shadow — recipe is plural, type is singular).
///
/// Layer discipline (SPEC § 5, B-1/B-2, I-1/I-2): the recipe only SEQUENCES.
/// It reads the graph via GLK (`recallTunnels`) and ranks via NeuronKit
/// (`keystones`, which surfaces SubstrateML's eigenvalue centrality). It
/// implements no algorithm and reaches no substrate kit directly. No
/// capability gate: a structural graph read, not a declared
/// `NeuronKitCapability` reasoning function. Read-only — no estate write
/// (B-6, I-6).
public enum Keystones {

    /// Rank the top `topK` load-bearing memories of `wing` by centrality
    /// over its drawer-to-drawer tunnel graph (descending, ties by ascending
    /// id). A wing with no tunnels yields an empty result. A recall-tunnels
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
        topK: Int,
        now: Date
    ) async throws -> [Keystone] {
        let tunnels = try await kit.recallTunnels(handle, wing: wing)

        // Edges: drawer-to-drawer tunnels only (an absent endpoint is dropped).
        let edges: [(String, String)] = tunnels.compactMap { t in
            guard let a = t.sourceDrawerId, let b = t.targetDrawerId else { return nil }
            return (a, b)
        }

        // Node set ⇒ deterministic, sorted (stable index assignment for the
        // centrality surface; same discipline across the structure lenses).
        var nodeSet = Set<String>()
        for (a, b) in edges {
            nodeSet.insert(a)
            nodeSet.insert(b)
        }
        let nodeIDs = nodeSet.sorted()

        // Thread estate and now so VizGraph analytics carry the correct estate
        // tag and timestamp instead of the empty defaults.
        return NeuronKit.keystones(nodeIDs: nodeIDs, edges: edges, topK: topK,
                                   estate: handle.estateUUID.uuidString, now: now)
    }
}
