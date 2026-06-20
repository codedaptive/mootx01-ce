// hmm_feature_extractor.rs
//
// Production DistillationPipeline feature extractor backed by the deterministic
// HMM/Viterbi tagger from lattice-lib.
//
// Mirrors Swift `NeuronKit.hmmFeatureExtractor` in Lenses/HMMFeatureExtractor.swift.
// Extraction rules are byte-identical across ports — all rule logic is a pure
// character-class scan or HMM call (no regex, no wall-clock, no randomness):
//
//   ENT (entity):    noun-tagged tokens via lattice_lib::word_class::hmm_tag
//   REL (relation):  verb-tagged tokens via lattice_lib::word_class::hmm_tag
//   NUM (numerical): tokens where every byte is an ASCII decimal digit (0x30–0x39)
//   TMP (temporal):  tokens matching a 4-digit year (YYYY) or ISO-8601 date
//                    (YYYY-MM-DD), detected by a pure byte-class scan
//
// Cross-port parity:
//   - Tokenisation via lattice_lib::tokenizer::tokenize (UAX #29, conformance-gated
//     with the Swift Tokenizer.tokenize).
//   - Noun/verb tagging via lattice_lib::word_class::hmm_tag, which reads the SAME
//     HMMTaggerModel.json artifact as the Swift HMMTagger.tag. Output is
//     byte-identical (HMM uses integer Viterbi; no float rounding).
//   - docFrequency is 0.0 on every emitted feature — the pipeline sets the real
//     value from the incidence matrix (Stage 2).
//
// Layer discipline: pure function, no I/O, no state, no substrate.

use lattice_lib::stemmer::stem;
use lattice_lib::tokenizer::tokenize;
use lattice_lib::word_class::{WordClass, hmm_tag};
use substrate_ml::distillation_pipeline::FeatureExtractor;
use substrate_ml::typed_decay_weighting::DistillationFeatureType;
use substrate_ml::distillation_scorer::ExtractedFeature;

/// Function-word stop list for distillation feature extraction. Tokens in this
/// set are NEVER emitted as ENT/REL features: they recur across an item's
/// sentences (so they clear the recurrence threshold) but carry no topical
/// signal — they are scaffolding, not "the words that matter". The HMM tagger
/// tags many of them as nouns ("the"/"to"/"by" came back Noun), so the filter
/// is applied independently of the tag.
///
/// CONFORMANCE: this exact set is mirrored byte-for-byte from the Swift port
/// (`HMMFeatureExtractor.swift` `distillationStopwords`). Keep the two in
/// lockstep — a divergence breaks cross-port factoid parity. The membership
/// test uses the lowercased surface token.
pub const DISTILLATION_STOPWORDS: &[&str] = &[
    // articles & determiners
    "a", "an", "the", "this", "that", "these", "those", "each", "every",
    "all", "any", "some", "no", "such", "both", "either", "neither",
    "much", "many", "more", "most", "other", "another", "same", "own",
    // prepositions
    "of", "in", "on", "at", "to", "for", "with", "by", "from", "as",
    "into", "onto", "upon", "about", "above", "below", "under", "over",
    "between", "among", "through", "during", "before", "after", "since",
    "until", "without", "within", "against", "toward", "towards", "across",
    "behind", "beyond", "near",
    // conjunctions
    "and", "or", "but", "nor", "so", "yet", "if", "then", "than",
    "because", "although", "though", "while", "whereas", "unless",
    // pronouns
    "i", "me", "my", "mine", "we", "us", "our", "ours", "you", "your",
    "yours", "he", "him", "his", "she", "her", "hers", "it", "its",
    "they", "them", "their", "theirs", "who", "whom", "whose", "which",
    "what",
    // be / have / do / modals
    "is", "am", "are", "was", "were", "be", "been", "being", "has",
    "have", "had", "having", "do", "does", "did", "doing", "will",
    "would", "shall", "should", "can", "could", "may", "might", "must",
    // common adverbs / particles
    "not", "very", "too", "also", "just", "only", "even", "still",
    "again", "ever", "never", "now", "here", "there", "when", "where",
    "why", "how", "once", "up", "down", "out", "off", "back",
];

