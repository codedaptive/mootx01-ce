// CollapseRule.swift
//
// The single-parent collapse rule. Wikidata's subclass/instance graph
// is messy: multi-parent, cyclic, and irregular. MDCC is a decimal
// tree — every node has exactly one parent. The collapse rule is the
// deterministic transform from the source graph to that tree.
//
// The rule has three tiers. They are applied in order; the first tier
// to break the tie wins. This ordering is the entire shape of MDCC —
// it decides which parent of a multi-parent Wikidata concept wins,
// and therefore which top-of-tree class the concept lives under.
//
//   Tier 1 — Pinned parent.
//     The canon ships with a pinned-parent map for high-profile
//     concepts. The pinned parent is an editorial decision: when a
//     concept could reasonably live in two classes, the canon names
//     the one it actually lives in. The pinned-parent map is small;
//     it covers the cases the editorial team has reviewed.
//
//   Tier 2 — Lowest spine-class index.
//     If no pin applies, walk the candidate parents in the source
//     graph. For each candidate, find the MDCC class it eventually
//     resolves to. Pick the candidate whose class has the lowest
//     `base` (000 before 100, 100 before 200, ...). This produces a
//     stable, deterministic preference for the more general class
//     over the more specific — Generalities before Philosophy,
//     Philosophy before Religion — but the preference can be
//     overridden by a pin in tier 1.
//
//   Tier 3 — Source-identity lexicographic minimum.
//     If two candidates resolve into the same MDCC class with no pin
//     between them, pick the candidate whose source-identity key is
//     lexicographically smallest. This is a determinism backstop, not
//     a semantic choice — it ensures the collapse is repeatable
//     across runs and across machines without depending on input
//     order.
//
// Cycles in the source graph are broken by recording the visited set
// during the walk and refusing to revisit. The first parent that
// would close a cycle is dropped; if every candidate would close a
// cycle, the node is orphaned (parent = nil) and the assembler reports
// it as a graph-shape diagnostic. Orphans are not assigned MDCC codes
// in v1.

import Foundation

/// A single edge in the source graph. The parent is the
/// subclass-of or instance-of target. The collapse rule is run over
/// the set of edges for a given child.
public struct SourceEdge: Sendable, Hashable, Codable {
    public let child: String   // source-identity key of the child
    public let parent: String  // source-identity key of the parent

    public init(child: String, parent: String) {
        self.child = child
        self.parent = parent
    }
}

/// The pinned-parent map. A pin says: when this child has multiple
/// candidate parents, the named parent wins. The map is editorial
/// input shipped with each canon.
public struct PinnedParents: Sendable {
    private let map: [String: String]

    public init(_ pairs: [String: String]) {
        self.map = pairs
    }

    /// Returns the pinned parent for a child, or nil if no pin is set.
    /// A pin overrides tier-2 and tier-3 selection, but only when the
    /// pinned parent survives the cycle filter.
    public func pinnedParent(for child: String) -> String? {
        map[child]
    }
}

/// The collapse rule, parameterised by the resolver that maps a
/// source-identity to its eventual MDCC class. The resolver is
/// supplied by the assembler — at collapse time it is the spine
/// assignment built up so far.
public struct CollapseRule: Sendable {

    /// Resolves a source identity to the spine class it belongs to,
    /// if known. Returns nil if the identity has not yet been placed.
    public typealias ClassResolver = @Sendable (String) -> LatticeClass?

    public let pins: PinnedParents
    public let resolver: ClassResolver

    public init(pins: PinnedParents, resolver: @escaping ClassResolver) {
        self.pins = pins
        self.resolver = resolver
    }

    /// Selects the single winning parent for `child` from the set of
    /// candidate `parents`. The visited set carries the ancestors
    /// already traversed by the caller's walk; any candidate already
    /// in `visited` is dropped before the tie-break tiers run.
    /// Returns nil only if every candidate was dropped as a cycle.
    public func selectParent(
        for child: String,
        candidates parents: [String],
        visited: Set<String>
    ) -> String? {
        // Cycle filter.
        let alive = parents.filter { !visited.contains($0) }
        if alive.isEmpty { return nil }

        // Tier 1: pinned parent.
        if let pinned = pins.pinnedParent(for: child),
           alive.contains(pinned) {
            return pinned
        }

        // Tier 2: lowest spine-class index. Candidates with no
        // resolved class yet are deferred to tier 3.
        let resolved: [(parent: String, classBase: Int)] = alive.compactMap { p in
            guard let cls = resolver(p) else { return nil }
            return (p, cls.base)
        }
        if !resolved.isEmpty {
            let minBase = resolved.map(\.classBase).min()!
            let lowest = resolved
                .filter { $0.classBase == minBase }
                .map(\.parent)
                .sorted()
            return lowest.first
        }

        // Tier 3: source-identity lexicographic minimum across all
        // surviving candidates.
        return alive.sorted().first
    }
}
