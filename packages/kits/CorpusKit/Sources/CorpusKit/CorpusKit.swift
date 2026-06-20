// CorpusKit.swift
//
// Public entry point for CorpusKit: the Corpus actor.
//
// The actor composes BundleStore (chunk persistence), BM25Index
// (keyword recall), VectorStore (vector kNN), and an EmbeddingProvider
// (text → engram) behind a sealed surface. Callers see only documents
// and queries — no VectorKit type is exposed on the public API.
//
// EmbeddingModel is a CorpusKit-owned enum so the host can select an
// embedding model without importing VectorKit or naming EmbeddingProvider.
// The deterministic default requires no CoreML model bundle; the named
// model cases (miniLM, mpNet, embeddingGemma) accept a host-supplied
// inference closure and handle tokenization + projection internally.
//
// CorpusKitProviders ships concrete text providers for production use.
// The Corpus actor's EmbeddingModel.miniLM / .mpNet / .embeddingGemma
// cases use the same modelID, projectionSeed, and FNV-1a tokenization
// parameters as CorpusKitProviders — callers that supply a CoreML
// inference closure through EmbeddingModel get consistent storage keys
// and can later switch to CorpusKitProviders directly if preferred.

import EngramLib
import Foundation
import IntellectusLib
import OSLog
import PersistenceKit
import SubstrateML
import SubstrateTypes
import VectorKit

// MARK: - FloatLaneOutcome

/// The observable outcome of a `Corpus.floatNearest` call.
///
/// Dark outcomes (`.unavailableProviderOptOut`, `.unavailableNoFloatRows`,
/// `.emptyQuery`) are EXPECTED degradations — the calling lane degrades
/// gracefully and emits an explainer marker. `.storeError` is NOT expected:
/// it is logged via OSLog and emitted as a telemetry counter so that store
/// failures are never swallowed silently. `.hits` is the happy path.
///
/// Callers must never treat a dark outcome as an error — per the softPrior
/// grammar a dark dense lane means the query runs on the other lanes only,
/// not that the query failed.
public enum FloatLaneOutcome: Sendable {
    /// The lane ran and returned at least one ranked hit.
    ///
    /// - Parameter hits: `(itemID, cosineSimilarity)` pairs, nearest first.
    ///   `itemID` is the `sourceID` the caller ingested under (drawer ID in
    ///   the GLK context). Similarity ∈ [−1, 1], 1.0 = identical direction.
    case hits([(itemID: String, similarity: Float)])

    /// Provider opted out of the float lane — expected, not an error.
    ///
    /// The configured `EmbeddingProvider` threw `VectorKitError.embeddingFailed`
    /// on the embed call, indicating it has no float lane at all (structural
    /// opt-out). This is the normal outcome for the default `.deterministic`
    /// provider and for any provider that does not override `embedFloat`. The
    /// dense lane is dark for this corpus; all other lanes are unaffected.
    ///
    /// Distinct from `.unavailableNoVocabHit`: that case indicates a TRAINED
    /// distributional provider where this specific query's tokens are all
    /// out-of-vocabulary. Both produce no float candidates, but the cause
    /// differs — a structural opt-out vs a vocabulary coverage gap.
    case unavailableProviderOptOut

    /// Trained distributional provider returned no float vector because all
    /// query tokens are out-of-vocabulary (OOV) — expected, not an error.
    ///
    /// The provider HAS a trained basis (vocab is non-empty) but none of the
    /// query's tokens appear in it. This is the normal outcome for a query on
    /// a thinly-trained estate or a query using vocabulary the corpus never saw.
    /// The dense lane is dark for this query; recall continues on other lanes.
    ///
    /// Distinct from `.unavailableProviderOptOut` (provider has no float lane
    /// at all) and from `.unavailableNoFloatRows` (provider supports float but
    /// ingest has not run yet or stored no rows).
    ///
    /// Surface string: `dense_lane:dark:vocabMiss`.
    case unavailableNoVocabHit

    /// No float rows are stored — expected when ingest has not run yet or the
    /// provider opted out during ingest. Dense lane is dark; other lanes are
    /// unaffected.
    case unavailableNoFloatRows

    /// Query was empty or `limit` was zero — the call was a no-op.
    ///
    /// Not a store error; the caller supplied a query that cannot produce
    /// results. No telemetry emitted for this case beyond the outcome itself.
    case emptyQuery

    /// The vector store threw an error during `findNearestFloat`.
    ///
    /// This is NOT an expected degradation. CorpusKit logs the error via OSLog
    /// (category "CorpusKit") and emits a `corpus.float_lane.store_error`
    /// telemetry counter so the failure is observable. The query still succeeds
    /// on the other lanes — this outcome degrades, not fails.
    ///
    /// - Parameter error: The underlying store error. Included for logging at
    ///   the call site; not propagated to the caller as a thrown error.
    case storeError(Error)
}

/// CorpusKit OSLog logger (category "CorpusKit").
///
/// Used by `floatNearest` to log store errors so they are never swallowed.
/// Declared at file scope to avoid repeated Logger construction on the hot path
/// (Logger init is not free on older OS versions).
private let corpusLog = Logger(subsystem: "com.mootx01.kit", category: "CorpusKit")

// MARK: - EmbeddingModel

/// Selects the embedding model the Corpus actor uses internally.
///
/// The caller names a CorpusKit case; no VectorKit type is required
/// at the call site.
///
/// `.deterministic` is the permanent, federation-grade vector provider
/// present in every version (v1.0+). It uses FNV-1a tokenization +
/// FloatSimHash projection, requires no CoreML model bundle, and produces
/// byte-identical vectors cross-device and cross-port — the reproducibility
/// federation requires. It captures surface/lexical signal, not learned
/// semantic meaning.
///
/// The named model cases (`.miniLM`, `.mpNet`, `.embeddingGemma`) are the
/// ADDITIVE v1.1 on-device learned semantic lane. They produce richer,
/// model-dependent vectors for enhanced on-device search but cannot serve
/// as the federation vector (model weights differ across devices). They do
/// not replace the deterministic lane; both lanes coexist.
public enum EmbeddingModel: Sendable {

    /// Permanent, federation-grade deterministic vector provider.
    ///
    /// Uses FNV-1a tokenization + FloatSimHash projection with a fixed
    /// seed (`0xC05BD15CA15D1B00`). Produces byte-identical 32-element
    /// float vectors across calls, across Swift/Rust ports, and across
    /// devices — the reproducibility federation requires. Captures
    /// surface/lexical signal; not a learned semantic embedding.
    ///
    /// This is NOT a test stand-in or placeholder. It is the vector
    /// representation that every version of the system (v1.0 through
    /// any future version) uses for the federation-synchronized lane.
    case deterministic

    /// MiniLM v6 text embedding (384-dim pooled output).
    ///
    /// CorpusKit handles FNV-1a tokenization (vocab 30522, max 128
    /// tokens) and FloatSimHash projection with the canonical MiniLM
    /// seed. The caller supplies the CoreML inference closure.
    ///
    /// - Parameter inference: Takes FNV-1a token ids and returns a
    ///   pooled 384-element float vector.
    case miniLM(inference: @Sendable ([Int32]) async throws -> [Float])

    /// MPNet base v2 text embedding (768-dim pooled output).
    ///
    /// CorpusKit handles FNV-1a tokenization (vocab 30522, max 128
    /// tokens) and FloatSimHash projection with the canonical MPNet
    /// seed.
    ///
    /// - Parameter inference: Takes FNV-1a token ids and returns a
    ///   pooled 768-element float vector.
    case mpNet(inference: @Sendable ([Int32]) async throws -> [Float])

    /// Embedding-Gemma 300M (768-dim pooled output).
    ///
    /// CorpusKit handles FNV-1a tokenization (vocab 256000, max 2048
    /// tokens) and FloatSimHash projection with the canonical
    /// EmbeddingGemma seed.
    ///
    /// - Parameter inference: Takes FNV-1a token ids and returns a
    ///   pooled 768-element float vector.
    case embeddingGemma(inference: @Sendable ([Int32]) async throws -> [Float])

    /// Random Indexing distributional-semantics provider.
    ///
    /// The caller constructs and trains a `RandomIndexingProvider` from
    /// `CorpusKitProviders`, then passes it here. The trained provider is
    /// self-contained: it requires no CoreML model bundle, no host inference
    /// closure, and captures co-occurrence semantics from the estate's own
    /// content during training.
    ///
    /// Unlike the named model cases, `.randomIndexing` carries the fully-built
    /// provider rather than an inference closure, because the provider state
    /// (the trained vocabulary) is built externally by the caller before
    /// constructing the Corpus.
    ///
    /// See ADR-010 Decision B for the rationale and `RandomIndexingProvider`
    /// in `CorpusKitProviders` for the full training API.
    case randomIndexing(provider: any EmbeddingProvider & Sendable)

    /// PPMI distributional-semantics provider.
    ///
    /// The caller constructs, trains, and finalizes a `PpmiProvider` from
    /// `CorpusKitProviders`, then passes it here.  Unlike RI, PPMI accumulates
    /// co-occurrence counts in a first pass and then computes PPMI-weighted
    /// context sums in a second pass (via `PpmiProvider.finalize()`).
    ///
    /// PPMI differs from RI in that each context term's contribution is
    /// weighted by its PPMI score (max(0, log(P(t,c)/(P(t)·P(c))))).
    /// Stopword-like co-occurrences are down-weighted toward zero; genuinely
    /// informative associations dominate.  The distinction is real: it is not
    /// an alias for `.randomIndexing`.
    ///
    /// See ADR-010 Decision B for the rationale and `PpmiProvider`
    /// in `CorpusKitProviders` for the full training API.
    case ppmi(provider: any EmbeddingProvider & Sendable)

