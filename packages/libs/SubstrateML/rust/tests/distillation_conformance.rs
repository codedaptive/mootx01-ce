// distillation_conformance.rs
//
// Cross-language conformance gate for the SubstrateML distillation pipeline.
//
// These tests assert FIXED numerical outputs for FIXED inputs. The identical
// inputs appear in Swift (DistillationConformanceTests.swift). Any divergence
// between Rust and Swift on featureHash or pipeline run behavior is a
// parity failure.
//
// Conformance vectors are sourced from the distillation conformance
// specification (§9).
//
// Inputs and expected values MUST NOT be changed to make tests pass.
// If a value doesn't match, fix the algorithm, not the vector.
//
// Sub-function confidence values match Swift semantics: 1.0 for STATIC,
// C (convergence_score) for CONVERGENT, decay_lambda for MONOTONE, 0.0 for
// OSCILLATING and DIVERGENT.

use substrate_ml::delta_feature_extractor::{DeltaFeatureExtractor, DeltaType};
use substrate_ml::distillation_pipeline::{DistillationInput, DistillationPipeline};
use substrate_ml::distillation_scorer::ExtractedFeature;
use substrate_ml::typed_decay_weighting::{DistillationFeatureType, TypedDecayWeighting};
use substrate_types::fingerprint256::Fingerprint256;

// Fixture timestamps as Unix epoch seconds (f64)
const T0: f64 = 0.0;
const T1: f64 = 1.0;
const T2: f64 = 2.0;
const T3: f64 = 3.0;

// ── DeltaFeatureExtractor conformance ───────────────────────────────────────

// Fixture: input_cat_convergent
// sequence = [("A",t0),("B",t1),("B",t2)], λ=0.5
// k=2, M=3, C=2/3≈0.6667 ≥ λ → CONVERGENT
// terminal_value="B", convergence_score=2/3, confidence=C=2/3
#[test]
fn categorical_convergent() {
    let sequence: Vec<(String, f64)> = vec![
        ("A".to_string(), T0),
        ("B".to_string(), T1),
        ("B".to_string(), T2),
    ];
    let result = DeltaFeatureExtractor::analyze_categorical(&sequence, 0.5);
    assert_eq!(result.delta_type, DeltaType::Convergent);
    assert_eq!(result.terminal_value, "B");
    assert!((result.convergence_score - (2.0_f32 / 3.0)).abs() < 1e-5,
        "expected convergence_score ≈ 0.6667, got {}", result.convergence_score);
    assert!(result.slope.is_none());
    // confidence = C (convergence_score), matching Swift semantics
    let expected_conf = 2.0_f32 / 3.0;
    assert!((result.confidence - expected_conf).abs() < 1e-5,
        "expected confidence ≈ {}, got {}", expected_conf, result.confidence);
}

// Fixture: input_cat_static
// sequence = [("X",t0),("X",t1),("X",t2)], λ=0.5
// All identical → STATIC, convergence_score=1.0, confidence=1.0
#[test]
fn categorical_static() {
    let sequence: Vec<(String, f64)> = vec![
        ("X".to_string(), T0),
        ("X".to_string(), T1),
        ("X".to_string(), T2),
    ];
    let result = DeltaFeatureExtractor::analyze_categorical(&sequence, 0.5);
    assert_eq!(result.delta_type, DeltaType::Static);
    assert_eq!(result.terminal_value, "X");
    assert!((result.convergence_score - 1.0).abs() < 1e-5,
        "expected convergence_score=1.0, got {}", result.convergence_score);
    assert!(result.slope.is_none());
    assert!((result.confidence - 1.0).abs() < 1e-5,
        "expected confidence=1.0, got {}", result.confidence);
}

