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
/// `substrate_ml::float_simhash::project`; conformers that
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

    /// Generate the pooled dense float vector for the given text — the
    /// float lane's source (Lane D).
    ///
    /// This is the SAME vector `embed` already computes on the way to the
    /// SimHash projection. Providers that run a real inference pass
    /// (MiniLM, mpnet, EmbeddingGemma) override this to return the pooled
    /// vector they would otherwise discard inside the SimHash projection —
    /// the two outputs come from one inference pass, so no model loads
    /// twice and no extra projection runs.
    ///
    /// # Empty input
    ///
    /// Empty input returns an empty `Vec` (`vec![]`): there is no dense
    /// direction for the empty string, and the binary lane already
    /// collapses empty input to `Engram::ZERO`. A float lane that returned
    /// a zero-filled vector here would surface every empty row as a
    /// cosine-distance-1 spurious neighbour.
    ///
    /// # Opt-out
    ///
    /// The default implementation returns `Err(EmbeddingFailed(..))`:
    /// float embeddings are opt-in. A provider that does not produce a
    /// dense float vector throws so callers must handle the unsupported
    /// case explicitly rather than recalling against a silently-wrong
    /// projection of the binary fingerprint. The Swift `EmbeddingProvider`
    /// protocol carries the identical opt-out rule.
    fn embed_float(&self, _text: &str) -> Result<Vec<f32>, VectorKitError> {
        Err(VectorKitError::EmbeddingFailed(format!(
            "embed_float is not supported by this provider (model_id={}); the float lane is opt-in",
            self.model_id()
        )))
    }

    /// Generate the binary engram AND the dense float vector for `text` from a
    /// SINGLE inference pass.
    ///
    /// `embed` already computes the pooled float vector on its way to the
    /// SimHash projection, and `embed_float` computes that same vector — a caller
    /// that needs both (the Corpus ingest float lane) would otherwise run
    /// inference twice per chunk. Providers that compute-then-project SHOULD
    /// override this to run the inference ONCE and return both outputs.
    ///
    /// Returns `(engram, floats)`; `floats` is `vec![]` when `embed_float`
    /// returns any error — including structural opt-out, vocab miss, or
    /// provider inference failure. The Swift `EmbeddingProvider` protocol
    /// carries the identical `embedPair` rule.
    fn embed_pair(&self, text: &str) -> Result<(Engram, Vec<f32>), VectorKitError> {
        let engram = self.embed(text)?;
        let floats = self.embed_float(text).unwrap_or_default();
        Ok((engram, floats))
    }

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
