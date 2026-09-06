//! `SpanEncoderFactory` — model directory → `SpanEncoder`.
//!
//! Lives in `corpus-kit-providers` (not the `corpus-kit` core) because it
//! instantiates the concrete candle provider; the contract types it returns
//! live in `corpus_kit::encoder` so the recall stage and the duty never
//! depend on this crate's optional ML runtime.
//!
//! Mirror of Swift `CorpusKitProviders/Encoder/SpanEncoderFactory.swift`.

use std::path::Path;

use corpus_kit::encoder::{EncoderError, EncoderModelSpec, SpanEncoder, DEFAULT_ENCODER_BATCH_SIZE};
use substrate_kernel::sha256;

/// The vendored vocabulary file every model directory carries; its SHA-256
/// hex digest must equal `EncoderModelSpec::tokenizer_hash`. The candle
/// runtime tokenises from `tokenizer.json` in the same directory; both ports
/// hash `vocab.txt` so one registry row serves both.
pub const VOCABULARY_FILE_NAME: &str = "vocab.txt";

/// Builds span encoders from model directories.
pub struct SpanEncoderFactory;

impl SpanEncoderFactory {
    /// Build the encoder for `spec` from `model_dir` with the default batch.
    ///
    /// Order of checks, each with its own failure class so the one stderr
    /// line the coordinator emits names the real cause:
    /// 1. directory and `vocab.txt` present → else `ModelUnavailable`;
    /// 2. `sha256(vocab.txt) == spec.tokenizer_hash` → else `TokenizerMismatch`;
    /// 3. the runtime accepts the spec and the weights → else `LoadFailed`;
    ///    a build without the `candle` feature → `ModelUnavailable`.
    pub fn make(spec: &EncoderModelSpec, model_dir: &Path) -> Result<Box<dyn SpanEncoder>, EncoderError> {
        Self::make_with_batch(spec, model_dir, DEFAULT_ENCODER_BATCH_SIZE)
    }

    /// `make` with an explicit `batch_size` (the manifest's `encoder_batch`).
    pub fn make_with_batch(
        spec: &EncoderModelSpec,
        model_dir: &Path,
        batch_size: usize,
    ) -> Result<Box<dyn SpanEncoder>, EncoderError> {
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
        let actual = Self::hex_digest(&vocab);
        if actual != spec.tokenizer_hash {
            return Err(EncoderError::TokenizerMismatch {
                expected: spec.tokenizer_hash.clone(),
                actual,
            });
        }
        Self::load_runtime(spec, model_dir, batch_size)
    }

    /// Lowercase SHA-256 hex of `bytes`, through the substrate's SHA-256 so
    /// both ports hash the vocabulary with the same conformance-gated
    /// primitive.
    pub fn hex_digest(bytes: &[u8]) -> String {
        sha256::hash(bytes).iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Candle runtime: mean-pooled all-MiniLM-L6-v2 over
    /// `config.json` + `tokenizer.json` + `model.safetensors`, truncated at
    /// `spec.max_sequence`.
    #[cfg(feature = "candle")]
    fn load_runtime(
        spec: &EncoderModelSpec,
        model_dir: &Path,
        batch_size: usize,
    ) -> Result<Box<dyn SpanEncoder>, EncoderError> {
        use corpus_kit::encoder::{Pooling, ProviderSpanEncoder};

        use crate::candle_provider::{CandleNLProvider, CANDLE_NL_DIMENSION};

        // The candle provider pools by attention-masked mean; a CLS-pooled
        // row cannot be served by it and must not be silently mean-pooled.
        if spec.pooling != Pooling::Mean {
            return Err(EncoderError::LoadFailed(format!(
                "{}: candle runtime pools by mean, spec asks for {:?}",
                spec.model_id, spec.pooling
            )));
        }
        if spec.dim != CANDLE_NL_DIMENSION {
            return Err(EncoderError::LoadFailed(format!(
                "{}: candle runtime produces dim {CANDLE_NL_DIMENSION}, spec dim {}",
                spec.model_id, spec.dim
            )));
        }
        let provider = CandleNLProvider::load_with_max_tokens(model_dir, spec.max_sequence)
            .map_err(EncoderError::LoadFailed)?;
        Ok(Box::new(ProviderSpanEncoder::new(spec.clone(), Box::new(provider), batch_size)))
    }

    /// No inference runtime in this build: the hash check above still ran,
    /// so a wrong vocabulary is reported before the missing runtime.
    #[cfg(not(feature = "candle"))]
    fn load_runtime(
        spec: &EncoderModelSpec,
        _model_dir: &Path,
        _batch_size: usize,
    ) -> Result<Box<dyn SpanEncoder>, EncoderError> {
        Err(EncoderError::ModelUnavailable(format!(
            "{}: this build carries no inference runtime (candle feature off)",
            spec.model_id
        )))
    }
}
