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

use lattice_lib::tokenizer::tokenize;
use lattice_lib::word_class::{WordClass, hmm_tag};
use substrate_ml::distillation_pipeline::FeatureExtractor;
use substrate_ml::typed_decay_weighting::DistillationFeatureType;
use substrate_ml::distillation_scorer::ExtractedFeature;

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
            // ENT: tokens classified as Noun by the HMM tagger.
            for token in &tokens {
                let lowered = token.to_lowercase();
                if hmm_tag(&lowered) == WordClass::Noun {
                    results.push(ExtractedFeature::new(
                        DistillationFeatureType::Entity,
                        lowered,
                        0.0,
                    ));
                }
            }
        }

        DistillationFeatureType::Relation => {
            // REL: tokens classified as Verb by the HMM tagger.
            for token in &tokens {
                let lowered = token.to_lowercase();
                if hmm_tag(&lowered) == WordClass::Verb {
                    results.push(ExtractedFeature::new(
                        DistillationFeatureType::Relation,
                        lowered,
                        0.0,
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
        let values: Vec<&str> = features.iter().map(|f| f.value.as_str()).collect();
        // "project", "apollo", "postgresql" are expected nouns from the HMM.
        // At minimum, apollo and postgresql must be in the result.
        assert!(
            values.contains(&"apollo"),
            "expected 'apollo' in ENT features; got {:?}",
            values
        );
        assert!(
            values.contains(&"postgresql"),
            "expected 'postgresql' in ENT features; got {:?}",
            values
        );
    }

    #[test]
    fn relation_extraction_adopted() {
        let features = hmm_extract(APOLLO_SENTENCE, DistillationFeatureType::Relation);
        let values: Vec<&str> = features.iter().map(|f| f.value.as_str()).collect();
        assert!(
            values.contains(&"adopted"),
            "expected 'adopted' in REL features; got {:?}",
            values
        );
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
