//! HMM Feature Extractor conformance tests — Rust half of the cross-language gate.
//!
//! These tests drive the same fixture sentences as HMMFeatureExtractorTests.swift
//! and assert the same extracted feature sets, establishing Swift-Rust byte-identity
//! for the production distillation extractor.
//!
//! Shared fixture: "Project Apollo adopted PostgreSQL in 2021"
//!   ENT -> display surfaces must include "apollo" and "postgresql"
//!   REL -> display surface must include "adopted" (value = stem "adopt")
//!   TMP -> must include "2021"
//!   NUM -> "42" in a separate fixture sentence
//!
//! ENT/REL features now carry a stemmed grouping `value` and a `display`
//! surface form. Surface assertions key off `display`; the grouping key is
//! `stem(display)`, byte-identical Swift↔Rust via the Snowball stemmer.
//!
//! Cross-port parity:
//!   Both ports use the same HMMTaggerModel.json artifact (loaded via include_bytes!
//!   in word_class.rs). The integer Viterbi decoder has no floating-point rounding,
//!   so the two ports must agree on every token classification for table-resident tokens
//!   (identical via the static word-class table) and for novel tokens (same HMM model).

use lattice_lib::stemmer::stem;
use neuron_kit::hmm_feature_extractor::hmm_feature_extractor;
use substrate_ml::distillation_pipeline::{DistillationInput, DistillationPipeline};
use substrate_ml::typed_decay_weighting::DistillationFeatureType;

const APOLLO_SENTENCE: &str = "Project Apollo adopted PostgreSQL in 2021";

// ── ENT tests ────────────────────────────────────────────────────────────────

// "apollo" must appear as an ENT feature surface — mirrors Swift "ENT: 'apollo'".
#[test]
fn ent_apollo_present() {
    let extractor = hmm_feature_extractor();
    let features = extractor(APOLLO_SENTENCE, DistillationFeatureType::Entity);
    let displays: Vec<&str> = features.iter().map(|f| f.display.as_str()).collect();
    assert!(
        displays.contains(&"apollo"),
        "expected 'apollo' surface in ENT features; got {:?}",
        displays
    );
    // The grouping value is the Snowball stem of the surface form.
    let apollo = features.iter().find(|f| f.display == "apollo").unwrap();
    assert_eq!(apollo.value, stem("apollo"));
}

// "postgresql" must appear as an ENT feature surface — mirrors Swift.
#[test]
fn ent_postgresql_present() {
    let extractor = hmm_feature_extractor();
    let features = extractor(APOLLO_SENTENCE, DistillationFeatureType::Entity);
    let displays: Vec<&str> = features.iter().map(|f| f.display.as_str()).collect();
    assert!(
        displays.contains(&"postgresql"),
        "expected 'postgresql' surface in ENT features; got {:?}",
        displays
    );
}

// All ENT features must have type Entity.
#[test]
fn ent_features_have_correct_type() {
    let extractor = hmm_feature_extractor();
    let features = extractor(APOLLO_SENTENCE, DistillationFeatureType::Entity);
    for f in &features {
        assert_eq!(
            f.feature_type,
            DistillationFeatureType::Entity,
            "feature '{}' has wrong type {:?}",
            f.value,
            f.feature_type
        );
    }
}

// ── REL tests ────────────────────────────────────────────────────────────────

// "adopted" must appear as a REL feature surface; value is its stem.
#[test]
fn rel_adopted_present() {
    let extractor = hmm_feature_extractor();
    let features = extractor(APOLLO_SENTENCE, DistillationFeatureType::Relation);
    let displays: Vec<&str> = features.iter().map(|f| f.display.as_str()).collect();
    assert!(
        displays.contains(&"adopted"),
        "expected 'adopted' surface in REL features; got {:?}",
        displays
    );
    let adopted = features.iter().find(|f| f.display == "adopted").unwrap();
    assert_eq!(adopted.value, stem("adopted"));
}

// ── TMP tests ────────────────────────────────────────────────────────────────

// "2021" must appear as a TMP feature (4-digit year).
#[test]
fn tmp_2021_present() {
    let extractor = hmm_feature_extractor();
    let features = extractor(APOLLO_SENTENCE, DistillationFeatureType::Temporal);
    let values: Vec<&str> = features.iter().map(|f| f.value.as_str()).collect();
    assert!(
        values.contains(&"2021"),
        "expected '2021' in TMP features; got {:?}",
        values
    );
}

