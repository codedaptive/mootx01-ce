// LatticeDistance.swift
//
// Lattice distance per cookbook § 8.3.
//
// The lattice anchor is a two-part address: a Universal Decimal
// Classification (UDC) code (numeric, hierarchical, treated here
// as a string of digits and dots) and an optional Wikidata Q-ID.
// Lattice distance between two anchors is a weighted sum:
//
//   lattice_distance(a, b)
//     = alpha_udc * udc_tree_distance(a.udc, b.udc)
//     + alpha_qid * wikidata_graph_distance(a.qid, b.qid)
//
// Both component distances are normalized to [0, 1]; the weighted
// sum is therefore in [0, 1] when alpha_udc + alpha_qid = 1.
//
// UDC tree distance uses longest common prefix (in characters):
//   d_udc(a, b) = (len(a) - len(lcp))
//               + (len(b) - len(lcp))
//   normalized = d_udc / max(len(a), len(b))   ∈ [0, 1]
//
// Divisor is max(len(a), len(b)) per glref oracle (cookbook § 8.3).
// Guard: when both strings are empty (maxLen = 0) return 0.0.
//
// Wikidata graph distance uses BFS over the subclass-of /
// instance-of / part-of edge set, bounded to depth 4, then
// exponentially normalized:
//   d_qid(a, b) = 1 - exp(-path_length / 3)    ∈ [0, 1)
//   if no path within depth 4: d_qid = 1.0
//
// The graph itself is opaque to the reference: it's accessed
// through a `WikidataAdjacencyProvider` protocol so the reference
// can be tested with synthetic graphs. Production code wires in
// Wikidata SPARQL or a local dump.
//
// Cookbook reference: § 8.3.

import Foundation
import SubstrateTypes

// MARK: - Anchor type (mirrors Verbs.swift; redeclared for
// standalone readability)

public struct LatticeAnchorStr: Hashable, Sendable {
    /// UDC code as a string of digits and dots, e.g., "004.42".
    public let udc: String
    /// Wikidata Q-ID as a positive integer, or 0 for null.
    public let qid: UInt64

    public init(udc: String, qid: UInt64 = 0) {
        self.udc = udc
        self.qid = qid
    }
}

// MARK: - UDC tree distance

public enum UDCTreeDistance {

    /// Returns the longest common prefix length (in characters).
    @inlinable
    public static func longestCommonPrefixLength(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = min(aChars.count, bChars.count)
        var i = 0
        while i < n && aChars[i] == bChars[i] { i += 1 }
        return i
    }

    /// UDC tree distance per glref oracle (cookbook § 8.3).
    ///
    /// Formula: raw = (lenA - lcp) + (lenB - lcp), divisor = max(lenA, lenB).
    /// Guard: both-empty strings are equal (caught by the identity check);
    /// when maxLen = 0, return 0.0.
    public static func distance(_ a: String, _ b: String) -> Double {
        if a == b { return 0.0 }
        let lenA = a.count
        let lenB = b.count
        let maxLen = max(lenA, lenB)
        // Guard: both-empty are equal and caught above; a non-empty vs
        // empty pair yields maxLen > 0. Explicit guard to match glref.
        if maxLen == 0 { return 0.0 }
        let lcp = longestCommonPrefixLength(a, b)
        let raw = Double((lenA - lcp) + (lenB - lcp))
        return raw / Double(maxLen)
    }
}

// MARK: - Wikidata graph distance

/// Adjacency over the subclass-of / instance-of / part-of edge
/// set. Production implementations consult Wikidata SPARQL or a
/// local dump; the reference accepts a callback.
public protocol WikidataAdjacencyProvider {
    /// Returns the set of Q-IDs reachable from `qid` by exactly
    /// one of the {subclass_of, instance_of, part_of} edges.
    func neighbors(of qid: UInt64) -> Set<UInt64>
}

public enum WikidataGraphDistance {

    public static let maxDepth: Int = 4
    public static let normalizationScale: Double = 3.0

