//! `EncoderModelSpec` — the in-process form of one `encoder_models` row.
//!
//! Mirror of Swift `EncoderModelSpec.swift`. Field names serialise to the
//! row's column names (`serde(rename)`), so a JSON spec is a JSON row.

use serde::{Deserialize, Serialize};

/// How the encoder collapses the token matrix into one vector.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Pooling {
    /// Attention-masked mean over the token positions.
    Mean,
    /// The first (`[CLS]`) position.
    Cls,
}

/// One shipped sentence encoder and its span-index geometry.
///
/// `model_id` carries the span unit (`<model>-w<window_words>`): two specs
/// that differ only in `window_words` are two different indexes and are
/// never compared. `model_version` is the weights revision; a weights change
/// is a new version and a re-index.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EncoderModelSpec {
    /// `<model>-w<window_words>`, e.g. `minilm-l6-v2-w60`.
    #[serde(rename = "model_id")]
    pub model_id: String,
    /// Weights revision: HF revision short hash or the CoreML bundle version.
    #[serde(rename = "model_version")]
    pub model_version: String,
    /// Output dimension of the pooled vector.
    pub dim: usize,
    /// Text prepended to every query before encoding (`""` when none).
    #[serde(rename = "query_prefix")]
    pub query_prefix: String,
    /// Text prepended to every span before encoding (`""` when none).
    #[serde(rename = "doc_prefix")]
    pub doc_prefix: String,
    /// Pooling the inference pass applies before L2 normalisation.
    pub pooling: Pooling,
    /// SHA-256 hex digest of the vendored `vocab.txt`; the factory refuses a
    /// model directory whose vocab hashes differently.
    #[serde(rename = "tokenizer_hash")]
    pub tokenizer_hash: String,
    /// Span window in words (`spanner::words` units).
    #[serde(rename = "window_words")]
    pub window_words: usize,
    /// Overlap divisor: `step = window_words / overlap_divisor` (2 = half overlap).
    #[serde(rename = "overlap_divisor")]
    pub overlap_divisor: usize,
    /// Upper bound on spans per record; `spanner::spans` widens the step to
    /// stay at or under it.
    #[serde(rename = "max_spans")]
    pub max_spans: usize,
    /// Maximum token sequence the model accepts; the tokenizer truncates here.
    #[serde(rename = "max_sequence")]
    pub max_sequence: usize,
}

impl EncoderModelSpec {
    /// The floor model for all development: `sentence-transformers/all-MiniLM-L6-v2`
    /// at HF revision `1110a243fdf4706b3f48f1d95db1a4f5529b4d41`, 384-d, mean
    /// pooling, no prefixes, 256-token maximum, 60-word spans with half
    /// overlap and at most 32 spans per record.
    ///
    /// `tokenizer_hash` is `sha256(vocab.txt)` of that revision's vocabulary
    /// (the 30 522-entry uncased BERT vocabulary, 231 508 bytes), computed
    /// with `shasum -a 256` on the vendored file. Byte-identical to the
    /// Swift `EncoderModelSpec.floor`.
    pub fn floor() -> Self {
        Self {
            model_id: "minilm-l6-v2-w60".to_string(),
            model_version: "1110a243".to_string(),
            dim: 384,
            query_prefix: String::new(),
            doc_prefix: String::new(),
            pooling: Pooling::Mean,
            tokenizer_hash: "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"
                .to_string(),
            window_words: 60,
            overlap_divisor: 2,
            max_spans: 32,
            max_sequence: 256,
        }
    }
}
