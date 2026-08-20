//! Pipeline-p2 categorizer stage. Twin of Swift
//! `GeniusLocusKit/Brain/EnrichmentStage.swift` — see that file and
//! DECISION_DENSE_LANE_ENRICHMENT for the design and measured rationale.
//! Deterministic end to end (HMM word-class baseline, bundled FDC canon).

use corpus_kit::trailer_lexical_supplement::{TRAILER_CLOSE, TRAILER_OPEN};

/// At most this many facts per trailer (Swift `EnrichmentStage.maxFacts`).
pub const ENRICHMENT_MAX_FACTS: usize = 6;

/// Nouns shorter than this never anchor (Swift `minNounLength`).
const MIN_NOUN_LENGTH: usize = 3;

/// Lowercases a frame label and truncates at the first comma (the trailer
/// grammar separates PAIRS with commas). Twin of Swift `grammarSafe`.
fn grammar_safe(label: &str) -> String {
    label
        .to_lowercase()
        .split(',')
        .next()
        .unwrap_or("")
        .trim()
        .to_string()
}

/// Builds the grammar-v1 trailer for an item's verbatim content, or ""
/// when no noun anchors. Twin of Swift `EnrichmentStage.trailer(forContent:)`.
pub fn enrichment_trailer(content: &str) -> String {
    let mut facts: Vec<(&'static str, String)> = Vec::new();
    let mut seen_values: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut seen_nouns: std::collections::HashSet<String> = std::collections::HashSet::new();

    for raw in content.split(|c: char| !c.is_alphabetic()) {
        if facts.len() >= ENRICHMENT_MAX_FACTS {
            break;
        }
        let token = raw.to_lowercase();
        if token.chars().count() < MIN_NOUN_LENGTH
            || seen_nouns.contains(&token)
            || lattice_lib::word_class_table::word_class(&token) != lattice_lib::WordClass::Noun
        {
            continue;
        }
        seen_nouns.insert(token.clone());

        let anchor = eidetic_lib::lookup(&token);
        // Root-class anchors ("000" — general works) are junk facts:
        // filler tokens like "yeah" resolve there. Skip them.
        if anchor.code.is_empty() || anchor.code == "000" {
            continue;
        }
        if seen_values.insert(format!("entity:{token}")) {
            facts.push(("entity", token.clone()));
        }
        if facts.len() < ENRICHMENT_MAX_FACTS {
            if let Some(label) = lattice_lib::fdc_runtime::Fdc::label(&anchor.code) {
                let label = grammar_safe(&label);
                if seen_values.insert(format!("fdc:{label}")) {
                    facts.push(("fdc", label));
                }
            }
        }
        if facts.len() < ENRICHMENT_MAX_FACTS {
            if let Some(parent) = lattice_lib::fdc_runtime::Fdc::ancestors(&anchor.code).first() {
                if let Some(kind) = lattice_lib::fdc_runtime::Fdc::label(parent) {
                    let kind = grammar_safe(&kind);
                    if seen_values.insert(format!("kind:{kind}")) {
                        facts.push(("kind", kind));
                    }
                }
            }
        }
    }

    if facts.is_empty() {
        return String::new();
    }
    let body = facts
        .iter()
        .map(|(l, v)| format!("{l}: {v}"))
        .collect::<Vec<_>>()
        .join(", ");
    format!(" {TRAILER_OPEN} {body} {TRAILER_CLOSE}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_when_nothing_anchors() {
        assert_eq!(enrichment_trailer(""), "");
        assert_eq!(enrichment_trailer("ok so um yeah"), "");
    }

    #[test]
    fn trailer_shape_and_determinism() {
        let content = "I finally finished my first full screenplay and printed it last Friday.";
        let t = enrichment_trailer(content);
        if !t.is_empty() {
            assert!(t.starts_with(" (*[ "));
            assert!(t.ends_with(" ]*)"));
            assert_ne!(
                corpus_kit::trailer_lexical_supplement::lexical_supplement(
                    Some(&format!("body.{t}"))),
                "");
        }
        assert_eq!(t, enrichment_trailer(content));
    }

    #[test]
    fn facts_capped_and_deduplicated() {
        let long = ["painting music travel robot guitar camera festival"; 5].join(" ");
        let t = enrichment_trailer(&long);
        if !t.is_empty() {
            let inner = &t[" (*[ ".len()..t.len() - " ]*)".len()];
            let pairs: Vec<&str> = inner.split(',').map(str::trim).collect();
            assert!(pairs.len() <= ENRICHMENT_MAX_FACTS);
            let set: std::collections::HashSet<&str> = pairs.iter().copied().collect();
            assert_eq!(set.len(), pairs.len());
        }
    }
}
