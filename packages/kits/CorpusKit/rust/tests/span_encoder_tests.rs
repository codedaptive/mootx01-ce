//! `ProviderSpanEncoder` over a fake provider: prefixes applied, vectors
//! L2-normalised, order kept across batch boundaries, empty span → zero
//! vector, wrong seam dimension → `InferenceFailed`.
//!
//! Failure modes: a prefix that is not applied (the provider would see the
//! bare text), a vector returned without normalisation, a batch boundary
//! that drops or reorders spans.

use std::sync::Mutex;

use corpus_kit::encoder::{
    EmbeddingProviderSpanInference, EncoderError, EncoderModelSpec, Pooling, ProviderSpanEncoder,
    SpanEncoder,
};
use engram_lib::Engram;
use synapsekit::{EmbeddingProvider, SynapseKitError};

/// Records every text `embed_float` receives and returns a pooled vector
/// keyed off the text bytes (distinct per input, NOT unit-length).
struct FakeProvider {
    dim: usize,
    seen: Mutex<Vec<String>>,
}

impl EmbeddingProvider for FakeProvider {
    fn model_id(&self) -> &str {
        "fake-w60"
    }
    fn model_version(&self) -> &str {
        "0"
    }
    fn embed(&self, _text: &str) -> Result<Engram, SynapseKitError> {
        Ok(Engram::ZERO)
    }
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, SynapseKitError> {
        self.seen.lock().unwrap().push(text.to_string());
        if text.is_empty() {
            return Ok(Vec::new());
        }
        // Key off the TAIL of the text: every span shares the prefix bytes,
        // so a head-keyed fake would return one vector for all of them.
        let bytes = text.as_bytes();
        Ok((0..self.dim)
            .map(|d| ((bytes[bytes.len() - 1 - (d % bytes.len())] % 13) as f32) + 1.0 + d as f32)
            .collect())
    }
}

fn spec(dim: usize, query_prefix: &str, doc_prefix: &str) -> EncoderModelSpec {
    EncoderModelSpec {
        model_id: "fake-w60".into(),
        model_version: "0".into(),
        dim,
        query_prefix: query_prefix.into(),
        doc_prefix: doc_prefix.into(),
        pooling: Pooling::Mean,
        tokenizer_hash: String::new(),
        window_words: 60,
        overlap_divisor: 2,
        max_spans: 32,
        max_sequence: 128,
    }
}

fn norm(v: &[f32]) -> f32 {
    v.iter().map(|x| x * x).sum::<f32>().sqrt()
}

#[test]
fn encode_query_applies_prefix_and_normalises() {
    let provider = FakeProvider { dim: 8, seen: Mutex::new(Vec::new()) };
    let encoder = ProviderSpanEncoder::new(
        spec(8, "query: ", "passage: "),
        Box::new(EmbeddingProviderSpanInference(provider)),
        2,
    );
    let v = encoder.encode_query("painting in brazil").expect("encode");
    assert_eq!(v.len(), 8);
    assert!((norm(&v) - 1.0).abs() < 1e-5, "norm {}", norm(&v));
}

#[test]
fn encode_spans_prefixes_each_keeps_order_and_normalises() {
    let seen_handle = std::sync::Arc::new(Mutex::new(Vec::<String>::new()));
    // The provider is moved into the encoder; observe through a second
    // provider instance's recorder is impossible, so record via a shared
    // Arc by wrapping.
    struct Sharing(std::sync::Arc<Mutex<Vec<String>>>, FakeProvider);
    impl EmbeddingProvider for Sharing {
        fn model_id(&self) -> &str { self.1.model_id() }
        fn model_version(&self) -> &str { self.1.model_version() }
        fn embed(&self, t: &str) -> Result<Engram, SynapseKitError> { self.1.embed(t) }
        fn embed_float(&self, t: &str) -> Result<Vec<f32>, SynapseKitError> {
            self.0.lock().unwrap().push(t.to_string());
            self.1.embed_float(t)
        }
    }
    let provider = Sharing(
        seen_handle.clone(),
        FakeProvider { dim: 8, seen: Mutex::new(Vec::new()) },
    );
    let encoder = ProviderSpanEncoder::new(
        spec(8, "query: ", "passage: "),
        Box::new(EmbeddingProviderSpanInference(provider)),
        2,
    );
    let spans = ["one two", "three four", "five"]; // 3 spans, batch 2 → 2 + 1
    let vectors = encoder.encode_spans(&spans).expect("encode");
    assert_eq!(vectors.len(), 3);
    for v in &vectors {
        assert!((norm(v) - 1.0).abs() < 1e-5);
    }
    let seen = seen_handle.lock().unwrap().clone();
    assert_eq!(
        seen,
        vec!["passage: one two", "passage: three four", "passage: five"]
    );
    assert_ne!(vectors[0], vectors[1]);

    let q = encoder.encode_query("x").expect("encode");
    assert_eq!(q.len(), 8);
    assert_eq!(seen_handle.lock().unwrap().last().map(String::as_str), Some("query: x"));
}

#[test]
fn empty_span_is_zero_vector() {
    let provider = FakeProvider { dim: 8, seen: Mutex::new(Vec::new()) };
    let encoder = ProviderSpanEncoder::new(
        spec(8, "", ""),
        Box::new(EmbeddingProviderSpanInference(provider)),
        64,
    );
    let vectors = encoder.encode_spans(&[""]).expect("encode");
    assert_eq!(vectors, vec![vec![0.0; 8]]);
}

#[test]
fn wrong_seam_dimension_is_inference_failed() {
    let provider = FakeProvider { dim: 8, seen: Mutex::new(Vec::new()) };
    let encoder = ProviderSpanEncoder::new(
        spec(9, "", ""),
        Box::new(EmbeddingProviderSpanInference(provider)),
        64,
    );
    match encoder.encode_query("x") {
        Err(EncoderError::InferenceFailed(_)) => {}
        other => panic!("expected InferenceFailed, got {other:?}"),
    }
}

#[test]
fn floor_spec_round_trips_as_a_registry_row() {
    let json = serde_json::to_value(EncoderModelSpec::floor()).unwrap();
    assert_eq!(json["model_id"], "minilm-l6-v2-w60");
    assert_eq!(json["window_words"], 60);
    assert_eq!(json["pooling"], "mean");
    let back: EncoderModelSpec = serde_json::from_value(json).unwrap();
    assert_eq!(back, EncoderModelSpec::floor());
}