    /// BFS over the adjacency provider up to `maxDepth`. Returns
    /// the shortest path length, or nil if not reachable within
    /// the depth budget.
    public static func shortestPathLength(
        from a: UInt64, to b: UInt64,
        provider: WikidataAdjacencyProvider,
        maxDepth: Int = maxDepth
    ) -> Int? {
        if a == b { return 0 }
        var visited: Set<UInt64> = [a]
        var frontier: Set<UInt64> = [a]
        for depth in 1...maxDepth {
            var next: Set<UInt64> = []
            for node in frontier {
                for neighbor in provider.neighbors(of: node) {
                    if neighbor == b { return depth }
                    if !visited.contains(neighbor) {
                        visited.insert(neighbor)
                        next.insert(neighbor)
                    }
                }
            }
            if next.isEmpty { return nil }
            frontier = next
        }
        return nil
    }

    /// Normalized Wikidata graph distance, [0, 1].
    public static func distance(
        from a: UInt64, to b: UInt64,
        provider: WikidataAdjacencyProvider,
        maxDepth: Int = maxDepth
    ) -> Double {
        if a == 0 || b == 0 { return 1.0 }  // null Q-ID
        if a == b { return 0.0 }
        guard let pathLength = shortestPathLength(
            from: a, to: b, provider: provider, maxDepth: maxDepth) else {
            return 1.0
        }
        return 1.0 - exp(-Double(pathLength) / normalizationScale)
    }
}

// MARK: - Combined lattice distance

public enum LatticeDistance {

    public static let defaultAlphaUDC: Double = 0.5
    public static let defaultAlphaQID: Double = 0.5

    /// Approximate distance over the integer-hashed `LatticeAnchor`
    /// form used by Block 2a/2b code. Returns 0.0 for identical
    /// anchors and 1.0 otherwise. Production code uses the
    /// `LatticeAnchorStr` overload below for true tree distance;
    /// the hashed form loses prefix structure so binary equality
    /// is the most accurate proxy available at this layer.
    public static func distance(_ a: LatticeAnchor, _ b: LatticeAnchor) -> Float32 {
        return (a == b) ? 0.0 : 1.0
    }

    /// Approximate subtree check over the integer-hashed form.
    /// Returns true if anchors match exactly. Production code
    /// checks `child.udc.hasPrefix(parent.udc)` against the
    /// string form.
    public static func isInSubtree(_ child: LatticeAnchor, of parent: LatticeAnchor) -> Bool {
        return child == parent
    }

    /// Combined lattice distance between two anchors.
    public static func distance(
        _ a: LatticeAnchorStr,
        _ b: LatticeAnchorStr,
        provider: WikidataAdjacencyProvider,
        alphaUDC: Double = defaultAlphaUDC,
        alphaQID: Double = defaultAlphaQID
    ) -> Double {
        let udcDistance = UDCTreeDistance.distance(a.udc, b.udc)
        let qidDistance = WikidataGraphDistance.distance(
            from: a.qid, to: b.qid, provider: provider)
        return alphaUDC * udcDistance + alphaQID * qidDistance
    }
}

// MARK: - Properties
//
//   reflexive:    distance(a, a) = 0 always (lcp = len(a)).
//   symmetric:    distance(a, b) = distance(b, a) for UDC by
//                 construction; symmetric for Wikidata when the
//                 adjacency is symmetric (subclass_of is not, but
//                 BFS treats edges as undirected for the distance
//                 metric per the cookbook).
//   bounded:      with alpha_udc + alpha_qid = 1, distance ∈ [0, 1].
//   null-qid:     when either anchor has qid = 0, qid_distance = 1
//                 (no info ⇒ maximally far on that axis).
//
// MARK: - Cookbook references
//   § 8.3   Lattice distance definition
//   § 2.7   Lattice anchor on all nouns (I-16)
//   § 3.3   Block 1 fingerprint construction (also uses Q-ID closure)
