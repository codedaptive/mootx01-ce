//! The cross-encoder contract the retrieval-time rerank stage codes against,
//! plus the one concrete scorer shape both ports ship: a `ProviderPairScorer`
//! that runs a pair-logit inference seam in batches and checks that every
//! span came back with exactly one finite logit.
//!
//! Logit values from a real model are allowed to differ by port (CoreML vs
//! candle); the SHAPE of this contract is what the two ports keep identical.
//! The scorer never sorts, never fuses and never truncates the span list:
//! selection and fusion belong to the stage in GeniusLocusKit.
//!
//! Mirror of Swift `PairScorer.swift`.

use super::cross_encoder_profile::CrossEncoderProfile;
use super::span_encoder::EncoderError;

/// Default `batch_size` when the caller supplies none: the lab's
/// `batch_size` of 8, which held FP32 latency flat on CPU.
pub const DEFAULT_PAIR_BATCH_SIZE: usize = 8;

/// A cross encoder over (query, span) pairs.
///
/// `score` returns one finite relevance logit per span, in span order, so
/// `result.len() == spans.len()` always holds. An empty span list returns
/// an empty vector without touching the model. Higher is more relevant; the
/// scale is the model's own and is only ever compared within one call.
pub trait PairScorer: Send + Sync {
    /// The packaged profile this scorer serves.
    fn profile(&self) -> &CrossEncoderProfile;
    /// The inference runtime behind the scorer (`coreml`, `candle`, or a
    /// test double's own name); reported on every recall the stage runs.
    fn backend(&self) -> &str;
    /// Score every `(query, span)` pair.
    fn score(&self, query: &str, spans: &[&str]) -> Result<Vec<f32>, EncoderError>;
}

/// The pair-logit inference seam a `ProviderPairScorer` drives.
///
/// Implementations tokenize each pair, run the classifier and return the
/// raw logit per span in input order. The seam is text-in so that the
/// tokenizer stays with the runtime that owns the vocabulary, exactly as
/// `SpanInference` does for the sentence encoder.
pub trait PairInference: Send + Sync {
    /// The runtime's name (`coreml`, `candle`, or a test double's own name).
    fn backend(&self) -> &str;
    /// Raw logits for `spans` against `query`, one per span, same order.
    fn logits(&self, query: &str, spans: &[&str]) -> Result<Vec<f32>, EncoderError>;
}

/// The concrete pair scorer: profile + inference seam + batch size.
///
/// `score` slices its spans into `batch_size` chunks and hands each chunk
/// to the seam with the same query, so a pool of 30 candidates times 3
/// spans never queues 90 pairs of tokens at once.
pub struct ProviderPairScorer {
    profile: CrossEncoderProfile,
    inference: Box<dyn PairInference>,
    batch_size: usize,
}

impl ProviderPairScorer {
    /// Build a scorer for `profile` over `inference`. A `batch_size` of 0
    /// acts as 1.
    pub fn new(profile: CrossEncoderProfile, inference: Box<dyn PairInference>, batch_size: usize) -> Self {
        Self { profile, inference, batch_size: batch_size.max(1) }
    }

    /// Pairs per seam call.
    pub fn batch_size(&self) -> usize {
        self.batch_size
    }

    /// One seam call. Count and finiteness are checked here so a mis-wired
    /// model fails loudly instead of fusing a NaN into the head order.
    fn score_batch(&self, query: &str, spans: &[&str]) -> Result<Vec<f32>, EncoderError> {
        let logits = self.inference.logits(query, spans)?;
        if logits.len() != spans.len() {
            return Err(EncoderError::InferenceFailed(format!(
                "{}: seam returned {} logits for {} pairs",
                self.profile.model_id,
                logits.len(),
                spans.len()
            )));
        }
        if let Some(bad) = logits.iter().position(|l| !l.is_finite()) {
            return Err(EncoderError::InferenceFailed(format!(
                "{}: seam returned a non-finite logit at pair {bad}",
                self.profile.model_id
            )));
        }
        Ok(logits)
    }
}

impl PairScorer for ProviderPairScorer {
    fn profile(&self) -> &CrossEncoderProfile {
        &self.profile
    }

    fn backend(&self) -> &str {
        self.inference.backend()
    }

    fn score(&self, query: &str, spans: &[&str]) -> Result<Vec<f32>, EncoderError> {
        let mut out = Vec::with_capacity(spans.len());
        for chunk in spans.chunks(self.batch_size) {
            out.extend(self.score_batch(query, chunk)?);
        }
        Ok(out)
    }
}