    /// LSA (Latent Semantic Analysis) distributional-semantics provider.
    ///
    /// The caller constructs and trains an `LsaProvider` (term-document matrix +
    /// deterministic Jacobi SVD truncated to k dimensions) and passes it here.
    ///
    /// See ADR-010 Decision B for the rationale and `LsaProvider` in
    /// `CorpusKitProviders` for the full training API.
    case lsa(provider: any EmbeddingProvider & Sendable)

    /// NMF (Non-Negative Matrix Factorization) distributional-semantics provider.
    ///
    /// The caller constructs, trains, and finalizes an `NmfProvider` (TF-weighted
    /// term-document matrix factorized via SubstrateML's NMFAlternatingLeastSquares
    /// with fixed iteration count for determinism) and passes it here.
    ///
    /// Document embeddings are the L2-normalised column vectors of the H factor;
    /// query embeddings use the pseudo-inverse fold-in formula on W.
    ///
    /// See ADR-010 Decision B for the rationale and `NmfProvider` in
    /// `CorpusKitProviders` for the full training API.
    case nmf(provider: any EmbeddingProvider & Sendable)

    /// FDC (Frame Decimal Classification) co-classification provider.
    ///
    /// The caller constructs an `FDCProvider` from `CorpusKitProviders` and
    /// passes it here. The provider is stateless — no training step is required.
    /// It encodes text to a deterministic float vector derived from the text's
    /// FDC classification code, such that codes sharing a longer prefix (more
    /// common ancestors in the FDC taxonomy) have higher cosine similarity.
    ///
    /// Unlike the distributional providers (RI/PPMI/LSA/NMF), FDCProvider
    /// requires no corpus training — it is ready to use immediately. Its recall
    /// signal reflects taxonomic proximity (class co-membership), not
    /// co-occurrence. The two signal types complement each other: distributional
    /// methods are strong on topical neighbours; FDC is strong on categorical siblings.
    ///
    /// The float lane is dark (returns `[]`) for texts the FDC engine cannot
    /// classify (UNRESOLVED). This is the expected opt-out, not an error.
    ///
    /// See ADR-010 Decision B (FDC lattice co-classification) and `FDCProvider`
    /// in `CorpusKitProviders` for the encoding details.
    case fdc(provider: any EmbeddingProvider & Sendable)

    /// Default: deterministic (no CoreML required).
    public static let `default`: EmbeddingModel = .deterministic

    // MARK: - Trainable-basis seam (mission 6a-ii-α)

    /// The provider this model carries, if the case carries one.
    ///
    /// The distributional and FDC cases carry an externally-built provider;
    /// the deterministic and named-model cases carry an inference closure (or
    /// nothing) and construct their provider lazily in `makeProvider()`. This
    /// accessor is the join point for the trainable-basis seam: it returns the
    /// carried provider so `reconstruct(from:)` and `isTrainable` can probe its
    /// `TrainableEmbeddingBasis` conformance without re-running construction.
    private var carriedProvider: (any EmbeddingProvider & Sendable)? {
        switch self {
        case .randomIndexing(let p), .ppmi(let p), .lsa(let p), .nmf(let p), .fdc(let p):
            return p
        case .deterministic, .miniLM, .mpNet, .embeddingGemma:
            return nil
        }
    }

    /// Whether this model's provider can be trained on a corpus and
    /// reconstructed from a serialized basis.
    ///
    /// True only when the carried provider conforms to
    /// `TrainableEmbeddingBasis` (the RI/PPMI/LSA/NMF distributional
    /// providers). FDC carries a provider but is stateless and does NOT
    /// conform, so it reports `false`. The deterministic and named-model
    /// cases carry no provider and report `false`.
    ///
    /// This is the capability-detection helper `Corpus` will use (β mission)
    /// before attempting to drive training/serialization through the seam. It
    /// changes no runtime behaviour on its own.
    public var isTrainable: Bool {
        carriedProvider is TrainableEmbeddingBasis
    }

    /// Reconstruct the provider for this model from a serialized basis blob.
    ///
    /// Dispatched by the enum case, which knows whether its carried provider
    /// is a `TrainableEmbeddingBasis`. A type-erased value cannot reconstruct
    /// itself into its concrete type, so reconstruction is routed through the
    /// `TrainableEmbeddingBasis.reconstructBasis(from:)` witness on the carried
    /// provider — which IS the right concrete type and delegates to that
    /// type's `init(deserializing:)`. CorpusKit core never names the concrete
    /// provider type, so layering (providers → core) is preserved.
    ///
    /// The deterministic and named-model cases, and the stateless FDC case,
    /// have no trained basis to restore and throw `CorpusKitError.notTrainable`
    /// rather than crashing or returning a wrong provider.
    ///
    /// - Parameter basis: the serialized basis blob (from `serializeBasis()`).
    /// - Returns: a reconstructed provider, type-erased.
    /// - Throws: `CorpusKitError.notTrainable` when the model is not a
    ///   trainable-basis conformer; `CorpusKitError.decodingFailure` when the
    ///   blob is truncated, the format version is unknown, or the provider
    ///   magic does not match the carried provider's type.
    public func reconstruct(from basis: Data) throws -> any EmbeddingProvider & Sendable {
        guard let trainable = carriedProvider as? TrainableEmbeddingBasis else {
            throw CorpusKitError.notTrainable(
                "embedding model is not a trainable-basis provider; reconstruction "
                + "from a serialized basis is only supported for RI/PPMI/LSA/NMF")
        }
        return try trainable.reconstructBasis(from: basis)
    }
}

// MARK: - Corpus

