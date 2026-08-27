// recall_tuning_composition_tests.rs
//
// Rust conformance tests for the W4 parametric recall-tuning surface in NeuronKit.
// Mirrors Swift RecallTuningParametricTests.
//
// Coverage:
//   (a) Default tuning: named_with_tuning returns same composition as named().
//   (b) Non-default mmr_lambda is applied to text+mmr composition.
//   (c) Non-MMR compositions are unchanged by tuning.
//   (d) Unknown name falls back to text (same as named()).
//   (e) Golden pin: k=80, λ=0.6, bm25=0.4, vector=0.6 produces overridden mmr_lambda.

use genius_locus_kit::RecallTuningManifest;
use neuron_kit::composition_grid::{named, named_with_tuning};

// MARK: (a) Default tuning preserves composition

#[test]
fn default_tuning_returns_same_as_named() {
    let base = named(Some("text+mmr"));
    let tuned = named_with_tuning(Some("text+mmr"), &RecallTuningManifest::default());
    assert_eq!(tuned, base, "default tuning must return the same composition as named()");
}

#[test]
fn default_tuning_text_composition_unchanged() {
    let base = named(Some("text"));
    let tuned = named_with_tuning(Some("text"), &RecallTuningManifest::default());
    assert_eq!(tuned, base);
}

// MARK: (b) Non-default mmr_lambda applied to text+mmr

#[test]
fn non_default_mmr_lambda_overrides_text_mmr() {
    let tuning = RecallTuningManifest {
        rrf_k: 60,
        mmr_lambda: 0.5,
        rrf_bm25_weight: 0.3,
        rrf_vector_weight: 0.7,
        ..RecallTuningManifest::default()
    };
    let comp = named_with_tuning(Some("text+mmr"), &tuning);
    // Float(0.5) → f64 is exact (power of two); tight tolerance fine.
    let diff = (comp.mmr_lambda - 0.5_f64).abs();
    assert!(diff < 1e-9, "expected mmr_lambda 0.5, got {}", comp.mmr_lambda);
}

#[test]
fn tuned_text_mmr_preserves_name_and_terms() {
    let base = named(Some("text+mmr"));
    let tuning = RecallTuningManifest {
        rrf_k: 60,
        mmr_lambda: 0.5,
        rrf_bm25_weight: 0.3,
        rrf_vector_weight: 0.7,
        ..RecallTuningManifest::default()
    };
    let tuned = named_with_tuning(Some("text+mmr"), &tuning);
    assert_eq!(tuned.name, base.name);
    assert_eq!(tuned.terms, base.terms);
}

// MARK: (c) Non-MMR compositions unchanged

#[test]
fn non_mmr_text_composition_unchanged_by_tuning() {
    let tuning = RecallTuningManifest {
        rrf_k: 80,
        mmr_lambda: 0.5,
        rrf_bm25_weight: 0.4,
        rrf_vector_weight: 0.6,
        ..RecallTuningManifest::default()
    };
    let base = named(Some("text"));
    let tuned = named_with_tuning(Some("text"), &tuning);
    assert_eq!(tuned, base);
}

#[test]
fn non_mmr_hamming_token_exact_unchanged() {
    let tuning = RecallTuningManifest {
        rrf_k: 80,
        mmr_lambda: 0.5,
        rrf_bm25_weight: 0.4,
        rrf_vector_weight: 0.6,
        ..RecallTuningManifest::default()
    };
    let base = named(Some("hamming+tokenExact"));
    let tuned = named_with_tuning(Some("hamming+tokenExact"), &tuning);
    assert_eq!(tuned, base);
}

// MARK: (d) Unknown name fallback

#[test]
fn unknown_name_falls_back_to_text() {
    let tuning = RecallTuningManifest {
        rrf_k: 80,
        mmr_lambda: 0.5,
        rrf_bm25_weight: 0.4,
        rrf_vector_weight: 0.6,
        ..RecallTuningManifest::default()
    };
    let result = named_with_tuning(Some("no-such-composition"), &tuning);
    assert_eq!(result.name, "text");
}

// MARK: (e) Golden pin

#[test]
fn golden_pin_k80_lambda06_bm25_04_vector06_overrides_mmr_lambda() {
    // Golden pin: k=80, λ=0.6, bm25=0.4, vector=0.6 — all differ from spec.
    // This test pins the exact wire from manifest → composition in BOTH ports.
    let manifest = RecallTuningManifest {
        rrf_k: 80,
        mmr_lambda: 0.6,
        rrf_bm25_weight: 0.4,
        rrf_vector_weight: 0.6,
        ..RecallTuningManifest::default()
    };
    let comp = named_with_tuning(Some("text+mmr"), &manifest);
    // Float(0.6) → f64 is NOT exact; use a tolerance that covers the conversion gap
    // (~2.4e-8) while rejecting the spec default (0.7) — 1e-5 covers the gap.
    let diff = (comp.mmr_lambda - 0.6_f64).abs();
    assert!(
        diff < 1e-5,
        "golden pin mmr_lambda expected ≈0.6, got {} (diff={diff})", comp.mmr_lambda
    );
    // The overridden lambda must be visibly different from the spec default 0.7.
    let spec_default = named(Some("text+mmr")).mmr_lambda;
    assert_ne!(comp.mmr_lambda, spec_default, "tuned lambda must differ from spec default");
}
