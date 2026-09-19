//! Gauntlet scorer — pure, deterministic per-needle scoring.
//!
//! Port of `GauntletScorer.swift` (Phase 2.2). The scorer takes ONE needle's
//! ground truth and ONE backend's ordered return list and produces per-needle
//! retrieval metrics. It is intentionally pure — no network contact, no clock
//! reads — so it is fully unit-testable against synthetic fixture result-sets.
//!
//! IDENTITY ACROSS BACKENDS. Scoring matches a returned item to a corpus record
//! by CONTENT, using `normalize`: lowercase, collapse whitespace, bounded 64-char
//! prefix. This works for both mootx01 (which exposes ids) and any baseline
//! product that returns only content.
//!
//! METRICS:
//!   found@k    — is the needle's content present in the top-k? k ∈ {1,5,10}.
//!                A T4 split needle is "found" only when BOTH halves appear.
//!   rank       — 1-based position of the needle. For a T4 split, the LATER of
//!                the two halves' positions (the join completes only once both
//!                are seen).
//!   completeness — 1.0 when the returned item byte-matches the needle's verbatim
//!                  content (both halves for T4). 0.0 otherwise.
//!   contamination — count of this needle's planted distractors in the returned
//!                   top-k (k = deepest depth scored).

use crate::gauntlet_corpus::{NoiseTier, Needle};

/// One returned item, reduced to what the scorer needs: its content (the match
/// key) and its id when the backend supplied one (diagnosis only). Mirrors Swift
/// `ScoredItem`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScoredItem {
    pub id: Option<String>,
    pub content: Option<String>,
}

/// The per-needle score for one backend/strategy. Mirrors Swift `NeedleScore`.
#[derive(Debug, Clone, PartialEq)]
pub struct NeedleScore {
    pub needle_id: String,
    pub tier: NoiseTier,
    /// found@k flags keyed by k. k ∈ kValues the scorer was initialised with.
    pub found_at_k: std::collections::HashMap<i32, bool>,
    /// 1-based rank of the needle, `None` if not found.
    pub rank: Option<usize>,
    /// 1.0 = exact byte match, 0.0 = not found or incomplete.
    pub completeness: f64,
    /// Count of planted distractors in the top-k (k = deepest scored depth).
    pub contamination: usize,
    /// Recall latency supplied by the runner (seconds).
    pub latency_seconds: f64,
    /// Raw bytes the backend returned for this query.
    pub bytes_returned: usize,
}

impl NeedleScore {
    /// Reciprocal rank for MRR aggregation. 1/rank, or 0.0 when not found.
    pub fn reciprocal_rank(&self) -> f64 {
        self.rank
            .map(|r| 1.0 / r as f64)
            .unwrap_or(0.0)
    }
}

/// The pure scorer. Construct once with the k-depths to evaluate; call
/// `score` per needle. Mirrors Swift `GauntletScorer`.
pub struct GauntletScorer {
    /// Sorted, de-duplicated k-depths. Sorting + de-duplication makes found@k
    /// keys stable and rank-vs-k logic correct.
    pub k_values: Vec<i32>,
}

impl GauntletScorer {
    /// Constructs with the given k-depths (default {1,5,10}). Sorted and
    /// de-duplicated so clients that pass `[10,1,5]` get the same results.
    pub fn new(mut k_values: Vec<i32>) -> Self {
        k_values.sort_unstable();
        k_values.dedup();
        Self { k_values }
    }

    /// Normalizes content to the cross-backend match key: lowercase, collapse
    /// whitespace, bounded 64-char prefix. MUST match the normalization the rest
    /// of the benchmarker uses so a hit identified here is the same notion of
    /// "same item". The 64-char prefix absorbs source-preview truncation vs
    /// mootx01 full content on the shared leading text. Mirrors Swift
    /// `GauntletScorer.normalize`.
    pub fn normalize(content: &str) -> String {
        // Split on any whitespace, lowercase each token, rejoin with single spaces.
        let collapsed: String = content
            .split_whitespace()
            .map(|t| t.to_lowercase())
            .collect::<Vec<_>>()
            .join(" ");
        // Bounded 64-char prefix by character (Unicode-safe: chars().take).
        collapsed.chars().take(64).collect()
    }

