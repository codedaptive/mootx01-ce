//! Real-artifact proof for the registry-driven Arctic span encoder.
//!
//! Run only after the parent task has produced the pinned ONNX reference:
//! `MOOT_ENCODER_PROOF=1 MOOT_ENCODER_MODEL_DIR=... \
//!  MOOT_ENCODER_REFERENCE_JSON=... MOOT_ENCODER_PROOF_OUTPUT=... \
//!  MOOT_ENCODER_TIMING_JSON=... \
//!  cargo test --features candle --test arctic_factory_proof -- --ignored`

#![cfg(feature = "candle")]

use std::path::Path;
use std::time::Instant;

use corpus_kit::encoder::{EncoderModelSpec, Pooling};
use corpus_kit_providers::{model_dir_for, EncoderModelSeed, SpanEncoderFactory};
use serde::{Deserialize, Serialize};
use substrate_kernel::int8_vec::{dequantize, dot_query, quantize};

#[derive(Deserialize)]
struct Reference {
    model_id: String,
    revision: String,
    dim: usize,
    pooling: String,
    query_prefix: String,
    doc_prefix: String,
    max_sequence: usize,
    tokenizer_hash: String,
    entries: Vec<ReferenceEntry>,
}

#[derive(Deserialize)]
struct ReferenceEntry {
    kind: String,
    text: String,
    encoded_text: String,
    vector: Vec<f32>,
}

#[derive(Deserialize)]
struct TimingInput {
    source_pool_sha256: String,
    samples: Vec<TimingSample>,
}

#[derive(Deserialize)]
struct TimingSample {
    query: String,
    windows: Vec<String>,
}

#[derive(Serialize)]
struct ProofOutput {
    port: &'static str,
    model_id: String,
    revision: String,
    cold_load_ms: f64,
    timing_scope: &'static str,
    timing_source_pool_sha256: String,
    query_ms_20: Vec<f64>,
    windows_750_ms_20: Vec<f64>,
    query_plus_windows_ms_20: Vec<f64>,
    median_query_ms_20: f64,
    median_windows_750_ms_20: f64,
    median_query_plus_windows_ms_20: f64,
    audition_total_ms: Option<f64>,
    query_to_span_int8_dot: Vec<f32>,
    entries: Vec<ProofEntry>,
}

#[derive(Serialize)]
struct ProofEntry {
    kind: String,
    text: String,
    cosine_to_onnx: f64,
    norm: f64,
    vector: Vec<f32>,
    int8_q: Vec<i8>,
    int8_scale: f32,
    int8_reconstruction_l2: f64,
}

fn dot(a: &[f32], b: &[f32]) -> f64 {
    assert_eq!(a.len(), b.len());
    a.iter()
        .zip(b)
        .map(|(x, y)| f64::from(*x) * f64::from(*y))
        .sum()
}

fn norm(v: &[f32]) -> f64 {
    dot(v, v).sqrt()
}

fn cosine(a: &[f32], b: &[f32]) -> f64 {
    dot(a, b) / (norm(a) * norm(b))
}

fn elapsed_ms(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1_000.0
}

fn median(values: &[f64]) -> f64 {
    let mut values = values.to_vec();
    values.sort_by(f64::total_cmp);
    (values[values.len() / 2 - 1] + values[values.len() / 2]) / 2.0
}

