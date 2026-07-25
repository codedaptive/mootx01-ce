// TrainableEmbeddingBasis.swift
//
// The seam that lets a type-erased embedding provider be trained on a
// corpus and serialized to (and reconstructed from) a basis blob — without
// the layering inversion that would otherwise be required.
//
// ## Why this protocol lives in CorpusKit core (not VectorKit)
//
// Training-on-corpus is a CorpusKit concern, not a generic embedding
// concern. VectorKit's `EmbeddingProvider` is the universal embed surface;
// it must stay narrow so a future pre-trained CoreML encoder can conform to
// it WITHOUT being forced to declare a training method it cannot honour.
// `TrainableEmbeddingBasis` is the opt-in capability for the distributional
// providers (RI/PPMI/LSA/NMF) that genuinely train on the estate's own
// content. FDC (stateless taxonomic) and the deterministic/named-model
// providers do NOT conform — their opt-out is a clean "does not implement
// this protocol", surfaced to callers as `CorpusKitError.notTrainable`.
//
// ## Why this is the honest dispatch for type erasure
//
// `Corpus` holds the provider as `any EmbeddingProvider` (type-erased), so
// it cannot itself call `train`/`serializeBasis`/`init(deserializing:)` —
// those live on the concrete provider types in CorpusKitProviders, which
// CorpusKit core cannot import (layering runs providers → core). This
// protocol is the bridge: CorpusKit core DECLARES it; CorpusKitProviders
// CONFORMS its concrete providers to it. A type-erased value that conforms
// can be driven through the protocol without core ever naming the concrete
// type. Reconstruction is an INSTANCE method (`reconstructBasis(from:)`)
// because only the concrete value knows how to deserialize into its own
// type — the protocol witness routes the call to the right
// `init(deserializing:)` without core importing the provider module.
//
// Rust port: packages/kits/CorpusKit/rust/src/trainable_embedding_basis.rs
// (the `TrainableEmbeddingBasis` trait).

import Foundation
import VectorKit

/// A provider whose embedding basis is trained from a corpus and can be
/// serialized to / reconstructed from a versioned basis blob.
///
/// Conformers are the CorpusKit distributional providers (RI, PPMI, LSA,
/// NMF) in `CorpusKitProviders`. The protocol is the type-erasure seam that
/// lets `Corpus` (which holds an `any EmbeddingProvider`) drive training and
/// serialization without CorpusKit core importing CorpusKitProviders.
///
/// Class-bound (`AnyObject`): every conformer is a reference-type provider
/// whose training mutates internal state in place, matching the existing
/// `final class` providers.
public protocol TrainableEmbeddingBasis: AnyObject, Sendable {

    /// Train this provider's basis on a corpus of raw document texts.
    ///
    /// The conformer is responsible for the FULL train+finalize sequence
    /// specific to its method:
    ///   - it tokenizes each text with the canonical `defaultKeywordTokens`
    ///     where its training API consumes term sequences (RI, PPMI), or
    ///     passes raw text where its API consumes documents (LSA, NMF);
    ///   - it runs any required finalization pass (PPMI/LSA/NMF; RI has none).
    ///
    /// Deterministic: this method MUST NOT call `Date()`/`now` — training is a
    /// pure function of `texts` and the provider's fixed seeds, so the same
    /// corpus yields a byte-identical basis on every run and on the Rust port.
    ///
    /// Training is additive over multiple calls where the underlying provider
    /// supports it, but the canonical usage is a single call with the whole
    /// corpus followed by serialization.
    ///
    /// - Parameter texts: raw document texts (NOT pre-tokenized term arrays).
    func trainOnCorpus(texts: [String])

    // MARK: - Streamed training (GLK shared-content 1.1 corrective pass)
    //
    // The bounded-memory training seam: callers stream the corpus in pages,
    // folding each page via `accumulateTraining` and running the method's
    // finalization pass exactly ONCE via `finalizeTraining`. For every
    // conformer, `accumulateTraining(pages...) + finalizeTraining()` is
    // BYTE-IDENTICAL to a single `trainOnCorpus(allTexts)` call — the pair
    // is the same per-text accumulation split from the same finalize, so
    // the trained basis (and its digest) does not depend on page size.
    // Peak memory is bounded by the accumulator (vocabulary-scale), never
    // by the corpus text.

    /// Fold one page of raw document texts into the SAME accumulation
    /// `trainOnCorpus` uses, WITHOUT finalizing. Deterministic; additive;
    /// order-sensitive exactly as `trainOnCorpus` is (callers stream in
    /// canonical ascending-ID order).
    func accumulateTraining(texts: [String])

    /// Run the method-specific finalization pass over the accumulated
    /// state (PPMI/LSA/NMF; RI has none — no-op). Call exactly once,
    /// after the last `accumulateTraining` page.
    func finalizeTraining()

    /// Serialize the trained basis to a versioned, little-endian blob.
    ///
    /// This is the same blob the concrete provider's `serializeBasis()`
    /// (mission 6a-i) produces; the protocol merely surfaces it through type
    /// erasure. The byte layout is the cross-port conformance contract: the
    /// Rust conformer's `serialize_basis` yields identical bytes for the same
    /// trained state.
    func serializeBasis() -> Data

