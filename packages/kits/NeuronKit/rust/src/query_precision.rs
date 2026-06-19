//! Query precision — the discriminative re-rank signal (the precision step of
//! PreciseRecall, CognitionKit). Rust port of
//! `NeuronKit/Sources/NeuronKit/Lenses/QueryPrecision.swift`.
//!
//! A coarse hybrid grab (BM25 + vector) keeps recall high but cannot tell
//! near-duplicates apart: "the indemnity was 46 million marks" and "the
//! indemnity was 11 million marks" share almost every shingle. The piece that
//! separates them is the DISTINCTIVE token — the number, the proper noun — that
//! the query names and only one candidate contains.
//!
//! `query_precision` composes two pure, deterministic signals into one score in
//! `[0, 1]`:
//!   1. content-word match rate — the fraction of the query's CONTENT words
//!      (non-stopword, non-question-word) present in the candidate.
//!   2. a discriminative exact-match bonus — of the query's DISTINCTIVE tokens
//!      (numbers and proper nouns), the fraction present verbatim, scaled by a
//!      bounded bonus.
//!
//! Total: every input yields a finite score; an empty query or empty candidate
//! yields 0. Deterministic: no locale-sensitive transform beyond
//! `to_lowercase()` (ASCII-folded, matching the Swift port's `lowercased()` on
//! the ASCII conformance vectors), no clock, no RNG.

use std::collections::BTreeSet;

/// The default maximum additive bonus a full distinctive-token match
/// contributes. Matches the Swift `queryPrecision` `distinctiveBonus`
/// default (0.25).
pub const DEFAULT_DISTINCTIVE_BONUS: f32 = 0.25;

/// Stopwords and question words dropped from the query before the content-word
/// match, so the entity + attribute words carry the signal. A small closed
/// ASCII list — locale-free, identical to the Swift port — covering the
/// function words and interrogatives that appear in every near-duplicate.
const STOPWORDS: &[&str] = &[
    "what", "which", "who", "whom", "whose", "where", "when", "why", "how", "is",
    "are", "was", "were", "be", "been", "the", "a", "an", "of", "in", "on", "at",
    "to", "for", "and", "or", "its", "it", "this", "that", "these", "those",
];

/// Precision of `candidate` as an answer to `query`, in `[0, 1]`.
///
/// `score = clamp(content_match + bonus * distinctive_rate)`. Pure, total,
/// deterministic; returns 0 when either side is empty. Mirrors Swift
/// `NeuronKit.queryPrecision(query:candidate:distinctiveBonus:)`.
pub fn query_precision(query: &str, candidate: &str, distinctive_bonus: f32) -> f32 {
    let bonus = distinctive_bonus.clamp(0.0, 1.0);
    let candidate_tokens: BTreeSet<String> = word_tokens(candidate).into_iter().collect();
    let query_tokens = word_tokens(query);
    if query_tokens.is_empty() || candidate_tokens.is_empty() {
        return 0.0;
    }

    // 1. LEAD SIGNAL — content-word match rate. Drop stopwords/question words;
    //    if the query is all stopwords (degenerate), fall back to the full
    //    token set so the signal is never undefined.
    let content_query: Vec<String> = query_tokens
        .iter()
        .filter(|t| !STOPWORDS.contains(&t.as_str()))
        .cloned()
        .collect();
    let effective_query: BTreeSet<String> = if content_query.is_empty() {
        query_tokens.iter().cloned().collect()
    } else {
        content_query.into_iter().collect()
    };
    let matched_content = effective_query
        .iter()
        .filter(|t| candidate_tokens.contains(*t))
        .count();
    let content_match = matched_content as f32 / effective_query.len() as f32;

    // 2. BONUS — distinctive-token match rate, scaled by `bonus`. 0 (not
    //    undefined) when the query names no distinctive token.
    let distinctive = distinctive_tokens(query);
    let distinctive_rate = if distinctive.is_empty() {
        0.0
    } else {
        let matched = distinctive
            .iter()
            .filter(|t| candidate_tokens.contains(*t))
            .count();
        matched as f32 / distinctive.len() as f32
    };

    (content_match + bonus * distinctive_rate).min(1.0)
}

/// Lowercased word tokens of `s`: maximal runs of alphanumerics, case-folded.
/// Punctuation and whitespace are separators. Mirrors Swift `wordTokens`.
pub fn word_tokens(s: &str) -> Vec<String> {
    s.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(String::from)
        .collect()
}