/// Returns true iff `lower` (an already-lowercased token) is a distillation
/// stopword. Linear scan over the fixed set — the set is small and the scan
/// runs once per token; mirrors Swift's `Set.contains`.
fn is_distillation_stopword(lower: &str) -> bool {
    DISTILLATION_STOPWORDS.contains(&lower)
}

/// Returns a FeatureExtractor function pointer backed by the deterministic
/// HMM/Viterbi tagger. This is the production extractor — identical mapping
/// rules as the Swift `NeuronKit.hmmFeatureExtractor`.
///
/// Use this constant as the `extract_features` argument to
/// `DistillationPipeline::run` or `distill_cluster` to engage the production
/// semantic extraction path on Rust.
pub fn hmm_feature_extractor() -> FeatureExtractor {
    hmm_extract
}

/// Inner extraction function (named so it can be stored as a function pointer).
///
/// Tokenises `content` via UAX #29 word-boundary segmentation, lowercases each
/// token, then applies feature-type–specific rules:
///
/// - ENT: noun-tagged tokens (HMM says Noun)
/// - REL: verb-tagged tokens (HMM says Verb)
/// - NUM: tokens where every byte is an ASCII decimal digit
/// - TMP: 4-digit year tokens or YYYY-MM-DD date tokens
fn hmm_extract(
    content: &str,
    feature_type: DistillationFeatureType,
) -> Vec<ExtractedFeature> {
    let tokens = tokenize(content);
    if tokens.is_empty() {
        return vec![];
    }

    let mut results = Vec::new();

    match feature_type {
        DistillationFeatureType::Entity => {
            // ENT: tokens classified as Noun by the HMM tagger, minus function
            // words. Function words recur but are scaffolding, and the HMM tagger
            // mis-tags several of them ("the"/"by") as nouns, so drop them first.
            for token in &tokens {
                let lowered = token.to_lowercase();
                if is_distillation_stopword(&lowered) {
                    continue;
                }
                if hmm_tag(&lowered) == WordClass::Noun {
                    // value = Snowball stem (groups migration/migrations into one
                    // df + one fingerprint bit); display = surface form for the
                    // factoid prose. The stemmer is bit-identical Swift↔Rust.
                    results.push(ExtractedFeature::new_with_display(
                        DistillationFeatureType::Entity,
                        stem(&lowered),
                        0.0,
                        lowered,
                    ));
                }
            }
        }

        DistillationFeatureType::Relation => {
            // REL: tokens classified as Verb by the HMM tagger, minus function words.
            for token in &tokens {
                let lowered = token.to_lowercase();
                if is_distillation_stopword(&lowered) {
                    continue;
                }
                if hmm_tag(&lowered) == WordClass::Verb {
                    // value = stem (unifies migrate/migrates); display = surface.
                    results.push(ExtractedFeature::new_with_display(
                        DistillationFeatureType::Relation,
                        stem(&lowered),
                        0.0,
                        lowered,
                    ));
                }
            }
        }

        DistillationFeatureType::Numerical => {
            // NUM: tokens where every byte is an ASCII decimal digit (0x30–0x39).
            // Pure byte-class scan — identical to the Swift isDigitOnly check.
            for token in &tokens {
                if !token.is_empty() && token.bytes().all(|b| b >= b'0' && b <= b'9') {
                    results.push(ExtractedFeature::new(
                        DistillationFeatureType::Numerical,
                        token.clone(),
                        0.0,
                    ));
                }
            }
        }

        DistillationFeatureType::Temporal => {
            // TMP: tokens that are a 4-digit year (YYYY — all ASCII digits, length 4).
            //
            // Note on ISO dates: the UAX #29 word-boundary tokenizer (unicode-segmentation
            // crate) splits on hyphens, so "2021-03-15" becomes ["2021", "03", "15"].
            // The year component "2021" is classified TMP via the 4-digit check;
            // sub-components "03" and "15" (2-digit) are not classified as TMP.
            // This is deterministic and consistent with the Swift port.
            //
            // Pure byte-class scan — no regex, no date parsing, no wall-clock.
            for token in &tokens {
                if is_year(token) {
                    results.push(ExtractedFeature::new(
                        DistillationFeatureType::Temporal,
                        token.clone(),
                        0.0,
                    ));
                }
            }
        }
    }

    results
}

