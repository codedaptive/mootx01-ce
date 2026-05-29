// WikidataResolver.swift
//
// The Wikidata Q-ID resolver, keyed to the MDCC canon. A resolved
// MDCC canon entry carries its CC0 Wikidata Q-ID directly in its
// `sourceIdentity` field (the canon was assembled by mapping each
// code to a CC0 Wikidata entity). This resolver surfaces that Q-ID
// and confirms it against the bundled CC0 Wikidata subset, reporting
// the label/alias evidence the subset holds for it.
//
// Determinism: for a fixed entry and subset the output is identical
// across runs — a single membership lookup, no randomness, no clock.
//
// The subset (Wikidata, CC0) ships in the default bundle; it carries
// the human-readable label and aliases that the bare canon entry's
// Q-ID does not, so it remains useful for enrichment even though the
// Q-ID itself comes from the canon entry.

import Foundation
import LatticeKit

/// The resolved Q-ID plus the subset-backed evidence supporting it.
/// Callers who only want the Q-ID read `qid`; `labelHits`/`aliasHits`
/// record whether the bundled CC0 subset corroborates the canon
/// entry's label and how many aliases it carries.
public struct ResolverDecision: Equatable, Sendable {
    public let qid: String
    public let labelHits: Int
    public let aliasHits: Int

    public init(qid: String, labelHits: Int, aliasHits: Int) {
        self.qid = qid
        self.labelHits = labelHits
        self.aliasHits = aliasHits
    }
}

public enum WikidataResolver {

    /// Resolve the Wikidata Q-ID for a resolved MDCC canon entry.
    /// The Q-ID is the entry's `sourceIdentity`; this confirms it
    /// against the bundled CC0 subset and reports the evidence found.
    /// Returns nil only when the entry carries no source identity.
    public static func resolve(
        entry: LatticeEntry,
        subset: WikidataSubset
    ) -> ResolverDecision? {
        guard !entry.sourceIdentity.isEmpty else { return nil }

        guard let match = subset.entries.first(
            where: { $0.qid == entry.sourceIdentity }
        ) else {
            // A valid canon Q-ID that the bundled CC0 subset does not
            // carry: surface it without subset-backed evidence.
            return ResolverDecision(
                qid: entry.sourceIdentity,
                labelHits: 0,
                aliasHits: 0
            )
        }

        let labelHits = (match.label == entry.label) ? 1 : 0
        return ResolverDecision(
            qid: entry.sourceIdentity,
            labelHits: labelHits,
            aliasHits: match.aliases.count
        )
    }
}
