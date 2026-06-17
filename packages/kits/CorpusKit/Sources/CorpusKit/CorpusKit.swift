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
    /// on the embed call, indicating it has no float lane. This is the normal
    /// outcome for the default `.deterministic` provider and for any provider
    /// that does not override `embedFloat`. The dense lane is dark for this
    /// corpus; all other lanes are unaffected.
    case unavailableProviderOptOut

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
/// Corpus composes BundleStore, BM25Index, VectorStore, and an
/// EmbeddingProvider internally. The public surface exposes only
/// `ingest`, `recall`, `remove`, and `count`. No VectorKit type
/// appears in any public signature — the sealed-vector principle is
/// enforced here, not by the caller.
///
/// Lifecycle: construct with a PersistenceKit Storage (the actor calls
/// `storage.open(schema:)` for both BundleStore and VectorStore during
/// `init`), then call `ingest` to add documents and `recall` to query.
/// The BundleStore is append-only; `remove(sourceID:)` clears the
/// recall index (BM25 + vectors) without deleting content rows.
public actor Corpus {

    private let bundleStore: BundleStore
    private let bm25: BM25Index
    private let vectorStore: VectorStore
    private let provider: any EmbeddingProvider
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

    /// Construct a Corpus against a PersistenceKit Storage.
    ///
    /// Opens the BundleStore and VectorStore schema declarations on the
    /// supplied storage before constructing internal components. The
    /// caller owns the Storage lifecycle; Corpus does not close it.
    ///
    /// - Parameters:
    ///   - storage: A PersistenceKit Storage instance. Both the
    ///     BundleStore and VectorStore schemas are applied here; if the
    ///     same storage is shared with other kits their schemas must be
    ///     applied separately before or after this call.
    ///   - model: Embedding model selection. Defaults to `.deterministic`
    ///     (no CoreML required).
    public init(storage: any Storage, model: EmbeddingModel = .default) async throws {
        // Apply both schema declarations. `open(schema:)` is version-gated
        // (skips if the schema version is already current). Since both
        // BundleStore and VectorStore are version 1, the second `open` would
        // be skipped when called on the same storage; `migrate(to:)` bypasses
        // the gate and ensures all tables are created regardless of which
        // schema was applied first.
        try await storage.migrate(to: BundleStore.schemaDeclaration)
        try await storage.migrate(to: VectorStore.schemaDeclaration)

        self.bundleStore = BundleStore(storage: storage)
        // CorpusDefaultTokenizer provides keyword tokenization for the
        // BM25 index. It is private to CorpusKit to avoid a circular
        // dependency (CorpusKitProviders depends on CorpusKit).
        self.bm25 = BM25Index(tokenizer: CorpusDefaultTokenizer())
        self.vectorStore = VectorStore(storage: storage)
        self.provider = model.makeProvider()
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

        self.bundleStore = BundleStore(storage: storage)
        self.bm25 = BM25Index(tokenizer: CorpusDefaultTokenizer())
        self.vectorStore = VectorStore(storage: storage)
        self.provider = provider
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
        for chunk in chunks { chunkSourceMap[chunk.id] = chunk.sourceID }

        // Fan-out: embed each chunk and store the vector. The
        // chunk.id.uuidString == vector.item_id join is maintained here;
        // the caller never sees it (sealed-vector principle). The column
        // was renamed drawer_id → item_id in Lane F (arch spec §4.1).
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
            // per chunk under the same item_id, distinguished by `kind=float32`
            // and `vector_index=1` (the binary engram is vector_index=0). It is
            // written only when the provider supports `embedFloat`; the default
            // provider opts out by throwing, so a non-float provider stores the
            // binary lane only and the dense float lane stays dark for it.
            // Cosine over this true embedding ranks an answer above a near-
            // duplicate of the question, which the 256-bit SimHash projection
            // cannot (it loses the magnitude signal).
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
        for chunk in chunks {
            await bm25.remove(chunk.id)
            chunkSourceMap.removeValue(forKey: chunk.id)
            // Delete ALL vector_index rows for this chunk, not just the binary
            // engram at vector_index=0: the float lane (Lane D) stores a second
            // row at vector_index=1 under the same item_id. deleteAllVectors
            // removes both and invalidates the float index so a removed source
            // cannot resurface through the dense float lane.
            try await vectorStore.deleteAllVectors(
                itemID: chunk.id.uuidString,
                modelID: provider.modelID
            )
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
        //    table. Vectors are not append-only so deletion is permitted.
        try await vectorStore.destroyAllVectors()
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
        try await provider.embed(text)
    }

    /// The embedding model identifier this corpus was configured with.
    ///
    /// Exposed for GeniusLocusKit's RecallDirector vector lane so it can pass
    /// the correct `modelID` to `VectorStore.findNearest`. Must match the
    /// `modelID` used during `ingest` — vectors stored under a different model
    /// ID are not comparable per spec I-4.
    public var modelID: String { provider.modelID }

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
        try await provider.embedFloat(text)
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

        // Attempt to embed the query text via the float lane. A throw here
        // means the provider has no float lane (expected opt-out). This is NOT
        // a store error — no log, no store_error counter. Emit the dark_provider
        // counter so the caller can observe the lane was dark.
        let probe: [Float]
        do {
            let result = try await provider.embedFloat(query)
            guard !result.isEmpty else {
                // Provider returned an empty vector — treat as opt-out.
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_provider",
                    value: 1.0,
                    tags: ["kit": "CorpusKit"],
                    ts: Date().timeIntervalSince1970
                ))
                return .unavailableProviderOptOut
            }
            probe = result
        } catch {
            // Provider threw — this is the expected opt-out path (e.g.
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
            matches = try await vectorStore.findNearestFloat(
                probe: probe, modelID: provider.modelID, limit: limit * 4)
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
        // real Drawer row. A source's similarity is its best (max) chunk cosine.
        // VectorMatch.distance is the cosine DISTANCE (1 − sim) quantised
        // ×10_000 (FloatBruteForceIndex convention); recover sim = 1 − dist/1e4.
        var bySource: [String: Float] = [:]
        for m in matches {
            guard let chunkUUID = UUID(uuidString: m.itemID),
                  let sourceID = chunkSourceMap[chunkUUID] else { continue }
            let similarity = 1.0 - Float(m.distance) / 10_000.0
            bySource[sourceID] = max(bySource[sourceID] ?? -Float.greatestFiniteMagnitude, similarity)
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

        // Sort by similarity descending, sourceID ascending on tie (the
        // universal deterministic tie-break), and return the top `limit`.
        var ranked = bySource.map { (itemID: $0.key, similarity: $0.value) }
        ranked.sort { a, b in
            if a.similarity != b.similarity { return a.similarity > b.similarity }
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

    /// Whether this corpus's embedding provider supports the dense float lane
    /// (Lane D). True when `embedFloat` returns a vector rather than throwing
    /// the opt-out error. Probes with a single non-empty token so the answer
    /// reflects provider capability, not input. The GLK dense lane checks this
    /// (via a non-empty `floatNearest`) before fusing the dense column.
    public var supportsFloat: Bool {
        get async {
            ((try? await provider.embedFloat("x")) ?? []).isEmpty == false
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