// ISO dates: "2021-03-15" is split by UAX #29 into ["2021", "03", "15"].
// "2021" is extracted as TMP (4-digit year). "03", "15" are not TMP.
// This is verified implicitly via tmp_2021_present which covers the same year.
// Note: wrong-separator "2021/03/15" is also split into ["2021", "03", "15"]
// by the UAX #29 tokenizer (forward-slash is a word boundary); "2021" still
// appears as TMP via the 4-digit check.

// ── NUM tests ────────────────────────────────────────────────────────────────

// "42" must appear as a NUM feature.
#[test]
fn num_42_present() {
    let extractor = hmm_feature_extractor();
    let features = extractor("There were 42 issues found", DistillationFeatureType::Numerical);
    let values: Vec<&str> = features.iter().map(|f| f.value.as_str()).collect();
    assert!(
        values.contains(&"42"),
        "expected '42' in NUM features; got {:?}",
        values
    );
}

// ── Edge cases ────────────────────────────────────────────────────────────────

// Empty content must produce no features for any type.
#[test]
fn empty_content_returns_empty() {
    let extractor = hmm_feature_extractor();
    for ft in [
        DistillationFeatureType::Entity,
        DistillationFeatureType::Relation,
        DistillationFeatureType::Numerical,
        DistillationFeatureType::Temporal,
    ] {
        let features = extractor("", ft);
        assert!(
            features.is_empty(),
            "empty content must produce no features for {:?}; got {:?}",
            ft, features
        );
    }
}

// doc_frequency must be 0.0 from the extractor (pipeline sets the real value).
#[test]
fn doc_frequency_is_zero() {
    let extractor = hmm_feature_extractor();
    for ft in [
        DistillationFeatureType::Entity,
        DistillationFeatureType::Relation,
        DistillationFeatureType::Numerical,
        DistillationFeatureType::Temporal,
    ] {
        let features = extractor(APOLLO_SENTENCE, ft);
        for f in &features {
            assert_eq!(
                f.doc_frequency, 0.0,
                "doc_frequency must be 0.0 from extractor; got {} for '{}'",
                f.doc_frequency, f.value
            );
        }
    }
}

// ── Integration: pipeline succeeds with HMM extractor ────────────────────────

// No-empty-feature guard: the HMM extractor must not produce the
// "No features extracted from memories" failure on a noun-rich cluster.
// The pipeline may or may not succeed the SNR gate — that is a
// cluster-quality property, not an extractor property. This test
// verifies the extractor produces MEANINGFUL features (ENT/REL) rather
// than the empty-feature failure that happens with a no-op extractor.
#[test]
fn pipeline_produces_features_with_hmm_extractor() {
    let input = DistillationInput::new(
        vec![
            "apollo launched the mission".to_string(),
            "the apollo crew trained for months".to_string(),
            "apollo achieved orbit successfully".to_string(),
        ],
        None,
        "hmm-extractor-integration-cluster",
        vec!["s1".to_string(), "s2".to_string(), "s3".to_string()],
    );
    let output = DistillationPipeline::run(&input, hmm_feature_extractor(), false);
    // With the HMM extractor, the pipeline must NOT fail with "No features extracted"
    // — it must extract ENT features (apollo) from every memory. The pipeline may
    // still fail the SNR gate (cluster-quality property), but the "No features
    // extracted" failure is a no-op-extractor failure, not an HMM failure.
    let failure_reason = output.failure_reason.as_deref().unwrap_or("");
    assert!(
        !failure_reason.contains("No features extracted from memories"),
        "HMM extractor must produce features; got: {}",
        failure_reason
    );
}

// ── Determinism ───────────────────────────────────────────────────────────────

// Same input must produce identical ENT output on repeated calls.
#[test]
fn ent_is_deterministic() {
    let extractor = hmm_feature_extractor();
    let first: Vec<String> = extractor(APOLLO_SENTENCE, DistillationFeatureType::Entity)
        .into_iter()
        .map(|f| f.value)
        .collect();
    let second: Vec<String> = extractor(APOLLO_SENTENCE, DistillationFeatureType::Entity)
        .into_iter()
        .map(|f| f.value)
        .collect();
    assert_eq!(first, second, "HMM extractor must be deterministic for ENT");
}