// Fixture: input_cat_oscillating
// sequence = [("A",t0),("B",t1),("A",t2),("B",t3)], λ=0.5
// M≥4: convergence_score=0.25 < 0.5 (not CONVERGENT),
// last4=[A,B,A,B]: a0==a1 && b0==b1 && a0≠b0 → OSCILLATING
// convergence_score=0.0, confidence=0.0
#[test]
fn categorical_oscillating() {
    let sequence: Vec<(String, f64)> = vec![
        ("A".to_string(), T0),
        ("B".to_string(), T1),
        ("A".to_string(), T2),
        ("B".to_string(), T3),
    ];
    let result = DeltaFeatureExtractor::analyze_categorical(&sequence, 0.5);
    assert_eq!(result.delta_type, DeltaType::Oscillating);
    assert!((result.convergence_score - 0.0).abs() < 1e-5,
        "expected convergence_score=0.0, got {}", result.convergence_score);
    assert!((result.confidence - 0.0).abs() < 1e-5,
        "expected confidence=0.0, got {}", result.confidence);
}

// Fixture: input_num_monotone
// sequence = [(1.0,t0),(2.0,t1),(3.0,t2)], λ=0.8
// diffs=[1.0,1.0], all positive → MONOTONE
// slope = mean(diffs) = 1.0, confidence = decay_lambda = 0.8
#[test]
fn numerical_monotone() {
    let sequence: Vec<(f64, f64)> = vec![(1.0, T0), (2.0, T1), (3.0, T2)];
    let result = DeltaFeatureExtractor::analyze_numerical(&sequence, 0.8);
    assert_eq!(result.delta_type, DeltaType::Monotone);
    assert!(result.slope.is_some(), "slope must be Some for MONOTONE");
    assert!((result.slope.unwrap() - 1.0_f32).abs() < 1e-5,
        "expected slope=1.0, got {:?}", result.slope);
    assert!((result.confidence - 0.8).abs() < 1e-5,
        "expected confidence=0.8, got {}", result.confidence);
}

// ── TypedDecayWeighting conformance ─────────────────────────────────────────

// Fixture: weight(ENT, 5.0) = exp(-0.1×5) = exp(-0.5) ≈ 0.60653
#[test]
fn weight_ent_age5() {
    let w = TypedDecayWeighting::weight(DistillationFeatureType::Entity, 5.0);
    let expected: f32 = 0.60653066; // exp(-0.5)
    assert!((w - expected).abs() < 1e-5,
        "expected weight≈{}, got {}", expected, w);
}

// Fixture: weight(REL, 5.0) = exp(-0.2×5) = exp(-1.0) ≈ 0.36788
#[test]
fn weight_rel_age5() {
    let w = TypedDecayWeighting::weight(DistillationFeatureType::Relation, 5.0);
    let expected: f32 = 0.36787944; // exp(-1.0)
    assert!((w - expected).abs() < 1e-5,
        "expected weight≈{}, got {}", expected, w);
}

// Fixture: weight(TMP, 5.0) = exp(-0.5×5) = exp(-2.5) ≈ 0.08208
#[test]
fn weight_tmp_age5() {
    let w = TypedDecayWeighting::weight(DistillationFeatureType::Temporal, 5.0);
    let expected: f32 = 0.08208500; // exp(-2.5)
    assert!((w - expected).abs() < 1e-5,
        "expected weight≈{}, got {}", expected, w);
}

// Fixture: weight(NUM, 5.0) = exp(-0.8×5) = exp(-4.0) ≈ 0.01832
#[test]
fn weight_num_age5() {
    let w = TypedDecayWeighting::weight(DistillationFeatureType::Numerical, 5.0);
    let expected: f32 = 0.01831564; // exp(-4.0)
    assert!((w - expected).abs() < 1e-5,
        "expected weight≈{}, got {}", expected, w);
}

