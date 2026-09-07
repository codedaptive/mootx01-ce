//! Pipeline-p2 categorizer stage. Twin of Swift
//! `GeniusLocusKit/Brain/EnrichmentStage.swift` — see that file and
//! DECISION_DENSE_LANE_ENRICHMENT for the design and measured rationale.
//! Deterministic end to end (HMM word-class baseline, bundled FDC canon).
//!
//! Schema 19: `facts(content)` returns the bare pair list stored in the
//! `ssc_facts` column; `enrichment_trailer` renders the same pairs in the
//! grammar-v1 `(*[ … ]*)` trailer format.

// Grammar-v1 trailer delimiters — used by enrichment_trailer only.
// The BM25 supplement path reads from ssc_facts directly (no scanning).
const TRAILER_OPEN: &str = "(*[";
const TRAILER_CLOSE: &str = "]*)";

/// At most this many facts per trailer (Swift `EnrichmentStage.maxFacts`).
pub const ENRICHMENT_MAX_FACTS: usize = 6;

/// Nouns shorter than this never anchor (Swift `minNounLength`).
pub(crate) const MIN_NOUN_LENGTH: usize = 3;

/// Function words, conversational fillers, and evaluative adjectives the
/// word-class baseline sometimes admits as nouns. Pinned identically to the
/// Swift twin (see `Tests/Fixtures/ssc_stoplist.json`); extending it bumps
/// the pipeline version.
/// Schema 19: evaluative adjectives added: good, great, nice, sounds, plan, time, new.
/// Measurement: "entity: good" ×1,077 was the most common wing fact before this stoplist.
pub(crate) const STOPWORDS: [&str; 55] = [
    // function words
    "the", "and", "but", "for", "nor", "not", "you", "your", "our", "their",
    "his", "her", "its", "they", "them", "this", "that", "these", "those",
    "was", "were", "are", "been", "being", "have", "has", "had", "with",
    "from", "into", "about", "some", "any", "all", "each", "what", "which",
    "who", "how", "when", "where", "why",
    // conversational fillers
    "yeah", "yes", "okay", "hey", "wow", "guess",
    // evaluative adjectives / generic nouns (schema 19, measured corpus junk)
    "good", "great", "nice", "sounds", "plan", "time", "new",
];

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
/// Longest phrase length attempted by the multi-word pre-pass.
pub(crate) const MAX_PHRASE_WORDS: usize = 5;

