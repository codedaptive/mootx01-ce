//! `PairScorerFactory` failure contract: missing directory, vocab hash
//! mismatch, matching hash without a runtime / weights.
//!
//! Failure mode: an error of the wrong class (the coordinator's one stderr
//! line would then name the wrong cause), or the hash check running after
//! the runtime check.

use std::path::PathBuf;

use corpus_kit::encoder::{CrossEncoderProfile, EncoderError};
use corpus_kit_providers::{PairScorerFactory, SpanEncoderFactory};

fn scratch_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("pair-factory-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

const VOCAB: &[u8] = b"[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\n";

#[test]
fn missing_directory_is_model_unavailable() {
    let missing = std::env::temp_dir().join(format!("pair-factory-missing-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&missing);
    match PairScorerFactory::make(&CrossEncoderProfile::minilm_l6(), &missing) {
        Err(EncoderError::ModelUnavailable(_)) => {}
        Ok(_) => panic!("factory must fail for a missing directory"),
        Err(other) => panic!("expected ModelUnavailable, got {other:?}"),
    }
}

#[test]
fn vocab_hash_disagreement_is_tokenizer_mismatch_with_real_digest() {
    let dir = scratch_dir("mismatch");
    std::fs::write(dir.join("vocab.txt"), VOCAB).unwrap();
    let result = PairScorerFactory::make(&CrossEncoderProfile::minilm_l6(), &dir);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        result.err(),
        Some(EncoderError::TokenizerMismatch {
            expected: CrossEncoderProfile::minilm_l6().tokenizer_hash,
            actual: SpanEncoderFactory::hex_digest(VOCAB),
        })
    );
}

#[test]
fn matching_hash_without_weights_does_not_load() {
    let dir = scratch_dir("nomodel");
    std::fs::write(dir.join("vocab.txt"), VOCAB).unwrap();
    let profile = CrossEncoderProfile {
        tokenizer_hash: SpanEncoderFactory::hex_digest(VOCAB),
        ..CrossEncoderProfile::minilm_l6()
    };
    let result = PairScorerFactory::make(&profile, &dir);
    let _ = std::fs::remove_dir_all(&dir);
    match result {
        // Without the candle feature the runtime is absent; with it, the
        // weights are absent. Either way nothing loads and the hash check
        // already passed.
        Err(EncoderError::ModelUnavailable(_)) => {}
        Ok(_) => panic!("factory must not load without weights"),
        Err(other) => panic!("unexpected error class {other:?}"),
    }
}