// age=0 → weight=1.0 for all types (exp(0)=1)
#[test]
fn weight_at_age_zero() {
    for ft in [
        DistillationFeatureType::Entity,
        DistillationFeatureType::Relation,
        DistillationFeatureType::Temporal,
        DistillationFeatureType::Numerical,
    ] {
        let w = TypedDecayWeighting::weight(ft, 0.0);
        assert!((w - 1.0).abs() < 1e-6,
            "expected weight=1.0 at age=0 for {:?}, got {}", ft, w);
    }
}

// Negative age clamped to 0 → weight=1.0 (future timestamps treated as present)
#[test]
fn weight_negative_age_clamped() {
    let w = TypedDecayWeighting::weight(DistillationFeatureType::Entity, -10.0);
    assert!((w - 1.0).abs() < 1e-6,
        "expected weight=1.0 for negative age, got {}", w);
}

// ── DistillationPipeline::feature_hash conformance ──────────────────────────

// Fixture: feature_hash("provenance") must be non-zero
#[test]
fn provenance_non_zero() {
    let h = DistillationPipeline::feature_hash("provenance");
    assert!(
        h.block0 != 0 || h.block1 != 0 || h.block2 != 0 || h.block3 != 0,
        "feature_hash(\"provenance\") must be non-zero"
    );
}

// Fixture: exact 256-bit value of feature_hash("provenance")
//
// Computed by simulating the SplitMix64 mix+expand against
// FEATURE_SIM_HASH_SEED = 0x44495354494C4C41 ("DISTILLA" ASCII big-endian).
// These block values are the cross-language conformance anchor — Swift
// DistillationConformanceTests.provenanceExactBits must agree.
#[test]
fn provenance_exact_bits() {
    let h = DistillationPipeline::feature_hash("provenance");
    assert_eq!(h.block0, 0xd06e3650b74eb209, "block0 mismatch");
    assert_eq!(h.block1, 0x6e9d3d0f52394bc5, "block1 mismatch");
    assert_eq!(h.block2, 0x8e3b3aa6cbe0f400, "block2 mismatch");
    assert_eq!(h.block3, 0xcef0a66667eb79a5, "block3 mismatch");
}

// Fixture: feature_hash("A").union(feature_hash("B")) exact bits
//
// OR-reduce of two independent hashes. Both Rust and Swift must
// compute the same per-block OR from the same individual hashes.
// These values match Swift DistillationConformanceTests.unionABExactBits.
#[test]
fn union_ab_exact_bits() {
    let ha = DistillationPipeline::feature_hash("A");
    let hb = DistillationPipeline::feature_hash("B");
    let union = ha.zip4(&hb, |a, b| a | b);
    assert_eq!(union.block0, 0xdfcabff67e7ce1fd, "block0 mismatch");
    assert_eq!(union.block1, 0xe33ff5f225916ff5, "block1 mismatch");
    assert_eq!(union.block2, 0xfbfd77fabdbdaff7, "block2 mismatch");
    assert_eq!(union.block3, 0xbbe273bf37e6fab4, "block3 mismatch");
}

// Union is idempotent: h.union(h) == h (OR-reduce with self = self)
#[test]
fn union_idempotent() {
    let h = DistillationPipeline::feature_hash("provenance");
    let unioned = h.zip4(&h, |a, b| a | b);
    assert_eq!(unioned.block0, h.block0);
    assert_eq!(unioned.block1, h.block1);
    assert_eq!(unioned.block2, h.block2);
    assert_eq!(unioned.block3, h.block3);
}

// Union with ZERO = self (OR identity)
#[test]
fn union_with_zero_is_identity() {
    let h = DistillationPipeline::feature_hash("provenance");
    let unioned = h.zip4(&Fingerprint256::ZERO, |a, b| a | b);
    assert_eq!(unioned.block0, h.block0);
    assert_eq!(unioned.block1, h.block1);
    assert_eq!(unioned.block2, h.block2);
    assert_eq!(unioned.block3, h.block3);
}

// ── DistillationPipeline::run conformance ───────────────────────────────────