    /// Scores one needle against a backend's ordered return list.
    ///
    /// Parameters mirror Swift `GauntletScorer.score`:
    /// - `needle`: ground truth.
    /// - `returned`: ordered result items from the backend.
    /// - `distractor_contents`: verbatim content of the needle's planted
    ///   distractors, keyed by distractor id (for contamination counting).
    /// - `split_partner_content`: partner half's verbatim content for a T4
    ///   split needle, `None` for non-split needles.
    /// - `latency_seconds` / `bytes_returned`: runner-supplied transport metrics.
    pub fn score(
        &self,
        needle: &Needle,
        returned: &[ScoredItem],
        distractor_contents: &std::collections::HashMap<String, String>,
        split_partner_content: Option<&str>,
        latency_seconds: f64,
        bytes_returned: usize,
    ) -> NeedleScore {
        // Verbatim content list (items with no content dropped from the match
        // space; their slot still counts in the raw return length the runner
        // measures). `returned_contents` keeps verbatim for the completeness
        // byte-compare; `returned_keys` is its normalized form for matching.
        let returned_contents: Vec<&str> = returned
            .iter()
            .filter_map(|i| i.content.as_deref())
            .collect();
        let returned_keys: Vec<String> = returned_contents
            .iter()
            .map(|c| Self::normalize(c))
            .collect();

        let needle_key = Self::normalize(&needle.content);
        let needle_index = returned_keys.iter().position(|k| k == &needle_key);

        // For T4 split: both halves must appear; effective rank is the LATER of
        // the two positions (the join completes only once both are seen).
        let partner_index: Option<usize> = if needle.split_partner_id.is_some() {
            split_partner_content.and_then(|pc| {
                let pk = Self::normalize(pc);
                returned_keys.iter().position(|k| k == &pk)
            })
        } else {
            None
        };

        let rank: Option<usize> = if needle.split_partner_id.is_some() {
            match (needle_index, partner_index) {
                (Some(n), Some(p)) => Some(n.max(p) + 1), // 1-based; later half
                _ => None,                                 // missing half → incomplete
            }
        } else {
            needle_index.map(|i| i + 1)
        };

        // found@k: true when the needle's (effective) rank is within k.
        let mut found_at_k = std::collections::HashMap::new();
        for &k in &self.k_values {
            found_at_k.insert(k, rank.map(|r| r <= k as usize).unwrap_or(false));
        }

        // Completeness: the returned item byte-matches the needle's verbatim content.
        // For T4 BOTH halves' returned items must byte-match.
        let needle_returned = needle_index.map(|i| returned_contents[i]);
        let completeness: f64 = if needle.split_partner_id.is_some() {
            let needle_ok = needle_returned == Some(needle.content.as_str());
            let partner_ok = partner_index
                .map(|i| Some(returned_contents[i]) == split_partner_content)
                .unwrap_or(false);
            if needle_ok && partner_ok { 1.0 } else { 0.0 }
        } else {
            if needle_returned == Some(needle.content.as_str()) { 1.0 } else { 0.0 }
        };

        // Contamination: count of this needle's planted distractors in top-k
        // (k = deepest scored depth).
        let max_k = self.k_values.iter().max().copied().unwrap_or(10) as usize;
        let top_k_keys: std::collections::HashSet<&str> = returned_keys
            .iter()
            .take(max_k)
            .map(|s| s.as_str())
            .collect();
        let contamination = distractor_contents
            .values()
            .filter(|c| top_k_keys.contains(Self::normalize(c).as_str()))
            .count();

        NeedleScore {
            needle_id: needle.id.clone(),
            tier: needle.tier,
            found_at_k,
            rank,
            completeness,
            contamination,
            latency_seconds,
            bytes_returned,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gauntlet_corpus::Needle;
    use std::collections::HashMap;

    fn scorer() -> GauntletScorer {
        GauntletScorer::new(vec![1, 5, 10])
    }

    fn needle(content: &str) -> Needle {
        Needle {
            id: "n0001".to_string(),
            query: "test query".to_string(),
            content: content.to_string(),
            tier: NoiseTier::Lexical,
            location: "Agentic Memory/test-room".to_string(),
            distractor_ids: vec![],
            split_partner_id: None,
            expected_rank: 1,
        }
    }

    fn item(content: &str) -> ScoredItem {
        ScoredItem { id: None, content: Some(content.to_string()) }
    }

    // ── normalize ──────────────────────────────────────────────────────────────

    #[test]
    fn normalize_lowercases() {
        assert_eq!(GauntletScorer::normalize("Hello World"), "hello world");
    }

    #[test]
    fn normalize_collapses_whitespace() {
        // Multiple spaces, tabs, and newlines all collapse to a single space.
        assert_eq!(GauntletScorer::normalize("one  two\tthree\nfour"), "one two three four");
    }

    #[test]
    fn normalize_64_char_prefix() {
        // Exactly 64 chars should survive untouched.
        let s = "a".repeat(64);
        assert_eq!(GauntletScorer::normalize(&s), s);
        // 65 chars are truncated to 64.
        let long = "a".repeat(65);
        assert_eq!(GauntletScorer::normalize(&long), "a".repeat(64));
    }

    #[test]
    fn normalize_empty() {
        assert_eq!(GauntletScorer::normalize(""), "");
    }

    // ── found@k / rank ────────────────────────────────────────────────────────

    #[test]
    fn found_at_1_when_needle_is_first() {
        let s = scorer();
        let n = needle("The answer is here.");
        let returned = vec![item("The answer is here.")];
        let score = s.score(&n, &returned, &HashMap::new(), None, 0.1, 100);
        assert_eq!(score.rank, Some(1));
        assert_eq!(*score.found_at_k.get(&1).unwrap(), true);
        assert_eq!(*score.found_at_k.get(&5).unwrap(), true);
        assert_eq!(*score.found_at_k.get(&10).unwrap(), true);
        assert_eq!(score.completeness, 1.0);
    }

    #[test]
    fn found_at_5_not_at_1_when_needle_is_third() {
        let s = scorer();
        let n = needle("Target content here.");
        let returned = vec![
            item("distractor 1"),
            item("distractor 2"),
            item("Target content here."),
        ];
        let score = s.score(&n, &returned, &HashMap::new(), None, 0.1, 100);
        assert_eq!(score.rank, Some(3));
        assert_eq!(*score.found_at_k.get(&1).unwrap(), false);
        assert_eq!(*score.found_at_k.get(&5).unwrap(), true);
        assert_eq!(*score.found_at_k.get(&10).unwrap(), true);
    }

    #[test]
    fn not_found_when_needle_absent() {
        let s = scorer();
        let n = needle("The needle.");
        let returned = vec![item("something else"), item("more noise")];
        let score = s.score(&n, &returned, &HashMap::new(), None, 0.1, 100);
        assert_eq!(score.rank, None);
        assert_eq!(*score.found_at_k.get(&1).unwrap(), false);
        assert_eq!(*score.found_at_k.get(&5).unwrap(), false);
        assert_eq!(*score.found_at_k.get(&10).unwrap(), false);
        assert_eq!(score.completeness, 0.0);
    }

    // ── case-insensitive normalization match ───────────────────────────────────

    #[test]
    fn match_is_case_insensitive_and_whitespace_tolerant() {
        let s = scorer();
        let n = needle("Exact Content");
        // Backend returned with different case and extra spaces.
        let returned = vec![item("exact  content")];
        let score = s.score(&n, &returned, &HashMap::new(), None, 0.0, 0);
        // Normalized keys match, but verbatim content differs → rank found, completeness 0.
        assert_eq!(score.rank, Some(1));
        assert_eq!(*score.found_at_k.get(&1).unwrap(), true);
        // Completeness 0: the returned item does NOT byte-match the needle's verbatim content.
        assert_eq!(score.completeness, 0.0);
    }

    // ── completeness ──────────────────────────────────────────────────────────

    #[test]
    fn completeness_1_when_verbatim_match() {
        let s = scorer();
        let content = "Caldwynn Foundry maintains its primary archive on the level called Gallery Zero.";
        let n = needle(content);
        let returned = vec![item(content)];
        let score = s.score(&n, &returned, &HashMap::new(), None, 0.05, 200);
        assert_eq!(score.completeness, 1.0);
    }

    // ── contamination ────────────────────────────────────────────────────────

    #[test]
    fn contamination_counts_distractors_in_top_k() {
        let s = scorer();
        let n = needle("The right answer.");
        let mut distractors = HashMap::new();
        distractors.insert("d1".to_string(), "Wrong answer A".to_string());
        distractors.insert("d2".to_string(), "Wrong answer B".to_string());
        let returned = vec![
            item("The right answer."),
            item("Wrong answer A"),
            item("Wrong answer B"),
            item("Unrelated noise"),
        ];
        let score = s.score(&n, &returned, &distractors, None, 0.0, 0);
        assert_eq!(score.contamination, 2);
    }

    #[test]
    fn contamination_zero_when_distractors_absent() {
        let s = scorer();
        let n = needle("The right answer.");
        let mut distractors = HashMap::new();
        distractors.insert("d1".to_string(), "Wrong answer A".to_string());
        // The distractor is NOT in the returned list.
        let returned = vec![item("The right answer."), item("Totally different")];
        let score = s.score(&n, &returned, &distractors, None, 0.0, 0);
        assert_eq!(score.contamination, 0);
    }

    // ── T4 split needle ───────────────────────────────────────────────────────

    #[test]
    fn split_needle_found_when_both_halves_present() {
        let s = scorer();
        let mut n = needle("First half of the answer.");
        n.split_partner_id = Some("n0001-b".to_string());
        let partner_content = "Second half of the answer.";
        let returned = vec![
            item("First half of the answer."),
            item("noise"),
            item("Second half of the answer."),
        ];
        let score = s.score(&n, &returned, &HashMap::new(), Some(partner_content), 0.0, 0);
        // Effective rank = max(1, 3) = 3.
        assert_eq!(score.rank, Some(3));
        assert_eq!(*score.found_at_k.get(&1).unwrap(), false);
        assert_eq!(*score.found_at_k.get(&5).unwrap(), true);
        // Completeness: both halves byte-match → 1.0.
        assert_eq!(score.completeness, 1.0);
    }

    #[test]
    fn split_needle_not_found_when_partner_missing() {
        let s = scorer();
        let mut n = needle("First half.");
        n.split_partner_id = Some("n0001-b".to_string());
        // Only the first half is returned.
        let returned = vec![item("First half.")];
        let score = s.score(&n, &returned, &HashMap::new(), Some("Second half."), 0.0, 0);
        assert_eq!(score.rank, None);
        assert_eq!(*score.found_at_k.get(&1).unwrap(), false);
        assert_eq!(score.completeness, 0.0);
    }

    // ── reciprocal rank ───────────────────────────────────────────────────────

    #[test]
    fn reciprocal_rank_at_rank_1() {
        let s = scorer();
        let n = needle("At rank 1.");
        let returned = vec![item("At rank 1.")];
        let score = s.score(&n, &returned, &HashMap::new(), None, 0.0, 0);
        assert!((score.reciprocal_rank() - 1.0).abs() < 1e-9);
    }

    #[test]
    fn reciprocal_rank_zero_when_not_found() {
        let s = scorer();
        let n = needle("Not found.");
        let score = s.score(&n, &[], &HashMap::new(), None, 0.0, 0);
        assert_eq!(score.reciprocal_rank(), 0.0);
    }

    #[test]
    fn reciprocal_rank_at_rank_4() {
        let s = scorer();
        let n = needle("At rank 4.");
        let returned = vec![
            item("noise1"), item("noise2"), item("noise3"), item("At rank 4."),
        ];
        let score = s.score(&n, &returned, &HashMap::new(), None, 0.0, 0);
        assert!((score.reciprocal_rank() - 0.25).abs() < 1e-9);
    }

    // ── k-values config ───────────────────────────────────────────────────────

    #[test]
    fn scorer_deduplicates_k_values() {
        let s = GauntletScorer::new(vec![10, 1, 5, 1, 10]);
        assert_eq!(s.k_values, vec![1, 5, 10]);
    }

    #[test]
    fn scorer_sorts_k_values() {
        let s = GauntletScorer::new(vec![10, 5, 1]);
        assert_eq!(s.k_values, vec![1, 5, 10]);
    }
}
