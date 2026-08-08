//! Review-queue ranking. Ports `ReviewQueueRanking.swift`.
//!
//! MXE-CT3 P2.5 — the review queue's ordering, and the ONLY consumer of
//! endorsement weight. Weight ranks the queue; it never activates
//! anything (see TunnelReviewLadder.swift / `endorse_tunnel` for why).
//!
//! Ordering: (tier ascending, then within the tier band: contested
//! first, endorsement weight descending, recency descending, tunnel id
//! ascending as the final deterministic tie-break).
//!
//! Weight = distinct-endorser count + 1.0 diversity bonus when ≥ 2
//! distinct model FAMILIES are present. Family = the endorser id's
//! prefix before the first '-' or ':' (whichever comes first) —
//! "apple-onboard" → "apple", "claude" → "claude",
//! "dream-adjudicator@1" → "dream". Two endorsements from the same
//! family are one family: agreement across model VENDORS is stronger
//! evidence than agreement across two checkpoints of the same lineage.
//!
//! Contested floats to the top of its tier band: genuine model
//! disagreement is the most user-worthy queue position — two
//! independent reviewers read the same pair and split, which is exactly
//! where a human judgment pays the most.
//!
//! Pure functions, no I/O — unit-tested on fixtures identical to the
//! Swift port's.

use locus_kit::tunnel::Tunnel;
use locus_kit::tunnel_review_ledger::{iso8601_from_millis, TunnelReviewLedger};

/// One proposed tunnel's ranking inputs. Mirrors Swift
/// `ReviewQueueEntry`.
#[derive(Debug, Clone, PartialEq)]
pub struct ReviewQueueEntry {
    pub tunnel_id: String,
    /// Decline-matrix tier of the label family (1/2/3). Labels outside
    /// the families (`hunter: …`, foreign) rank in the weakest band
    /// (3): an unknown claim must never outrank a typed proof.
    pub tier: u8,
    /// Bit 15 — floats to the top of its tier band.
    pub contested: bool,
    /// `endorsement_weight` output.
    pub weight: f64,
    /// Canonical ISO-8601 recency key (lexicographic order IS
    /// chronological order for the canonical format): the latest ledger
    /// activity when model review happened, else the filing instant.
    pub recency_iso: String,
}

/// Model family of an endorser id: the prefix before the first '-' or
/// ':' (whichever comes first); the whole id when neither separator
/// appears. Mirrors Swift `ReviewQueueRanking.modelFamily(of:)`.
pub fn model_family(endorser_id: &str) -> &str {
    match endorser_id.find(['-', ':']) {
        Some(i) => &endorser_id[..i],
        None => endorser_id,
    }
}

/// Endorsement weight: distinct-endorser count + 1.0 when the endorser
/// set spans ≥ 2 distinct model families. Feeds queue RANKING ONLY —
/// no weight threshold activates anything. Mirrors Swift
/// `ReviewQueueRanking.endorsementWeight(endorserIDs:)`.
pub fn endorsement_weight(endorser_ids: &[&str]) -> f64 {
    let distinct: std::collections::HashSet<&str> = endorser_ids.iter().copied().collect();
    let families: std::collections::HashSet<&str> =
        distinct.iter().map(|id| model_family(id)).collect();
    distinct.len() as f64 + if families.len() >= 2 { 1.0 } else { 0.0 }
}

/// Build one queue entry from a proposed tunnel and its parsed ledger.
/// Tier comes from the label family
/// (`conflict_projection_sweep::rejection_tier_of_label`); labels
/// outside the families rank in band 3 (weakest). `filed_at` is the
/// tunnel's epoch-millisecond filing instant (the Rust port's native
/// clock domain). Mirrors Swift `ReviewQueueRanking.entry(for:ledger:)`.
pub fn entry_for(tunnel: &Tunnel, ledger: &TunnelReviewLedger) -> ReviewQueueEntry {
    let endorsers: Vec<&str> = ledger.endorsements.iter().map(|e| e.by.as_str()).collect();
    ReviewQueueEntry {
        tunnel_id: tunnel.id.clone(),
        tier: crate::brain::conflict_projection_sweep::rejection_tier_of_label(&tunnel.label)
            .unwrap_or(3),
        contested: tunnel.is_contested(),
        weight: endorsement_weight(&endorsers),
        recency_iso: ledger
            .latest_activity_iso()
            .map(str::to_string)
            .unwrap_or_else(|| iso8601_from_millis(tunnel.filed_at)),
    }
}

/// Rank queue entries: tier ascending; within a tier band contested
/// first, then weight descending, then recency descending, then tunnel
/// id ascending (total, deterministic order). Mirrors Swift
/// `ReviewQueueRanking.rank(_:)`.
pub fn rank(mut entries: Vec<ReviewQueueEntry>) -> Vec<ReviewQueueEntry> {
    entries.sort_by(|a, b| {
        a.tier
            .cmp(&b.tier)
            .then_with(|| b.contested.cmp(&a.contested))
            .then_with(|| {
                b.weight
                    .partial_cmp(&a.weight)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| b.recency_iso.cmp(&a.recency_iso))
            .then_with(|| a.tunnel_id.cmp(&b.tunnel_id))
    });
    entries
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, tier: u8, contested: bool, weight: f64, recency: &str) -> ReviewQueueEntry {
        ReviewQueueEntry {
            tunnel_id: id.to_string(),
            tier,
            contested,
            weight,
            recency_iso: recency.to_string(),
        }
    }

    #[test]
    fn model_family_splits_on_first_dash_or_colon() {
        assert_eq!(model_family("apple-onboard"), "apple");
        assert_eq!(model_family("claude"), "claude");
        assert_eq!(model_family("dream-adjudicator@1"), "dream");
        assert_eq!(model_family("claude:haiku"), "claude");
        assert_eq!(model_family("a:b-c"), "a");
    }

    #[test]
    fn weight_counts_distinct_endorsers_with_family_diversity_bonus() {
        // Idempotent votes: duplicates collapse.
        assert_eq!(endorsement_weight(&["claude", "claude"]), 1.0);
        // Same family, two ids: no bonus.
        assert_eq!(endorsement_weight(&["claude", "claude:haiku"]), 2.0);
        // Two families: +1.0 bonus.
        assert_eq!(endorsement_weight(&["claude", "apple-onboard"]), 3.0);
        assert_eq!(endorsement_weight(&[]), 0.0);
    }

    #[test]
    fn rank_orders_tier_then_contested_then_weight_then_recency_then_id() {
        let ranked = rank(vec![
            entry("t3-heavy", 3, false, 9.0, "2026-08-07T12:00:00Z"),
            entry("t1-light", 1, false, 0.0, "2026-08-01T00:00:00Z"),
            entry("t2-contested", 2, true, 1.0, "2026-08-02T00:00:00Z"),
            entry("t2-heavy", 2, false, 5.0, "2026-08-07T12:00:00Z"),
            entry("t2-b", 2, false, 2.0, "2026-08-03T00:00:00Z"),
            entry("t2-a", 2, false, 2.0, "2026-08-03T00:00:00Z"),
        ]);
        let ids: Vec<&str> = ranked.iter().map(|e| e.tunnel_id.as_str()).collect();
        // Tier band first (a strong tier-3 never outranks a weak
        // tier-1); contested tops its band despite lower weight; equal
        // weight+recency breaks on id.
        assert_eq!(
            ids,
            vec!["t1-light", "t2-contested", "t2-heavy", "t2-a", "t2-b", "t3-heavy"]
        );
    }
}
