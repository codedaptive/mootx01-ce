//! `PairScorerFactory` — model directory → `PairScorer`.
//!
//! Lives in `corpus-kit-providers` (not the `corpus-kit` core) because it
//! instantiates the candle classifier; the contract types it returns live
//! in `corpus_kit::encoder` so the rerank stage never depends on this
//! crate's optional ML runtime.
//!
//! Mirror of Swift `CorpusKitProviders/Encoder/PairScorerFactory.swift`.

use std::path::Path;

use corpus_kit::encoder::{CrossEncoderProfile, EncoderError, PairScorer, DEFAULT_PAIR_BATCH_SIZE};

use crate::span_encoder_factory::{SpanEncoderFactory, VOCABULARY_FILE_NAME};

/// Builds pair scorers from model directories.
pub struct PairScorerFactory;

impl PairScorerFactory {
    /// Build the scorer for `profile` from `model_dir` with the default batch.
    ///
    /// Order of checks, each with its own failure class so the one stderr
    /// line the coordinator emits names the real cause:
    /// 1. directory and `vocab.txt` present → else `ModelUnavailable`;
    /// 2. `sha256(vocab.txt) == profile.tokenizer_hash` → else `TokenizerMismatch`;
    /// 3. the runtime accepts the weights → else `LoadFailed`; a build
    ///    without the `candle` feature → `ModelUnavailable`.
    pub fn make(profile: &CrossEncoderProfile, model_dir: &Path) -> Result<Box<dyn PairScorer>, EncoderError> {
        Self::make_with_batch(profile, model_dir, DEFAULT_PAIR_BATCH_SIZE)
    }

    /// `make` with an explicit `batch_size`.
    pub fn make_with_batch(
        profile: &CrossEncoderProfile,
        model_dir: &Path,
        batch_size: usize,
    ) -> Result<Box<dyn PairScorer>, EncoderError> {
        if !model_dir.is_dir() {
            return Err(EncoderError::ModelUnavailable(format!(
                "{}: no such directory",
                model_dir.display()
            )));
        }
        let vocab_path = model_dir.join(VOCABULARY_FILE_NAME);
        let vocab = std::fs::read(&vocab_path).map_err(|e| {
            EncoderError::ModelUnavailable(format!("{}: {e}", vocab_path.display()))
        })?;
        let actual = SpanEncoderFactory::hex_digest(&vocab);
        if actual != profile.tokenizer_hash {
            return Err(EncoderError::TokenizerMismatch {
                expected: profile.tokenizer_hash.clone(),
                actual,
            });
        }
        Self::load_runtime(profile, model_dir, batch_size)
    }

    /// Candle runtime: the BERT sequence classifier loaded from the
    /// `config.json` + `tokenizer.json` + `model.safetensors` triple.
    #[cfg(feature = "candle")]
    fn load_runtime(
        profile: &CrossEncoderProfile,
        model_dir: &Path,
        batch_size: usize,
    ) -> Result<Box<dyn PairScorer>, EncoderError> {
        use corpus_kit::encoder::ProviderPairScorer;

        use crate::candle_pair_scorer::CandlePairScorer;

        if !CandlePairScorer::assets_present(model_dir) {
            return Err(EncoderError::ModelUnavailable(format!(
                "{}: missing one of config.json / tokenizer.json / model.safetensors",
                model_dir.display()
            )));
        }
        let scorer = CandlePairScorer::load(model_dir, profile.max_sequence)
            .map_err(EncoderError::LoadFailed)?;
        Ok(Box::new(ProviderPairScorer::new(profile.clone(), Box::new(scorer), batch_size)))
    }

    /// No inference runtime in this build: the hash check above still ran,
    /// so a wrong vocabulary is reported before the missing runtime.
    #[cfg(not(feature = "candle"))]
    fn load_runtime(
        profile: &CrossEncoderProfile,
        _model_dir: &Path,
        _batch_size: usize,
    ) -> Result<Box<dyn PairScorer>, EncoderError> {
        Err(EncoderError::ModelUnavailable(format!(
            "{}: this build carries no inference runtime (candle feature off)",
            profile.model_id
        )))
    }
}
