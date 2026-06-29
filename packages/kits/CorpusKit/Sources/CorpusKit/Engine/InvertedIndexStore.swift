// InvertedIndexStore.swift
//
// SQLite-backed persistence for the weighted impact inverted index.
//
// Lane D — InvertedIndex persistence sidecar.
// Architecture spec §4.4: "the inverted index persists to a CorpusKit
// sidecar so it is not rebuilt from scratch each startup at scale."
//
// Tables (in the InvertedIndexStore schema):
//   iix_termfreqs  — (term TEXT, item_id TEXT, freq INTEGER) composite PK
//   iix_doclens    — (item_id TEXT PK, length INTEGER)
//
// The posting rows themselves (with quantized impacts) are derived
// at query time from the term-frequency table plus BM25 parameters;
// they are NOT stored separately. This keeps the persistence layer
// separate from the impact quantization policy: changing k1/b/scale
// does not require a migration of the posting layer, only a rebuild
// of the in-memory InvertedIndex.
//
// All dates are TEXT (ISO8601). No Bool stored columns.
// Actor boundary serializes all mutations.
//
// Parity: Rust twin in CorpusKit/rust/src/engine/inverted_index_store.rs.

import Foundation
import OSLog
import PersistenceKit

private let logger = Logger(subsystem: "com.mootx01.kit", category: "InvertedIndexStore")

// MARK: - InvertedIndexStore

