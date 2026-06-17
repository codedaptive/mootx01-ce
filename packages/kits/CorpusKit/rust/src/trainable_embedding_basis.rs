//! `TrainableEmbeddingBasis` — the type-erasure seam that lets a boxed
//! embedding provider be trained on a corpus and serialized to (and
//! reconstructed from) a basis blob, without a layering inversion.
//!
//! ## Why this trait lives in core `corpus-kit` (not `vectorkit`)
//!
//! Training-on-corpus is a corpus-kit concern, not a generic embedding
//! concern. `vectorkit::EmbeddingProvider` is the universal embed surface; it
//! must stay narrow so a future pre-trained encoder can conform WITHOUT being
//! forced to declare a training method it cannot honour. `TrainableEmbeddingBasis`
//! is the opt-in capability for the distributional providers (RI/PPMI/LSA/NMF)
//! that genuinely train on the estate's own content. FDC (stateless taxonomic)
//! and the deterministic/named-model providers do NOT implement it; their
//! opt-out is surfaced to callers as `CorpusKitError::NotTrainable`.
//!
//! ## Why this is the honest dispatch for type erasure
//!
//! `Corpus` holds the provider as `Box<dyn EmbeddingProvider>` (type-erased),
//! so it cannot call `train`/`serialize_basis`/`from_serialized_basis` — those
//! live on the concrete provider types in `corpus-kit-providers`, which core
//! cannot depend on (layering runs providers → core). This trait is the bridge:
//! core DECLARES it; `corpus-kit-providers` IMPLEMENTS it for its concrete
//! providers. `reconstruct_basis` returns `Box<dyn EmbeddingProvider>` (a trait
//! object cannot return `Self`), so the call routes to the correct concrete
//! type's `from_serialized_basis` without core ever naming it.
//!
//! ## The `EmbeddingProvider` supertrait (the Rust mirror of Swift's `as?`)
//!
//! Swift's `EmbeddingModel.reconstruct` runtime-casts the carried provider with
//! `as? TrainableEmbeddingBasis`. Rust has no runtime cross-cast between
//! unrelated trait objects, so the Rust mirror makes `EmbeddingProvider` a
//! SUPERTRAIT of `TrainableEmbeddingBasis`. A trained provider is therefore a
//! `Box<dyn TrainableEmbeddingBasis>` that UPCASTS to `Box<dyn EmbeddingProvider>`
//! (stable trait upcasting) wherever the corpus needs the embed surface. The
//! trainable `EmbeddingModelConfig` cases carry `Box<dyn TrainableEmbeddingBasis>`
//! directly, so `reconstruct` calls `reconstruct_basis` with no downcast and no
//! `Any`; the non-trainable cases (Deterministic / named / FDC) carry
//! `Box<dyn EmbeddingProvider>` and report `NotTrainable`.
//!
//! Swift port: packages/kits/CorpusKit/Sources/CorpusKit/TrainableEmbeddingBasis.swift

use crate::error::CorpusKitError;
use vectorkit::EmbeddingProvider;

/// A provider whose embedding basis is trained from a corpus and can be
/// serialized to / reconstructed from a versioned basis blob.
///
/// Implementors are the corpus-kit distributional providers (RI, PPMI, LSA,
/// NMF) in `corpus-kit-providers`. The trait is the type-erasure seam that lets
/// `Corpus` drive training and serialization without core depending on
/// `corpus-kit-providers`.
///
/// `EmbeddingProvider` is a supertrait so a `Box<dyn TrainableEmbeddingBasis>`
/// upcasts to `Box<dyn EmbeddingProvider>` for the corpus's embed surface — the
/// Rust mirror of Swift's `any EmbeddingProvider & Sendable` carried value plus
/// its `as? TrainableEmbeddingBasis` runtime probe.
pub trait TrainableEmbeddingBasis: EmbeddingProvider {
    /// Train this provider's basis on a corpus of raw document texts.
    ///
    /// The implementor is responsible for the FULL train+finalize sequence
    /// specific to its method:
    ///   - it tokenizes each text with the canonical `default_keyword_tokens`
    ///     where its training API consumes term sequences (RI, PPMI), or passes
    ///     raw text where its API consumes documents (LSA, NMF);
    ///   - it runs any required finalization pass (PPMI/LSA/NMF; RI has none).
    ///
    /// Deterministic: training is a pure function of `texts` and the provider's
    /// fixed seeds, so the same corpus yields a byte-identical basis on every
    /// run and on the Swift port. No wall-clock time is read.
    ///
    /// `texts` are raw document texts (NOT pre-tokenized term arrays).
    fn train_on_corpus(&mut self, texts: &[&str]);

    /// Serialize the trained basis to a versioned, little-endian blob.
    ///
    /// This is the same blob the concrete provider's `serialize_basis()`
    /// (mission 6a-i) produces; the trait merely surfaces it through type
    /// erasure. The byte layout is the cross-port conformance contract: the
    /// Swift implementor's `serializeBasis()` yields identical bytes for the
    /// same trained state.
    fn serialize_basis(&self) -> Vec<u8>;

    /// Reconstruct a fresh provider of this implementor's concrete type from a
    /// serialized basis blob, returned as a boxed `EmbeddingProvider`.
    ///
    /// The returned provider's `embed`/`embed_float` output is identical to the
    /// originally-trained provider's (round-trip law). Implemented by delegating
    /// to the concrete type's `from_serialized_basis` (mission 6a-i), so
    /// reconstruction routes to the correct concrete type without core naming it.
    ///
    /// Returns `Err(CorpusKitError::DecodingFailure)` on a truncated blob, an
    /// unknown format version, or a provider-magic mismatch — never panics.
    fn reconstruct_basis(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn EmbeddingProvider>, CorpusKitError>;
}
