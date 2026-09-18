//! Named text embedding providers — Rust port of Swift's
//! `CorpusKitProviders` `MiniLMTextProvider`.
//!
//! # The seam, and what each port actually owns
//!
//! These providers are the cross-platform parity surface for the
//! dense semantic lane. They own exactly what the Swift providers
//! own, and nothing the Swift providers delegate to the host:
//!
//! 1. **Model identity** — `model_id` / `model_version`, tagging
//!    every stored vector per spec I-4.
//! 2. **A tokenizer** — held internally as an impl detail (the
//!    `EmbeddingProvider` trait carries no tokenizer; tokenization
//!    stays out of synapsekit's contract). At v1.0 every named
//!    provider holds a `DeterministicTokenizer`; see the tokenizer
//!    note below for why that is the truthful state and not a gap
//!    this port introduced.
//! 3. **A model-specific projection seed** — byte-identical to the
//!    Swift constant, so the same pooled vector projects to the
//!    same 256-bit engram on every platform.
//! 4. **All post-processing** — the pooled vector is fed straight
//!    into `substrate_ml::float_simhash::project`, the
//!    conformance-gated SimHash that is bit-identical Swift/Rust.
//!    The float lane returns the pooled vector unprojected.
//!
//! # What the host supplies (the inference seam)
//!
//! `inference: Fn(&[i32]) -> Result<Vec<f32>, String>` — the model
//! pass. The host injects it, exactly as the Swift providers take
//! `inference: ([Int32]) async throws -> [Float]`. On Apple
//! platforms the host wraps a CoreML model; on Windows/Linux the
//! host wraps whatever runtime it chooses (the kit bundles no model
//! weights and links no ML-runtime crate — external deps are
//! prohibited by C-1 doctrine). The seam carries the SAME payload
//! shape on every platform: token IDs in, pooled float vector out.
//!
//! # Why "bit-identical embeddings cross-OS" is the wrong frame
//!
//! Swift does NOT own the real WordPiece/SentencePiece tokenizers
//! and does NOT own model inference. Both are host-supplied: the
//! Swift providers hold a `DeterministicTokenizer` stand-in and
//! call a host inference closure. So the embedding *values* are a
//! property of the host's model bundle, not of either language
//! port. What IS bit-identical across ports — and what this module
//! guarantees — is everything the kit owns: for any shared
//! (tokens → pooled vector) pair, the Swift and Rust providers
//! produce the same engram and the same float lane output, because
//! they share the projection seed and the substrate SimHash. The
//! deterministic tokenizer is itself already bit-identical across
//! ports (both fold token strings through `substrate_types::fnv`),
//! so the full no-host pipeline is bit-identical too.
//!
//! # Tokenizer note (the honest fallback)
//!
//! The real model tokenizer (BERT WordPiece for MiniLM) is NOT
//! implemented in EITHER port for this provider, because neither port
//! owns it: Swift's `MiniLMTextProvider` defaults to
//! `DeterministicTokenizer` exactly as this one does, and the
//! real tokenizer "lands when the model assets ship in the host
//! bundle" (Swift provider doc comments). When the host bundle
//! carries the real vocab, the host constructs the provider with a
//! tokenizer it supplies — the `tokenizer` field is injectable for
//! that reason. Until then the `DeterministicTokenizer` is the
//! truthful fallback: stable per token, but its IDs match no model
//! vocabulary, so feeding them to a real model yields garbage. That
//! is acceptable only for the no-host conformance pipeline and BM25
//! fixtures, never for production recall against a real model.

use corpus_kit::Tokenizer;
use engram_lib::Engram;
use substrate_ml::float_simhash;
use synapsekit::{EmbeddingProvider, SynapseKitError};

use crate::DeterministicTokenizer;

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. The SimHash
// projection used below is substrate_ml::float_simhash::project; do
// not hand-roll a projection. See packages/libs/SubstrateML/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

