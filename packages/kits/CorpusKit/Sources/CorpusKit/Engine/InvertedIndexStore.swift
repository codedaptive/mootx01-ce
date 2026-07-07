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

    /// ADR-026: when `.ramResident`, term frequencies and document lengths
    /// are held in RAM between queries (pre-ADR-026 behavior). When
    /// `.diskBacked` (default), they are loaded from SQLite on demand.
    private var ramTermFreqs: BM25Weighting.TermFreqTable?
    private var ramDocLengths: [String: Int]?

    // MARK: - Cached index (ADR-026: no persistent in-memory dictionaries)

    /// Last-built (index, termMapping), served by `buildIndex(parameters:)`
    /// while `isDirty` is false. Term frequencies and document lengths are
    /// NOT held in RAM between builds — they are loaded from SQLite into
    /// transient locals inside `buildIndex`, used to construct the index,
    /// then discarded. This eliminates ~580MB of heap dictionaries on a
    /// 50K-memory estate (the `termFreqs` and `docLengths` maps that
    /// previously persisted between queries). The built `InvertedIndex`
    /// itself is compact (impact-quantized postings, ~120MB) and remains
    /// cached until the next write invalidates it.
    private var cachedPair: (index: InvertedIndex, termMapping: [String: UInt32])? = nil
    /// True when the durable iix_* tables have changed since `cachedPair`
    /// was built. Starts `true` — there is nothing to serve until the
    /// first build. Set by every mutating call (`index`, `foldPostings`,
    /// `remove`, `deleteAll`); cleared only inside `buildIndex(parameters:)`
    /// once a fresh pair has been built.
    private var isDirty: Bool = true

    // MARK: - Init

    /// Create an InvertedIndexStore. Requires a `Storage` backend opened
    /// with a schema that includes `InvertedIndexStore.schemaDeclaration`.
    ///
    /// - Parameter storage: already-opened Storage backend.
    public init(storage: any Storage) {
        self.storage = storage
    }

    // MARK: - Open (load persisted state)

    /// Validate the schema is accessible. ADR-026: term frequencies and
    /// document lengths are no longer loaded into RAM at open time. They
    /// are loaded from SQLite on demand inside `buildIndex` and discarded
    /// after the index is built.
    public func open() async throws {
        if storage.configuration.residencyHint == .ramResident {
            // Pre-ADR-026 behavior: load everything into RAM at open.
            ramTermFreqs = try await loadTermFreqsTransient()
            ramDocLengths = try await loadDocLengthsTransient()
            let docCount = self.ramDocLengths?.count ?? 0
            let termCount = self.ramTermFreqs?.count ?? 0
            logger.info("InvertedIndexStore opened (ramResident): \(docCount) docs, \(termCount) terms")
        } else {
            // ADR-026: verify tables are readable. Data stays on disk.
            let docRows = try await storage.rowStore.query(
                table: "iix_doclens", where: nil, orderBy: [], limit: 1, offset: nil)
            let termRows = try await storage.rowStore.query(
                table: "iix_termfreqs", where: nil, orderBy: [], limit: 1, offset: nil)
            logger.info("InvertedIndexStore opened (diskBacked): tables accessible (docs=\(!docRows.isEmpty), terms=\(!termRows.isEmpty))")
        }
    }

    /// Load term frequencies from SQLite into a transient dictionary.
    /// Called only inside `buildIndex`; the result is discarded after
    /// the InvertedIndex is built. ADR-026: no persistent in-memory mirror.
    private func loadTermFreqsTransient() async throws -> BM25Weighting.TermFreqTable {
        var tf: BM25Weighting.TermFreqTable = [:]
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
            tf[term, default: [:]][itemID] = Int(freq)
        }
        return tf
    }

    /// Load document lengths from SQLite into a transient dictionary.
    /// Called only inside `buildIndex`; the result is discarded after
    /// the InvertedIndex is built. ADR-026: no persistent in-memory mirror.
    private func loadDocLengthsTransient() async throws -> [String: Int] {
        var dl: [String: Int] = [:]
        let rows = try await storage.rowStore.query(
            table: "iix_doclens",
            where: nil
        )
        for row in rows {
            guard
                case .text(let itemID) = row["item_id"],
                case .int(let length) = row["length"]
            else { continue }
            dl[itemID] = Int(length)
        }
        return dl
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

        guard !tokens.isEmpty else { isDirty = true; return }

        var tf = [String: Int]()
        for t in tokens { tf[t, default: 0] += 1 }
        let docLen = tokens.count

        // Persist term frequencies — durable SQLite only, no in-memory mirror.
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
        // Maintain RAM mirror when ramResident.
        if ramTermFreqs != nil {
            for (term, freq) in tf {
                ramTermFreqs?[term, default: [:]][itemID] = freq
            }
            ramDocLengths?[itemID] = docLen
        }
        isDirty = true
    }

    /// Fold worker-computed postings into the IN-MEMORY maps only — the memory
    /// twin of the EXT-4 shard merge, which writes the durable iix_* tables via
    /// `SQLiteStorage.mergeShard` (SQLite copies the shard rows internally; this
    /// method folds the same postings the workers already computed, so nothing
    /// is re-read from disk). Re-delivered items simply overwrite their prior
    /// entries (idempotent under queue-retry). Marks the cached BM25 index
    /// dirty once for the whole batch (see `isDirty`) rather than per item —
    /// the next query rebuilds once, not once per folded item. Rust twin:
    /// `InvertedIndexStore::fold_postings`.
    /// Mark the index dirty after an external shard merge writes to the
    /// durable iix_* tables. ADR-026: no in-memory mirror — the durable
    /// tables are the source of truth, and `buildIndex` reloads from them
    /// on the next query. The `items` parameter is accepted for API
    /// compatibility but the data is NOT copied into RAM dictionaries.
    public func foldPostings(_ items: [(itemID: String, tf: [String: Int], docLen: Int)]) {
        isDirty = true
    }

    /// Remove a document from the index.
    ///
    /// - Parameter itemID: item to remove. No-op if not present.
    public func remove(itemID: String) async throws {
        try await deleteFromStorage(itemID: itemID)
        // Release cached index immediately on destructive ops so sensitive
        // terms don't linger in process memory after deletion.
        cachedPair = nil
        ramTermFreqs = nil
        ramDocLengths = nil
        isDirty = true
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

    // MARK: - Index building

    /// Build (or return cached) InvertedIndex with BM25-weighted impacts.
    ///
    /// - Parameter parameters: BM25 k1/b.
    /// - Returns: (InvertedIndex, term mapping) ready for querying.
    /// Build the BM25-weighted InvertedIndex from the durable iix_* tables.
    ///
    /// ADR-026: term frequencies and document lengths are loaded from SQLite
    /// into transient locals, used to build the index, then discarded. The
    /// built InvertedIndex is cached; the raw dictionaries are not.
    public func buildIndex(
        parameters: BM25Parameters = BM25Parameters()
    ) async throws -> (index: InvertedIndex, termMapping: [String: UInt32]) {
        if let cached = cachedPair, !isDirty { return cached }
        // ADR-026: use RAM maps when ramResident, else load from SQLite.
        let termFreqs: BM25Weighting.TermFreqTable
        let docLengths: [String: Int]
        if let rt = ramTermFreqs, let rd = ramDocLengths {
            termFreqs = rt; docLengths = rd
        } else {
            termFreqs = try await loadTermFreqsTransient()
            docLengths = try await loadDocLengthsTransient()
        }
        let pair = BM25Weighting.build(
            termFreqs: termFreqs,
            docLengths: docLengths,
            parameters: parameters
        )
        cachedPair = pair
        isDirty = false
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
    ) async throws -> [SparseHit] {
        let (index, termMapping) = try await buildIndex(parameters: parameters)
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
        // Release cached index immediately so sensitive terms don't linger.
        cachedPair = nil
        ramTermFreqs = nil
        ramDocLengths = nil
        isDirty = true
        logger.info("InvertedIndexStore: deleteAll cleared all term-freq + doc-len rows")
    }

    // MARK: - Accessors

    /// Number of indexed documents. Queries the durable table
    /// (ADR-026: no in-memory mirror).
    public func documentCount() async throws -> Int {
        let rows = try await storage.rowStore.query(
            table: "iix_doclens", where: nil)
        return rows.count
    }
}
