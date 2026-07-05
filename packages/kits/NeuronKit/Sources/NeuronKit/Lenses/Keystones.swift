import Foundation
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
    ///
    /// - Parameters:
    ///   - estate: Estate UUID string for VizGraph telemetry. Threaded to
    ///             SubstrateML so analytics rows carry the correct estate tag.
    ///   - now: Caller-supplied timestamp for telemetry. Never read a clock
    ///          inside NeuronKit or SubstrateML; the caller provides `now`.
    public static func keystones(nodeIDs: [String], edges: [(String, String)],
                                 topK: Int,
                                 estate: String,
                                 now: Date) -> [Keystone] {
        guard !nodeIDs.isEmpty, topK > 0 else { return [] }

        let adjacency = StructureGraph.build(nodeIDs: nodeIDs, edges: edges)
        // Thread estate and ts so the VizGraph telemetry row carries the caller's
        // estate identifier and timestamp — not the empty defaults that caused
        // analytics to emit with estate:"" and ts:0 before this fix.
        let centralities = SubstrateML.EigenvalueCentrality.compute(
            adjacency: adjacency,
            estate: estate,
            ts: now.timeIntervalSince1970)

        // Break into two steps — the zip+map chain is too deep for the Swift
        // type-checker to infer in one pass (produces "unable to type-check
        // in reasonable time" otherwise).
        let keystones: [Keystone] = zip(nodeIDs, centralities)
            .map { pair in Keystone(id: pair.0, centrality: pair.1) }
        let ranked = keystones.sorted { lhs, rhs in
            lhs.centrality == rhs.centrality
                ? lhs.id < rhs.id            // ties: ascending id
                : lhs.centrality > rhs.centrality   // primary: descending centrality
        }
        return Array(ranked.prefix(topK))
    }
}