/// Host-supplied inference seam: token IDs in, pooled float vector
/// out. Mirrors the Swift providers' `([Int32]) async throws ->
/// [Float]` closure. Synchronous to match the Rust
/// `EmbeddingProvider` trait and the sibling
/// `synapsekit::FloatSimHashEmbeddingProvider`, which the Rust port
/// keeps synchronous; the host adapts any async model pass behind
/// this boundary.
pub type InferenceFn = Box<dyn Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static>;

// MARK: - Projection seeds
//
// Each constant is byte-identical to the Swift provider's
// `projectionSeed` default. The hex encodes an ASCII tag; the
// values MUST NOT drift from the Swift side or the same pooled
// vector would project to a different engram across ports, breaking
// the cross-port parity contract this module exists to hold.

/// "MINLM_v1" — equals Swift `MiniLMTextProvider.projectionSeed`
/// (`0x4D49_4E4C_4D_5F76_31`); regrouped here into even nibble groups,
/// same numeric value.
const MINILM_PROJECTION_SEED: u64 = 0x4D49_4E4C_4D5F_7631;

// MARK: - Shared pipeline
//
// The embed / embed_float / embed_pair bodies are factored here.
// The shared shape matches the Swift implementation.

/// Tokenize, run the host inference seam, and project the pooled
/// vector to a 256-bit engram. Returns `Engram::ZERO` for empty
/// input WITHOUT touching the inference seam — the empty-input
/// contract every `EmbeddingProvider` conformer shares.
fn embed_via_seam(
    text: &str,
    tokenizer: &dyn Tokenizer,
    inference: &InferenceFn,
    seed: u64,
) -> Result<Engram, SynapseKitError> {
    // EmbeddingProvider contract: empty input MUST return
    // Engram::ZERO. Short-circuit before the seam so the contract
    // holds even when the host closure would hash empty input to a
    // non-zero vector (or panic / error on it).
    if text.is_empty() {
        return Ok(Engram::ZERO);
    }
    let tokens = tokenizer.tokenize(text);
    let pooled = inference(&tokens).map_err(SynapseKitError::EmbeddingFailed)?;
    // float_simhash::project returns a Fingerprint256; Engram is a
    // type alias for Fingerprint256. The canonical projection IS the
    // engram — no reconstruction step.
    Ok(float_simhash::project(&pooled, seed))
}

/// Float lane source (Lane D): the pooled vector the seam produces,
/// returned unprojected. Empty input returns `vec![]` per the
/// `embed_float` contract (no dense direction for the empty string).
/// One inference pass feeds both the binary engram and this vector.
fn embed_float_via_seam(
    text: &str,
    tokenizer: &dyn Tokenizer,
    inference: &InferenceFn,
) -> Result<Vec<f32>, SynapseKitError> {
    if text.is_empty() {
        return Ok(Vec::new());
    }
    let tokens = tokenizer.tokenize(text);
    inference(&tokens).map_err(SynapseKitError::EmbeddingFailed)
}

/// Single-pass override: run the host inference seam ONCE, then derive
/// BOTH outputs from the one pooled vector — the projected engram and
/// the float-lane vector. This replaces the two independent seam calls
/// that `embed` and `embed_float` would each make (Corpus ingest needs
/// both per chunk; for a real NN model that is the most expensive
/// double-pass). Outputs are byte-identical to calling `embed` and
/// `embed_float` separately: empty input short-circuits before the seam
/// returning `(Engram::ZERO, vec![])`, the engram is
/// `float_simhash::project(pooled)`, and the float row is `pooled`.
fn embed_pair_via_seam(
    text: &str,
    tokenizer: &dyn Tokenizer,
    inference: &InferenceFn,
    seed: u64,
) -> Result<(Engram, Vec<f32>), SynapseKitError> {
    if text.is_empty() {
        return Ok((Engram::ZERO, Vec::new()));
    }
    let tokens = tokenizer.tokenize(text);
    let pooled = inference(&tokens).map_err(SynapseKitError::EmbeddingFailed)?;
    Ok((float_simhash::project(&pooled, seed), pooled))
}

// MARK: - MiniLMTextProvider

/// MiniLM-L6 v2 text embedding provider. 384-dimensional pooled
/// vector. Rust mirror of Swift `MiniLMTextProvider`.
pub struct MiniLMTextProvider {
    model_id: String,
    model_version: String,
    tokenizer: Box<dyn Tokenizer>,
    projection_seed: u64,
    inference: InferenceFn,
}