pub fn enrichment_trailer(content: &str) -> String {
    let mut facts: Vec<(&'static str, String)> = Vec::new();
    let mut seen_values: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut seen_nouns: std::collections::HashSet<String> = std::collections::HashSet::new();

    // MULTI-WORD ENTITY PRE-PASS (p2.2): greedy longest-match against the
    // vendored multi-word labels; matched tokens are consumed so the
    // single-token pass never re-anchors phrase fragments. Twin of Swift.
    let tokens: Vec<String> = content
        .split(|c: char| !c.is_alphabetic())
        .filter(|t| !t.is_empty())
        .map(|t| t.to_lowercase())
        .collect();
    let mut consumed: std::collections::HashSet<usize> = std::collections::HashSet::new();
    let mut i = 0;
    while i < tokens.len() && facts.len() < ENRICHMENT_MAX_FACTS {
        let mut matched = false;
        let mut n = MAX_PHRASE_WORDS.min(tokens.len() - i);
        while n >= 2 {
            let phrase = tokens[i..i + n].join(" ");
            if let Some(qid) = lattice_lib::qid_facts::qid_for_phrase(&phrase) {
                for k in i..i + n {
                    consumed.insert(k);
                }
                if seen_values.insert(format!("entity:{phrase}")) {
                    facts.push(("entity", phrase.clone()));
                }
                if facts.len() < ENRICHMENT_MAX_FACTS {
                    if let Some(country) = lattice_lib::qid_facts::country_label(qid) {
                        let country = grammar_safe(country);
                        if facts.len() < ENRICHMENT_MAX_FACTS
                            && seen_values.insert(format!("place:{phrase}"))
                        {
                            facts.push(("place", phrase.clone()));
                        }
                        if facts.len() < ENRICHMENT_MAX_FACTS
                            && seen_values.insert(format!("country:{country}"))
                        {
                            facts.push(("country", country));
                        }
                    }
                }
                if facts.len() < ENRICHMENT_MAX_FACTS {
                    if let Some(parent) = lattice_lib::qid_closure::ancestors(qid).first() {
                        if let Some(kind) = lattice_lib::qid_facts::label(parent) {
                            let kind = grammar_safe(kind);
                            if seen_values.insert(format!("kind:{kind}")) {
                                facts.push(("kind", kind));
                            }
                        }
                    }
                }
                i += n;
                matched = true;
                break;
            }
            n -= 1;
        }
        if !matched {
            i += 1;
        }
    }

    let mut token_index_iter = 0usize;
    for raw in content.split(|c: char| !c.is_alphabetic()) {
        if raw.is_empty() {
            continue;
        }
        let this_index = token_index_iter;
        token_index_iter += 1;
        if consumed.contains(&this_index) {
            continue;
        }
        if facts.len() >= ENRICHMENT_MAX_FACTS {
            break;
        }
        let token = raw.to_lowercase();
        if token.chars().count() < MIN_NOUN_LENGTH
            || STOPWORDS.contains(&token.as_str())
            || seen_nouns.contains(&token)
            || lattice_lib::word_class_table::word_class_no_record(&token) != lattice_lib::WordClass::Noun
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
        // Wikidata property subset (DECISION v0.2): when the anchor carries
        // a Q-ID, the vendored facts beat the FDC frame — `kind` from the
        // first taxonomic ancestor's label, `place` + `country` from P17.
        // The FDC frame label remains the `fdc` fact and the kind fallback.
        let mut kind_emitted = false;
        if let Some(qid) = anchor.wikidata_qid.as_deref().filter(|q| !q.is_empty()) {
            if facts.len() < ENRICHMENT_MAX_FACTS {
                if let Some(country) = lattice_lib::qid_facts::country_label(qid) {
                    let country = grammar_safe(country);
                    if seen_values.insert(format!("place:{token}")) {
                        facts.push(("place", token.clone()));
                    }
                    if facts.len() < ENRICHMENT_MAX_FACTS
                        && seen_values.insert(format!("country:{country}"))
                    {
                        facts.push(("country", country));
                    }
                }
            }
            if facts.len() < ENRICHMENT_MAX_FACTS {
                if let Some(parent) = lattice_lib::qid_closure::ancestors(qid).first() {
                    if let Some(kind) = lattice_lib::qid_facts::label(parent) {
                        let kind = grammar_safe(kind);
                        if seen_values.insert(format!("kind:{kind}")) {
                            facts.push(("kind", kind));
                            kind_emitted = true;
                        }
                    }
                }
            }
        }
        if facts.len() < ENRICHMENT_MAX_FACTS {
            if let Some(label) = lattice_lib::fdc_runtime::Fdc::label(&anchor.code) {
                let label = grammar_safe(&label);
                if seen_values.insert(format!("fdc:{label}")) {
                    facts.push(("fdc", label));
                }
            }
        }
        if !kind_emitted && facts.len() < ENRICHMENT_MAX_FACTS {
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

/// Returns the bare comma-separated pair list for the `drawers.ssc_facts`
/// column (schema 19), or `None` when no facts can be derived. Twin of Swift
/// `EnrichmentStage.facts(forContent:)`.
///
/// Output format: `"entity: louvre, place: paris"` — no grammar-v1 delimiters.
/// Stop list applied: STOPWORDS blocks function words and evaluative adjectives.
/// Proper-noun preference: tokens that appear capitalised in the source text
/// are ranked before lowercase nouns (visited before the others in the
/// single-token pass below).
pub fn facts(content: &str) -> Option<String> {
    let mut pairs: Vec<(&'static str, String)> = Vec::new();
    let mut seen_values: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Collect tokens with a flag indicating whether they were capitalised in the source.
    let mut indexed_tokens: Vec<(String, bool)> = content
        .split(|c: char| !c.is_alphabetic())
        .filter(|t| !t.is_empty())
        .map(|t| {
            let is_cap = t.chars().next().map(|c| c.is_uppercase()).unwrap_or(false);
            (t.to_lowercase(), is_cap)
        })
        .collect();

    // Proper-noun preference: process capitalised tokens before lowercase ones.
    indexed_tokens.sort_by_key(|(_, is_cap)| if *is_cap { 0 } else { 1 });

    for (token, _) in &indexed_tokens {
        if pairs.len() >= ENRICHMENT_MAX_FACTS {
            break;
        }
        if token.chars().count() < MIN_NOUN_LENGTH
            || STOPWORDS.contains(&token.as_str())
            || seen_values.contains(&format!("entity:{token}"))
            || lattice_lib::word_class_table::word_class_no_record(token)
                != lattice_lib::WordClass::Noun
        {
            continue;
        }
        let anchor = eidetic_lib::lookup(token);
        if anchor.code.is_empty() || anchor.code == "000" {
            continue;
        }
        if seen_values.insert(format!("entity:{token}")) {
            pairs.push(("entity", token.clone()));
        }
        if pairs.len() < ENRICHMENT_MAX_FACTS {
            if let Some(qid) = &anchor.wikidata_qid {
                if !qid.is_empty() {
                    if let Some(country) = lattice_lib::qid_facts::country_label(qid) {
                        let country = grammar_safe(&country);
                        if seen_values.insert(format!("place:{token}")) {
                            pairs.push(("place", token.clone()));
                        }
                        if pairs.len() < ENRICHMENT_MAX_FACTS
                            && seen_values.insert(format!("country:{country}"))
                        {
                            pairs.push(("country", country));
                        }
                    }
                }
            }
        }
    }

    if pairs.is_empty() {
        return None;
    }
    Some(
        pairs
            .iter()
            .map(|(l, v)| format!("{l}: {v}"))
            .collect::<Vec<_>>()
            .join(", "),
    )
}

/// Query-side lattice anchoring (W2.5 Track S): derives the ONE §8.3 lattice
/// anchor a recall query is "about", using the SAME selection rules as
/// `enrichment_trailer` (multi-word phrase pre-pass, then the first anchoring
/// noun) so the query and the drawer sides anchor in the same code space.
/// Returns `(udc_code, qid)` — udc_code is the drawer-side FDC code ("" for
/// phrase anchors, which carry no FDC code); qid is "" when the anchoring
/// term has none. Unanchorable query → ("", "") and the lattice reduction
/// signal stays neutral. Mirrors Swift `QueryLatticeAnchor.derive(from:)`.
pub fn query_anchor(text: &str) -> (String, String) {
    let tokens: Vec<String> = text
        .split(|c: char| !c.is_alphabetic())
        .filter(|t| !t.is_empty())
        .map(|t| t.to_lowercase())
        .collect();

    // Multi-word phrase pass — the first phrase hit anchors the query.
    let mut i = 0usize;
    while i < tokens.len() {
        let mut n = MAX_PHRASE_WORDS.min(tokens.len() - i);
        while n >= 2 {
            let phrase = tokens[i..i + n].join(" ");
            if let Some(qid) = lattice_lib::qid_facts::qid_for_phrase(&phrase) {
                return (String::new(), qid.to_string());
            }
            n -= 1;
        }
        i += 1;
    }

    // Single-token pass — the first anchoring noun wins.
    for token in &tokens {
        if token.chars().count() < MIN_NOUN_LENGTH
            || STOPWORDS.contains(&token.as_str())
            || lattice_lib::word_class_table::word_class_no_record(token) != lattice_lib::WordClass::Noun
        {
            continue;
        }
        let anchor = eidetic_lib::lookup(token);
        if anchor.code.is_empty() || anchor.code == "000" {
            continue;
        }
        return (anchor.code, anchor.wikidata_qid.unwrap_or_default());
    }
    (String::new(), String::new())
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
            // Trailer still uses grammar-v1 delimiters (ContextDistillLib path).
            assert!(t.starts_with(" (*[ "));
            assert!(t.ends_with(" ]*)"));
        }
        // Determinism: same input, same output.
        assert_eq!(t, enrichment_trailer(content));
    }

    #[test]
    fn query_anchor_phrase_first() {
        // Mirrors the Swift QueryLatticeAnchor pins.
        let (udc, qid) = query_anchor("Where is Rio de Janeiro?");
        assert_eq!(qid, "Q8678");
        assert_eq!(udc, "");
    }

    /// GOLDEN PIN (M4 — cross-port conformance vector).
    ///
    /// Same input/output asserted in both ports:
    ///   Swift: `EnrichmentStageTests.QueryLatticeAnchorTests.m4GoldenPin()`
    ///   Rust:  this test — `query_anchor_golden_pin_m4`
    ///
    /// "Where is Rio de Janeiro?" → QID Q8678, no FDC code.
    /// The phrase "rio de janeiro" is in QIDFacts and anchors via the
    /// phrase-first pass before any single-noun pass is attempted.
    /// Neither port may change this output without cross-port re-pinning.
    #[test]
    fn query_anchor_golden_pin_m4() {
        let (udc, qid) = query_anchor("Where is Rio de Janeiro?");
        assert_eq!(qid, "Q8678", "M4 golden pin: expected QID Q8678 for 'rio de janeiro'");
        assert_eq!(udc, "", "M4 golden pin: phrase-anchored query carries no FDC code");
        // Verify the anchor is non-empty (would be caught above, but explicit for clarity).
        assert!(!qid.is_empty(), "M4 golden pin: QID must be non-empty");
    }

    #[test]
    fn query_anchor_first_noun() {
        // Selection-logic pin without pinning HMM word classes: compute the
        // first token that satisfies the categorizer's own predicate chain,
        // then assert query_anchor picked exactly that token's anchor.
        // Mirrors the Swift QueryLatticeAnchor pin.
        let text = "tell me about the painting guitar camera";
        let tokens: Vec<String> = text
            .split(|c: char| !c.is_alphabetic())
            .filter(|t| !t.is_empty())
            .map(|t| t.to_lowercase())
            .collect();
        let expected = tokens
            .iter()
            .filter(|t| t.chars().count() >= MIN_NOUN_LENGTH && !STOPWORDS.contains(&t.as_str()))
            .filter(|t| lattice_lib::word_class_table::word_class_no_record(t) == lattice_lib::WordClass::Noun)
            .map(|t| eidetic_lib::lookup(t))
            .find(|a| !a.code.is_empty() && a.code != "000");
        let (udc, qid) = query_anchor(text);
        match &expected {
            Some(a) => {
                assert_eq!(udc, a.code);
                assert_eq!(qid, a.wikidata_qid.clone().unwrap_or_default());
            }
            None => assert!(udc.is_empty() && qid.is_empty()),
        }
        // The fixture is chosen so at least one noun anchors — if the canon
        // ever stops anchoring all three, this pin must be re-fixtured.
        assert!(expected.is_some());
    }

    #[test]
    fn query_anchor_unanchorable_is_empty() {
        let (udc, qid) = query_anchor("the and was were yeah okay");
        assert!(udc.is_empty() && qid.is_empty());
    }

    #[test]
    fn stopwords_never_anchor() {
        let t = enrichment_trailer("The idea is that they have been with you and them about it.");
        assert!(!t.contains("entity: the"));
        assert!(!t.contains("entity: they"));
    }

    #[test]
    fn multi_word_anchoring() {
        let t = enrichment_trailer("We got back from an awesome trip to Rio de Janeiro yesterday.");
        assert!(t.contains("entity: rio de janeiro"), "{t}");
        assert!(t.contains("country: brazil"), "{t}");
        assert!(!t.contains("entity: rio,") && !t.contains("entity: janeiro"));
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

    // Schema 19 tests for facts() API (ssc_facts column path)
    #[test]
    fn facts_place_carries_country() {
        // The word-class fallback anchors the capitalised token through its QID and
        // emits the country fact after the place fact (Swift twin: same path, reached
        // only when NLTagger finds no named entity).
        let f = facts("We got back from an awesome trip to Rio de Janeiro yesterday.").unwrap_or_default();
        assert!(f.contains("place: rio"), "{f}");
        assert!(f.contains("country: brazil"), "{f}");
    }

    #[test]
    fn facts_evaluative_adjectives_blocked() {
        // Failure mode: stop list missing "good" → "entity: good" appears.
        let content = "We met Sarah at the Louvre on Tuesday, it was good";
        let f = facts(content);
        if let Some(f) = f {
            assert!(!f.contains("entity: good"), "evaluative adjective leaked: {f}");
        }
    }

    #[test]
    fn facts_returns_bare_pairs_no_delimiters() {
        // facts() must never include (*[ ]*) delimiters — those belong to enrichment_trailer.
        let content = "We visited the Louvre in Paris last Tuesday.";
        if let Some(f) = facts(content) {
            assert!(!f.contains("(*["), "delimiter leaked into facts: {f}");
            assert!(!f.contains("]*)"), "delimiter leaked into facts: {f}");
        }
    }

    #[test]
    fn facts_none_when_nothing_anchors() {
        assert_eq!(facts(""), None);
        assert_eq!(facts("ok so um yeah"), None);
    }
}
