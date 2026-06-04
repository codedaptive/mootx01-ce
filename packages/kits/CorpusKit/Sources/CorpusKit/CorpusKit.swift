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
import PersistenceKit
import SubstrateML
import SubstrateTypes
import VectorKit

// MARK: - EmbeddingModel

/// Selects the embedding model the Corpus actor uses internally.
///
/// The caller names a CorpusKit case; no VectorKit type is required
/// at the call site. For tests and offline contexts use `.deterministic`
/// (the default) — it requires no CoreML model bundle and produces
/// consistent projections via FNV-1a hashing + FloatSimHash. For
/// semantic retrieval supply a CoreML inference closure via a named
/// model case.
public enum EmbeddingModel: Sendable {

    /// Deterministic hash embedding. No CoreML required.
    ///
    /// Uses FNV-1a hashing through the canonical FloatSimHash projection
    /// with a fixed seed. Consistent across calls and across Swift/Rust
    /// ports, but not semantically meaningful — suitable for tests,
    /// prototyping, and offline use.
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

    /// Default: deterministic (no CoreML required).
    public static let `default`: EmbeddingModel = .deterministic
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
        // chunk.id.uuidString == vector.drawerID join is maintained here;
        // the caller never sees it (sealed-vector principle).
        for chunk in chunks {
            let engram = try await provider.embed(chunk.text)
            try await vectorStore.addVector(
                drawerID: chunk.id.uuidString,
                engram: engram,
                modelID: provider.modelID,
                modelVersion: provider.modelVersion,
                filedAt: now
            )
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
            try await vectorStore.deleteVector(
                drawerID: chunk.id.uuidString,
                modelID: provider.modelID
            )
        }
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

    /// Count the total chunks in the bundle store across all sources.
    ///
    /// Because BundleStore is append-only, this count does not decrease
    /// when `remove(sourceID:)` is called — removed chunks are still
    /// stored but no longer appear in recall results.
    public func count() async throws -> Int {
        try await bundleStore.count()
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
private struct CorpusDefaultTokenizer: Tokenizer {
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
}
