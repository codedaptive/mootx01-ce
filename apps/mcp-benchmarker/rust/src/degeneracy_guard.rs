//! degeneracy_guard.rs — the fail-loud degeneracy guard (SPEC §9).
//!
//! Ports `DegeneracyGuard.swift` exactly. Pure scorer over already-fetched
//! responses — no `Date::now()`, no randomness, no network contact.
//!
//! A non-`Healthy` verdict REFUSES the comparison (caller exits non-zero and
//! does NOT emit a published number).

use crate::divergence::{jaccard_divergence, rank_divergence};

// ─────────────────────────────────────────────────────────────────────────────
// Verdict
// ─────────────────────────────────────────────────────────────────────────────

/// A verdict on whether a backend is being driven in a way that makes its
/// recall/quality numbers trustworthy. Mirrors Swift `DegeneracyGuard.Verdict`.
#[derive(Debug)]
pub enum Verdict {
    /// Backend looks healthy — all invariance checks passed.
    Healthy,
    /// Backend returned essentially the same ranking for every probe query.
    QueryInvariant { diagnostic: String },
    /// Backend returned a "found N" count alongside a no-results/fallback hint.
    DegradedFallback { diagnostic: String },
    /// Confirmation round-trip contradicts the recall score.
    ConfirmationContradiction { diagnostic: String },
}

impl Verdict {
    /// A human-readable explanation, suitable for stderr. Mirrors Swift `Verdict.diagnostic`.
    pub fn diagnostic(&self) -> &str {
        match self {
            Self::Healthy => "backend is healthy — rankings vary across probe queries",
            Self::QueryInvariant { diagnostic }          => diagnostic,
            Self::DegradedFallback { diagnostic }        => diagnostic,
            Self::ConfirmationContradiction { diagnostic } => diagnostic,
        }
    }