/// Returns true iff `token` is a 4-digit year string (all ASCII digits, length 4).
///
/// Byte-identical to the Swift `isYear` helper in HMMFeatureExtractor.swift.
fn is_year(token: &str) -> bool {
    let bytes = token.as_bytes();
    bytes.len() == 4 && bytes.iter().all(|&b| b >= b'0' && b <= b'9')
}

// Note: is_iso_date is not implemented. The UAX #29 word-boundary tokenizer
// (unicode-segmentation) splits "2021-03-15" into ["2021", "03", "15"] —
// hyphenated date strings are never presented as single tokens. Year components
// are classified via is_year. This is correct and conformant with the Swift port.

#[cfg(test)]
mod tests {
    use super::*;

    // Verify the "Project Apollo adopted PostgreSQL in 2021" canonical fixture:
    //   ENT -> apollo, postgresql
    //   REL -> adopted
    //   TMP -> 2021
    //   NUM -> (none — 2021 is all digits but is also classified TMP, not NUM,
    //            because is_year fires first in TMP branch; NUM branch is separate
    //            and would also match "2021", but in NUM mode that year token
    //            also satisfies is_digit_only — so 2021 would appear in NUM too
    //            if called with that featureType. The pipeline calls each type
    //            separately; "2021" appears as both NUM and TMP features.)
    const APOLLO_SENTENCE: &str = "Project Apollo adopted PostgreSQL in 2021";

    #[test]
    fn entity_extraction_apollo() {
        let features = hmm_extract(APOLLO_SENTENCE, DistillationFeatureType::Entity);
        // value is the stem; display is the surface form. Assert on the surface
        // forms (display) — "apollo" and "postgresql" must appear as entities.
        let displays: Vec<&str> = features.iter().map(|f| f.display.as_str()).collect();
        assert!(
            displays.contains(&"apollo"),
            "expected 'apollo' surface in ENT features; got {:?}",
            displays
        );
        assert!(
            displays.contains(&"postgresql"),
            "expected 'postgresql' surface in ENT features; got {:?}",
            displays
        );
        // Every feature's value must equal the Snowball stem of its display.
        for f in &features {
            assert_eq!(
                f.value,
                stem(&f.display),
                "value must be the stem of display ({})",
                f.display
            );
        }
    }

    #[test]
    fn relation_extraction_adopted() {
        let features = hmm_extract(APOLLO_SENTENCE, DistillationFeatureType::Relation);
        let displays: Vec<&str> = features.iter().map(|f| f.display.as_str()).collect();
        assert!(
            displays.contains(&"adopted"),
            "expected 'adopted' surface in REL features; got {:?}",
            displays
        );
        // "adopted" stems to "adopt"; the grouping value is the stem.
        let adopted = features.iter().find(|f| f.display == "adopted").unwrap();
        assert_eq!(adopted.value, stem("adopted"));
    }

    // Stopword filtering: function words tagged Noun/Verb by the HMM are dropped
    // from ENT/REL features. "the", "to", "by" are common HMM-noun mis-tags.
    #[test]
    fn stopwords_dropped_from_entities() {
        // Every distillation stopword must be filtered regardless of HMM tag.
        let text = "the database in the system was migrated by the team to the cloud";
        let features = hmm_extract(text, DistillationFeatureType::Entity);
        for f in &features {
            assert!(
                !is_distillation_stopword(&f.display),
                "stopword '{}' must not appear as an ENT feature",
                f.display
            );
        }
    }

