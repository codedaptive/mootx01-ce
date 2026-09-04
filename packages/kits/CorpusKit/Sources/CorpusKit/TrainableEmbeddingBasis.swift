// TrainableEmbeddingBasis.swift
//
// The seam that lets a type-erased embedding provider be trained on a
// corpus and serialized to (and reconstructed from) a basis blob — without
// the layering inversion that would otherwise be required.
//
// ## Why this protocol lives in CorpusKit core (not SynapseKit)
//
// Training-on-corpus is a CorpusKit concern, not a generic embedding
// concern. SynapseKit's `EmbeddingProvider` is the universal embed surface;
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
import SynapseKit

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
    // resumes that snapshot on open. The maintained counts are consumed by:
    //   - Corpus.reindex (standalone): PPMI only, when the population guard passes
    //     (countsDocumentCount == activeChunks count), restored counts finalize into
    //     the serving basis (countsRestore decision). RI stays on the corpus path
    //     (countsDeltaFoldSafe == false; float accumulation is order-sensitive).
    //     LSA/NMF keep the corpus path because finalizeFromCounts() == false.
    //   - CorpusContentEngine.trainTrainableSlots (attached): PPMI may delta-fold
    //     pending reference rows into the restored counts (countsDeltaFold decision).
    //     RI is restore-only with an empty pending delta. LSA/NMF always use the
    //     full corpus re-tokenize path.

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

    /// Split maintained counts into a small header and one entry per vocabulary
    /// term, so storage does not have to hold the whole map in a single value.
    ///
    /// Optional by design. The default implementation returns `nil`, meaning
    /// "this provider has no term decomposition — persist me as one blob", and
    /// every provider whose counts are small keeps that behavior with no code.
    /// Only providers whose counts scale with vocabulary need to override it:
    /// RandomIndexing's map reached 1,009,861,855 bytes on a real estate and
    /// exceeded SQLite's bind ceiling (ee#49), while Nmf and Lsa sit at ~2 MB
    /// and gain nothing from the split.
    ///
    /// `header` MUST remain a valid counts blob on its own — same magic and
    /// format version, with an empty term map — so a reader that knows nothing
    /// about term rows still decodes it, and `counts` never becomes NULL.
    /// A NULL there is silently read as "no counts, start from zero", which
    /// would discard an estate's accumulated statistics.
    ///
    /// Each entry's `vector` is the provider's own per-term bytes, byte-identical
    /// to what the blob format writes for that term. Nothing recomputes, so
    /// cross-port byte equality is unaffected.
    func decomposeCounts() -> (header: Data, terms: [(term: String, vector: Data)])?

    /// Restore maintained counts from a header plus per-term entries — the
    /// inverse of `decomposeCounts()`.
    ///
    /// Default implementation throws `CorpusKitError.decodingFailure`; a
    /// provider that returns non-nil from `decomposeCounts()` MUST override
    /// this, and the pair is exercised together by the round-trip tests.
    func restoreCounts(header: Data, terms: [(term: String, vector: Data)]) throws

    /// Derive the finalized serving basis from accumulated maintained counts,
    /// reading NO corpus text.
    ///
    /// **Contract.** The caller has already restored maintained counts via
    /// `restoreCounts(from:)` or the term-decomposed `restoreCounts(header:terms:)`
    /// and MAY have folded additional delta texts via `addToCounts(text:)`.
    /// `finalizeFromCounts()` drives whatever method-specific finalization pass
    /// is needed and leaves this provider in the same state as a
    /// `trainOnCorpus` run over the same accumulated corpus:
    ///
    /// - **Returns `true`** when the provider's maintained counts fully determine
    ///   its basis without corpus text:
    ///   - *RandomIndexing* ("RICT"): the restored vocabulary of term-to-context
    ///     vectors IS the basis — restoration alone reproduces it; finalization is
    ///     a no-op, so `true` is returned immediately.
    ///   - *PPMI* ("PPMC"): the counts blob holds the full raw co-occurrence
    ///     state (coCount, termCount, totalPairs, totalTerms) — exactly what
    ///     `finalize()` consumes to derive `ppmiVectors`. One finalize pass
    ///     over the restored state yields a basis that is byte-identical to a
    ///     from-scratch `trainOnCorpus` over the same accumulated corpus. That
    ///     byte-identity through the digest gate is the acceptance contract.
    ///
    /// - **Returns `false`** when the maintained counts are insufficient:
    ///   - *LSA* / *NMF*: the counts blob holds only vocab + documentCount
    ///     trigger anchors; the per-document TF rows and per-term DF needed by
    ///     the factorization are deliberately NOT persisted (per the design-doc
    ///     open decision: re-tokenize at refactor time). No counts-only basis
    ///     can be derived. On `false` the provider's state is unchanged and the
    ///     caller MUST keep the corpus re-tokenization path.
    ///
    /// **Deterministic:** never reads wall-clock time.
    ///
    /// **Default:** returns `false` — counts-only refactoring is an explicit
    /// per-provider opt-in. A conformer that has not audited its counts payload
    /// MUST NOT be silently eligible.
    func finalizeFromCounts() -> Bool

    /// Whether folding ADDITIONAL texts into RESTORED maintained counts produces
    /// bytes identical to a from-scratch fold over the same corpus in canonical
    /// order.
    ///
    /// `true` only for providers whose accumulation is commutative — PPMI uses
    /// integer count maps (coCount, termCount, totalPairs, totalTerms) whose fold
    /// order is irrelevant to the derived basis. The finalize pass is a pure
    /// function of those counts, so restore + delta + finalize == from-scratch.
    ///
    /// `false` for float in-place accumulation (RandomIndexing): float addition
    /// is not associative, so folding additional texts after restore can produce
    /// context vectors that differ by a floating-point rounding step from a
    /// from-scratch fold in canonical order (reviewer finding F-3). For RI the
    /// counts path is restore-only with an EMPTY delta — no further accumulation.
    ///
    /// `false` is also correct for providers whose counts blob is insufficient to
    /// derive the basis at all (LSA, NMF), though that property is governed by
    /// `finalizeFromCounts()` returning `false`. The retrain wiring (Part 3)
    /// reads `countsDeltaFoldSafe` only after `finalizeFromCounts() == true`.
    ///
    /// **Default `false`:** delta-fold eligibility is an explicit, audited opt-in.
    /// A conformer that has not proved commutativity MUST keep the default.
    var countsDeltaFoldSafe: Bool { get }

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

    /// Default: no term decomposition. The provider is persisted as one blob,
    /// which is correct for every provider whose counts do not scale with
    /// vocabulary size.
    func decomposeCounts() -> (header: Data, terms: [(term: String, vector: Data)])? { nil }

    /// Default: unsupported. Reaching this means a caller tried to rehydrate
    /// term rows for a provider that never emits them, which is a wiring bug
    /// rather than bad data.
    func restoreCounts(header: Data, terms: [(term: String, vector: Data)]) throws {
        throw CorpusKitError.decodingFailure(
            "provider does not support term-decomposed counts")
    }

    /// Synthetic/test providers that do not expose a vocabulary conservatively
    /// treat every term as novel. Production distributional providers override
    /// this with their exact maintained-vocabulary lookup.
    func countsContainsTerm(_ term: String) -> Bool { false }

    /// Default: counts-only finalization is not supported. A conformer that
    /// has not explicitly audited its counts payload and confirmed it is
    /// sufficient to derive a byte-identical basis (the digest-gate acceptance
    /// contract) must not be silently eligible. Providers that CAN derive their
    /// basis from counts alone (RandomIndexing, PPMI) override this with `true`
    /// after the finalize pass completes; LSA and NMF keep the default because
    /// their per-document TF input is not persisted in the counts blob.
    func finalizeFromCounts() -> Bool { false }

    /// Default: delta-fold after restore is not safe. Providers whose accumulation
    /// is order-sensitive (float in-place, e.g. RandomIndexing) or whose counts
    /// blob does not fully determine the basis (LSA, NMF) keep this default.
    /// PPMI overrides to `true` because its integer count maps are commutative.
    var countsDeltaFoldSafe: Bool { false }
}
