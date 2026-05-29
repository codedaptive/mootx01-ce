//! `EmbeddingProvider` trait -- Rust mirror of the Swift protocol.
//!
//! Per spec I-4 every stored vector carries the model ID and version
//! that produced it, so `model_id()` and `model_version()` are part
//! of the trait surface rather than something a storage adapter has
//! to track separately. Conformers are `Send + Sync` because
//! embedding jobs run on background threads.

use engram_lib::Engram;

use crate::error::VectorKitError;

/// Trait for on-device embedding generation.
///
/// Conformers project text into a 256-bit `Engram` whose Hamming
/// geometry approximates the model's semantic similarity. The
/// canonical projection lives in
/// `substrate_lib::float_simhash::project`; conformers that
/// produce engrams by any other path break the cross-provider
/// distance contract and should not be used in production.
pub trait EmbeddingProvider: Send + Sync {
    /// Stable identifier for this model (e.g. `"minilm-v6"`). Used
    /// to tag stored vectors and to filter queries to a single
    /// model. Per spec I-4, vectors with different `model_id` are
    /// never compared.
    fn model_id(&self) -> &str;

    /// Semantic version of the model weights (e.g. `"1.0.0"`). A
    /// weight update bumps this string; vectors produced under
    /// different versions cannot be compared.
    fn model_version(&self) -> &str;

    /// Generate an engram for the given text.
    ///
    /// # Empty input
    ///
    /// Empty input is permitted. Conformers MUST return the
    /// substrate's canonical zero engram (`Engram::ZERO`) for the
    /// empty string. This is the cross-provider contract: every
    /// `EmbeddingProvider` in the kit graph treats the empty
    /// string identically so empty-text rows from different
    /// providers collide on the same Hamming-distance-0 partition.
    /// The Swift `EmbeddingProvider` protocol carries the same
    /// rule (`Engram.zero` for empty input).
    fn embed(&self, text: &str) -> Result<Engram, VectorKitError>;

    /// Batched embedding. Default sequential implementation;
    /// providers with batched inference (e.g. ONNX graphs with a
    /// batch dimension) can override for throughput. Order of
    /// outputs matches the order of inputs; empty entries in the
    /// input slice yield `Engram::ZERO` per the `embed` contract.
    fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Engram>, VectorKitError> {
        let mut out = Vec::with_capacity(texts.len());
        for t in texts {
            out.push(self.embed(t)?);
        }
        Ok(out)
    }
}
