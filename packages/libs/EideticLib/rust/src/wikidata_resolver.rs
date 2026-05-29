//! The Wikidata Q-ID resolver. Mirror of the Swift port at
//! Sources/EideticLib/WikidataResolver.swift; the algorithmic
//! specification is documented there in full and the Rust
//! implementation realizes the same contract byte-for-byte
//! for shared test vectors.
//!
//! Score vector: (label_hits, alias_hits, udc_agreement,
//! -qid_number). Acceptance: label_hits >= 1 OR
//! (alias_hits >= 1 AND udc_agreement >= 2).

use crate::wikidata_subset::WikidataSubset;
use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolverDecision {
    pub qid: String,
    pub label_hits: u32,
    pub alias_hits: u32,
    pub udc_agreement: u8,
}

/// Resolve a Q-ID from normalized tokens and the classified
/// code. Returns `None` when no candidate meets the
/// acceptance threshold.
pub fn resolve(
    tokens: &[String],
    code: &str,
    subset: &WikidataSubset,
) -> Option<ResolverDecision> {
    if tokens.is_empty() {
        return None;
    }

    let token_set: HashSet<String> =
        tokens.iter().map(|t| t.to_lowercase()).collect();

    let mut best: Option<ResolverDecision> = None;

    for entry in &subset.entries {
        let label_hits: u32 =
            if token_set.contains(&entry.label) { 1 } else { 0 };
        let alias_hits: u32 = entry
            .aliases
            .iter()
            .filter(|a| token_set.contains(*a))
            .count() as u32;
        let udc_agreement = udc_agreement_score(
            entry.udc_hint.as_deref(),
            code,
        );

        if label_hits == 0 && alias_hits == 0 {
            continue;
        }

        let candidate = ResolverDecision {
            qid: entry.qid.clone(),
            label_hits,
            alias_hits,
            udc_agreement,
        };

        match &best {
            None => best = Some(candidate),
            Some(current) if beats(&candidate, current) => {
                best = Some(candidate)
            }
            _ => {}
        }
    }

    match best {
        Some(d) if is_acceptable(&d) => Some(d),
        _ => None,
    }
}

/// UDC-tree agreement score: 4 on equality, 3 on depth-2
/// prefix, 2 on depth-1 prefix, 0 otherwise. Returns 0 when
/// the entry has no UDC hint.
pub fn udc_agreement_score(entry_hint: Option<&str>, classified: &str) -> u8 {
    let hint = match entry_hint {
        Some(h) if !h.is_empty() => h,
        _ => return 0,
    };
    if classified.is_empty() {
        return 0;
    }
    if hint == classified {
        return 4;
    }
    if hint.len() >= 2 && classified.len() >= 2 {
        let hint_prefix = &hint[..2];
        let classified_prefix = &classified[..2];
        if hint_prefix == classified_prefix {
            return 3;
        }
    }
    let hint_first = hint.chars().next();
    let classified_first = classified.chars().next();
    if hint_first == classified_first && hint_first.is_some() {
        return 2;
    }
    0
}

/// Lexicographic comparison: a beats b when a's score vector
/// is strictly greater than b's under (label_hits,
/// alias_hits, udc_agreement, -qid_number).
fn beats(a: &ResolverDecision, b: &ResolverDecision) -> bool {
    if a.label_hits != b.label_hits {
        return a.label_hits > b.label_hits;
    }
    if a.alias_hits != b.alias_hits {
        return a.alias_hits > b.alias_hits;
    }
    if a.udc_agreement != b.udc_agreement {
        return a.udc_agreement > b.udc_agreement;
    }
    qid_number(&a.qid) < qid_number(&b.qid)
}

/// Extract the integer suffix from a Q-ID. Returns u64::MAX
/// for malformed Q-IDs so they lose tie-breaks rather than
/// panicking.
fn qid_number(qid: &str) -> u64 {
    if !qid.starts_with('Q') {
        return u64::MAX;
    }
    qid[1..].parse::<u64>().unwrap_or(u64::MAX)
}