#[test]
#[ignore = "requires pinned Arctic weights and parent-generated ONNX reference"]
fn arctic_factory_matches_onnx_and_records_timing() {
    assert_eq!(
        std::env::var("MOOT_ENCODER_PROOF").expect("MOOT_ENCODER_PROOF must be set"),
        "1"
    );
    let model_dir = std::env::var("MOOT_ENCODER_MODEL_DIR")
        .expect("MOOT_ENCODER_MODEL_DIR must name the local Arctic triple");
    let data_dir = std::env::var("MOOT_ENCODER_DATA_DIR")
        .expect("MOOT_ENCODER_DATA_DIR must name an empty data directory");
    let reference_path = std::env::var("MOOT_ENCODER_REFERENCE_JSON")
        .expect("MOOT_ENCODER_REFERENCE_JSON must name stage/reference/reference.json");
    let output_path = std::env::var("MOOT_ENCODER_PROOF_OUTPUT")
        .expect("MOOT_ENCODER_PROOF_OUTPUT must name the Rust result JSON");
    let timing_path = std::env::var("MOOT_ENCODER_TIMING_JSON")
        .expect("MOOT_ENCODER_TIMING_JSON must name the external 20-sample timing input");

    let reference: Reference =
        serde_json::from_slice(&std::fs::read(&reference_path).expect("read ONNX reference JSON"))
            .expect("decode ONNX reference JSON");
    let timing: TimingInput =
        serde_json::from_slice(&std::fs::read(&timing_path).expect("read timing input JSON"))
            .expect("decode timing input JSON");
    assert_eq!(
        timing.samples.len(),
        20,
        "timing input must contain 20 samples"
    );
    assert_eq!(timing.source_pool_sha256.len(), 64);
    assert!(timing
        .source_pool_sha256
        .bytes()
        .all(|byte| byte.is_ascii_hexdigit()));
    assert!(timing
        .samples
        .iter()
        .all(|sample| sample.windows.len() == 750));
    assert_eq!(reference.entries.len(), 6, "one query plus five spans");
    assert_eq!(reference.entries[0].kind, "query");
    assert!(reference.entries[1..]
        .iter()
        .all(|entry| entry.kind == "span"));
    assert_eq!(reference.model_id, EncoderModelSeed::MODEL_ID);
    assert_eq!(reference.revision, EncoderModelSeed::MODEL_VERSION);
    assert_eq!(reference.dim, EncoderModelSeed::DIM);
    assert_eq!(reference.pooling, EncoderModelSeed::POOLING);
    assert_eq!(reference.query_prefix, EncoderModelSeed::QUERY_PREFIX);
    assert_eq!(reference.doc_prefix, EncoderModelSeed::DOC_PREFIX);
    assert_eq!(reference.max_sequence, EncoderModelSeed::MAX_SEQUENCE);
    assert_eq!(reference.tokenizer_hash, EncoderModelSeed::TOKENIZER_HASH);

    let pooling = match reference.pooling.as_str() {
        "cls" => Pooling::Cls,
        "mean" => Pooling::Mean,
        other => panic!("unsupported pooling {other}"),
    };
    let spec = EncoderModelSpec {
        model_id: reference.model_id.clone(),
        model_version: reference.revision.clone(),
        dim: reference.dim,
        query_prefix: reference.query_prefix.clone(),
        doc_prefix: reference.doc_prefix.clone(),
        pooling,
        tokenizer_hash: reference.tokenizer_hash.clone(),
        window_words: EncoderModelSeed::WINDOW_WORDS,
        overlap_divisor: EncoderModelSeed::OVERLAP_DIVISOR,
        max_spans: EncoderModelSeed::MAX_SPANS,
        max_sequence: reference.max_sequence,
    };

    let download_slot = Path::new(&data_dir)
        .join("models")
        .join(EncoderModelSeed::MODEL_ID);
    assert!(
        !download_slot.exists(),
        "real proof must exercise installed-share discovery, not the download slot"
    );
    let resolved_model_dir = model_dir_for(EncoderModelSeed::MODEL_ID, Path::new(&data_dir))
        .expect("resolve Arctic through the shipped installed-share layout");
    assert_eq!(
        resolved_model_dir
            .canonicalize()
            .expect("canonical resolved model directory"),
        Path::new(&model_dir)
            .canonicalize()
            .expect("canonical expected model directory")
    );

    let load_started = Instant::now();
    let encoder = SpanEncoderFactory::make(&spec, &resolved_model_dir)
        .expect("load Arctic through shipped Rust factory");
    let cold_load_ms = elapsed_ms(load_started);

    let query_ref = &reference.entries[0];
    assert_eq!(
        query_ref.encoded_text,
        format!("{}{}", reference.query_prefix, query_ref.text)
    );
    let span_refs = &reference.entries[1..];
    for entry in span_refs {
        assert_eq!(
            entry.encoded_text,
            format!("{}{}", reference.doc_prefix, entry.text)
        );
    }
    let query = encoder
        .encode_query(&query_ref.text)
        .expect("encode proof query");
    let span_texts: Vec<&str> = span_refs.iter().map(|entry| entry.text.as_str()).collect();
    let spans = encoder
        .encode_spans(&span_texts)
        .expect("encode five proof spans");
    assert_eq!(spans.len(), span_refs.len(), "factory omitted proof spans");
    let vectors: Vec<Vec<f32>> = std::iter::once(query).chain(spans).collect();
    assert_eq!(vectors.len(), reference.entries.len());

    let mut proof_entries = Vec::with_capacity(6);
    for (actual, expected) in vectors.iter().zip(&reference.entries) {
        assert_eq!(actual.len(), reference.dim);
        assert_eq!(expected.vector.len(), reference.dim);
        let actual_norm = norm(actual);
        assert!(
            (actual_norm - 1.0).abs() <= 1e-5,
            "{} norm {actual_norm}",
            expected.kind
        );
        let cosine_to_onnx = cosine(actual, &expected.vector);
        assert!(
            cosine_to_onnx >= 0.999,
            "{} cosine to ONNX {cosine_to_onnx}",
            expected.kind
        );
        let (int8_q, int8_scale) = quantize(actual);
        let reconstructed = dequantize(&int8_q, int8_scale);
        let int8_reconstruction_l2 = actual
            .iter()
            .zip(&reconstructed)
            .map(|(x, y)| {
                let delta = f64::from(*x) - f64::from(*y);
                delta * delta
            })
            .sum::<f64>()
            .sqrt();
        let reconstruction_bound =
            (reference.dim as f64).sqrt() * f64::from(int8_scale) / 2.0 + 1e-5;
        assert!(int8_reconstruction_l2 <= reconstruction_bound);
        proof_entries.push(ProofEntry {
            kind: expected.kind.clone(),
            text: expected.text.clone(),
            cosine_to_onnx,
            norm: actual_norm,
            vector: actual.clone(),
            int8_q,
            int8_scale,
            int8_reconstruction_l2,
        });
    }
    let query_to_span_int8_dot = proof_entries[1..]
        .iter()
        .map(|span| dot_query(&vectors[0], &span.int8_q, span.int8_scale))
        .collect();

    let mut query_samples = Vec::with_capacity(timing.samples.len());
    let mut windows_samples = Vec::with_capacity(timing.samples.len());
    let mut query_plus_windows_samples = Vec::with_capacity(timing.samples.len());
    for sample in &timing.samples {
        let total_started = Instant::now();
        let query_started = Instant::now();
        encoder
            .encode_query(&sample.query)
            .expect("timed query encode");
        query_samples.push(elapsed_ms(query_started));

        let windows: Vec<&str> = sample.windows.iter().map(String::as_str).collect();
        let windows_started = Instant::now();
        let encoded_windows = encoder
            .encode_spans(&windows)
            .expect("timed 750-window encode");
        windows_samples.push(elapsed_ms(windows_started));
        query_plus_windows_samples.push(elapsed_ms(total_started));
        assert_eq!(encoded_windows.len(), 750);
    }

    let output = ProofOutput {
        port: "rust-candle",
        model_id: reference.model_id,
        revision: reference.revision,
        cold_load_ms,
        timing_scope: "factory_encode_only_excludes_audition_dot_matrix",
        timing_source_pool_sha256: timing.source_pool_sha256,
        median_query_ms_20: median(&query_samples),
        median_windows_750_ms_20: median(&windows_samples),
        median_query_plus_windows_ms_20: median(&query_plus_windows_samples),
        query_ms_20: query_samples,
        windows_750_ms_20: windows_samples,
        query_plus_windows_ms_20: query_plus_windows_samples,
        audition_total_ms: None,
        query_to_span_int8_dot,
        entries: proof_entries,
    };
    std::fs::write(output_path, serde_json::to_vec_pretty(&output).unwrap())
        .expect("write Rust proof output JSON");
}
