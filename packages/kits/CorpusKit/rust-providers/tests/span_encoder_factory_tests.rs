//! `SpanEncoderFactory` failure contract: missing directory, vocab hash
//! mismatch, matching hash without a runtime / weights.
//!
//! Failure mode: a throw of the wrong class (the coordinator's one stderr
//! line would then name the wrong cause), or the hash check running after
//! the runtime check.

use std::path::PathBuf;

use corpus_kit::encoder::{EncoderError, EncoderModelSpec, Pooling};
use corpus_kit_providers::SpanEncoderFactory;

fn scratch_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("enc-factory-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

const VOCAB: &[u8] = b"[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\n";

#[test]
fn missing_directory_is_model_unavailable() {
    let missing = std::env::temp_dir().join(format!("enc-factory-missing-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&missing);
    match SpanEncoderFactory::make(&EncoderModelSpec::floor(), &missing) {
        Err(EncoderError::ModelUnavailable(_)) => {}
        Ok(_) => panic!("factory must fail for a missing directory"),
        Err(other) => panic!("expected ModelUnavailable, got {other:?}"),
    }
}

#[test]
fn vocab_hash_disagreement_is_tokenizer_mismatch_with_real_digest() {
    let dir = scratch_dir("mismatch");
    std::fs::write(dir.join("vocab.txt"), VOCAB).unwrap();
    let result = SpanEncoderFactory::make(&EncoderModelSpec::floor(), &dir);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        result.err(),
        Some(EncoderError::TokenizerMismatch {
            expected: EncoderModelSpec::floor().tokenizer_hash,
            actual: SpanEncoderFactory::hex_digest(VOCAB),
        })
    );
}

#[test]
fn matching_hash_without_weights_does_not_load() {
    let dir = scratch_dir("nomodel");
    std::fs::write(dir.join("vocab.txt"), VOCAB).unwrap();
    let spec = EncoderModelSpec {
        tokenizer_hash: SpanEncoderFactory::hex_digest(VOCAB),
        ..EncoderModelSpec::floor()
    };
    let result = SpanEncoderFactory::make(&spec, &dir);
    let _ = std::fs::remove_dir_all(&dir);
    match result {
        // Without the candle feature the runtime is absent; with it, the
        // weights are absent. Either way nothing loads and the hash check
        // already passed (a TokenizerMismatch here would mean the check
        // order is wrong).
        Err(EncoderError::ModelUnavailable(_)) | Err(EncoderError::LoadFailed(_)) => {}
        Ok(_) => panic!("factory must not load without weights"),
        Err(other) => panic!("unexpected error class {other:?}"),
    }
}

#[test]
fn cls_pooling_is_refused_by_candle_runtime_or_unavailable() {
    let dir = scratch_dir("cls");
    std::fs::write(dir.join("vocab.txt"), VOCAB).unwrap();
    let spec = EncoderModelSpec {
        tokenizer_hash: SpanEncoderFactory::hex_digest(VOCAB),
        pooling: Pooling::Cls,
        ..EncoderModelSpec::floor()
    };
    let result = SpanEncoderFactory::make(&spec, &dir);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(result.is_err());
}

#[test]
fn hex_digest_known_answer() {
    // sha256("abc") — the FIPS 180 known answer.
    assert_eq!(
        SpanEncoderFactory::hex_digest(b"abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}

/// Real-weights smoke: `MOOT_ENCODER_MODEL_DIR` names a directory holding
/// `config.json`, `tokenizer.json`, `model.safetensors` and `vocab.txt` of
/// all-MiniLM-L6-v2 @ 1110a243. Run with
/// `cargo test --features candle -- --ignored candle_smoke`.
#[test]
#[ignore]
#[cfg(feature = "candle")]
fn candle_smoke_encodes_unit_vectors() {
    let Ok(dir) = std::env::var("MOOT_ENCODER_MODEL_DIR") else {
        eprintln!("MOOT_ENCODER_MODEL_DIR unset; skipping");
        return;
    };
    let encoder = SpanEncoderFactory::make(&EncoderModelSpec::floor(), std::path::Path::new(&dir))
        .expect("load candle encoder");
    let q = encoder.encode_query("where did she paint").unwrap();
    assert_eq!(q.len(), 384);
    let n: f32 = q.iter().map(|x| x * x).sum::<f32>().sqrt();
    assert!((n - 1.0).abs() < 1e-4, "norm {n}");
    let spans = encoder.encode_spans(&["she painted in brazil", "the weather in oslo"]).unwrap();
    let dot = |a: &[f32], b: &[f32]| a.iter().zip(b).map(|(x, y)| x * y).sum::<f32>();
    assert!(dot(&q, &spans[0]) > dot(&q, &spans[1]), "topical span must score higher");
}