/// The query's DISTINCTIVE tokens, case-folded: a token is distinctive when it
/// carries a digit (a number) or is a proper noun (its ORIGINAL casing has an
/// uppercase letter). Returned case-folded to match the candidate's folded
/// token set. Mirrors Swift `distinctiveTokens`.
pub fn distinctive_tokens(s: &str) -> BTreeSet<String> {
    // Split the ORIGINAL string (casing preserved) so proper-noun detection
    // can see the uppercase letters.
    let mut out = BTreeSet::new();
    for token in s.split(|c: char| !c.is_alphanumeric()).filter(|t| !t.is_empty()) {
        let has_digit = token.chars().any(|c| c.is_numeric());
        let has_upper = token.chars().any(|c| c.is_uppercase());
        if has_digit || has_upper {
            out.insert(token.to_lowercase());
        }
    }
    out
}

/// Whether `query` contains at least one distinctive token (a number or a word
/// with an uppercase letter). When true, the exact-token gate in
/// `moot_recall_precise` applies: a result set where no candidate contains any
/// of those tokens should be suppressed (not_found) rather than returned as a
/// confident ranked list. Mirrors Swift `NeuronKit.hasDistinctiveTokens`.
pub fn has_distinctive_tokens(query: &str) -> bool {
    !distinctive_tokens(query).is_empty()
}

/// Whether at least one of `candidate_contents` satisfies the distinctive-token
/// containment gate for `query`. Returns `true` when:
///   - the query has no distinctive tokens (gate does not apply), OR
///   - at least one candidate's content contains at least one distinctive token
///     from the query (i.e. `token_exact_rate` for that candidate > 0).
///
/// When this returns `false`, the recall set is a confident non-match.
/// Mirrors Swift `NeuronKit.containmentSatisfied(query:candidateContents:)`.
pub fn containment_satisfied(query: &str, candidate_contents: &[&str]) -> bool {
    let distinctive = distinctive_tokens(query);
    if distinctive.is_empty() {
        return true;
    }
    for content in candidate_contents {
        let tokens: BTreeSet<String> = word_tokens(content).into_iter().collect();
        // Any match where at least one distinctive token is present passes.
        if distinctive.iter().any(|t| tokens.contains(t)) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_sides_score_zero() {
        assert_eq!(query_precision("", "anything", DEFAULT_DISTINCTIVE_BONUS), 0.0);
        assert_eq!(query_precision("anything", "", DEFAULT_DISTINCTIVE_BONUS), 0.0);
    }

    #[test]
    fn distinctive_number_separates_near_duplicates() {
        // "46" is distinctive; only the candidate that contains it gets the bonus.
        let q = "the indemnity was 46 million marks";
        let hit = query_precision(q, "the indemnity was 46 million marks", DEFAULT_DISTINCTIVE_BONUS);
        let miss = query_precision(q, "the indemnity was 11 million marks", DEFAULT_DISTINCTIVE_BONUS);
        assert!(hit > miss, "distinctive number must lift the matching candidate");
    }

    #[test]
    fn distinctive_tokens_pick_numbers_and_proper_nouns() {
        let d = distinctive_tokens("what was the Versailles indemnity of 46 million");
        assert!(d.contains("versailles"));
        assert!(d.contains("46"));
        assert!(!d.contains("indemnity")); // common lowercase word, not distinctive
    }

    #[test]
    fn stopwords_dropped_from_lead_signal() {
        // All query content words present → content_match 1.0.
        let s = query_precision("what is the reserve value", "the reserve value is large", DEFAULT_DISTINCTIVE_BONUS);
        assert!((s - 1.0).abs() < 1e-6, "expected full content match, got {s}");
    }

    // Wave B, Part 1a — containment gate helpers

    #[test]
    fn has_distinctive_tokens_detects_numbers_and_proper_nouns() {
        assert!(has_distinctive_tokens("the indemnity was 46 million marks"));
        assert!(has_distinctive_tokens("the treaty of Versailles"));
        assert!(has_distinctive_tokens("Q3 revenue report"));
        // Plain lowercase words only — no distinctive tokens.
        assert!(!has_distinctive_tokens("the quick brown fox"));
        assert!(!has_distinctive_tokens("what is the indemnity"));
        assert!(!has_distinctive_tokens(""));
    }

    #[test]
    fn containment_satisfied_no_distinctive_always_true() {
        // Generic query — gate cannot fire; result is always satisfied.
        assert!(containment_satisfied("what is the indemnity", &["anything at all", "another result"]));
        // Empty candidates is also satisfied when no distinctive tokens.
        assert!(containment_satisfied("what is the indemnity", &[]));
    }

    #[test]
    fn containment_satisfied_partial_match_passes() {
        // "46" is distinctive; one candidate contains it.
        assert!(containment_satisfied(
            "indemnity 46 million",
            &["indemnity was 11 million", "indemnity was 46 million"],
        ));
    }

    #[test]
    fn containment_satisfied_no_match_fires() {
        // "46" is distinctive; neither candidate contains it.
        assert!(!containment_satisfied(
            "indemnity 46 million",
            &["indemnity was 11 million", "indemnity was 23 million"],
        ));
        // Empty candidates with a distinctive query also fires.
        assert!(!containment_satisfied("Versailles treaty", &[]));
    }
}
