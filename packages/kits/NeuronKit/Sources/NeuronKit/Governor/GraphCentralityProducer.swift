import Foundation
import GeniusLocusKit
import LocusKit

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// Eigenvalue centrality is a conformance-gated SubstrateML primitive,
// surfaced through NeuronKit's `keystones` lens. This producer is a
// CADENCE WRAPPER over that oracle: it shapes the estate's structure
// graph into (nodeIDs, edges), calls `NeuronKit.keystones`, and caches
// the per-drawer scores. It owns no math.
// ─────────────────────────────────────────────────────────────────

/// Pre-built per-drawer graph-centrality cache for one estate.
///
/// Holds the eigenvalue-centrality score for every live drawer, computed
/// by `NeuronKit.AutonomicGovernor.graphCentralityScan` on a cadence. Implements
/// the GLK `GraphCache` consumption protocol: the `matrixAware` / `unionBest`
/// recall path reads `graphScore(for:)` per candidate drawer to populate
/// the `graph` score column. Drawers absent from the snapshot score 0.0,
/// which is correct (a drawer with no structural edges has no centrality).
///
/// Immutable after construction — the producer builds a fresh cache each
/// cadence and re-registers it, so a registered cache never mutates under
/// a concurrent recall read. `Sendable` via the immutable dictionary.
public final class GraphCentralityCache: GraphCache, Sendable {

    /// drawerID → eigenvalue centrality. Built once at construction.
    private let scores: [String: Float]

    /// Wrap a per-drawer centrality snapshot.
    public init(scores: [String: Float]) {
        self.scores = scores
    }

    /// The centrality score for `drawerID`, or 0.0 when the drawer is not
    /// in the snapshot. A pure dictionary lookup — no estate traversal,
    /// honouring the candidate-frontier-lookup-only contract (spec §15).
    public func graphScore(for drawerID: String) -> Float {
        scores[drawerID] ?? 0.0
    }

    /// Number of drawers in the snapshot. Diagnostic accessor surfaced in
    /// the producer's tick log.
    public var count: Int { scores.count }
}

/// Builds the estate's structure-graph adjacency in the exact shape the
/// `NeuronKit.keystones` oracle consumes, from the same substrate reads the
/// topology lens uses (drawers + tunnels + kg_facts). The Rust producer
/// (`graph_centrality_adjacency` in neuron-kit/autonomic_governor.rs) builds the
/// IDENTICAL (nodeIDs, edges) so both ports feed keystones the same graph
/// and obtain bit-identical centralities.
public enum GraphCentralityAdjacency {

    /// Maximum number of drawers per KGFact subject group included in the
    /// centrality graph edge set. Planned hardening: prevents O(n²) edge
    /// explosion on generic subjects shared by many drawers. Drawers beyond
    /// the cap are excluded from this subject's bonds but still appear as
    /// isolated or tunnel-bonded nodes (score 0.0 per spec C-16). Parity:
    /// matches `KGFACT_CLIQUE_CAP` in topology_analysis.rs and
    /// `NeuronKit.kgFactCliqueCap` in TopologyAnalysis.swift.
    public static let kgFactGroupCap = 50

    /// The (nodeIDs, edges) pair for `keystones`.
    public struct Graph: Sendable {
        /// Live drawer IDs, sorted ascending (stable index space — keystones
        /// returns centralities[i] for nodeIDs[i]).
        public let nodeIDs: [String]
        /// Undirected, unit-weight drawer-id edge pairs. keystones drops
        /// self-loops and absent-endpoint edges; we pre-filter to live nodes
        /// so the diagnostic counts are honest and the cross-port edge
        /// multiset is identical.
        public let edges: [(String, String)]
    }

    /// Build the canonical estate centrality graph.
    ///
    /// Node set: all non-tombstoned drawers, sorted ascending by id.
    ///
    /// Edges (unit weight, the keystones model — NOT the topology lens's
    /// weighted 1.0/0.3/0.2 split; this producer feeds the unit-weight
    /// `keystones` oracle the mission specifies):
    ///   1. Tunnel edges — each non-tombstoned tunnel with both endpoints
    ///      present and both in the live node set contributes one pair.
    ///   2. KGFact edges — drawers sharing a KGFact `subject` are bonded.
    ///      Facts are grouped by subject; within each subject group the
    ///      distinct live source-drawer IDs are sorted ascending and all
    ///      unordered pairs (i<j) are emitted. This mirrors the topology
    ///      lens's shared-subject bond, at unit weight.
    ///
    /// Determinism: tunnels are iterated in input order (already a stable
    /// `filedAt`-ordered estate read), subject groups and their members are
    /// sorted, so the same estate state always yields the same edge
    /// sequence — required for cross-port byte-identity of the diagnostic
    /// and for the keystones input to match Swift↔Rust.
    public static func build(
        drawers: [Drawer],
        tunnels: [Tunnel],
        facts: [KGFact]
    ) -> Graph {
        // Live node set + membership lookup.
        let liveIDs = drawers.compactMap { $0.tombstonedAt == nil ? $0.id : nil }
        let live = Set(liveIDs)
        let nodeIDs = liveIDs.sorted()

        var edges: [(String, String)] = []

        // 1. Tunnel edges — explicit drawer-to-drawer structural links.
        for tunnel in tunnels {
            guard tunnel.tombstonedAt == nil,
                  let a = tunnel.sourceDrawerId,
                  let b = tunnel.targetDrawerId,
                  a != b,
                  live.contains(a), live.contains(b)
            else { continue }
            edges.append((a, b))
        }

        // 2. KGFact edges — drawers sharing a subject. Group, sort, pair.
        //
        // Planned hardening: cap each subject group at kgFactGroupCap drawers
        // to prevent O(n²) edge explosion on generic subjects shared by many
        // drawers. Drawers beyond the cap are excluded from the centrality
        // graph for that subject — they still appear as isolated or
        // tunnel-bonded nodes and receive graph score 0.0 (C-16). Cap
        // value matches NeuronKit.kgFactCliqueCap in TopologyAnalysis.swift
        // for consistency across the two functions that build KGFact edges.
        var bySubject: [String: Set<String>] = [:]
        for fact in facts where live.contains(fact.sourceDrawerID) {
            bySubject[fact.subject, default: []].insert(fact.sourceDrawerID)
        }
        // Subjects sorted for a deterministic edge sequence.
        for subject in bySubject.keys.sorted() {
            let allMembers = bySubject[subject]!.sorted()
            guard allMembers.count >= 2 else { continue }
            // Cap group size: a generic subject bonding hundreds of drawers
            // would generate O(n²) pairs; kgFactGroupCap keeps it bounded.
            let members = allMembers.count > GraphCentralityAdjacency.kgFactGroupCap
                ? Array(allMembers.prefix(GraphCentralityAdjacency.kgFactGroupCap))
                : allMembers
            for i in 0..<members.count {
                for j in (i + 1)..<members.count {
                    edges.append((members[i], members[j]))
                }
            }
        }

        return Graph(nodeIDs: nodeIDs, edges: edges)
    }
}
