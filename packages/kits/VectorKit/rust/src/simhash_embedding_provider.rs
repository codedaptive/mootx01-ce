//! `FloatSimHashEmbeddingProvider` -- the concrete
//! `EmbeddingProvider` in vectorkit. Rust mirror of the Swift
//! `VectorKit.FloatSimHashEmbeddingProvider`.
//!
//! The provider holds a stable `projection_seed` and an injectable
//! inference closure that turns text into a dense `Vec<f32>`. The
//! closure result is fed through
//! `substrate_ml::float_simhash::project` (the canonical SimHash
//! projection -- bit-identical Swift/Rust per the substrate's
//! conformance harness) to obtain the 256-bit `Engram`.
//!
//! VectorKit owns neither tokenization, model bundles, nor model
//! identity. Concrete text providers that carry a tokenizer and a
//! model-specific projection seed (MiniLM, mpnet, EmbeddingGemma)
//! live in corpus-kit-providers and conform to vectorkit's own
//! `EmbeddingProvider` trait (the `CorpusKit::TextEmbeddingProvider`
//! protocol and its Rust mirror were deleted; all providers now
//! conform to `VectorKit::EmbeddingProvider`). This provider is the low-level "host
//! supplies inference, kit supplies the canonical projection"
//! building block; the caller passes the projection seed.

use engram_lib::Engram;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_ml::float_simhash;

use crate::{EmbeddingProvider, VectorKitError};

/// Provider that uses `FloatSimHash` for the float-vector to
/// engram projection. The host application supplies the inference
/// closure (typically wrapping an ONNX model or similar).
pub struct FloatSimHashEmbeddingProvider {
    model_id: String,
    model_version: String,
    projection_seed: u64,
    inference: Box<dyn Fn(&str) -> Result<Vec<f32>, String> + Send + Sync + 'static>,
}

impl FloatSimHashEmbeddingProvider {
    /// Build a provider with the given identifiers, projection
    /// seed (FloatSimHash hyperplane seed), and inference closure.
    pub fn new(
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        projection_seed: u64,
        inference: impl Fn(&str) -> Result<Vec<f32>, String> + Send + Sync + 'static,
    ) -> Self {
        FloatSimHashEmbeddingProvider {
            model_id: model_id.into(),
            model_version: model_version.into(),
            projection_seed,
            inference: Box::new(inference),
        }
    }

}

impl EmbeddingProvider for FloatSimHashEmbeddingProvider {
    fn model_id(&self) -> &str {
        &self.model_id
    }

    fn model_version(&self) -> &str {
        &self.model_version
    }

    fn embed(&self, text: &str) -> Result<Engram, VectorKitError> {
        // Empty-input contract from the EmbeddingProvider trait:
        // every conformer returns the substrate's canonical zero
        // engram for the empty string. Short-circuit before
        // touching the inference closure so the contract holds
        // even when callers pass closures that would otherwise
        // hash empty input to a non-zero vector.
        if text.is_empty() {
            return Ok(Engram::ZERO);
        }
        let floats = (self.inference)(text).map_err(VectorKitError::EmbeddingFailed)?;
        // `float_simhash::project` returns a `Fingerprint256`;
        // `Engram` is a type alias for `Fingerprint256` in the
        // EngramLib crate. The substrate's canonical projection
        // IS the engram -- no reconstruction needed.
        Ok(float_simhash::project(&floats, self.projection_seed))
    }

    /// Return the pooled dense float vector — the float lane source.
    ///
    /// This is exactly the vector `embed` feeds into
    /// `float_simhash::project`; the inference closure is the model pass
    /// MiniLM/mpnet/EmbeddingGemma run. Returning it directly is the
    /// "retain, don't recompute" path: the float lane and the binary
    /// SimHash lane are two reads of one inference output. Empty input
    /// returns `vec![]` per the trait contract (no dense direction for the
    /// empty string).
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, VectorKitError> {
        if text.is_empty() {
            return Ok(Vec::new());
        }
        (self.inference)(text).map_err(VectorKitError::EmbeddingFailed)
    }
}
