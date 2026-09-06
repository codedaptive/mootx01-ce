//! The encoder contract the recall rerank stage and the `spanEncode` duty
//! code against, plus the one concrete encoder shape both ports ship: a
//! `ProviderSpanEncoder` that applies the spec's prefixes, runs a pooled
//! inference seam in batches and L2-normalises every vector through the
//! substrate's conformance-gated `float_vec_ops::l2_normalize`.
//!
//! Float values from a real model are allowed to differ by port (CoreML vs
//! candle); the SHAPE of this contract is what the two ports keep identical.
//!
//! Mirror of Swift `SpanEncoder.swift`.

use std::fmt;

use substrate_kernel::float_vec_ops::l2_normalize;
use synapsekit::EmbeddingProvider;

use super::spec::EncoderModelSpec;

/// Default `batch_size` when activation supplies none: the non-iOS
/// `encoder_batch` default (the Rust port never runs on iOS).
pub const DEFAULT_ENCODER_BATCH_SIZE: usize = 64;

/// Failure classes of building or running a span encoder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EncoderError {
    /// No usable model at the resolved location: the directory, the vocab
    /// file or the weights are missing, or this build carries no inference
    /// runtime (the `candle` feature is off).
    ModelUnavailable(String),
    /// `sha256(vocab.txt)` in the model directory differs from
    /// `EncoderModelSpec::tokenizer_hash`: the weights and the vocabulary the
    /// registry row describes would not agree, so nothing loads.
    TokenizerMismatch { expected: String, actual: String },
    /// The assets are present and hash correctly but the runtime refused
    /// them (malformed weights, unsupported pooling, dimension disagreement).
    LoadFailed(String),
    /// The loaded model failed while encoding (runtime error, wrong output
    /// dimension, or a batch that came back with the wrong count).
    InferenceFailed(String),
}

impl fmt::Display for EncoderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EncoderError::ModelUnavailable(s) => write!(f, "encoder model unavailable: {s}"),
            EncoderError::TokenizerMismatch { expected, actual } => write!(
                f,
                "encoder tokenizer mismatch: expected sha256 {expected}, vocab.txt hashes {actual}"
            ),
            EncoderError::LoadFailed(s) => write!(f, "encoder load failed: {s}"),
            EncoderError::InferenceFailed(s) => write!(f, "encoder inference failed: {s}"),
        }
    }
}

impl std::error::Error for EncoderError {}

/// A sentence encoder over span text.
///
/// `encode_query` applies `spec.query_prefix`; `encode_spans` applies
/// `spec.doc_prefix` to each span. Both return L2-normalised vectors of
/// `spec.dim` floats. An empty input string yields the all-zero vector of
/// `spec.dim` (no direction), never an error.
pub trait SpanEncoder: Send + Sync {
    /// The registry row this encoder serves.
    fn spec(&self) -> &EncoderModelSpec;
    /// Encode one query: prefix, pool, L2-normalise.
    fn encode_query(&self, text: &str) -> Result<Vec<f32>, EncoderError>;
    /// Encode spans in order: prefix each, pool, L2-normalise. Output count
    /// and order equal the input's.
    fn encode_spans(&self, spans: &[&str]) -> Result<Vec<Vec<f32>>, EncoderError>;
}

/// The pooled-vector inference seam a `ProviderSpanEncoder` drives.
///
/// Implementations return one pooled (NOT yet normalised) vector per input
/// text, in input order. An empty text may return `vec![]`; the encoder
/// maps it to the zero vector. Everything else must be `spec.dim` floats.
pub trait SpanInference: Send + Sync {
    /// Pooled vectors for `texts`, one per text, same order.
    fn pooled_batch(&self, texts: &[&str]) -> Result<Vec<Vec<f32>>, EncoderError>;
}

/// `SpanInference` over any `EmbeddingProvider` whose `embed_float` returns
/// the pooled vector (the named text providers).
///
/// Runs `embed_float` once per text: the provider's own inference seam is
/// the batch unit, so there is no second batching layer to disagree with
/// the model's. Provider errors surface as `EncoderError::InferenceFailed`.
pub struct EmbeddingProviderSpanInference<P: EmbeddingProvider>(pub P);

impl<P: EmbeddingProvider> SpanInference for EmbeddingProviderSpanInference<P> {
    fn pooled_batch(&self, texts: &[&str]) -> Result<Vec<Vec<f32>>, EncoderError> {
        texts
            .iter()
            .map(|t| {
                self.0.embed_float(t).map_err(|e| {
                    EncoderError::InferenceFailed(format!("{}: {e:?}", self.0.model_id()))
                })
            })
            .collect()
    }
}

/// The concrete span encoder: spec + pooled inference seam + batch size.
///
/// `encode_spans` slices its input into `batch_size` chunks and hands each
/// chunk to the seam; the manifest key `encoder_batch` sets `batch_size` at
/// activation.
pub struct ProviderSpanEncoder {
    spec: EncoderModelSpec,
    inference: Box<dyn SpanInference>,
    batch_size: usize,
}

impl ProviderSpanEncoder {
    /// Build an encoder for `spec` over `inference`. A `batch_size` of 0
    /// acts as 1.
    pub fn new(spec: EncoderModelSpec, inference: Box<dyn SpanInference>, batch_size: usize) -> Self {
        Self { spec, inference, batch_size: batch_size.max(1) }
    }

    /// Spans per seam call in `encode_spans`.
    pub fn batch_size(&self) -> usize {
        self.batch_size
    }

    /// One seam call: pooled vectors in, unit vectors out. Dimension and
    /// count are checked here so a mis-wired model fails loudly instead of
    /// writing wrong-length rows.
    fn encode_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EncoderError> {
        let refs: Vec<&str> = texts.iter().map(String::as_str).collect();
        let pooled = self.inference.pooled_batch(&refs)?;
        if pooled.len() != texts.len() {
            return Err(EncoderError::InferenceFailed(format!(
                "{}: seam returned {} vectors for {} texts",
                self.spec.model_id,
                pooled.len(),
                texts.len()
            )));
        }
        pooled
            .into_iter()
            .map(|v| {
                // Empty text has no direction: the zero vector dots to 0
                // against every query and never wins a span.
                if v.is_empty() {
                    return Ok(vec![0.0; self.spec.dim]);
                }
                if v.len() != self.spec.dim {
                    return Err(EncoderError::InferenceFailed(format!(
                        "{}: seam returned dim {}, spec dim {}",
                        self.spec.model_id,
                        v.len(),
                        self.spec.dim
                    )));
                }
                Ok(l2_normalize(v))
            })
            .collect()
    }
}

impl SpanEncoder for ProviderSpanEncoder {
    fn spec(&self) -> &EncoderModelSpec {
        &self.spec
    }

    fn encode_query(&self, text: &str) -> Result<Vec<f32>, EncoderError> {
        let prefixed = format!("{}{}", self.spec.query_prefix, text);
        let mut out = self.encode_batch(std::slice::from_ref(&prefixed))?;
        Ok(out.pop().expect("encode_batch returns one vector per text"))
    }

    fn encode_spans(&self, spans: &[&str]) -> Result<Vec<Vec<f32>>, EncoderError> {
        let mut out = Vec::with_capacity(spans.len());
        for chunk in spans.chunks(self.batch_size) {
            let prefixed: Vec<String> =
                chunk.iter().map(|s| format!("{}{}", self.spec.doc_prefix, s)).collect();
            out.extend(self.encode_batch(&prefixed)?);
        }
        Ok(out)
    }
}