/// The acceptance predicate. Any label hit accepts; an alias
/// hit accepts only with UDC agreement at depth-1 or better.
fn is_acceptable(d: &ResolverDecision) -> bool {
    if d.label_hits >= 1 {
        return true;
    }
    if d.alias_hits >= 1 && d.udc_agreement >= 2 {
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wikidata_subset::{WikidataEntry, WikidataSubset};

    fn make_subset(entries: Vec<WikidataEntry>) -> WikidataSubset {
        WikidataSubset {
            schema_version: "1".to_string(),
            data_version: "0.1.0-test".to_string(),
            source_notes: "test fixture".to_string(),
            license_note: "test fixture".to_string(),
            entries,
        }
    }

    fn e(
        qid: &str,
        label: &str,
        aliases: &[&str],
        udc_hint: Option<&str>,
    ) -> WikidataEntry {
        WikidataEntry {
            qid: qid.to_string(),
            label: label.to_string(),
            aliases: aliases.iter().map(|a| a.to_string()).collect(),
            udc_hint: udc_hint.map(|s| s.to_string()),
            source_section: "test".to_string(),
        }
    }

    #[test]
    fn udc_agreement_equal_codes_score_four() {
        assert_eq!(udc_agreement_score(Some("547"), "547"), 4);
    }

    #[test]
    fn udc_agreement_depth_two_prefix_scores_three() {
        assert_eq!(udc_agreement_score(Some("54"), "547"), 3);
    }

    #[test]
    fn udc_agreement_depth_one_prefix_scores_two() {
        assert_eq!(udc_agreement_score(Some("5"), "547"), 2);
    }

    #[test]
    fn udc_agreement_unrelated_codes_score_zero() {
        assert_eq!(udc_agreement_score(Some("611"), "547"), 0);
    }

    #[test]
    fn udc_agreement_nil_hint_scores_zero() {
        assert_eq!(udc_agreement_score(None, "547"), 0);
    }

    #[test]
    fn empty_tokens_return_none() {
        let s = make_subset(vec![e("Q900001", "chemistry", &[], Some("54"))]);
        assert!(resolve(&[], "54", &s).is_none());
    }

    #[test]
    fn no_match_returns_none() {
        let s = make_subset(vec![e("Q900001", "chemistry", &[], Some("54"))]);
        assert!(
            resolve(&["nonsense".to_string()], "54", &s).is_none()
        );
    }

    #[test]
    fn alias_only_hit_without_udc_agreement_below_threshold() {
        let s = make_subset(vec![e(
            "Q900001",
            "chemistry",
            &["alchemy"],
            None,
        )]);
        assert!(
            resolve(&["alchemy".to_string()], "54", &s).is_none()
        );
    }

    #[test]
    fn label_hit_returns_candidate() {
        let s = make_subset(vec![e(
            "Q900001",
            "chemistry",
            &[],
            Some("54"),
        )]);
        let d = resolve(&["chemistry".to_string()], "54", &s).unwrap();
        assert_eq!(d.qid, "Q900001");
        assert_eq!(d.label_hits, 1);
        assert_eq!(d.udc_agreement, 4);
    }

    #[test]
    fn alias_hit_with_udc_agreement_accepts() {
        let s = make_subset(vec![e(
            "Q900001",
            "chemistry",
            &["chem"],
            Some("54"),
        )]);
        let d = resolve(&["chem".to_string()], "54", &s).unwrap();
        assert_eq!(d.qid, "Q900001");
        assert_eq!(d.alias_hits, 1);
    }

    #[test]
    fn label_hit_beats_alias_hit() {
        let s = make_subset(vec![
            e("Q900001", "chemistry", &["chem"], Some("54")),
            e("Q900002", "physics", &["chemistry"], Some("53")),
        ]);
        let d = resolve(&["chemistry".to_string()], "54", &s).unwrap();
        assert_eq!(d.qid, "Q900001");
    }

    #[test]
    fn udc_agreement_breaks_tie_between_alias_hits() {
        let s = make_subset(vec![
            e("Q900002", "physics", &["target"], Some("53")),
            e("Q900001", "chemistry", &["target"], Some("54")),
        ]);
        let d = resolve(&["target".to_string()], "54", &s).unwrap();
        assert_eq!(d.qid, "Q900001");
    }

    #[test]
    fn smaller_qid_wins_final_tie_break() {
        let s = make_subset(vec![
            e("Q900005", "alpha", &[], Some("54")),
            e("Q900003", "alpha", &[], Some("54")),
        ]);
        let d = resolve(&["alpha".to_string()], "54", &s).unwrap();
        assert_eq!(d.qid, "Q900003");
    }

    #[test]
    fn determinism_across_repeated_calls() {
        let s = make_subset(vec![e(
            "Q900001",
            "chemistry",
            &["chem"],
            Some("54"),
        )]);
        let a = resolve(&["chemistry".to_string()], "54", &s);
        let b = resolve(&["chemistry".to_string()], "54", &s);
        assert_eq!(a, b);
    }

    #[test]
    fn monotonicity_adding_matching_token_preserves_winner() {
        let s = make_subset(vec![e(
            "Q900001",
            "chemistry",
            &["chem", "molecules"],
            Some("54"),
        )]);
        let single = resolve(
            &["chemistry".to_string()],
            "54",
            &s,
        )
        .unwrap();
        let multi = resolve(
            &["chemistry".to_string(), "molecules".to_string()],
            "54",
            &s,
        )
        .unwrap();
        assert_eq!(single.qid, multi.qid);
        assert!(multi.alias_hits >= single.alias_hits);
    }
}