/// Actor-wrapped, SQLite-backed persistence sidecar for the inverted index.
///
/// Persists term frequencies and document lengths. Rebuilds the
/// BM25-weighted `InvertedIndex` on demand (cached between mutations).
///
/// Lifecycle:
/// 1. `init(storage:)` — create with an already-opened Storage backend.
/// 2. `open()` — load persisted term frequencies and doc lengths from storage.
/// 3. `index(itemID:tokens:now:)` — add/update a document's terms.
/// 4. `remove(itemID:)` — remove a document.
/// 5. `buildIndex(parameters:)` — produce an InvertedIndex + term mapping.
/// 6. `topK(queryTerms:k:parameters:algorithm:)` — convenience retrieve.
///
/// Thread-safety: all mutations are serialized by the actor.
public actor InvertedIndexStore {

    // MARK: - Schema declaration (public for migration callers)

    /// Schema declaration for the inverted index sidecar tables.
    ///
    /// Callers migrate storage with `storage.migrate(to: InvertedIndexStore.schemaDeclaration)`,
    /// then construct `InvertedIndexStore(storage:)` and call `open()`.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "InvertedIndexStore",
        version: 1,
        tables: [
            TableDeclaration(
                name: "iix_termfreqs",
                columns: [
                    .text("term"),
                    .text("item_id"),
                    .int("freq")
                ],
                primaryKey: ["term", "item_id"]
            ),
            TableDeclaration(
                name: "iix_doclens",
                columns: [
                    .text("item_id"),
                    .int("length")
                ],
                primaryKey: ["item_id"]
            )
        ],
        indices: [
            IndexDeclaration(
                name: "idx_iix_tf_item",
                table: "iix_termfreqs",
                columns: ["item_id"]
            )
        ]
    )

    // MARK: - Dependencies

    private let storage: any Storage

    // MARK: - In-memory state (derived from DB on open)

    /// term → itemID → term frequency
    private var termFreqs: BM25Weighting.TermFreqTable = [:]
    /// itemID → document length in tokens
    private var docLengths: [String: Int] = [:]
    /// Cached (index, termMapping). Invalidated by every write.
    private var cachedPair: (index: InvertedIndex, termMapping: [String: UInt32])? = nil

    // MARK: - Init

    /// Create an InvertedIndexStore. Requires a `Storage` backend opened
    /// with a schema that includes `InvertedIndexStore.schemaDeclaration`.
    ///
    /// - Parameter storage: already-opened Storage backend.
    public init(storage: any Storage) {
        self.storage = storage
    }

    // MARK: - Open (load persisted state)

    /// Load persisted term frequencies and document lengths from storage.
    ///
    /// Call this once after the `Storage` backend is opened with the schema.
    public func open() async throws {
        try await loadTermFreqs()
        try await loadDocLengths()
        logger.info("InvertedIndexStore opened: \(self.docLengths.count) docs, \(self.termFreqs.count) terms")
    }

    private func loadTermFreqs() async throws {
        let rows = try await storage.rowStore.query(
            table: "iix_termfreqs",
            where: nil
        )
        for row in rows {
            guard
                case .text(let term) = row["term"],
                case .text(let itemID) = row["item_id"],
                case .int(let freq) = row["freq"]
            else { continue }
            termFreqs[term, default: [:]][itemID] = Int(freq)
        }
    }

    private func loadDocLengths() async throws {
        let rows = try await storage.rowStore.query(
            table: "iix_doclens",
            where: nil
        )
        for row in rows {
            guard
                case .text(let itemID) = row["item_id"],
                case .int(let length) = row["length"]
            else { continue }
            docLengths[itemID] = Int(length)
        }
    }

    // MARK: - Document indexing

    /// Index a document's tokenized terms.
    ///
    /// Re-indexing an existing item replaces all its term frequencies atomically.
    ///
    /// - Parameters:
    ///   - itemID: stable item identifier (chunk UUID string or any unique string).
    ///   - tokens: tokenized keyword terms using the same vocabulary as query time.
    ///   - now: present for deterministic-date discipline; not currently read — only term frequencies and document length are persisted.
    public func index(itemID: String, tokens: [String], now: Date) async throws {
        // Remove existing state for this item first (idempotent re-index).
        try await deleteFromStorage(itemID: itemID)
        deleteMem(itemID: itemID)

        guard !tokens.isEmpty else { return }

        var tf = [String: Int]()
        for t in tokens { tf[t, default: 0] += 1 }
        let docLen = tokens.count

        // Persist term frequencies.
        for (term, freq) in tf {
            try await storage.rowStore.upsert(
                table: "iix_termfreqs",
                values: [
                    "term": .text(term),
                    "item_id": .text(itemID),
                    "freq": .int(Int64(freq))
                ],
                conflictColumns: ["term", "item_id"]
            )
            termFreqs[term, default: [:]][itemID] = freq
        }
        // Persist doc length.
        try await storage.rowStore.upsert(
            table: "iix_doclens",
            values: [
                "item_id": .text(itemID),
                "length": .int(Int64(docLen))
            ],
            conflictColumns: ["item_id"]
        )
        docLengths[itemID] = docLen
        cachedPair = nil
    }

    /// Remove a document from the index.
    ///
    /// - Parameter itemID: item to remove. No-op if not present.
    public func remove(itemID: String) async throws {
        try await deleteFromStorage(itemID: itemID)
        deleteMem(itemID: itemID)
        cachedPair = nil
    }

    private func deleteFromStorage(itemID: String) async throws {
        _ = try await storage.rowStore.delete(
            table: "iix_termfreqs",
            where: .eq(Column(table: "iix_termfreqs", name: "item_id"), .text(itemID))
        )
        _ = try await storage.rowStore.delete(
            table: "iix_doclens",
            where: .eq(Column(table: "iix_doclens", name: "item_id"), .text(itemID))
        )
    }

    private func deleteMem(itemID: String) {
        docLengths.removeValue(forKey: itemID)
        for term in Array(termFreqs.keys) {
            termFreqs[term]?.removeValue(forKey: itemID)
            if termFreqs[term]?.isEmpty == true { termFreqs.removeValue(forKey: term) }
        }
    }

    // MARK: - Index building

    /// Build (or return cached) InvertedIndex with BM25-weighted impacts.
    ///
    /// - Parameter parameters: BM25 k1/b.
    /// - Returns: (InvertedIndex, term mapping) ready for querying.
    public func buildIndex(
        parameters: BM25Parameters = BM25Parameters()
    ) -> (index: InvertedIndex, termMapping: [String: UInt32]) {
        if let cached = cachedPair { return cached }
        let pair = BM25Weighting.build(
            termFreqs: termFreqs,
            docLengths: docLengths,
            parameters: parameters
        )
        cachedPair = pair
        return pair
    }

    // MARK: - Convenience top-k

    /// Build the index and return top-k SparseHit results for tokenized query terms.
    ///
    /// - Parameters:
    ///   - queryTerms: tokenized query terms.
    ///   - k: number of results.
    ///   - parameters: BM25 k1/b.
    ///   - algorithm: WAND or BMW (default BMW).
    /// - Returns: SparseHit array, score descending.
    public func topK(
        queryTerms: [String],
        k: Int,
        parameters: BM25Parameters = BM25Parameters(),
        algorithm: InvertedIndex.Algorithm = .blockMaxWand
    ) -> [SparseHit] {
        let (index, termMapping) = buildIndex(parameters: parameters)
        let query = BM25Weighting.queryPairs(queryTerms: queryTerms, termMapping: termMapping)
        return index.topK(query: query, k: k, algorithm: algorithm)
    }

    // MARK: - Bulk clear

    /// Delete all persisted term frequencies and document lengths, and clear
    /// in-memory state. Used by `Corpus.destroyRecallIndex` to wipe the
    /// durable inverted index in one call (no per-item iteration needed).
    ///
    /// Mirrors BasisStore.deleteAll() and VectorStore.destroyAllVectors() in
    /// its semantics: the store is left empty but structurally intact (tables
    /// remain, indices remain; only rows are removed).
    public func deleteAll() async throws {
        // `.isTrue` is the always-match predicate — delete requires a non-optional
        // predicate (the RowStore API does not expose a nil shortcut for "delete all"),
        // so `.isTrue` is the standard pattern used across the codebase (see BasisStore.deleteAll).
        _ = try await storage.rowStore.delete(
            table: "iix_termfreqs",
            where: .isTrue
        )
        _ = try await storage.rowStore.delete(
            table: "iix_doclens",
            where: .isTrue
        )
        // Clear in-memory state to match the now-empty tables.
        termFreqs.removeAll()
        docLengths.removeAll()
        cachedPair = nil
        logger.info("InvertedIndexStore: deleteAll cleared all term-freq + doc-len rows")
    }

    // MARK: - Accessors

    /// Number of indexed documents.
    public var documentCount: Int { docLengths.count }
}