impl MiniLMTextProvider {
    /// Build with the Swift defaults (`model_id = "minilm-v6"`,
    /// `model_version = "1.0.0"`, `DeterministicTokenizer` with the
    /// MiniLM-L6 vocab id, the "MINLM_v1" projection seed) and a
    /// host-supplied inference seam.
    pub fn new(
        inference: impl Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static,
    ) -> Self {
        Self::with_parameters(
            "minilm-v6",
            "1.0.0",
            Box::new(DeterministicTokenizer::with_parameters(
                "minilm-l6-v2",
                30_522,
                128,
            )),
            MINILM_PROJECTION_SEED,
            inference,
        )
    }

    /// Build with explicit identity, tokenizer, and seed. The host
    /// injects a real tokenizer here once the model bundle carries
    /// the WordPiece vocab. The seed is parameterized only for
    /// tests; production callers use [`MiniLMTextProvider::new`] so
    /// the seed stays the cross-port constant.
    pub fn with_parameters(
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        tokenizer: Box<dyn Tokenizer>,
        projection_seed: u64,
        inference: impl Fn(&[i32]) -> Result<Vec<f32>, String> + Send + Sync + 'static,
    ) -> Self {
        MiniLMTextProvider {
            model_id: model_id.into(),
            model_version: model_version.into(),
            tokenizer,
            projection_seed,
            inference: Box::new(inference),
        }
    }
}

impl EmbeddingProvider for MiniLMTextProvider {
    fn model_id(&self) -> &str {
        &self.model_id
    }
    fn model_version(&self) -> &str {
        &self.model_version
    }
    fn embed(&self, text: &str) -> Result<Engram, SynapseKitError> {
        embed_via_seam(text, self.tokenizer.as_ref(), &self.inference, self.projection_seed)
    }
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, SynapseKitError> {
        embed_float_via_seam(text, self.tokenizer.as_ref(), &self.inference)
    }
    fn embed_pair(&self, text: &str) -> Result<(Engram, Vec<f32>), SynapseKitError> {
        embed_pair_via_seam(text, self.tokenizer.as_ref(), &self.inference, self.projection_seed)
    }
}


// MARK: - Tests
//
// Unit-level mirrors of Swift's ProvidersTests. The cross-language
// bit-identity gate lives in tests/embedding_conformance_tests.rs; these
// cover the seam behaviour the fixture cannot (e.g. that empty input
// never reaches a panicking host closure).

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minilm_projects_same_input_to_same_engram() {
        let p = MiniLMTextProvider::new(|_| Ok(vec![0.1f32; 384]));
        let a = p.embed("first text").unwrap();
        let b = p.embed("first text").unwrap();
        assert_eq!(a, b, "same input must produce the same engram");
    }

    #[test]
    fn empty_input_short_circuits_before_the_seam() {
        // MiniLM (always compiled) must not reach the host closure on empty input.
        let bomb = |_: &[i32]| -> Result<Vec<f32>, String> {
            Err("inference must not be called on empty input".to_string())
        };
        let mini = MiniLMTextProvider::new(bomb);
        assert_eq!(mini.embed("").unwrap(), Engram::ZERO);
        assert!(mini.embed_float("").unwrap().is_empty());
    }

    #[test]
    fn float_lane_returns_the_pooled_vector() {
        let p = MiniLMTextProvider::new(|_| Ok(vec![0.25f32; 384]));
        let floats = p.embed_float("anything").unwrap();
        assert_eq!(floats.len(), 384);
        assert!(floats.iter().all(|&f| f == 0.25));
    }

    #[test]
    fn host_inference_error_surfaces_as_embedding_failed() {
        let p = MiniLMTextProvider::new(|_| Err("model not loaded".to_string()));
        match p.embed("text") {
            Err(SynapseKitError::EmbeddingFailed(msg)) => assert!(msg.contains("model not loaded")),
            other => panic!("expected EmbeddingFailed, got {other:?}"),
        }
    }
}