    #[test]
    fn stopwords_dropped_from_relations() {
        let text = "the team has to migrate and they will be doing it by friday";
        let features = hmm_extract(text, DistillationFeatureType::Relation);
        for f in &features {
            assert!(
                !is_distillation_stopword(&f.display),
                "stopword '{}' must not appear as a REL feature",
                f.display
            );
        }
    }

    // Stemming groups morphological variants: migration/migrations share a stem,
    // so the value (grouping key) is identical while the display surfaces differ.
    #[test]
    fn morphological_variants_share_stem_value() {
        // Force the same lemma in two surface forms through the noun path.
        // Use a sentence that the HMM tags the target tokens as nouns.
        let a = hmm_extract("the migration finished", DistillationFeatureType::Entity);
        let b = hmm_extract("the migrations finished", DistillationFeatureType::Entity);
        let mig_a = a.iter().find(|f| f.display == "migration");
        let mig_b = b.iter().find(|f| f.display == "migrations");
        if let (Some(fa), Some(fb)) = (mig_a, mig_b) {
            assert_eq!(fa.value, fb.value, "migration/migrations must share one stem");
            assert_ne!(fa.display, fb.display, "surfaces must differ");
            assert_eq!(fa.value, stem("migration"));
        }
        // Independently assert the stemmer groups them (extractor-agnostic).
        assert_eq!(stem("migration"), stem("migrations"));
    }

    // The stopword constant must match the Swift set's element count exactly.
    // Swift `distillationStopwords` has the same words; the count is a cheap
    // byte-for-byte drift detector across the two ports.
    #[test]
    fn stopword_set_count_matches_swift() {
        // Count of words in HMMFeatureExtractor.swift `distillationStopwords`
        // (152 unique words, same spelling, same order).
        assert_eq!(DISTILLATION_STOPWORDS.len(), 152);
    }

    #[test]
    fn temporal_extraction_2021() {
        let features = hmm_extract(APOLLO_SENTENCE, DistillationFeatureType::Temporal);
        let values: Vec<&str> = features.iter().map(|f| f.value.as_str()).collect();
        assert!(
            values.contains(&"2021"),
            "expected '2021' in TMP features; got {:?}",
            values
        );
    }

    #[test]
    fn numerical_extraction_digit_token() {
        // "42" is a pure digit token — must be classified NUM.
        let features = hmm_extract("There were 42 issues found", DistillationFeatureType::Numerical);
        let values: Vec<&str> = features.iter().map(|f| f.value.as_str()).collect();
        assert!(
            values.contains(&"42"),
            "expected '42' in NUM features; got {:?}",
            values
        );
    }

    #[test]
    fn empty_content_returns_empty() {
        for ft in [
            DistillationFeatureType::Entity,
            DistillationFeatureType::Relation,
            DistillationFeatureType::Numerical,
            DistillationFeatureType::Temporal,
        ] {
            let features = hmm_extract("", ft);
            assert!(features.is_empty(), "empty content must produce no features for {:?}", ft);
        }
    }

    // is_year: boundary checks
    #[test]
    fn is_year_valid() {
        assert!(is_year("2021"));
        assert!(is_year("1999"));
        assert!(is_year("0000"));
    }

    #[test]
    fn is_year_invalid() {
        assert!(!is_year("21"));      // too short
        assert!(!is_year("20210"));   // too long
        assert!(!is_year("202A"));    // non-digit
        assert!(!is_year(""));
    }

    // ISO dates are split by the UAX #29 tokenizer — no is_iso_date tests here.
    // The year component (4-digit) is tested via is_year_* tests above.
    // See the note above the is_year function for the full explanation.

    // doc_frequency is 0 on every emitted feature (pipeline sets real value).
    #[test]
    fn doc_frequency_is_zero() {
        let features = hmm_extract(APOLLO_SENTENCE, DistillationFeatureType::Temporal);
        for f in &features {
            assert_eq!(
                f.doc_frequency, 0.0,
                "doc_frequency must be 0.0 from the extractor; pipeline sets the real value"
            );
        }
    }
}
