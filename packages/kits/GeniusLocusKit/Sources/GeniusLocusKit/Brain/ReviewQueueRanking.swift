// ReviewQueueRanking.swift
//
// MXE-CT3 P2.5 — the review queue's ordering, and the ONLY consumer of
// endorsement weight. Weight ranks the queue; it never activates
// anything (see TunnelReviewLadder.swift for why).
//
// Ordering: (tier ascending, then within the tier band: contested
// first, endorsement weight descending, recency descending, tunnel id
// ascending as the final deterministic tie-break).
//
// Weight = distinct-endorser count + 1.0 diversity bonus when ≥ 2
// distinct model FAMILIES are present. Family = the endorser id's
// prefix before the first "-" or ":" (whichever comes first) —
// "apple-onboard" → "apple", "claude" → "claude",
// "dream-adjudicator@1" → "dream". Two endorsements from the same
// family (e.g. "claude" and "claude:haiku") are one family: agreement
// across model VENDORS is stronger evidence than agreement across two
// checkpoints of the same lineage.
//
// Contested floats to the top of its tier band: genuine model
// disagreement is the most user-worthy queue position — it means two
// independent reviewers read the same pair and split, which is exactly
// where a human judgment pays the most.
//
// Pure functions, no I/O — the Rust twin is
// `brain::review_queue` and both ports are unit-tested on identical
// fixtures.

import Foundation
import LocusKit

/// One proposed tunnel's ranking inputs, precomputed by the caller
/// (typically from a `Tunnel` + its parsed `TunnelReviewLedger` via
/// `entry(for:)`).
public struct ReviewQueueEntry: Sendable, Equatable {
    public let tunnelID: String
    /// Decline-matrix tier of the label family (1/2/3). Labels outside
    /// the families (`hunter: …`, foreign) rank in the weakest band
    /// (3): they are lexical-or-unknown claims, and an unknown claim
    /// must never outrank a typed proof.
    public let tier: Int
    /// Bit 15 — floats to the top of its tier band.
    public let contested: Bool
    /// `ReviewQueueRanking.endorsementWeight` output.
    public let weight: Double
    /// Canonical ISO-8601 recency key (lexicographic order IS
    /// chronological order for the canonical format): the latest ledger
    /// activity when model review happened, else the filing instant.
    public let recencyISO: String

    public init(
        tunnelID: String, tier: Int, contested: Bool,
        weight: Double, recencyISO: String
    ) {
        self.tunnelID = tunnelID
        self.tier = tier
        self.contested = contested
        self.weight = weight
        self.recencyISO = recencyISO
    }
}

/// Pure review-queue ranking. See the file header for the full
/// ordering and weight contracts.
public enum ReviewQueueRanking {

    /// Model family of an endorser id: the prefix before the first "-"
    /// or ":" (whichever comes first); the whole id when neither
    /// separator appears.
    public static func modelFamily(of endorserID: String) -> String {
        if let cut = endorserID.firstIndex(where: { $0 == "-" || $0 == ":" }) {
            return String(endorserID[..<cut])
        }
        return endorserID
    }

    /// Endorsement weight: distinct-endorser count + 1.0 when the
    /// endorser set spans ≥ 2 distinct model families. Feeds queue
    /// RANKING ONLY — no weight threshold activates anything.
    public static func endorsementWeight(endorserIDs: [String]) -> Double {
        let distinct = Set(endorserIDs)
        let families = Set(distinct.map(modelFamily(of:)))
        return Double(distinct.count) + (families.count >= 2 ? 1.0 : 0.0)
    }

    /// Build one queue entry from a proposed tunnel and its parsed
    /// ledger. Tier comes from the label family
    /// (`GeniusLocusKit.rejectionTier(ofLabel:)`); labels outside the
    /// families rank in band 3 (weakest — see `ReviewQueueEntry.tier`).
    public static func entry(
        for tunnel: Tunnel, ledger: TunnelReviewLedger
    ) -> ReviewQueueEntry {
        ReviewQueueEntry(
            tunnelID: tunnel.id,
            tier: GeniusLocusKit.rejectionTier(ofLabel: tunnel.label) ?? 3,
            contested: tunnel.isContested,
            weight: endorsementWeight(endorserIDs: ledger.endorsements.map(\.by)),
            recencyISO: ledger.latestActivityISO
                ?? TunnelReviewLedger.isoTimestamp(tunnel.filedAt))
    }

    /// Rank queue entries: tier ascending; within a tier band contested
    /// first, then weight descending, then recency descending, then
    /// tunnel id ascending (total, deterministic order).
    public static func rank(_ entries: [ReviewQueueEntry]) -> [ReviewQueueEntry] {
        entries.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.contested != b.contested { return a.contested }
            if a.weight != b.weight { return a.weight > b.weight }
            if a.recencyISO != b.recencyISO { return a.recencyISO > b.recencyISO }
            return a.tunnelID < b.tunnelID
        }
    }
}
