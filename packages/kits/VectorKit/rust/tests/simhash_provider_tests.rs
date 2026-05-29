//! Tests for `FloatSimHashEmbeddingProvider`. Mirror of the Swift
//! provider tests in `CorpusKit/Tests/CorpusKitTests/ProvidersTests.swift`:
//! deterministic output, distinct projection seeds across the three
//! convenience constructors (MiniLM / mpnet / EmbeddingGemma),
//! empty-input contract.

use engram_lib::Engram;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use vectorkit::{EmbeddingProvider, FloatSimHashEmbeddingProvider};

// Projection seeds are owned by the concrete text providers in
// corpus-kit-providers; the test pins its own values to exercise the
// generic constructor and the distinct-seed behavior.
const MINILM_SEED: u64 = 0x4D49_4E4C_4D_5F76_31;
const MPNET_SEED: u64 = 0x4D50_4E45_54_5F76_31;
const GEMMA_SEED: u64 = 0x454D_4247_4D_5F76_31;

/// Constant 384-dim vector for MiniLM-shaped inference.
fn minilm_inference(_text: &str) -> Result<Vec<f32>, String> {
    Ok(vec![0.1; 384])
}

/// Constant 768-dim vector for mpnet / EmbeddingGemma.
fn mpnet_inference(_text: &str) -> Result<Vec<f32>, String> {
    Ok(vec![0.5; 768])
}

#[test]
fn provider_carries_model_identity() {
    let provider = FloatSimHashEmbeddingProvider::new("minilm-v6", "1.0.0", MINILM_SEED, minilm_inference);
    assert_eq!(provider.model_id(), "minilm-v6");
    assert_eq!(provider.model_version(), "1.0.0");
}

#[test]
fn provider_embed_is_deterministic_for_same_text() {
    let provider = FloatSimHashEmbeddingProvider::new("minilm-v6", "1.0.0", MINILM_SEED, minilm_inference);
    let e1 = provider.embed("first text").expect("embed");
    let e2 = provider.embed("first text").expect("embed");
    assert_eq!(e1, e2, "same input must produce the same engram");
}

#[test]
fn different_providers_produce_different_engrams_for_same_text() {
    // Each provider has a distinct FloatSimHash seed; same float
    // input -> different fingerprint.
    let mini = FloatSimHashEmbeddingProvider::new("minilm-v6", "1.0.0", MINILM_SEED, minilm_inference);
    let mpnet = FloatSimHashEmbeddingProvider::new("mpnet-base-v2", "1.0.0", MPNET_SEED, mpnet_inference);
    let e_mini = mini.embed("test").expect("embed mini");
    let e_mpnet = mpnet.embed("test").expect("embed mpnet");
    assert_ne!(
        e_mini, e_mpnet,
        "different providers must produce different engrams"
    );
}

#[test]
fn embedding_gemma_seed_distinct() {
    let gemma =
        FloatSimHashEmbeddingProvider::new("embedding-gemma-300m", "1.0.0", GEMMA_SEED, |_text| Ok(vec![0.5; 768]));
    let mini = FloatSimHashEmbeddingProvider::new("minilm-v6", "1.0.0", MINILM_SEED, minilm_inference);
    let e_gemma = gemma.embed("test").expect("embed gemma");
    let e_mini = mini.embed("test").expect("embed mini");
    assert_ne!(e_gemma, e_mini);
    assert_eq!(gemma.model_id(), "embedding-gemma-300m");
}

#[test]
fn inference_failure_surfaces_as_embedding_failed() {
    let provider = FloatSimHashEmbeddingProvider::new(
        "broken",
        "0.0.0",
        0xCAFE,
        |_text| Err("inference broken".to_string()),
    );
    match provider.embed("anything") {
        Err(vectorkit::VectorKitError::EmbeddingFailed(msg)) => {
            assert_eq!(msg, "inference broken");
        }
        other => panic!("expected EmbeddingFailed, got {:?}", other),
    }
}

/// Empty input returns the substrate's canonical zero engram per
/// the EmbeddingProvider trait contract. Every provider in the
/// kit graph honours the same rule, so empty-text rows collide on
/// the same Hamming-distance-0 partition across providers.
#[test]
fn empty_text_returns_zero_engram() {
    let provider = FloatSimHashEmbeddingProvider::new("minilm-v6", "1.0.0", MINILM_SEED, minilm_inference);
    let engram = provider.embed("").expect("embed");
    assert_eq!(engram, Engram::ZERO);
}

/// The empty-input shortcut bypasses the inference closure
/// entirely. A provider built with a closure that returns an
/// error for any input still produces `Engram::ZERO` for "".
#[test]
fn empty_text_does_not_invoke_inference() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let provider = FloatSimHashEmbeddingProvider::new(
        "guarded",
        "1.0.0",
        0xBEEF,
        move |_text| {
            counter.fetch_add(1, Ordering::SeqCst);
            Err("must not be called".to_string())
        },
    );
    let engram = provider.embed("").expect("empty input bypasses closure");
    assert_eq!(engram, Engram::ZERO);
    assert_eq!(calls.load(Ordering::SeqCst), 0, "inference closure must not run on empty input");
}

/// Default `embed_batch` impl iterates `embed` sequentially.
/// Verify count preservation, empty-entry contract (`Engram::ZERO`
/// per the trait contract), and that non-empty entries return
/// non-zero engrams. Mirrors the Swift
/// `testEmptyStringReturnsZeroEngramAllProviders` test that proves
/// the empty-input shortcut fires inside batched flows too.
#[test]
fn embed_batch_default_impl_handles_mixed_empty_and_non_empty() {
    let provider = FloatSimHashEmbeddingProvider::new(
        "minilm-v6", "1.0.0", MINILM_SEED, minilm_inference,
    );

    // Empty input slice -> empty output.
    let empty: Vec<&str> = vec![];
    assert!(provider.embed_batch(&empty).unwrap().is_empty());

    // Mixed slice: count preserved, empty entries -> Engram::ZERO,
    // non-empty entries -> non-zero (constant inference vector
    // projects to a fixed non-zero engram).
    let texts = vec!["alpha", "", "beta", ""];
    let batch = provider.embed_batch(&texts).expect("embed_batch");
    assert_eq!(batch.len(), texts.len(), "output count must match input count");
    assert_ne!(batch[0], Engram::ZERO, "non-empty input must yield non-zero engram");
    assert_eq!(batch[1], Engram::ZERO, "empty input must yield Engram::ZERO");
    assert_ne!(batch[2], Engram::ZERO);
    assert_eq!(batch[3], Engram::ZERO);
    // Constant inference -> two non-empty inputs project identically.
    assert_eq!(batch[0], batch[2]);
}

