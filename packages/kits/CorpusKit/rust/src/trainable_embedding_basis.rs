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

    /// Streamed-training page (GLK shared-content 1.1 corrective pass): fold
    /// one page of raw document texts into the SAME accumulation
    /// `train_on_corpus` uses, WITHOUT finalizing. For every implementor,
    /// `accumulate_training(pages...) + finalize_training()` is BYTE-IDENTICAL
    /// to a single `train_on_corpus(all_texts)` — the pair is the same
    /// per-text accumulation split from the same finalize, so the trained
    /// basis (and its digest) does not depend on page size. Peak memory is
    /// bounded by the accumulator (vocabulary-scale), never the corpus text.
    fn accumulate_training(&mut self, texts: &[&str]);

    /// Run the method-specific finalization pass over the accumulated state
    /// (PPMI/LSA/NMF; RI has none — no-op). Call exactly once, after the
    /// last `accumulate_training` page.
    fn finalize_training(&mut self);

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

    /// release the in-memory trained vocabulary to free heap.
    /// The next embed call must go through reconstruct_basis from BasisStore.
    fn release_basis(&mut self);

    /// Reconstruct a fresh provider from a serialized basis, returned as a boxed
    /// `TrainableEmbeddingBasis` (i.e. RETAINING the trainable capability).
    ///
    /// ## Why this exists (the Rust-only parity need, mission 6a-ii-β)
    ///
    /// `train_on_corpus` is ADDITIVE — it accumulates over calls — so a correct
    /// `reindex` must train a FRESH provider from scratch, never retrain an
    /// already-trained one. Swift's `Corpus` gets this for free: it reconstructs
    /// from the empty-basis blob and the result is the concrete trainable type,
    /// which Swift recovers with a runtime `as?` cast. Rust has no runtime
    /// cross-cast between trait objects, and `reconstruct_basis` returns a PLAIN
    /// `Box<dyn EmbeddingProvider>` whose trainability is unrecoverable. This
    /// sibling returns the trainable box directly so `Corpus::reindex` /
    /// first-ingest can rebuild a fresh trainable provider from the empty blob
    /// and train it from scratch — the byte-for-byte parity with the Swift
    /// from-scratch basis.
    ///
    /// The default implementation is unimplemented because a trait method cannot
    /// return `Box<Self>` generically; each concrete implementor overrides it to
    /// delegate to its own `from_serialized_basis` (mission 6a-i). No new math —
    /// it is the same constructor `reconstruct_basis` uses, boxed as trainable.
    ///
    /// Returns `Err(CorpusKitError::DecodingFailure)` on a truncated blob, an
    /// unknown format version, or a provider-magic mismatch — never panics.
    fn reconstruct_trainable_basis(
        &self,
        basis: &[u8],
    ) -> Result<Box<dyn TrainableEmbeddingBasis>, CorpusKitError>;

    // ----- Maintained counts (incremental-counts change set, P3) -----------
    //
    // The counts seam lets `Corpus` keep each trainable provider's raw additive
    // statistics current AS CHUNKS ARE WRITTEN — the "increment as we go" table —
    // instead of rebuilding them from scratch by re-reading the whole corpus on
    // every reindex. `Corpus` holds the provider as `Box<dyn ...>`, so these
    // uniform methods are the bridge: each implementor routes them to its own
    // method-specific accumulation (RI/PPMI fold term sequences; LSA/NMF fold
    // documents). Persistence is the caller's job and happens at BATCH
    // boundaries, never per chunk: re-serializing the whole counts blob on every
    // chunk would be O(N·vocab) over an import — the very wall this removes.
    //
    // Swift mirror: the `addToCounts` / `serializeCounts` / `restoreCounts` /
    // `countsVocabularySize` requirements on `TrainableEmbeddingBasis`.

    /// Fold one chunk's raw text into the maintained accumulated counts.
    ///
    /// The implementor tokenizes with the canonical `default_keyword_tokens`
    /// where its accumulation consumes term sequences (RI, PPMI), or folds the
    /// raw document where it consumes documents (LSA, NMF). This is the per-chunk
    /// half of the same additive logic `train_on_corpus` runs over a whole
    /// corpus. Deterministic; does NOT finalize.
    fn add_to_counts(&mut self, text: &str);

    /// Serialize the maintained accumulated counts to a versioned blob — the RAW
    /// additive state (the maintained statistics table), not the derived basis.
    /// Persisted in `corpus_provider_counts`. Byte-identical to the Swift
    /// implementor's `serializeCounts()`.
    fn serialize_counts(&self) -> Vec<u8>;

    /// Restore maintained counts from a blob, resuming incremental upkeep across
    /// a restart. Mutates accumulation in place; does NOT rebuild the derived
    /// basis. Returns `Err(CorpusKitError::DecodingFailure)` on a bad blob.
    fn restore_counts(&mut self, bytes: &[u8]) -> Result<(), CorpusKitError>;

    /// The maintained vocabulary size — the cheap anchor the vocab-growth retrain
    /// trigger reads to decide when a basis has drifted enough to warrant a
    /// refactor. Reflects the current accumulated state, not the derived basis.
    fn counts_vocabulary_size(&self) -> usize;

    /// Whether the published counts generation already contains `term`.
    ///
    /// Attached engines use this read-only seam to retain hashes only for
    /// genuinely novel terms. The default keeps synthetic test providers
    /// source-compatible; every production distributional provider overrides
    /// it with an exact vocabulary lookup.
    fn counts_contains_term(&self, _term: &str) -> bool {
        false
    }
}