/// Unified RAG entry point for CorpusKit.
///
/// Corpus composes BundleStore, BM25Index, VectorStore, and one OR MORE
/// EmbeddingProviders internally. The public surface exposes only
/// `ingest`, `recall`, `remove`, and `count`. No VectorKit type
/// appears in any public signature — the sealed-vector principle is
/// enforced here, not by the caller.
///
/// Lifecycle: construct with a PersistenceKit Storage (the actor calls
/// `storage.open(schema:)` for both BundleStore and VectorStore during
/// `init`), then call `ingest` to add documents and `recall` to query.
/// The BundleStore is append-only; `remove(sourceID:)` clears the
/// recall index (BM25 + vectors) without deleting content rows.
///
/// ## N-provider capability (mission 6a-iii-core)
///
/// Corpus holds an ORDERED collection of provider slots, one per held
/// `EmbeddingModel`, each keyed by its `modelID`. The single-provider
/// `init(storage:model:)` is the N=1 special case: it builds a one-slot
/// corpus that behaves byte-identically to the pre-6a-iii single-provider
/// implementation. Multi-provider `init(storage:models:)` fans every
/// operation (ingest embed, reindex train, remove, destroy) across all slots,
/// each under its own `modelID`, so the VectorStore/BasisStore — already keyed
/// by (modelID, modelVersion) — hold the N providers' rows side by side with
/// no schema change.
///
/// The single-signal entry points (`recall`, `floatNearest`, `embed`,
/// `embedFloat`, `modelID`, `supportsFloat`) delegate to the DEFAULT signal —
/// the first held slot — so existing callers are unaffected. The per-signal
/// fan-out for recall is exposed additively via `floatNearestPerSignal`, the
/// 6b RRF-fusion seam (this mission builds the seam, NOT the fusion).
public actor Corpus {

    /// One held embedding provider plus its fresh-basis blob.
    ///
    /// A slot is the per-provider unit the N-provider corpus fans operations
    /// over. `provider` is the serving provider (replaced in place by training
    /// or by load-on-open reconstruction — hence `var`); `freshBasisBlob` is
    /// the EMPTY (untrained) serialized basis captured ONLY for a fresh
    /// trainable provider with no persisted basis (see the field doc below).
    /// For N=1 the corpus holds exactly one slot, and every fan-out loop runs
    /// once — byte-identical to the pre-6a-iii single-provider path.
    private struct ProviderSlot {
        /// The serving provider for this signal. `var` because the load-on-open
        /// path and each training pass install a replacement. Never exposed on
        /// the public surface (sealed-vector principle).
        var provider: any EmbeddingProvider
        /// The serialized basis of a FRESH (untrained) trainable provider,
        /// captured ONLY when this slot was built from a fresh trainable
        /// provider (RI/PPMI/LSA/NMF) with no persisted basis — NOT when the
        /// provider was restored from a persisted basis on open.
        ///
        /// Each training pass (`reindex` and the first-ingest auto-train)
        /// reconstructs a FRESH provider from this empty-basis blob, trains it
        /// on the full corpus, and installs it as `provider`. This is the only
        /// correct retrain semantics: `trainOnCorpus` is ADDITIVE (it
        /// accumulates over calls), so retraining an already-trained provider
        /// would double-count the first-ingest corpus. Reconstructing from the
        /// empty blob guarantees every train starts from scratch, so reindex is
        /// idempotent and produces the canonical from-scratch basis (the
        /// cross-port conformance contract).
        ///
        /// When the provider was restored from a persisted basis on open, this
        /// is nil: a reopened corpus is already trained and serving; `reindex`
        /// then re-embeds under the loaded basis without retraining. This
        /// deliberately mirrors the Rust port, where the seam's
        /// `reconstruct_basis` yields a non-trainable boxed provider, so a
        /// reopened-from-blob corpus is not retrained-in-place on either port.
        let freshBasisBlob: Data?
    }

    private let bundleStore: BundleStore
    private let bm25: BM25Index
    private let vectorStore: VectorStore
    private let basisStore: BasisStore
    /// The ordered per-provider slots, one per held `EmbeddingModel`, in
    /// construction order. `slots[0]` is the DEFAULT signal that the
    /// single-signal entry points delegate to. Never empty: every init builds
    /// at least one slot. For N=1 this holds exactly one slot.
    private var slots: [ProviderSlot]
    private var hlcGenerator: HLCGenerator
    /// Maps chunk UUID → sourceID for the `bm25TopKBySource` join.
    ///
    /// Populated on `init` (from persisted chunks) and on each `ingest` call.
    /// Cleared per-source on `remove(sourceID:)`. The map is in-memory only;
    /// it is rebuilt from BundleStore on every process restart alongside the
    /// BM25 index, so the two stay in sync.
    private var chunkSourceMap: [UUID: String] = [:]

    /// Test-only: when non-nil, `floatNearest` returns `.storeError(this)` immediately,
    /// bypassing the real vector store. Set via `_testForceFloatStoreError(_:)`.
    /// Never set in production code; documented here so future agents do not mistake
    /// this property for production logic.
    var _forcedFloatError: Error? = nil

    /// Construct a single-provider Corpus against a PersistenceKit Storage.
    ///
    /// This is the N=1 entry point. It delegates to `init(storage:models:)`
    /// with a one-element model set, so a single-provider corpus is just the
    /// degenerate case of the N-provider corpus — ONE code path, not two — and
    /// behaves byte-identically to the pre-6a-iii single-provider
    /// implementation. The production default remains a single provider; this
    /// init's signature is PRESERVED so every existing call site compiles
    /// unchanged (mission 6a-iii-core back-compat mandate).
    ///
    /// - Parameters:
    ///   - storage: A PersistenceKit Storage instance. Both the
    ///     BundleStore and VectorStore schemas are applied here; if the
    ///     same storage is shared with other kits their schemas must be
    ///     applied separately before or after this call.
    ///   - model: Embedding model selection. Defaults to `.deterministic`
    ///     (no CoreML required).
    public init(storage: any Storage, model: EmbeddingModel = .default) async throws {
        try await self.init(storage: storage, models: [model])
    }

    /// Construct an N-provider Corpus against a PersistenceKit Storage.
    ///
    /// Builds one ordered provider slot per element of `models`, each keyed by
    /// its `modelID`. `models[0]` becomes the DEFAULT signal that the
    /// single-signal entry points (`recall`, `floatNearest`, `embed`,
    /// `embedFloat`, `modelID`, `supportsFloat`) delegate to. Every fan-out
    /// operation (ingest embed, reindex train, remove, destroy) runs across all
    /// slots, each under its own modelID — the VectorStore/BasisStore are
    /// already keyed by (modelID, modelVersion), so N providers' rows coexist
    /// with no schema change.
    ///
    /// For each slot: build the fresh provider, then — if it is a trainable
    /// distributional provider AND a basis was previously persisted for its
    /// (modelID, modelVersion) — reconstruct the trained provider from that
    /// blob so the dense lane is trained-ready immediately after restart,
    /// without re-running training on every open. A non-trainable provider, or
    /// a trainable provider with no persisted basis yet, keeps the fresh one.
    ///
    /// - Parameters:
    ///   - storage: A PersistenceKit Storage instance (schemas applied here).
    ///   - models: One or more embedding model selections, in priority order.
    ///     Must be non-empty; `models[0]` is the default signal. Distinct
    ///     `modelID`s are expected — two slots with the same modelID would key
    ///     the same vector/basis rows and is a caller error.
    public init(storage: any Storage, models: [EmbeddingModel]) async throws {
        precondition(!models.isEmpty, "Corpus requires at least one embedding model")

        // Apply both schema declarations. `open(schema:)` is version-gated
        // (skips if the schema version is already current). Since both
        // BundleStore and VectorStore are version 1, the second `open` would
        // be skipped when called on the same storage; `migrate(to:)` bypasses
        // the gate and ensures all tables are created regardless of which
        // schema was applied first.
        try await storage.migrate(to: BundleStore.schemaDeclaration)
        try await storage.migrate(to: VectorStore.schemaDeclaration)
        // Additive basis-persistence table (mission 6a-ii-β). A separate
        // schema declaration applied via migrate(to:) so the table is created
        // regardless of the other schemas' version gates, exactly like the
        // BundleStore/VectorStore pair above.
        try await storage.migrate(to: BasisStore.schemaDeclaration)

        self.bundleStore = BundleStore(storage: storage)
        // CorpusDefaultTokenizer provides keyword tokenization for the
        // BM25 index. It is private to CorpusKit to avoid a circular
        // dependency (CorpusKitProviders depends on CorpusKit).
        self.bm25 = BM25Index(tokenizer: CorpusDefaultTokenizer())
        self.vectorStore = VectorStore(storage: storage)
        self.basisStore = BasisStore(storage: storage)

        // Build one slot per model, resolving each against any persisted basis.
        // The resolution per slot is exactly the single-provider resolve, so a
        // one-element `models` produces the byte-identical single-slot state.
        var built: [ProviderSlot] = []
        built.reserveCapacity(models.count)
        for model in models {
            let freshProvider = model.makeProvider()
            let resolved = try await Self.resolveProvider(
                freshProvider: freshProvider,
                isTrainable: model.isTrainable,
                basisStore: basisStore
            )
            built.append(ProviderSlot(
                provider: resolved.provider,
                freshBasisBlob: resolved.freshBasisBlob))
        }
        self.slots = built
        // nodeID 1: Corpus is a standalone actor; HLC ordering is for
        // chunk sequencing within one store, not cross-replica ordering.
        self.hlcGenerator = HLCGenerator(nodeID: 1)

        // Rebuild the BM25 index from persisted chunks so keyword recall
        // survives a process restart. allChunks() returns all non-tombstoned
        // rows (append-only table, no deletes) ordered by HLC ascending —
        // the same ordering as ingest. The fresh BM25Index is empty at this
        // point, so there is no risk of double-indexing.
        let existing = try await bundleStore.allChunks()
        if !existing.isEmpty {
            await bm25.index(existing)
            // Rebuild chunkSourceMap in lockstep with BM25 so bm25TopKBySource
            // can resolve chunk UUIDs back to their source identifiers.
            for chunk in existing {
                chunkSourceMap[chunk.id] = chunk.sourceID
            }
        }
    }

    /// The default signal's serving provider — `slots[0].provider`.
    ///
    /// The single-signal entry points read through this accessor so existing
    /// callers see exactly the first held provider, identical to the
    /// pre-6a-iii single-provider behaviour. `slots` is never empty (every init
    /// builds at least one slot), so the force-unwrap of `first` cannot trap.
    private var defaultProvider: any EmbeddingProvider {
        // swiftlint:disable:next force_unwrapping — slots is never empty (init invariant)
        slots.first!.provider
    }

    /// Resolve the serving provider and the fresh-empty-basis blob on open.
    ///
    /// Used by both inits. Three outcomes:
    ///   - Not trainable: serve `freshProvider`, no fresh-basis blob.
    ///   - Trainable, no persisted basis: serve `freshProvider` AND capture its
    ///     EMPTY (untrained) serialized basis so first-ingest/`reindex` can
    ///     reconstruct a fresh provider from it and train from scratch.
    ///   - Trainable, basis persisted: reconstruct the trained provider from the
    ///     persisted blob (so the dense lane is trained-ready without retraining)
    ///     and serve THAT, with no fresh-basis blob — a reopened-from-blob corpus
    ///     is already trained; `reindex` then re-embeds under the loaded basis
    ///     without retraining. This matches the Rust port, whose seam
    ///     `reconstruct_basis` yields a non-trainable boxed provider.
    ///
    /// Reconstruction routes through the carried provider's
    /// `TrainableEmbeddingBasis.reconstructBasis(from:)` witness — CorpusKit core
    /// never names the concrete provider type, so layering (providers → core) is
    /// preserved. A corrupt/version-mismatched blob throws `decodingFailure`
    /// rather than silently serving an untrained provider.
    private static func resolveProvider(
        freshProvider: any EmbeddingProvider,
        isTrainable: Bool,
        basisStore: BasisStore
    ) async throws -> (provider: any EmbeddingProvider, freshBasisBlob: Data?) {
        guard isTrainable, let trainable = freshProvider as? any TrainableEmbeddingBasis else {
            return (freshProvider, nil)
        }
        guard let persisted = try await basisStore.load(
            modelID: freshProvider.modelID,
            modelVersion: freshProvider.modelVersion
        ) else {
            // Trainable provider, no basis yet: serve it untrained and capture
            // its EMPTY serialized basis as the fresh-provider factory for
            // first-ingest/reindex (which reconstruct fresh and train from
            // scratch — trainOnCorpus is additive, so a fresh start is required).
            return (freshProvider, trainable.serializeBasis())
        }
        // Basis exists: reconstruct the trained provider for serving; no
        // fresh-basis blob (already trained, reopened corpus is not retrained).
        let restored = try trainable.reconstructBasis(from: persisted.basis)
        return (restored, nil)
    }

    // MARK: - Test seams (internal — not part of the public surface)

    /// Test-only init that accepts an `EmbeddingProvider` directly.
    ///
    /// This seam exists so test suites can inject a custom provider (e.g. one that
    /// throws on `embedFloat`) without affecting production code paths. The public
    /// `init(storage:model:)` is the production entry point; this init is `internal`
    /// so `@testable import CorpusKit` tests can reach it while callers outside the
    /// module cannot.
    ///
    /// - Parameters:
    ///   - storage: A PersistenceKit Storage instance.
    ///   - provider: A directly-supplied `EmbeddingProvider`. The caller is
    ///     responsible for providing a provider whose `modelID` and `modelVersion`
    ///     are consistent with any pre-existing vectors in `storage`.
    init(storage: any Storage, provider: any EmbeddingProvider) async throws {
        try await storage.migrate(to: BundleStore.schemaDeclaration)
        try await storage.migrate(to: VectorStore.schemaDeclaration)
        try await storage.migrate(to: BasisStore.schemaDeclaration)

        self.bundleStore = BundleStore(storage: storage)
        self.bm25 = BM25Index(tokenizer: CorpusDefaultTokenizer())
        self.vectorStore = VectorStore(storage: storage)
        self.basisStore = BasisStore(storage: storage)

        // This seam receives a directly-built provider rather than an
        // EmbeddingModel. Trainability is probed via the type-erasure cast
        // `as? any TrainableEmbeddingBasis`, then the same resolveProvider path
        // the production init uses applies: load-on-open reconstructs from a
        // persisted basis (capturing no trainable handle), else the fresh
        // trainable handle is captured for first-ingest/reindex. The injected
        // provider becomes the corpus's single (default) slot — N=1.
        let resolved = try await Self.resolveProvider(
            freshProvider: provider,
            isTrainable: provider is any TrainableEmbeddingBasis,
            basisStore: basisStore
        )
        self.slots = [ProviderSlot(
            provider: resolved.provider,
            freshBasisBlob: resolved.freshBasisBlob)]
        self.hlcGenerator = HLCGenerator(nodeID: 1)

        let existing = try await bundleStore.allChunks()
        if !existing.isEmpty {
            await bm25.index(existing)
            for chunk in existing {
                chunkSourceMap[chunk.id] = chunk.sourceID
            }
        }
    }

    /// Test-only: force `floatNearest` to return `.storeError(error)` on the next call.
    ///
    /// Intended for tests that need to verify the store-error code path (observable
    /// degradation contract §4). The error is consumed on the first `floatNearest`
    /// call after this is set; subsequent calls behave normally.
    ///
    /// Never call this in production code. Marked `internal` so it is visible to
    /// `@testable import CorpusKit` test suites and invisible to callers outside the module.
    func _testForceFloatStoreError(_ error: Error) {
        _forcedFloatError = error
    }

    // MARK: - Public API

    /// Ingest text from a source document.
    ///
    /// The text is chunked, stored in the BundleStore (idempotent on
    /// content-addressed ids), indexed for keyword recall in BM25, and
    /// embedded + stored in VectorStore. Re-ingesting the same text for
    /// the same `sourceID` is a no-op: content-addressed chunk ids make
    /// duplicate inserts idempotent at every layer.
    ///
    /// - Parameters:
    ///   - text: Document text to ingest.
    ///   - sourceID: Stable identifier for the source document. Use a
    ///     consistent handle (path, URL string, UUID string) across calls.
    ///   - now: Wall-clock time for vector filing timestamps and
    ///     determinism discipline. Never call `Date()` inside engines;
    ///     pass `now` from the caller.
    public func ingest(_ text: String, sourceID: String, now: Date) async throws {
        let chunks = Chunker.chunk(text: text, sourceID: sourceID, hlcGenerator: &hlcGenerator)
        guard !chunks.isEmpty else { return }

        try await bundleStore.insert(chunks)
        await bm25.index(chunks)
        // Update chunkSourceMap so bm25TopKBySource can resolve these chunks.
        // BM25 and the source map are provider-INDEPENDENT (one keyword index
        // per corpus), so they are maintained once, outside the per-provider
        // fan-out below.
        for chunk in chunks { chunkSourceMap[chunk.id] = chunk.sourceID }

        // Fan out the embedding work across every held provider slot. For N=1
        // this loop runs once over the default slot — byte-identical to the
        // pre-6a-iii single-provider ingest. Each slot embeds independently
        // under its own modelID; the VectorStore/BasisStore keys keep the N
        // providers' rows apart. `allChunks` is loaded lazily and shared across
        // slots that take the first-ingest train path (the corpus snapshot is
        // the same for every provider).
        var cachedAllChunks: [Chunk]?
        for index in slots.indices {
            // First-ingest auto-train (mission 6a-ii-β): when this slot has a
            // fresh-basis blob (trainable provider) AND no basis has been
            // persisted yet, train a fresh basis on the CURRENT corpus snapshot
            // (which now includes the just-inserted chunks) and re-embed every
            // chunk under the trained basis. This is the ONLY implicit train
            // trigger. Subsequent ingests (once a basis exists) take the fold-in
            // path below: `embedFloat` projects new chunks onto the FROZEN basis
            // without retraining — LSA/NMF cannot incrementally refactor a basis,
            // so a per-ingest retrain would be both wrong and wasteful. Explicit
            // `reindex(now:)` retrains on growth. A reopened-from-blob corpus has
            // no fresh-basis blob, so it always takes the fold-in path here
            // (already trained on open).
            if slots[index].freshBasisBlob != nil {
                let slotProvider = slots[index].provider
                let hasBasis = try await basisStore.load(
                    modelID: slotProvider.modelID,
                    modelVersion: slotProvider.modelVersion
                ) != nil
                if !hasBasis {
                    let allChunks: [Chunk]
                    if let cached = cachedAllChunks {
                        allChunks = cached
                    } else {
                        allChunks = try await bundleStore.allChunks()
                        cachedAllChunks = allChunks
                    }
                    try await trainAndPersistBasis(slotIndex: index, chunks: allChunks, now: now)
                    // Re-embed the whole corpus under the freshly-trained basis
                    // so the chunks ingested before this first-ingest train (if
                    // any) are embedded on the same basis as the new ones.
                    // reembedChunks is delete-first, so no duplicate rows.
                    try await reembedChunks(slotIndex: index, allChunks, now: now)
                    continue
                }
            }

            // Fold-in path: a basis already exists (or the provider is not
            // trainable). Embed only the NEW chunks; for a trainable provider
            // `embedFloat` projects them onto the frozen basis (no retrain).
            //
            // Fan-out: embed each chunk and store the vector. The
            // chunk.id.uuidString == vector.item_id join is maintained here;
            // the caller never sees it (sealed-vector principle). The column
            // was renamed drawer_id → item_id in Lane F (arch spec §4.1).
            let provider = slots[index].provider
            for chunk in chunks {
                let engram = try await provider.embed(chunk.text)
                try await vectorStore.addVector(
                    itemID: chunk.id.uuidString,
                    engram: engram,
                    modelID: provider.modelID,
                    modelVersion: provider.modelVersion,
                    filedAt: now
                )

                // Float lane (Lane D): RETAIN, don't recompute. The provider's
                // float vector is the SAME pooled embedding `embed` already ran
                // through `FloatSimHash.project` for the binary engram — one
                // inference pass, two stored rows. The float row is a SECOND row
                // per chunk under the same item_id, distinguished by
                // `kind=float32` and `vector_index=1` (the binary engram is
                // vector_index=0). It is written only when the provider supports
                // `embedFloat`; the default provider opts out by throwing, so a
                // non-float provider stores the binary lane only and the dense
                // float lane stays dark for it. Cosine over this true embedding
                // ranks an answer above a near-duplicate of the question, which
                // the 256-bit SimHash projection cannot (it loses the magnitude
                // signal).
                if let floats = try? await provider.embedFloat(chunk.text), !floats.isEmpty {
                    try await vectorStore.addPayload(
                        itemID: chunk.id.uuidString,
                        vectorIndex: 1,
                        payload: VectorPayload(floats: floats),
                        modelID: provider.modelID,
                        modelVersion: provider.modelVersion,
                        filedAt: now
                    )
                }
            }
        }
    }

    /// Retrain the embedding basis on the full corpus and re-embed every chunk.
    ///
    /// When the configured provider is trainable (RI/PPMI/LSA/NMF), this:
    ///   1. gathers ALL chunk texts from the BundleStore,
    ///   2. trains the basis on them through the `TrainableEmbeddingBasis` seam
    ///      (`trainOnCorpus(texts:)`, which runs the provider's own
    ///      train+finalize sequence — RI no finalize, PPMI/LSA/NMF finalize),
    ///   3. persists the serialized basis blob (UPSERT, one row per provider
    ///      key) with `now` and the trained chunk count, and
    ///   4. re-embeds every chunk (binary lane v0 + float lane v1) under the
    ///      provider's modelID, REPLACING stale vectors in place (delete-all
    ///      then re-add per chunk — no duplicate rows).
    ///
    /// When the provider is NOT trainable (deterministic / named-model / FDC),
    /// no basis is persisted; the chunks are simply (re)embedded so the call is
    /// still a well-defined "refresh the vectors" operation.
    ///
    /// Deterministic: `now` is the only clock source — the engine never calls
    /// `Date()`. Training itself is a pure function of the corpus texts and the
    /// provider's fixed seeds (the seam contract), so the persisted basis and
    /// the resulting vectors are reproducible and cross-port identical.
    ///
    /// `reindex` is the EXPLICIT retrain trigger. The only other train trigger
    /// is the first-ingest auto-train inside `ingest` (when a trainable provider
    /// has no basis yet). A growth-threshold auto-retrain — retraining once the
    /// live chunk count grows materially past `trained_chunk_count` — is a
    /// DOCUMENTED FOLLOW-UP KNOB, deliberately NOT wired here: LSA/NMF cannot
    /// incrementally refactor a frozen basis, so an automatic mid-stream retrain
    /// policy needs its own decision. The staleness anchor (`trained_chunk_count`)
    /// is persisted so that future policy can compute the delta.
    ///
    /// - Parameter now: wall-clock time for the basis `trained_at` stamp and the
    ///   re-embedded vectors' filing timestamps. Pass `now` from the caller;
    ///   never call `Date()` inside the engine.
    public func reindex(now: Date) async throws {
        let chunks = try await bundleStore.allChunks()

        // Fan out: refresh every held provider slot. For N=1 this loops once
        // over the default slot — byte-identical to the pre-6a-iii reindex.
        for index in slots.indices {
            if slots[index].freshBasisBlob != nil {
                // Train a FRESH basis on the full corpus snapshot through the
                // seam, install the trained provider for this slot, and persist
                // the basis. Reconstructing fresh (rather than retraining the
                // live provider in place) is required because trainOnCorpus is
                // additive — see ProviderSlot.freshBasisBlob.
                try await trainAndPersistBasis(slotIndex: index, chunks: chunks, now: now)
            }

            // Re-embed every chunk under this slot's (now possibly retrained)
            // provider, replacing stale vectors. Done whether or not a retrain
            // occurred: for a non-trainable provider — or a reopened-from-blob
            // slot with no fresh-basis blob — reindex is a vector refresh under
            // the current basis, with no basis row written.
            try await reembedChunks(slotIndex: index, chunks, now: now)
        }
    }

    /// Train a FRESH provider on the given chunks' texts and persist the
    /// serialized basis FOR THE GIVEN SLOT. Shared by `reindex` and the
    /// first-ingest auto-train.
    ///
    /// Reconstructs a fresh (untrained) provider from the slot's
    /// `freshBasisBlob`, trains it on the chunk texts through the seam, installs
    /// it as the slot's `provider`, and UPSERTs the resulting basis keyed by
    /// (modelID, modelVersion). `trainedChunkCount` is the count the basis was
    /// trained on (the staleness anchor). Training fresh — not in place —
    /// guarantees the additive `trainOnCorpus` starts from scratch, so the basis
    /// is the canonical from-scratch one and reindex is idempotent.
    /// Precondition: `slots[slotIndex].freshBasisBlob != nil` (the caller checks
    /// this).
    private func trainAndPersistBasis(slotIndex: Int, chunks: [Chunk], now: Date) async throws {
        guard let freshBlob = slots[slotIndex].freshBasisBlob,
              let fresh = slots[slotIndex].provider as? any TrainableEmbeddingBasis else {
            // Defensive: trainAndPersistBasis is only invoked when this slot's
            // freshBasisBlob is non-nil and its provider is trainable. If neither
            // holds there is nothing to train; return without persisting a basis.
            return
        }
        // Reconstruct a fresh untrained provider from the empty-basis blob, train
        // it from scratch on the corpus, then install it as the slot's provider.
        let trainedProvider = try fresh.reconstructBasis(from: freshBlob)
        guard let trainable = trainedProvider as? any TrainableEmbeddingBasis else {
            // The reconstructed provider must itself be trainable (it is the same
            // concrete type). If not, the seam is broken; surface it rather than
            // silently persisting an untrained basis.
            throw CorpusKitError.notTrainable(
                "reconstructed provider is not trainable — basis seam invariant violated")
        }
        // `trainable` and `trainedProvider` are the SAME reference object;
        // training via the trainable view mutates the provider we install.
        trainable.trainOnCorpus(texts: chunks.map(\.text))
        slots[slotIndex].provider = trainedProvider
        try await basisStore.upsert(PersistedBasis(
            modelID: trainedProvider.modelID,
            modelVersion: trainedProvider.modelVersion,
            basis: trainable.serializeBasis(),
            trainedAt: now,
            trainedChunkCount: chunks.count
        ))
    }

    /// Re-embed every chunk (binary v0 + float v1) under the GIVEN SLOT's
    /// provider, replacing any stale vectors so no duplicate rows accumulate.
    ///
    /// For each chunk the prior vectors (all vector_index rows under that
    /// item_id for the slot provider's modelID) are deleted, then the binary
    /// engram and — when the provider supports it — the float vector are
    /// re-added. This is the same store-side shape as `ingest`'s fan-out, but
    /// delete-first so a retrain under a changed basis overwrites rather than
    /// duplicates. Other slots' rows (keyed by a different modelID) are
    /// untouched.
    private func reembedChunks(slotIndex: Int, _ chunks: [Chunk], now: Date) async throws {
        let provider = slots[slotIndex].provider
        for chunk in chunks {
            // Delete-all before re-adding so a chunk that already had vectors
            // under a previous basis ends up with exactly the new vectors, not
            // a mix. deleteAllVectors clears both lanes (v0 binary + v1 float)
            // for THIS slot's modelID only.
            try await vectorStore.deleteAllVectors(
                itemID: chunk.id.uuidString,
                modelID: provider.modelID
            )
            let engram = try await provider.embed(chunk.text)
            try await vectorStore.addVector(
                itemID: chunk.id.uuidString,
                engram: engram,
                modelID: provider.modelID,
                modelVersion: provider.modelVersion,
                filedAt: now
            )
            // Float lane (Lane D): retain the pooled vector the provider's
            // embed already produced. Written only when the provider supports
            // embedFloat; a non-float provider stores the binary lane only.
            if let floats = try? await provider.embedFloat(chunk.text), !floats.isEmpty {
                try await vectorStore.addPayload(
                    itemID: chunk.id.uuidString,
                    vectorIndex: 1,
                    payload: VectorPayload(floats: floats),
                    modelID: provider.modelID,
                    modelVersion: provider.modelVersion,
                    filedAt: now
                )
            }
        }
    }

    /// Recall the top-k chunks relevant to a query.
    ///
    /// Embeds the query, then fuses vector kNN hits and BM25 keyword
    /// hits via Reciprocal Rank Fusion (SPEC § 5, B-4). Both passes are
    /// filtered to the model id the Corpus was configured with.
    ///
    /// - Parameters:
    ///   - query: Natural language query text.
    ///   - limit: Maximum number of results. Defaults to 10.
    ///   - now: Wall-clock time (reserved; included for API symmetry
    ///     with ingest and determinism discipline).
    /// - Returns: Scored chunks ranked by fused relevance, descending.
    public func recall(_ query: String, limit: Int = 10, now: Date) async throws -> [ScoredChunk] {
        // Single-signal entry point: recall runs on the DEFAULT signal (the
        // first held provider). Per-signal fan-out is exposed additively via
        // `floatNearestPerSignal` (the 6b RRF seam); this method is unchanged
        // for existing callers.
        let provider = defaultProvider
        let probe = try await provider.embed(query)
        return try await HybridRecall.recall(
            probe: probe,
            query: query,
            modelID: provider.modelID,
            limit: limit,
            vectorStore: vectorStore,
            bm25: bm25,
            bundleStore: bundleStore
        )
    }

    /// Remove a source document from the recall index.
    ///
    /// Removes the source's chunks from BM25 and deletes their vectors
    /// from VectorStore. The BundleStore is append-only, so chunk rows
    /// are not deleted from content storage; the source will no longer
    /// appear in recall results after this call.
    ///
    /// - Parameter sourceID: The source document identifier supplied to
    ///   `ingest`.
    public func remove(sourceID: String) async throws {
        let chunks = try await bundleStore.chunksForSource(sourceID)
        // Vector deletion fans out across every held provider's modelID so no
        // slot leaves orphan rows for a removed source. For N=1 this inner loop
        // runs once. The modelIDs are gathered once up front (stable for the
        // corpus lifetime) so the per-chunk loop does not re-read `slots`.
        let modelIDs = slots.map { $0.provider.modelID }
        for chunk in chunks {
            await bm25.remove(chunk.id)
            chunkSourceMap.removeValue(forKey: chunk.id)
            // Delete ALL vector_index rows for this chunk under EVERY held
            // modelID, not just the binary engram at vector_index=0: the float
            // lane (Lane D) stores a second row at vector_index=1 under the same
            // item_id. deleteAllVectors removes both and invalidates the float
            // index so a removed source cannot resurface through any signal's
            // dense float lane.
            for modelID in modelIDs {
                try await vectorStore.deleteAllVectors(
                    itemID: chunk.id.uuidString,
                    modelID: modelID
                )
            }
        }
    }

    // MARK: - Lifecycle (GLK_PROVISION_001)

    /// Destroy the corpus's recall index.
    ///
    /// Clears the in-memory BM25 index, the chunk-source map, and all vector
    /// rows from the VectorStore so this corpus no longer participates in recall.
    ///
    /// The BundleStore's `chunks` table is append-only (PersistenceKit schema
    /// invariant enforced by write triggers). Chunk rows are not deleted by this
    /// call — they remain in the backing storage for audit and migration purposes.
    /// What is destroyed is the corpus's active recall capability: after this
    /// call, `recall` returns empty results and `ingest` would re-index from
    /// scratch.
    ///
    /// Called by `GeniusLocusKit.destroy(storage:corpusStorage:handle:)` as part
    /// of the coordinated estate teardown path. The caller must ensure the estate
    /// is closed (not in use) before calling this.
    public func destroyRecallIndex() async throws {
        // 1. Clear the in-memory BM25 index and chunk-source map.
        //    BM25Index is a separate actor; clearing it requires removing each
        //    tracked chunk. Since we are destroying everything, rebuild from empty.
        let allChunks = try await bundleStore.allChunks()
        for chunk in allChunks {
            await bm25.remove(chunk.id)
        }
        chunkSourceMap.removeAll()

        // 2. Delete all vector rows from the VectorStore.
        //    VectorStore.destroyAllVectors() deletes every row in the vectors
        //    table regardless of modelID, so it clears ALL held signals' rows
        //    in one call (no per-slot fan-out needed). Vectors are not
        //    append-only so deletion is permitted.
        try await vectorStore.destroyAllVectors()

        // 3. Wipe the persisted trained basis (mission 6a-ii-β). A destroyed
        //    corpus must leave no orphaned basis row FOR ANY held modelID: the
        //    next open would otherwise reconstruct a trained provider whose
        //    basis no longer matches any stored vectors. basisStore.deleteAll()
        //    clears every row regardless of modelID, so all held signals' bases
        //    are wiped in one call. The basis table is not append-only, so
        //    deletion is permitted.
        try await basisStore.deleteAll()
    }

    /// BM25-only top-k recall at the source granularity, using a bounded min-heap.
    ///
    /// Returns the top-`limit` sources by BM25 keyword score for the query text.
    /// Unlike `recall(_:limit:now:)`, this method skips embedding and vector kNN —
    /// it is the pure BM25 lane used by GeniusLocusKit's RecallDirector to drive
    /// the BM25 frontier independently from the vector lane.
    ///
    /// The returned `sourceID` values are the identifiers passed to `ingest`. In
    /// the GLK context these are LocusKit drawer IDs; the RecallDirector uses them
    /// to join BM25 hits back to hydrated `Drawer` rows.
    ///
    /// Sources with multiple matching chunks use the highest-scoring chunk's score
    /// for that source (max aggregation). Results are sorted descending by score.
    ///
    /// - Parameters:
    ///   - query: Natural language query text.
    ///   - limit: Maximum number of source-level results.
    /// - Returns: Up to `limit` (sourceID, score) pairs, descending by score.
    public func bm25TopKBySource(query: String, limit: Int) async -> [(sourceID: String, score: Float)] {
        guard limit > 0, !query.isEmpty else { return [] }
        // Tokenise using the same vocabulary as the indexed chunks. The
        // CorpusDefaultTokenizer is stateless; a fresh instance is equivalent
        // to the instance stored inside bm25.
        let tokens = CorpusDefaultTokenizer().keywordTokens(query)
        guard !tokens.isEmpty else { return [] }

        // Fetch chunk-level BM25 top-k with a 4× over-fetch so that after
        // source-level aggregation we still have at least `limit` sources.
        // The over-fetch is bounded: frontierK <= 256 per the RecallDirector
        // contract, so limit * 4 <= 1024 at most.
        let chunkHits = await bm25.topK(limit * 4, for: tokens)

        // Aggregate by sourceID — take the max chunk score per source.
        var sourceScores: [String: Float] = [:]
        for hit in chunkHits {
            guard let sourceID = chunkSourceMap[hit.id] else { continue }
            sourceScores[sourceID] = max(sourceScores[sourceID, default: 0], hit.score)
        }

        // Sort descending by score, sourceID ascending on tie (deterministic).
        var ranked = sourceScores.map { (sourceID: $0.key, score: $0.value) }
        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.sourceID < b.sourceID
        }
        return Array(ranked.prefix(limit))
    }

    /// Embed the given text using the corpus's configured embedding model.
    ///
    /// Exposes the embedding surface for GeniusLocusKit's RecallDirector vector
    /// lane, which needs to embed the query text to produce a probe `Engram` for
    /// Hamming nearest-neighbour search against VectorStore.
    ///
    /// Returns `Engram.zero` for empty input (same as the internal ingest path).
    ///
    /// - Parameter text: Text to embed. Should be the query string.
    /// - Returns: A 256-bit `Engram` encoding the text's semantic fingerprint.
    public func embed(_ text: String) async throws -> Engram {
        // Single-signal entry point: embeds on the DEFAULT signal.
        try await defaultProvider.embed(text)
    }

    /// The embedding model identifier of this corpus's DEFAULT signal.
    ///
    /// Exposed for GeniusLocusKit's RecallDirector vector lane so it can pass
    /// the correct `modelID` to `VectorStore.findNearest`. Must match the
    /// `modelID` used during `ingest` for the default signal — vectors stored
    /// under a different model ID are not comparable per spec I-4. For an
    /// N-provider corpus this is the first held provider's modelID; the other
    /// signals' modelIDs are reachable through `floatNearestPerSignal`.
    public var modelID: String { defaultProvider.modelID }

    /// Embed the query text into the pooled dense float vector (Lane D) — the
    /// probe for the dense float recall lane.
    ///
    /// Delegates to the configured provider's `embedFloat`. The default
    /// `.deterministic` provider DOES implement `embedFloat` (FNV-1a + FloatSimHash),
    /// so Lane D is live from the first capture under the default. Providers that
    /// choose not to produce a dense float vector throw
    /// `VectorKitError.embeddingFailed`; the caller treats a throw as "this
    /// corpus has no float lane" and skips the dense lane rather than failing
    /// the whole recall. Empty input returns `[]` (no dense direction for the
    /// empty string), matching the storage-side contract in `ingest`.
    ///
    /// - Parameter text: the query text to embed.
    /// - Returns: the pooled float vector, or `[]` for empty input.
    /// - Throws: `VectorKitError.embeddingFailed` when the provider opts out.
    public func embedFloat(_ text: String) async throws -> [Float] {
        // Single-signal entry point: embeds on the DEFAULT signal.
        try await defaultProvider.embedFloat(text)
    }

    /// Dense float nearest-neighbour recall (Lane D): embed `query` to its
    /// pooled float vector and rank stored chunks by cosine over the in-house
    /// `FloatBruteForceIndex`. Returns a `FloatLaneOutcome` that is always
    /// observable — dark lanes carry a typed reason, store errors are logged
    /// and counted, never swallowed.
    ///
    /// This is the cosine path the 256-bit SimHash-Hamming lane could not
    /// serve: cosine is scale-invariant, so an answer statement ranks above a
    /// near-duplicate of the question.
    ///
    /// **Degradation contract:** this method never throws. A dark lane is
    /// represented as `.unavailableProviderOptOut`, `.unavailableNoFloatRows`,
    /// or `.emptyQuery` — all expected outcomes. `.storeError` is NOT expected:
    /// the error is logged (OSLog "CorpusKit") and emitted as
    /// `corpus.float_lane.store_error` telemetry before returning so the
    /// failure is always observable. The query continues on other lanes.
    ///
    /// **Telemetry** (off by default — single `Atomic<Bool>` load when disabled):
    /// - `corpus.float_lane.hit`           — lane ran and returned ≥1 result.
    /// - `corpus.float_lane.dark_provider` — provider opted out.
    /// - `corpus.float_lane.dark_no_rows`  — no float rows stored.
    /// - `corpus.float_lane.store_error`   — unexpected store failure.
    ///
    /// - Parameters:
    ///   - query: the query text.
    ///   - limit: maximum number of matches.
    /// - Returns: a `FloatLaneOutcome` describing the result.
    public func floatNearest(query: String, limit: Int) async -> FloatLaneOutcome {
        guard limit > 0, !query.isEmpty else {
            // Empty query or zero limit — no telemetry: this is a no-op call.
            return .emptyQuery
        }

        // Test-only hook: if a forced error is installed, consume it and return
        // .storeError immediately. This exercises the observable store-error code
        // path without requiring production modifications to the vector store.
        // Both entry points consult the hook: this single-signal path, and the
        // per-signal `floatNearestPerSignal` for its DEFAULT slot (slot 0), so the
        // store-error dark contract is observable through whichever path GLK uses.
        if let forced = _forcedFloatError {
            _forcedFloatError = nil
            corpusLog.error("floatNearest: findNearestFloat failed — \(forced, privacy: .public)")
            Intellectus.report(.metric(
                name: "corpus.float_lane.store_error",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .storeError(forced)
        }

        // Single-signal entry point: run the dense float lane on the DEFAULT
        // signal. The per-provider mechanics live in `floatNearest(provider:…)`
        // so `floatNearestPerSignal` can reuse them unchanged.
        return await floatNearest(provider: defaultProvider, query: query, limit: limit)
    }

    /// Dense float recall for ONE provider — the per-signal mechanics shared by
    /// `floatNearest`/`floatNearestPerSignal` (nearest) and
    /// `floatFarthestPerSignal` (farthest, anti-similarity).
    ///
    /// Embeds `query` via `provider.embedFloat`, ranks stored chunks for that
    /// provider's modelID by cosine over the in-house `FloatBruteForceIndex`,
    /// aggregates chunk hits to source (drawer) level, and returns an observable
    /// `FloatLaneOutcome`. The telemetry counters and the degradation contract
    /// are identical regardless of direction.
    ///
    /// `direction` selects the objective (mission 6b-modifiers-antisim):
    ///   - `.nearest`  — surface the most SIMILAR sources. The store returns the
    ///     nearest chunks (`findNearestFloat`); a source's similarity is its
    ///     BEST (max) chunk cosine; sources rank similarity DESCENDING. This is
    ///     byte-identical to the pre-antisim behaviour (default).
    ///   - `.farthest` — surface the most DISSIMILAR sources ("find things
    ///     UNLIKE this"). The store returns the farthest chunks
    ///     (`findFarthestFloat`); a source's dissimilarity is its WORST (min)
    ///     chunk cosine; sources rank similarity ASCENDING. The max→min
    ///     inversion is required: a source's anti-similarity is governed by its
    ///     LEAST-similar chunk, the mirror of nearest's best-chunk rule.
    private func floatNearest(
        provider: any EmbeddingProvider,
        query: String,
        limit: Int,
        direction: SearchDirection = .nearest
    ) async -> FloatLaneOutcome {
        // Attempt to embed the query text via the float lane.
        //
        // Three distinct paths:
        //   1. Result is non-empty → proceed with the probe vector.
        //   2. Result is empty ([] from an untrained provider, or text that
        //      tokenises to nothing) → structural opt-out. Emit the
        //      dark_provider counter and return .unavailableProviderOptOut.
        //   3. Throw VectorKitError.embedFloatVocabMiss → the provider HAS a
        //      trained basis but all query tokens are OOV. This is a vocabulary
        //      coverage miss, not a structural opt-out. Return
        //      .unavailableNoVocabHit with its own counter so callers observe
        //      the correct dark-lane reason.
        //   4. Any other throw → structural opt-out (same as path 2).
        //
        // Path 2 and 4 share the dark_provider counter. Path 3 has its own
        // dark_vocabMiss counter (corpus.float_lane.dark_vocab_miss).
        let probe: [Float]
        do {
            let result = try await provider.embedFloat(query)
            guard !result.isEmpty else {
                // Provider returned an empty vector (untrained distributional
                // provider, or text that produces no tokens). Classify as
                // structural opt-out: the provider cannot produce a float vector
                // for structural reasons, not because of vocabulary coverage.
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_provider",
                    value: 1.0,
                    tags: ["kit": "CorpusKit"],
                    ts: Date().timeIntervalSince1970
                ))
                return .unavailableProviderOptOut
            }
            probe = result
        } catch VectorKitError.embedFloatVocabMiss {
            // Trained distributional provider: basis exists but query tokens
            // are all OOV. This is a vocabulary coverage miss — truthfully
            // distinct from a structural opt-out. Emit a separate counter
            // so telemetry surfaces vocabulary coverage vs. lane availability.
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_vocab_miss",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableNoVocabHit
        } catch {
            // Provider threw a non-vocabMiss error — structural opt-out (e.g.
            // the deterministic provider, or any provider without a float lane).
            // Log nothing; emit the dark_provider counter only.
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_provider",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableProviderOptOut
        }

        // Over-fetch 4× at the CHUNK granularity so that after source-level
        // aggregation we still have at least `limit` sources, mirroring
        // bm25TopKBySource's over-fetch discipline. The float index keys rows by
        // chunk.id (the vector item_id); we aggregate to sourceID below.
        let matches: [VectorMatch]
        do {
            // Direction selects which end of the cosine ranking the store
            // returns. Farthest is NOT a reordering of nearest results — the
            // dissimilar chunks are not in the nearest top-K, so the store must
            // run the farthest scan (mission 6b-modifiers-antisim).
            switch direction {
            case .nearest:
                matches = try await vectorStore.findNearestFloat(
                    probe: probe, modelID: provider.modelID, limit: limit * 4)
            case .farthest:
                matches = try await vectorStore.findFarthestFloat(
                    probe: probe, modelID: provider.modelID, limit: limit * 4)
            }
        } catch {
            // Store threw — this is NOT expected. Log it via OSLog so it is
            // never silent, then emit the store_error counter for telemetry
            // dashboards and alerts.
            corpusLog.error("floatNearest: findNearestFloat failed — \(error, privacy: .public)")
            Intellectus.report(.metric(
                name: "corpus.float_lane.store_error",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .storeError(error)
        }

        // Empty matches means no float rows are stored — expected dark outcome.
        guard !matches.isEmpty else {
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_no_rows",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableNoFloatRows
        }

        // Aggregate chunk-level cosine to SOURCE (drawer) level. The vector
        // item_id is the chunk uuid string; chunkSourceMap resolves it to the
        // sourceID the caller ingested under (the drawer id in the GLK context),
        // exactly as bm25TopKBySource does, so float hits hydrate back to the
        // real Drawer row.
        //   .nearest  — a source's similarity is its BEST (max) chunk cosine.
        //   .farthest — a source's anti-similarity is governed by its WORST
        //               (min) chunk cosine: a source is "unlike the query" only
        //               if even its closest chunk is far. Picking max here would
        //               surface sources that happen to have one near chunk, the
        //               opposite of the anti-similarity objective.
        // VectorMatch.distance is the cosine DISTANCE (1 − sim) quantised
        // ×10_000 (FloatBruteForceIndex convention); recover sim = 1 − dist/1e4.
        var bySource: [String: Float] = [:]
        for m in matches {
            guard let chunkUUID = UUID(uuidString: m.itemID),
                  let sourceID = chunkSourceMap[chunkUUID] else { continue }
            let similarity = 1.0 - Float(m.distance) / 10_000.0
            switch direction {
            case .nearest:
                bySource[sourceID] = max(bySource[sourceID] ?? -Float.greatestFiniteMagnitude, similarity)
            case .farthest:
                bySource[sourceID] = min(bySource[sourceID] ?? Float.greatestFiniteMagnitude, similarity)
            }
        }

        // After source aggregation, no results means no chunks are in the
        // chunk→source map (all chunks were removed). Treat as no-rows dark.
        guard !bySource.isEmpty else {
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_no_rows",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableNoFloatRows
        }

        // Sort by similarity, sourceID ascending on tie (the universal
        // deterministic tie-break), and return the top `limit`.
        //   .nearest  — similarity DESCENDING (most similar first).
        //   .farthest — similarity ASCENDING (most dissimilar first).
        // The tie-break (sourceID ascending) is identical in both directions.
        var ranked = bySource.map { (itemID: $0.key, similarity: $0.value) }
        ranked.sort { a, b in
            if a.similarity != b.similarity {
                switch direction {
                case .nearest:  return a.similarity > b.similarity
                case .farthest: return a.similarity < b.similarity
                }
            }
            return a.itemID < b.itemID
        }
        let result = Array(ranked.prefix(limit))

        // Happy path — lane ran. Emit hit counter (count = result size so
        // dashboards can see both that the lane ran and how many hits emerged).
        Intellectus.report(.metric(
            name: "corpus.float_lane.hit",
            value: Double(result.count),
            tags: ["kit": "CorpusKit"],
            ts: Date().timeIntervalSince1970
        ))
        return .hits(result)
    }

    /// Per-signal dense float nearest-neighbour recall (the 6b RRF-fusion seam).
    ///
    /// Runs the dense float lane independently for EVERY held provider slot,
    /// each queried against its own modelID float index, and returns one ranked
    /// `FloatLaneOutcome` per signal tagged by that signal's `modelID`. The
    /// outcome ordering follows slot (construction) order, so `[0]` is always
    /// the default signal.
    ///
    /// This is the seam the 6b mission's RRF/consensus fusion consumes: each
    /// signal's per-source similarity ranking is exposed separately, preserving
    /// the `FloatLaneOutcome` dark-lane observability per signal (a signal whose
    /// provider opted out reports `.unavailableProviderOptOut`; one with no rows
    /// reports `.unavailableNoFloatRows`; and so on). NO fusion happens here —
    /// the caller (6b) decides how to combine the per-signal lists.
    ///
    /// For N=1 this returns a single-element array whose only outcome equals what
    /// `floatNearest(query:limit:)` would return — same default-signal mechanics.
    ///
    /// - Parameters:
    ///   - query: the query text.
    ///   - limit: maximum number of matches per signal.
    /// - Returns: `(modelID, outcome)` pairs, one per held signal, in slot order.
    ///   An empty query or zero limit returns one `.emptyQuery` outcome per
    ///   signal (no store access), mirroring the single-signal no-op guard.
    public func floatNearestPerSignal(
        query: String,
        limit: Int
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        // No-op guard mirrors floatNearest: an empty query / zero limit yields a
        // per-signal .emptyQuery without touching the store. Returning one entry
        // per signal keeps the result shape stable (the caller can still see
        // every signal's modelID).
        guard limit > 0, !query.isEmpty else {
            return slots.map { (modelID: $0.provider.modelID, outcome: .emptyQuery) }
        }

        // Test-only hook: a forced store error is consumed for the DEFAULT slot
        // (slot 0), mirroring the single-signal `floatNearest(query:limit:)`
        // contract. GLK's dense lane consumes this method, so the store-error dark
        // contract must remain observable through the per-signal path: the default
        // signal reports `.storeError`, other slots run normally. The seam is
        // single-use and consumed here exactly as the single-signal entry does.
        var forcedDefaultStoreError: FloatLaneOutcome? = nil
        if let forced = _forcedFloatError {
            _forcedFloatError = nil
            corpusLog.error("floatNearestPerSignal: findNearestFloat failed (default signal) — \(forced, privacy: .public)")
            Intellectus.report(.metric(
                name: "corpus.float_lane.store_error",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            forcedDefaultStoreError = .storeError(forced)
        }

        var results: [(modelID: String, outcome: FloatLaneOutcome)] = []
        results.reserveCapacity(slots.count)
        for (index, slot) in slots.enumerated() {
            let provider = slot.provider
            // Slot 0 (default signal) honours the forced-error seam if installed;
            // all other slots — and slot 0 when no seam is set — run the real lane.
            let outcome: FloatLaneOutcome
            if index == 0, let forced = forcedDefaultStoreError {
                outcome = forced
            } else {
                outcome = await floatNearest(provider: provider, query: query, limit: limit)
            }
            results.append((modelID: provider.modelID, outcome: outcome))
        }
        return results
    }

    /// Per-signal dense float FARTHEST recall — the anti-similarity sibling of
    /// `floatNearestPerSignal` (mission 6b-modifiers-antisim).
    ///
    /// Runs the dense float lane in the FARTHEST direction independently for
    /// EVERY held provider slot: each signal surfaces the most DISSIMILAR
    /// sources for its modelID ("find things UNLIKE this"), ranked least-similar
    /// first. The outcome shape, dark-lane observability, telemetry counters,
    /// and slot ordering are identical to `floatNearestPerSignal`; only the
    /// ranking objective differs (the store returns the farthest chunks, and a
    /// source's score is its WORST chunk cosine — see `floatNearest(provider:…)`).
    ///
    /// This is the seam GLK's RecallShape `antiSimilarLanes` consumes: a dense
    /// lane marked anti-similar queries THIS method for its per-signal list
    /// instead of `floatNearestPerSignal`, so the dissimilar candidates flow
    /// into the same RRF/consensus fold.
    ///
    /// The forced-error test seam is NOT consulted here — it is nearest-path
    /// test infrastructure (`floatNearest`/`floatNearestPerSignal` only), so the
    /// farthest path always runs the real lane.
    ///
    /// - Parameters:
    ///   - query: the query text.
    ///   - limit: maximum number of matches per signal.
    /// - Returns: `(modelID, outcome)` pairs, one per held signal, in slot
    ///   order. An empty query or zero limit returns one `.emptyQuery` outcome
    ///   per signal (no store access), mirroring the nearest no-op guard.
    public func floatFarthestPerSignal(
        query: String,
        limit: Int
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        guard limit > 0, !query.isEmpty else {
            return slots.map { (modelID: $0.provider.modelID, outcome: .emptyQuery) }
        }

        var results: [(modelID: String, outcome: FloatLaneOutcome)] = []
        results.reserveCapacity(slots.count)
        for slot in slots {
            let provider = slot.provider
            let outcome = await floatNearest(
                provider: provider, query: query, limit: limit, direction: .farthest)
            results.append((modelID: provider.modelID, outcome: outcome))
        }
        return results
    }

    /// Whether this corpus's DEFAULT signal supports the dense float lane
    /// (Lane D). True when `embedFloat` returns a vector rather than throwing
    /// the opt-out error. Probes with a single non-empty token so the answer
    /// reflects provider capability, not input. The GLK dense lane checks this
    /// (via a non-empty `floatNearest`) before fusing the dense column.
    public var supportsFloat: Bool {
        get async {
            ((try? await defaultProvider.embedFloat("x")) ?? []).isEmpty == false
        }
    }

    /// Count the total chunks in the bundle store across all sources.
    ///
    /// Because BundleStore is append-only, this count does not decrease
    /// when `remove(sourceID:)` is called — removed chunks are still
    /// stored but no longer appear in recall results.
    public func count() async throws -> Int {
        try await bundleStore.count()
    }

    /// Return the set of all distinct source IDs (drawer IDs) currently in the
    /// chunks table — i.e. every drawer that has been ingested into this Corpus.
    ///
    /// Used by `GeniusLocusKit.reindexMissing(handle:)` to identify which
    /// drawers already have at least one chunk and can be skipped during
    /// a backfill sweep. The query touches all chunk rows but is only used
    /// in maintenance/admin contexts, never on hot paths.
    public func indexedSourceIDs() async throws -> Set<String> {
        try await bundleStore.allSourceIDs()
    }
}

// MARK: - EmbeddingModel → provider construction

extension EmbeddingModel {
    // Projection seeds match CorpusKitProviders' model-specific seeds so
    // storage keys are consistent regardless of which surface is used.
    // Changing a seed re-keys all stored vectors for that model.
    private static let miniLMSeed: UInt64 = 0x4D49_4E4C_4D5F_7631       // "MINLM_v1"
    private static let mpNetSeed: UInt64 = 0x4D50_4E45_545F_7631        // "MPNET_v1"
    private static let embeddingGemmaSeed: UInt64 = 0x454D_4247_4D5F_7631 // "EMBGM_v1"
    // Deterministic seed is CorpusKit-specific; distinct from all model seeds.
    private static let deterministicSeed: UInt64 = 0xC05B_D15C_A15D_1B00

    /// Construct the concrete EmbeddingProvider for this model selection.
    /// The returned value is held privately inside the Corpus actor and
    /// never exposed on the public API.
    fileprivate func makeProvider() -> any EmbeddingProvider {
        switch self {
        case .randomIndexing(let provider):
            // The caller built and trained the provider externally. Pass it
            // through unchanged — no further construction needed here.
            return provider

        case .ppmi(let provider):
            // The caller built, trained, and finalized the PpmiProvider
            // externally. Pass through unchanged — no further construction
            // needed here. The finalization step (count → PPMI vectors) must
            // already have happened before this Corpus is used for recall.
            return provider

        case .lsa(let provider):
            // The caller built and trained the LsaProvider externally (term-
            // document matrix + SVD). Pass through unchanged.
            return provider

        case .nmf(let provider):
            // The caller built, trained, and finalized the NmfProvider externally
            // (TF matrix + NMF factorization via SubstrateML). Pass through unchanged.
            return provider

        case .fdc(let provider):
            // The caller constructed an FDCProvider externally. FDCProvider is
            // stateless (no training required) — the caller just passes it through
            // to register it as the fusion voter. Pass through unchanged.
            return provider

        case .deterministic:
            // FNV-1a 64-bit hash of the input text drives a 32-element
            // float vector. Each element is drawn from an LCG seeded by
            // the text hash, mapped to [-1, 1]. Consistent across calls;
            // not semantically meaningful.
            return FloatSimHashEmbeddingProvider(
                modelID: "corpus-deterministic-v1",
                modelVersion: "1.0.0",
                projectionSeed: EmbeddingModel.deterministicSeed,
                inference: { text in
                    let fnvPrime: UInt64 = 1_099_511_628_211
                    let lcgMultiplier: UInt64 = 6_364_136_223_846_793_005
                    let lcgIncrement: UInt64 = 1_442_695_040_888_963_407
                    var h = text.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
                        ($0 ^ UInt64($1)) &* fnvPrime
                    }
                    return (0..<32).map { _ in
                        h = h &* lcgMultiplier &+ lcgIncrement
                        // High 24 bits as a mantissa in [0, 1), then scale to [-1, 1].
                        let mantissa = Float(h >> 40) / Float(1 << 24)
                        return mantissa * 2.0 - 1.0
                    }
                }
            )

        case .miniLM(let inference):
            return CorpusTextProvider(
                modelID: "minilm-v6",
                modelVersion: "1.0.0",
                projectionSeed: EmbeddingModel.miniLMSeed,
                vocabSize: 30522,
                maxTokenLen: 128,
                inference: inference
            )

        case .mpNet(let inference):
            return CorpusTextProvider(
                modelID: "mpnet-base-v2",
                modelVersion: "1.0.0",
                projectionSeed: EmbeddingModel.mpNetSeed,
                vocabSize: 30522,
                maxTokenLen: 128,
                inference: inference
            )

        case .embeddingGemma(let inference):
            return CorpusTextProvider(
                modelID: "embedding-gemma-300m",
                modelVersion: "1.0.0",
                projectionSeed: EmbeddingModel.embeddingGemmaSeed,
                vocabSize: 256_000,
                maxTokenLen: 2048,
                inference: inference
            )
        }
    }
}

// MARK: - Private helpers

/// FNV-1a tokenizer used by the Corpus actor's BM25 index and as the
/// bridge tokenizer for named model cases.
///
/// Uses the same FNV-1a word-fold algorithm as `DeterministicTokenizer`
/// in CorpusKitProviders (FNV-1a 32-bit over UTF-8 bytes, folded into
/// [2, vocabSize)). Defined here because CorpusKitProviders depends on
/// CorpusKit — importing it from here would create a circular dependency.
// Internal (not private) so HybridRecall.swift can tokenise queries
// with the same vocabulary before calling BM25Index.topK(_:for:).
struct CorpusDefaultTokenizer: Tokenizer {
    let vocabID: String
    let maxTokens: Int
    let padTokenID: Int32 = 0
    let unknownTokenID: Int32 = 1
    private let vocabRange: UInt32   // vocabSize - 2; token ids live in [2, vocabSize)

    init(vocabID: String = "corpus-default-v1",
         maxTokens: Int = 128,
         vocabSize: UInt32 = 30522) {
        self.vocabID = vocabID
        self.maxTokens = maxTokens
        self.vocabRange = vocabSize - 2
    }

    func tokenize(_ text: String) -> [Int32] {
        keywordTokens(text).prefix(maxTokens).map { word in
            // FNV-1a 32-bit: fold each UTF-8 byte into [2, vocabSize).
            let h = word.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 1_677_619 }
            return Int32(2 + Int(h % vocabRange))
        }
    }
}

/// EmbeddingProvider adapter for named model cases (miniLM, mpNet,
/// embeddingGemma). Tokenizes text using CorpusDefaultTokenizer's FNV-1a
/// fold, calls the host-supplied CoreML inference closure, and projects
/// the resulting float vector through FloatSimHash with the model's
/// canonical seed.
///
/// This type is private to CorpusKit; it does not appear on any public
/// signature. Callers interact only through `EmbeddingModel` cases.
private struct CorpusTextProvider: EmbeddingProvider {
    let modelID: String
    let modelVersion: String
    let projectionSeed: UInt64
    private let tokenizer: CorpusDefaultTokenizer
    let inference: @Sendable ([Int32]) async throws -> [Float]

    init(modelID: String,
         modelVersion: String,
         projectionSeed: UInt64,
         vocabSize: UInt32,
         maxTokenLen: Int,
         inference: @escaping @Sendable ([Int32]) async throws -> [Float]) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.projectionSeed = projectionSeed
        self.tokenizer = CorpusDefaultTokenizer(
            vocabID: modelID,
            maxTokens: maxTokenLen,
            vocabSize: vocabSize
        )
        self.inference = inference
    }

    func embed(_ text: String) async throws -> Engram {
        guard !text.isEmpty else { return Engram.zero }
        let tokens = tokenizer.tokenize(text)
        let floats = try await inference(tokens)
        return FloatSimHash.project(vector: floats, seed: projectionSeed)
    }

    /// Float lane source (Lane D): the pooled vector this provider's `embed`
    /// already computes before projecting it to the 256-bit engram. Returning
    /// it directly feeds the dense float lane's cosine ranking — one inference
    /// pass, two stored rows. Empty input returns `[]` (no dense direction for
    /// the empty string), matching the `EmbeddingProvider.embedFloat` contract.
    /// This is the production float-lane path for the `.miniLM`/`.mpNet`/
    /// `.embeddingGemma` models; without it those models would have NO float
    /// lane (the protocol default opts out by throwing).
    func embedFloat(_ text: String) async throws -> [Float] {
        guard !text.isEmpty else { return [] }
        let tokens = tokenizer.tokenize(text)
        return try await inference(tokens)
    }
}
