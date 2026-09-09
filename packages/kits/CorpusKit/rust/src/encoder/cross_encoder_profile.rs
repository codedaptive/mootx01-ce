//! `CrossEncoderProfile` — one packaged cross encoder and the operating
//! limits the retrieval-time rerank stage applies with it.
//!
//! A cross encoder scores (query, span) PAIRS to one relevance logit; it has
//! no vector geometry, no pooling and no span index, so it is a sibling of
//! `EncoderModelSpec`, not a variant of it. Nothing about a profile is
//! persisted per estate: the packaged profile is fixed, and the estate
//! manifest may lower the three pool limits (GeniusLocusKit's
//! `cross_encoder_pool`, `cross_encoder_head`, `cross_encoder_spans`).
//!
//! Mirror of Swift `CrossEncoderProfile.swift`. Field names serialise
//! column-style (`serde(rename)`), matching the lab's `profile.json`.

use serde::{Deserialize, Serialize};

/// One packaged cross encoder and the limits the rerank stage runs it under.
///
/// `pool`, `head` and `spans` are the MAXIMA the stage accepts: at most
/// `pool` candidates enter the stage, at most the first `head` of them are
/// scored, at most `spans` spans per candidate are paired with the query.
/// The stage clamps a caller's or manifest's value to these; it never
/// raises them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CrossEncoderProfile {
    /// Packaged identity, e.g. `ms-marco-minilm-l6-cross-v1`. Names the
    /// model directory under `<configuration>/models/<model_id>/`.
    #[serde(rename = "model_id")]
    pub model_id: String,
    /// Weights revision: HF revision short hash.
    #[serde(rename = "model_version")]
    pub model_version: String,
    /// SHA-256 hex digest of the vendored `vocab.txt`; the factory refuses a
    /// model directory whose vocab hashes differently.
    #[serde(rename = "tokenizer_hash")]
    pub tokenizer_hash: String,
    /// Maximum token sequence of the PAIR (`[CLS] q [SEP] s [SEP]`); the
    /// pair tokenizer truncates longest-first to this.
    #[serde(rename = "max_sequence")]
    pub max_sequence: usize,
    /// Maximum candidates handed to the stage from the authorized final list.
    pub pool: usize,
    /// Maximum candidates, counted from the front of the pool, that are scored.
    pub head: usize,
    /// Maximum spans per scored candidate paired with the query.
    pub spans: usize,
    /// The reciprocal-rank-fusion constant: `1/(rrf_k + rank)` per rank list.
    #[serde(rename = "rrf_k")]
    pub rrf_k: usize,
}

impl CrossEncoderProfile {
    /// Full source revision for the qualified MiniLM classifier. `model_version`
    /// remains the established short display value; strict transcript recall
    /// validates and reports this complete pin.
    pub const MINILM_L6_REVISION: &'static str =
        "233902d25c440f23af6f7d6e94d2946bac0bee0a";

    /// Base name of the packaged model artifact: `<artifact_name>.mlmodelc`
    /// on Apple platforms; the Rust runtime reads the fixed HF file triple
    /// instead and does not use it. Derived from `model_id` so a second
    /// packaged profile never collides with the first. Byte-identical to the
    /// Swift `artifactName`; the packaging pipeline names the artifact by it.
    pub fn artifact_name(&self) -> String {
        // `ms-marco-minilm-l6-cross-v1` → `MsMarcoMinilmL6CrossV1`
        self.model_id
            .split('-')
            .map(|part| {
                let mut chars = part.chars();
                match chars.next() {
                    Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                    None => String::new(),
                }
            })
            .collect()
    }

    /// The one qualified profile: `cross-encoder/ms-marco-MiniLM-L-6-v2` at
    /// HF revision `233902d25c440f23af6f7d6e94d2946bac0bee0a`, FP32, pair
    /// limit 512 tokens, pool 50 / head 30 / spans 3, RRF k = 60. These are
    /// the values the lab measured; they are not tuned here.
    ///
    /// `tokenizer_hash` is `sha256(vocab.txt)` of that revision, which is
    /// the same 30 522-entry uncased BERT vocabulary the floor sentence
    /// encoder ships (`EncoderModelSpec::floor().tokenizer_hash`).
    /// Byte-identical to the Swift `CrossEncoderProfile.minilmL6`.
    pub fn minilm_l6() -> Self {
        Self {
            model_id: "ms-marco-minilm-l6-cross-v1".to_string(),
            model_version: "233902d2".to_string(),
            tokenizer_hash: "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"
                .to_string(),
            max_sequence: 512,
            pool: 50,
            head: 30,
            spans: 3,
            rrf_k: 60,
        }
    }
}