// singleWordExtractor: extracts "provenance" from any text containing it.
// Used for cluster_5 because default_extractor only captures capitalized
// non-first words, which "provenance is invariant in ingestion" lacks.
fn single_word_extractor(text: &str, feature_type: substrate_ml::typed_decay_weighting::DistillationFeatureType) -> Vec<ExtractedFeature> {
    if feature_type != DistillationFeatureType::Entity {
        return vec![];
    }
    if !text.contains("provenance") {
        return vec![];
    }
    vec![ExtractedFeature {
        feature_type: DistillationFeatureType::Entity,
        value: "provenance".to_string(),
        display: "provenance".to_string(),
        doc_frequency: 0.0,
        weighted_doc_frequency: 0.0,
        structural_score: 0.0,
    }]
}

// Fixture: cluster_5
// 5 identical memories: "provenance is invariant in ingestion"
// Extractor: single_word_extractor (extracts "provenance" from each memory)
// M=5, V={"provenance"}, df("provenance")=5/5=1.0
// τ_struct(M=5) = 2/5 = 0.4, so df=1.0 ≥ 0.4 → passes the structural threshold
// succeeded=true, confidence>0.6, featureFingerprint≠zero
#[test]
fn cluster_5_succeeded() {
    let memories: Vec<String> = (0..5)
        .map(|_| "provenance is invariant in ingestion".to_string())
        .collect();
    let source_ids: Vec<String> = (0..5).map(|i| format!("src-{}", i)).collect();
    let input = DistillationInput::new(
        memories,
        None,
        "cluster-5-fixture",
        source_ids,
    );
    let output = DistillationPipeline::run(&input, single_word_extractor, false);
    assert!(output.succeeded, "cluster_5 must succeed");
    assert!(output.confidence > 0.6,
        "cluster_5 confidence must be >0.6, got {}", output.confidence);
    let is_zero = output.feature_fingerprint.block0 == 0
        && output.feature_fingerprint.block1 == 0
        && output.feature_fingerprint.block2 == 0
        && output.feature_fingerprint.block3 == 0;
    assert!(!is_zero, "cluster_5 featureFingerprint must be non-zero");
}

// cluster_5: featureFingerprint must equal feature_hash("provenance")
#[test]
fn cluster_5_fingerprint_equals_provenance_hash() {
    let memories: Vec<String> = (0..5)
        .map(|_| "provenance is invariant in ingestion".to_string())
        .collect();
    let source_ids: Vec<String> = (0..5).map(|i| format!("src-{}", i)).collect();
    let input = DistillationInput::new(
        memories,
        None,
        "cluster-5-fixture",
        source_ids,
    );
    let output = DistillationPipeline::run(&input, single_word_extractor, false);
    let expected = DistillationPipeline::feature_hash("provenance");
    assert_eq!(output.feature_fingerprint.block0, expected.block0, "block0 mismatch");
    assert_eq!(output.feature_fingerprint.block1, expected.block1, "block1 mismatch");
    assert_eq!(output.feature_fingerprint.block2, expected.block2, "block2 mismatch");
    assert_eq!(output.feature_fingerprint.block3, expected.block3, "block3 mismatch");
}

// Fixture: cluster_noise
// 3 memories with no text containing "provenance" → single_word_extractor extracts nothing
// V=0 → "No features extracted" → succeeded=false
#[test]
fn cluster_noise_failure() {
    let memories: Vec<String> = vec![
        "the quick brown fox".to_string(),
        "jumped over the lazy dog".to_string(),
        "lorem ipsum dolor sit amet".to_string(),
    ];
    let input = DistillationInput::new(
        memories,
        None,
        "cluster-noise-fixture",
        vec!["src-0".to_string(), "src-1".to_string(), "src-2".to_string()],
    );
    let output = DistillationPipeline::run(&input, single_word_extractor, false);
    assert!(!output.succeeded, "cluster_noise must not succeed");
}