    /// The discriminant name, for conformance-vector testing.
    pub fn discriminant(&self) -> &'static str {
        match self {
            Self::Healthy                       => "healthy",
            Self::QueryInvariant { .. }         => "queryInvariant",
            Self::DegradedFallback { .. }       => "degradedFallback",
            Self::ConfirmationContradiction { .. } => "confirmationContradiction",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// DegeneracyGuard
// ─────────────────────────────────────────────────────────────────────────────

/// The fail-loud degeneracy guard. Mirrors Swift `DegeneracyGuard`.
///
/// Pure scorer: caller issues probes; guard receives already-fetched rankings.
/// No `Date::now()`, no randomness, no networking inside this type.
pub struct DegeneracyGuard {
    /// Maximum mean pairwise divergence (Jaccard OR rank) below which two
    /// rankings are considered "the same". Default 0.05.
    pub invariance_threshold: f64,
    /// Minimum recall score above which a confirmed-count of 0 is considered
    /// a contradiction. Default 0.5.
    pub confirmation_recall_floor: f64,
}

impl Default for DegeneracyGuard {
    fn default() -> Self {
        Self {
            invariance_threshold: 0.05,
            confirmation_recall_floor: 0.5,
        }
    }
}

impl DegeneracyGuard {
    /// Create a guard with default thresholds (invarianceThreshold=0.05,
    /// confirmationRecallFloor=0.5). Mirrors Swift `DegeneracyGuard()`.
    pub fn new() -> Self {
        Self::default()
    }

    // ─── query-invariance check ──────────────────────────────────────────────

    /// Classifies a set of probe rankings as `QueryInvariant` or `Healthy`.
    ///
    /// Algorithm: compute pairwise `jaccard_divergence` + `rank_divergence` over
    /// every pair of probe rankings. If ALL pairs have Jaccard divergence below
    /// `invariance_threshold` AND rank divergence below `invariance_threshold`,
    /// the backend is query-invariant. Fewer than 2 probes → `Healthy`.
    ///
    /// Mirrors Swift `DegeneracyGuard.classify(probeRankings:)`.
    pub fn classify(&self, probe_rankings: &[Vec<String>]) -> Verdict {
        if probe_rankings.len() < 2 {
            return Verdict::Healthy;
        }

        let mut max_jaccard: f64 = 0.0;
        let mut max_rank: f64 = 0.0;

        let n = probe_rankings.len();
        for i in 0..n {
            for j in (i + 1)..n {
                let a: Vec<&str> = probe_rankings[i].iter().map(|s| s.as_str()).collect();
                let b: Vec<&str> = probe_rankings[j].iter().map(|s| s.as_str()).collect();
                let j_div = jaccard_divergence(&a, &b);
                let r_div = rank_divergence(&a, &b);
                if j_div > max_jaccard { max_jaccard = j_div; }
                if r_div > max_rank { max_rank = r_div; }
            }
        }

        // If EVERY pair has near-zero divergence on BOTH axes the backend is
        // returning the same ranking regardless of the probe query.
        if max_jaccard < self.invariance_threshold && max_rank < self.invariance_threshold {
            let sample: String = probe_rankings[0]
                .iter()
                .take(4)
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            return Verdict::QueryInvariant {
                diagnostic: format!(
                    "backend returned the same ranking across {} distinct probe queries \
                     (max Jaccard divergence {:.4}, max rank divergence {:.4}). \
                     Frozen ranking sample (first 4): [{}]. \
                     This matches the query-invariant failure mode in \
                     FINDINGS-2026-06-07. Refusing to publish recall numbers.",
                    probe_rankings.len(),
                    max_jaccard,
                    max_rank,
                    sample,
                ),
            };
        }

        Verdict::Healthy
    }

    // ─── degraded fallback check ─────────────────────────────────────────────

    /// Returns `true` when the text blocks contain a "found N" count co-present
    /// with a no-results/fallback hint.
    ///
    /// Mirrors Swift `DegeneracyGuard.checkFallback(textBlocks:)`.
    pub fn check_fallback(&self, text_blocks: &[&str]) -> bool {
        let combined: String = text_blocks.join("\n").to_lowercase();
        // Must contain a "found N" claim with N > 0.
        if !self.contains_found_positive(&combined) {
            return false;
        }
        // Must ALSO contain a no-results or fallback hint — the contradiction.
        combined.contains("no results")
            || combined.contains("no result")
            || combined.contains("hint:")
            || combined.contains("fallback")
            || combined.contains("no match")
    }

    // ─── confirmation-contradiction check ───────────────────────────────────

    /// Returns `true` when `confirmed_count` = 0 while `total` > 0 and `recall`
    /// is above `confirmation_recall_floor`.
    ///
    /// Mirrors Swift `DegeneracyGuard.checkConfirmation(confirmedCount:total:recall:)`.
    pub fn check_confirmation(&self, confirmed_count: usize, total: usize, recall: f64) -> bool {
        if total == 0 {
            return false;
        }
        confirmed_count == 0 && recall > self.confirmation_recall_floor
    }

    // ─── private helpers ─────────────────────────────────────────────────────

    /// True when any line/block in the lowercased combined text contains
    /// "found N" with N > 0. Mirrors Swift `containsFoundPositive(in:)`.
    fn contains_found_positive(&self, text: &str) -> bool {
        for line in text.lines() {
            let words: Vec<&str> = line.split_whitespace().collect();
            for (i, &word) in words.iter().enumerate() {
                if word == "found" {
                    if let Some(&next) = words.get(i + 1) {
                        if let Ok(n) = next.parse::<u64>() {
                            if n > 0 {
                                return true;
                            }
                        }
                    }
                }
            }
        }
        false
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests (inline — structural smoke tests; conformance vectors in
// tests/conformance.rs)
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_rankings_is_query_invariant() {
        let guard = DegeneracyGuard::new();
        let frozen = vec!["id-a".to_string(), "id-b".to_string(), "id-c".to_string()];
        let probes = vec![frozen.clone(), frozen.clone(), frozen.clone()];
        assert_eq!(guard.classify(&probes).discriminant(), "queryInvariant");
    }

    #[test]
    fn distinct_rankings_is_healthy() {
        let guard = DegeneracyGuard::new();
        let probes = vec![
            vec!["apple".to_string(), "banana".to_string(), "cherry".to_string()],
            vec!["date".to_string(), "cherry".to_string(), "elderberry".to_string()],
            vec!["grape".to_string(), "honeydew".to_string(), "apple".to_string()],
        ];
        assert_eq!(guard.classify(&probes).discriminant(), "healthy");
    }

    #[test]
    fn single_probe_is_healthy() {
        let guard = DegeneracyGuard::new();
        let probes = vec![vec!["a".to_string(), "b".to_string()]];
        assert_eq!(guard.classify(&probes).discriminant(), "healthy");
    }

    #[test]
    fn empty_probes_is_healthy() {
        let guard = DegeneracyGuard::new();
        assert_eq!(guard.classify(&[]).discriminant(), "healthy");
    }

    #[test]
    fn fallback_found_n_and_no_results() {
        let guard = DegeneracyGuard::new();
        let blocks = ["found 4 memory(s)", "hint: No results matched your query."];
        assert!(guard.check_fallback(&blocks));
    }

    #[test]
    fn fallback_found_zero_is_not_fallback() {
        let guard = DegeneracyGuard::new();
        let blocks = ["found 0 memory(s)"];
        assert!(!guard.check_fallback(&blocks));
    }

    #[test]
    fn confirmation_zero_with_perfect_recall_is_contradiction() {
        let guard = DegeneracyGuard::new();
        assert!(guard.check_confirmation(0, 5, 1.0));
    }

    #[test]
    fn confirmation_zero_with_zero_recall_is_not_contradiction() {
        let guard = DegeneracyGuard::new();
        assert!(!guard.check_confirmation(0, 5, 0.0));
    }

    #[test]
    fn confirmation_total_zero_is_not_contradiction() {
        let guard = DegeneracyGuard::new();
        assert!(!guard.check_confirmation(0, 0, 0.0));
    }
}