    /// Reconstruct a fresh provider of this conformer's concrete type from a
    /// serialized basis blob.
    ///
    /// The returned provider's `embed`/`embedFloat` output is identical to the
    /// originally-trained provider's (round-trip law). Implemented by
    /// delegating to the concrete type's `init(deserializing:)` (mission 6a-i),
    /// so reconstruction routes to the correct concrete type without CorpusKit
    /// core naming it.
    ///
    /// This is an instance method (not a static/initializer) so it can be
    /// invoked on a type-erased witness: `EmbeddingModel.reconstruct(from:)`
    /// calls it on the provider the enum case already carries, which IS the
    /// right concrete type.
    ///
    /// - Parameter basis: the serialized basis blob.
    /// - Returns: a reconstructed provider, type-erased to
    ///   `any EmbeddingProvider & Sendable`.
    /// - Throws: `CorpusKitError.decodingFailure` on a truncated blob, an
    ///   unknown format version, or a provider-magic mismatch — never crashes.
    func reconstructBasis(from basis: Data) throws -> any EmbeddingProvider & Sendable

    /// Release the in-memory trained vocabulary. The next
    /// `embed` call will need to reload from BasisStore. Called after
    /// reindex/reembed completes to free the ~2GB of `[Float]` arrays
    /// that the vocab dictionary holds. Providers that have no in-memory
    /// state (FDC, stateless providers) are no-ops.
    func releaseBasis()

    // MARK: - Maintained counts (incremental-counts change set, P3)
    //
    // The counts seam lets `Corpus` keep each trainable provider's raw additive
    // statistics current AS CHUNKS ARE WRITTEN — the "increment as we go" table —
    // instead of rebuilding them from scratch by re-reading the whole corpus on
    // every reindex. `Corpus` holds the provider type-erased, so these uniform
    // methods are the bridge: each conformer routes them to its own
    // method-specific accumulation (RI/PPMI fold term sequences; LSA/NMF fold
    // documents). The accumulated state is the SAME state `finalize()` consumes;
    // maintaining it incrementally is what makes a future refactor cheap.
    //
    // Persistence is the caller's job and happens at BATCH boundaries, never per
    // chunk: re-serializing the whole counts blob on every chunk would be
    // O(N·vocab) over an import — the very wall this change set removes. The
    // provider accumulates in memory; `Corpus` snapshots via `serializeCounts()`
    // when a batch closes and on shutdown points, and `restoreCounts(from:)`
    // resumes that snapshot on open. NOTE: the maintained-counts path is
    // infrastructure only; Corpus.reindex currently still trains from active
    // chunk text via trainOnCorpus(texts:), not from these maintained counts.

    /// Fold one chunk's raw text into the maintained accumulated counts.
    ///
    /// The conformer tokenizes with the canonical `defaultKeywordTokens` where
    /// its accumulation consumes term sequences (RI, PPMI), or folds the raw
    /// document where it consumes documents (LSA, NMF). This is the per-chunk
    /// half of the same additive logic `trainOnCorpus` runs over a whole corpus,
    /// surfaced so `Corpus` can drive it once per chunk at write time.
    ///
    /// Deterministic: never reads wall-clock time. Does NOT finalize — the
    /// derived basis is produced separately at refactor.
    ///
    /// - Parameter text: one chunk's raw document text.
    func addToCounts(text: String)

    /// Serialize the maintained accumulated counts to a versioned blob.
    ///
    /// Distinct from `serializeBasis()`: this is the RAW additive state (the
    /// maintained statistics table), not the derived basis. Persisted in
    /// `corpus_provider_counts` (vs. the basis in `corpus_provider_basis`) so a
    /// refactor can read the table instead of re-tokenizing the corpus. The byte
    /// layout is the cross-port conformance contract.
    func serializeCounts() -> Data

    /// Restore maintained counts from a blob, resuming incremental upkeep across
    /// a restart. Mutates this provider's accumulation in place; does NOT rebuild
    /// the derived basis (reconstructed separately from the basis blob).
    ///
    /// - Throws: `CorpusKitError.decodingFailure` on a truncated blob, an unknown
    ///   format version, or a provider-magic mismatch — never crashes.
    func restoreCounts(from data: Data) throws

    /// The maintained vocabulary size — the cheap anchor the vocab-growth retrain
    /// trigger reads to decide when a basis has drifted enough to warrant a
    /// refactor. Reflects the current accumulated state, not the derived basis.
    var countsVocabularySize: Int { get }

    /// Whether the published counts generation already contains `term`.
    ///
    /// Attached engines use this read-only seam to persist only the hashes of
    /// genuinely novel terms in their compact growth references. The published
    /// counts blob remains frozen between provider publications: revisions do
    /// not append obsolete text into an in-memory accumulator, so live and
    /// reopened growth state are identical.
    func countsContainsTerm(_ term: String) -> Bool
}

public extension TrainableEmbeddingBasis {
    /// Synthetic/test providers that do not expose a vocabulary conservatively
    /// treat every term as novel. Production distributional providers override
    /// this with their exact maintained-vocabulary lookup.
    func countsContainsTerm(_ term: String) -> Bool { false }
}
