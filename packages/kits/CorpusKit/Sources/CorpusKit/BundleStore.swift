// BundleStore.swift
//
// Storage for RAG chunks (the "content half" of a content-plus-
// vector bundle). The vector half lives in VectorKit's vectors
// table; the bundle store maintains the chunks table and the
// join via (chunk.id.uuidString == vector.item_id) by convention
// (Lane F rename: drawer_id → item_id, arch spec §4.1).
//
// Schema (single table, one row per chunk):
//   chunks (
//     id           UUID PRIMARY KEY,
//     source_id    TEXT NOT NULL,
//     start_offset INT NOT NULL,
//     length       INT NOT NULL,
//     text         TEXT NOT NULL,
//     hlc          HLC NOT NULL,
//     metadata     JSON NOT NULL,
//     created_at   TIMESTAMP NOT NULL,
//     ext          JSON,              -- v2: forward-compat slot
//     content_hash BLOB               -- v3: SHA-256 via MerkleHash.leaf (NT-C1)
//   )
//
// Indices on (source_id) for "give me everything from this doc"
// and on (hlc) for HLC-ordered iteration during sync.
//
// The chunks table is append-only. Chunks are content-addressed by
// id and never edited in place, which is exactly the invariant the
// sync layer relies on: CorpusKitSync declares the table with
// conflictPolicy .appendOnly so duplicate inserts across devices
// resolve idempotently rather than racing an update. Declaring the
// table appendOnly: true makes PersistenceKit emit the BEFORE UPDATE /
// BEFORE DELETE abort triggers that enforce that invariant at the
// substrate, so the store cannot accidentally mutate or drop a chunk
// row. Row-level removal is therefore not a BundleStore operation;
// erasure of chunk content is handled at the bundle-algebra/erasure
// layer (redaction, excision, compaction), not by an ad-hoc per-row
// delete.
//
// CORPUSKIT_REPORT_001 (cp-corpuskit-report): added IntellectusLib
// self-report telemetry to insert. The emit calls are placed at the
// operation boundary, after the batch completes, so the storage
// behaviour is unchanged. The insert path always reads Date() for
// startTime, Date() for each chunk's created_at, and Date() for
// endTime before calling Intellectus.report; the disabled-monitoring
// path does not short-circuit these clock reads.

import Foundation
import IntellectusLib
import SubstrateTypes
import SubstrateLib
import SubstrateKernel
import PersistenceKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

/// Thread-safe cache mapping chunk UUIDs to their Merkle containment
/// parent chain. Populated by BundleStore.insert before each
/// HashingRowStore write so the synchronous HashParentChainProvider
/// callback can look up the corpus-level parent without async I/O.
final class ParentChainCache: @unchecked Sendable {
    private var cache: [UUID: (parent: UUID, grandparent: UUID)] = [:]
    private let lock = NSLock()

    func set(_ key: UUID, parent: UUID, grandparent: UUID) {
        lock.lock()
        cache[key] = (parent, grandparent)
        lock.unlock()
    }

    func get(_ key: UUID) -> (parentNodeId: UUID, grandparentNodeId: UUID)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key] else { return nil }
        return (parentNodeId: entry.parent, grandparentNodeId: entry.grandparent)
    }

    func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

public actor BundleStore {

    let storage: any Storage

    /// The hashing decorator wrapping the raw row store. Intercepts
    /// inserts to hashable tables, computes ContentHash via
    /// MerkleHash.leaf, and emits DirtyChainEvents for Merkle rollup.
    private let hashingRowStore: HashingRowStore

    /// Pre-insert cache for the HashParentChainProvider callback.
    private let parentChainCache = ParentChainCache()

    /// Fixed UUID representing the corpus-level root node (grandparent
    /// in the chunk → corpus → root containment chain). Deterministic
    /// across Swift and Rust — SHA-256 of a fixed seed, first 16 bytes.
    static let corpusRootUUID: UUID = {
        let digest = SHA256.hash(Array("CorpusKit.corpusRoot".utf8))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                           digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }()

    /// Derives a deterministic UUID for a corpus from its source_id.
    /// SHA-256 of a fixed namespace prefix + source_id, first 16 bytes.
    /// Both Swift and Rust ports use identical derivation for
    /// byte-identical Merkle containment chains.
    static func corpusUUID(for sourceID: String) -> UUID {
        var input = Array("CorpusKit.corpusNamespace:".utf8)
        input.append(contentsOf: Array(sourceID.utf8))
        let digest = SHA256.hash(input)
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                           digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }

    /// Schema declaration consumed by Storage.open(schema:).
    ///
    /// v2 adds the nullable `.json` `ext` forward-compat slot.
    /// v3 adds `content_hash` BLOB column and marks the table `hashable`
    /// for hash-on-write via HashingRowStore (node-tree integrity, NT-C1).
    /// The `content_hash` column is nullable: NULL for rows inserted
    /// before v3 (backward-compatible migration, no backfill required).
    /// v3 also adds the `corpus_metadata` table for per-corpus Merkle roots.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKit",
        version: 3,
        tables: [
            TableDeclaration(
                name: "chunks",
                columns: [
                    .uuid("id"),
                    .text("source_id", nullable: false),
                    .int("start_offset", nullable: false),
                    .int("length", nullable: false),
                    .text("text", nullable: false),
                    ColumnDeclaration(name: "hlc", type: .hlc, nullable: false),
                    .json("metadata", nullable: false),
                    .timestamp("created_at", nullable: false),
                    // nullable entity ext slots forward-compat slot (v2). Nullable JSON; distinct
                    // from `metadata`. 1.0 omits it on insert and never reads it.
                    .json("ext", nullable: true),
                    // NT-C1 (v3): SHA-256 content hash computed by
                    // HashingRowStore on write via MerkleHash.leaf.
                    // Nullable for backward compat with pre-v3 rows.
                    .blob("content_hash", nullable: true)
                ],
                primaryKey: ["id"],
                appendOnly: false,
                hashable: true
            ),
            // Per-corpus Merkle root: MerkleHash.interior over the
            // content_hashes of all chunks sharing a source_id.
            // Updated incrementally after each insert batch (NT-C1 Part 3).
            TableDeclaration(
                name: "corpus_metadata",
                columns: [
                    .text("source_id", nullable: false),
                    // MerkleRoot bytes (32-byte SHA-256). NULL until the
                    // first rollup computes it.
                    .blob("merkle_root", nullable: true)
                ],
                primaryKey: ["source_id"]
            )
        ],
        indices: [
            IndexDeclaration(
                name: "idx_chunks_source",
                table: "chunks",
                columns: ["source_id"]
            ),
            IndexDeclaration(
                name: "idx_chunks_hlc",
                table: "chunks",
                columns: ["hlc"]
            )
        ]
    )

    /// Designated initialiser.
    ///
    /// Wraps the storage's raw row store in a `HashingRowStore` that
    /// computes ContentHash via `MerkleHash.leaf` on every chunk insert.
    /// The `dirtyChainSink` parameter accepts DirtyChainEvents for
    /// downstream Merkle rollup consumers (Part 3).
    public init(
        storage: any Storage,
        dirtyChainSink: HashingRowStore.ObserverRegistryRef? = nil
    ) {
        self.storage = storage

        let cache = parentChainCache
        let hashableTables: Set<String> = ["chunks"]

        let config = HashOnWriteConfig(
            hashableTables: hashableTables,
            hashProvider: { table, rowKey, values -> ContentHash in
                // Extract the chunk text for hashing. The text column
                // is the chunk's content; vectors live in VectorKit
                // (not inline), so the vector input is empty.
                let contentBytes: [UInt8]
                if case let .text(text) = values["text"] ?? .null {
                    contentBytes = Array(text.utf8)
                } else {
                    contentBytes = []
                }
                return MerkleHash.leaf(
                    drawerId: rowKey,
                    content: contentBytes,
                    vectors: []
                )
            },
            parentChainProvider: { table, rowKey in
                cache.get(rowKey)
            }
        )

        self.hashingRowStore = HashingRowStore(
            backing: storage.rowStore,
            config: config,
            dirtyChainSink: dirtyChainSink
        )
    }

    /// Insert a batch of chunks. Idempotent on primary key:
    /// re-inserting a chunk with the same id is a no-op.
    ///
    /// Returns the subset of `chunks` that were ACTUALLY inserted (new ids), in
    /// input order — duplicate-key no-ops are excluded. Callers that maintain
    /// derived per-chunk state which must NOT double-count on re-ingest (the
    /// maintained provider counts) fold only over the returned set; callers that
    /// don't care discard it (`@discardableResult`).
    ///
    /// The idempotent path is a plain insert that tolerates a
    /// duplicate-key rejection rather than an upsert. A plain insert
    /// hits the primary-key constraint and surfaces
    /// StorageError.duplicateKey, which is caught here and treated as
    /// the documented no-op. The first write of a given id wins; a
    /// later insert of the same id is dropped, which is correct because
    /// chunks are immutable and content-addressed.
    ///
    /// Note: the chunks table is NOT append-only (appendOnly: false),
    /// enabling `scrubText(sourceID:)` to zero verbatim text on expunge
    /// (secfix/ws2-coredelete: hard-delete destruction contract). The
    /// idempotent insert path is unaffected — duplicate-key rejection
    /// happens at the primary-key constraint level, not via triggers.
    ///
    /// Telemetry: emits `corpuskit.ingest.latency_ms` (wall time for the
    /// full batch insert) and `corpuskit.ingest.chunk_count` (number of
    /// chunks in the batch, including idempotent no-ops) when monitoring is
    /// enabled. Both are emitted at the operation boundary — after the last
    /// insert attempt completes — so they cannot affect the stored values or
    /// any thrown error. Off-path: single Atomic<Bool> load per call.
    @discardableResult
    public func insert(_ chunks: [Chunk]) async throws -> [Chunk] {
        guard !chunks.isEmpty else { return [] }
        var inserted: [Chunk] = []
        inserted.reserveCapacity(chunks.count)

        // Capture start time before the I/O. The code also stamps
        // created_at with Date() for every chunk and reads endTime
        // after the insert loop; multiple Date() reads occur per call.
        let startTime = Date().timeIntervalSince1970

        for chunk in chunks {
            let metadataJSON: Data
            do {
                metadataJSON = try JSONEncoder().encode(chunk.metadata)
            } catch {
                throw CorpusKitError.encodingFailure("metadata: \(error)")
            }
            let values: [String: TypedValue] = [
                "id": .uuid(chunk.id),
                "source_id": .text(chunk.sourceID),
                "start_offset": .int(Int64(chunk.startOffset)),
                "length": .int(Int64(chunk.length)),
                "text": .text(chunk.text),
                "hlc": .hlc(chunk.hlc),
                "metadata": .json(metadataJSON),
                "created_at": .timestamp(Date())
            ]
            // Pre-populate parent chain cache so the synchronous
            // HashParentChainProvider callback can map this chunk
            // to its corpus-level parent in the Merkle tree.
            let corpusUUID = Self.corpusUUID(for: chunk.sourceID)
            parentChainCache.set(
                chunk.id,
                parent: corpusUUID,
                grandparent: Self.corpusRootUUID
            )
            do {
                _ = try await hashingRowStore.insert(
                    table: "chunks",
                    values: values
                )
                inserted.append(chunk)
            } catch StorageError.duplicateKey {
                // Idempotent no-op: the chunk is already stored. Chunks
                // are immutable, so there is nothing to reconcile. NOT added to
                // `inserted` — derived per-chunk state must not double-count it.
                continue
            }
        }
        parentChainCache.clear()

        // Recompute per-corpus Merkle roots for all affected sources.
        let affectedSources = Set(chunks.map(\.sourceID))
        for sourceID in affectedSources {
            try await rollupCorpusMerkleRoot(sourceID: sourceID)
        }

        // Emit ingest telemetry at the operation boundary, after all inserts
        // complete (including idempotent no-ops). The autoclosures are
        // evaluated only when monitoring is enabled.
        //
        // corpuskit.ingest.latency_ms: wall time for the full batch insert.
        // corpuskit.ingest.chunk_count: chunks in the batch (incl. no-ops).
        let endTime = Date().timeIntervalSince1970
        let chunkCount = chunks.count
        Intellectus.report(.metric(
            name: "corpuskit.ingest.latency_ms",
            value: (endTime - startTime) * 1000.0,
            tags: ["kit": "CorpusKit"],
            ts: endTime
        ))
        Intellectus.report(.metric(
            name: "corpuskit.ingest.chunk_count",
            value: Double(chunkCount),
            tags: ["kit": "CorpusKit"],
            ts: endTime
        ))
        return inserted
    }

    public func get(id: UUID, asOf: AsOfCoordinate? = nil) async throws -> Chunk? {
        let rows = try await storage.rowStore.query(
            table: "chunks",
            where: .eq(Column(table: "chunks", name: "id"), .uuid(id)),
            orderBy: [],
            limit: 1,
            offset: nil,
            asOf: asOf
        )
        guard let row = rows.first else { return nil }
        return Self.decodeChunk(row)
    }

    public func getMany(ids: [UUID], asOf: AsOfCoordinate? = nil) async throws -> [Chunk] {
        guard !ids.isEmpty else { return [] }
        let values = ids.map { TypedValue.uuid($0) }
        let rows = try await storage.rowStore.query(
            table: "chunks",
            where: .in(Column(table: "chunks", name: "id"), values),
            orderBy: [],
            limit: nil,
            offset: nil,
            asOf: asOf
        )
        return rows.compactMap(Self.decodeChunk)
    }

    public func chunksForSource(_ sourceID: String, asOf: AsOfCoordinate? = nil) async throws -> [Chunk] {
        let rows = try await storage.rowStore.query(
            table: "chunks",
            where: .eq(Column(table: "chunks", name: "source_id"), .text(sourceID)),
            orderBy: [
                OrderClause(
                    column: Column(table: "chunks", name: "start_offset"),
                    direction: .ascending
                )
            ],
            limit: nil,
            offset: nil,
            asOf: asOf
        )
        return rows.compactMap(Self.decodeChunk)
    }

    /// Return the set of all distinct `source_id` values currently in the
    /// chunks table.
    ///
    /// Used by `reindexMissing` to identify which drawers already have at least
    /// one chunk and therefore do not need to be enqueued for re-encoding.
    /// The query is a full-table scan over the source_id index, but it is only
    /// called in maintenance/admin contexts (not on hot paths).
    public func allSourceIDs(asOf: AsOfCoordinate? = nil) async throws -> Set<String> {
        let rows = try await storage.rowStore.query(
            table: "chunks",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil,
            asOf: asOf
        )
        var ids = Set<String>()
        for row in rows {
            if case let .text(sourceID) = row["source_id"] ?? .null {
                ids.insert(sourceID)
            }
        }
        return ids
    }

    /// Compact projection — chunk UUID → source_id pairs for ALL non-tombstoned rows.
    ///
    /// Used by `Corpus.init` to warm-load `chunkSourceMap` on open WITHOUT loading
    /// chunk body text. Selecting only `id` and `source_id` avoids the O(N·body)
    /// cold-start cost of `allChunks()` when all we need is the reverse-map join key.
    ///
    /// "Non-tombstoned" here means the same filtering contract `activeChunks()`
    /// applies — callers combine this result with `RemovedSourceStore.removedIDs()`
    /// to exclude removed sources. Ordering is unspecified (the join key lookup
    /// is O(1) per UUID regardless of order).
    public func chunkSourcePairs() async throws -> [(id: UUID, sourceID: String)] {
        // Query with an empty orderBy to avoid the HLC-ordered full scan that
        // allChunks() uses — we only need the two key columns, not body or ordering.
        let rows = try await storage.rowStore.query(
            table: "chunks",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil
        )
        var pairs: [(id: UUID, sourceID: String)] = []
        pairs.reserveCapacity(rows.count)
        for row in rows {
            // Tolerate both `.uuid` (InMemory backend) and `.text` UUID string (SQLite
            // backend) — the same primitive-tolerance discipline all BundleStore decoders use.
            let maybeID: UUID?
            switch row["id"] ?? .null {
            case .uuid(let u):    maybeID = u
            case .text(let s):   maybeID = UUID(uuidString: s)
            default:             maybeID = nil
            }
            guard let id = maybeID,
                  case let .text(sourceID) = row["source_id"] ?? .null else { continue }
            pairs.append((id: id, sourceID: sourceID))
        }
        return pairs
    }

    // asOf not forwarded: RowStore.count has no as-of variant.
    // Count includes all rows regardless of snapshot coordinate.
    public func count(asOf: AsOfCoordinate? = nil) async throws -> Int {
        try await storage.rowStore.count(table: "chunks", where: nil)
    }

    public func allChunks(asOf: AsOfCoordinate? = nil) async throws -> [Chunk] {
        let rows = try await storage.rowStore.query(
            table: "chunks",
            where: nil,
            orderBy: [
                OrderClause(
                    column: Column(table: "chunks", name: "hlc"),
                    direction: .ascending
                )
            ],
            limit: nil,
            offset: nil,
            asOf: asOf
        )
        return rows.compactMap(Self.decodeChunk)
    }

    // MARK: - Hard-delete erasure (secfix/ws2-coredelete)

    /// Zero the verbatim text of every chunk belonging to `sourceID`.
    ///
    /// This is the corpus layer's contribution to the hard-delete destruction
    /// contract: `CorpusKit.remove(sourceID:)` removes a source from recall
    /// (invertedIndex, vectorStore, removedSourceStore) but leaves the verbatim
    /// chunk text rows in SQLite. `scrubText` performs the actual erasure —
    /// UPDATE `chunks` SET `text` = "" WHERE `source_id` = sourceID.
    ///
    /// Called by `CorpusKit.expunge(sourceID:)` as part of the two-phase
    /// expunge flow: scrub first, then remove. Callers that only want to
    /// suppress recall without erasing content continue to use `remove`.
    ///
    /// The update bypasses the `HashingRowStore` wrapper intentionally — the
    /// content_hash column is left stale after scrubbing (the hash no longer
    /// matches the empty text). This is acceptable: the row is being destroyed;
    /// the Merkle chain accuracy of a destroyed corpus is not a requirement.
    ///
    /// - Parameter sourceID: the source to scrub.
    /// - Returns: the number of chunk rows whose text was zeroed.
    @discardableResult
    public func scrubText(sourceID: String) async throws -> Int {
        try await storage.rowStore.update(
            table: "chunks",
            values: ["text": .text("")],
            where: .eq(Column(table: "chunks", name: "source_id"), .text(sourceID))
        )
    }

    // MARK: - Per-corpus Merkle root (NT-C1 Part 3)

    /// Recompute the Merkle root for one corpus (source_id) from
    /// the content_hashes of its chunks. Stores the result in the
    /// `corpus_metadata` table via upsert.
    ///
    /// For chunks without a stored content_hash (pre-v3 data), a
    /// leaf hash is computed on-demand from the chunk text. The
    /// rollup is called after every insert batch for each affected
    /// source_id, mirroring LocusKit's room-level rollup pattern.
    func rollupCorpusMerkleRoot(sourceID: String) async throws {
        let rows = try await storage.rowStore.query(
            table: "chunks",
            where: .eq(Column(table: "chunks", name: "source_id"), .text(sourceID)),
            orderBy: [],
            limit: nil,
            offset: nil
        )

        var childHashes: [(UUID, ContentHash)] = []
        for row in rows {
            guard let chunkId = Self.decodeRowUUID(row["id"]) else { continue }
            let contentHash: ContentHash

            if case .blob(let data) = row["content_hash"], data.count == 32 {
                contentHash = ContentHash(bytes: Array(data))
            } else {
                // No stored hash (pre-v3 row) — compute on-demand.
                let text: String
                if case .text(let t) = row["text"] ?? .null {
                    text = t
                } else {
                    text = ""
                }
                contentHash = MerkleHash.leaf(
                    drawerId: chunkId,
                    content: Array(text.utf8),
                    vectors: []
                )
            }
            childHashes.append((chunkId, contentHash))
        }

        let root = MerkleHash.interior(childHashes: childHashes)
        _ = try await storage.rowStore.upsert(
            table: "corpus_metadata",
            values: [
                "source_id": .text(sourceID),
                "merkle_root": .blob(Data(root.bytes))
            ],
            conflictColumns: ["source_id"]
        )
    }

    /// Returns the current per-corpus Merkle root for the given source.
    /// Returns `MerkleRoot.empty` if the corpus has no metadata row yet.
    public func corpusMerkleRoot(for sourceID: String) async throws -> MerkleRoot {
        let rows = try await storage.rowStore.query(
            table: "corpus_metadata",
            where: .eq(Column(table: "corpus_metadata", name: "source_id"), .text(sourceID)),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first,
              case .blob(let data) = row["merkle_root"],
              data.count == 32 else {
            return MerkleRoot.empty
        }
        return MerkleRoot(bytes: Array(data))
    }

    /// Returns the estate-level corpus Merkle root — the interior hash
    /// over all per-corpus roots. Returns `MerkleRoot.empty` when no
    /// corpora exist.
    public func globalCorpusMerkleRoot() async throws -> MerkleRoot {
        let rows = try await storage.rowStore.query(
            table: "corpus_metadata",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil
        )
        var childHashes: [(UUID, ContentHash)] = []
        for row in rows {
            guard case .text(let sourceID) = row["source_id"] ?? .null else { continue }
            let corpusId = Self.corpusUUID(for: sourceID)
            let rootBytes: [UInt8]
            if case .blob(let data) = row["merkle_root"], data.count == 32 {
                rootBytes = Array(data)
            } else {
                rootBytes = MerkleRoot.empty.bytes
            }
            childHashes.append((corpusId, ContentHash(bytes: rootBytes)))
        }
        return MerkleHash.interior(childHashes: childHashes)
    }

    // MARK: - Upgrade backfill

    /// Recompute Merkle roots for all existing corpora.
    ///
    /// Called on every `Corpus.init` after schema migration to backfill any
    /// existing chunks that were inserted before the `corpus_metadata` table
    /// was introduced (schema v3). Without this call, `globalCorpusMerkleRoot`
    /// returns `MerkleRoot.empty` for any estate that was upgraded from v2,
    /// even though chunks exist (WS2-F3).
    ///
    /// The operation is idempotent: if `corpus_metadata` rows already exist,
    /// re-rolling the hash is a harmless upsert. For large corpora this adds
    /// a one-time startup cost; for typical estates (tens of thousands of
    /// chunks) the cost is sub-second and not repeated after the first run.
    func recomputeAllCorpusMerkleRoots() async throws {
        // Collect all distinct source_ids from the chunks table. This includes
        // sources that may not yet have a corpus_metadata row (pre-v3 estates).
        let sourceIDs = try await allSourceIDs()
        for sourceID in sourceIDs {
            // rollupCorpusMerkleRoot is idempotent: upsert on conflict.
            try await rollupCorpusMerkleRoot(sourceID: sourceID)
        }
    }

    // MARK: - Decode

    static func decodeChunk(_ row: StorageRow) -> Chunk? {
        // Decode against the PRIMITIVE TypedValue forms the SQLite backend hands
        // back on read, not the semantic insert-side forms. SQLite has no native
        // UUID/HLC types, so a UUID column round-trips as `.text` and an HLC
        // column (a packed UInt64) round-trips as `.int` — while the InMemory
        // backend preserves the inserted `.uuid`/`.hlc`. Decoding only the
        // semantic forms silently dropped EVERY persisted chunk on reopen:
        // `allChunks()` returned empty, `Corpus.init`'s BM25 rebuild indexed
        // nothing, and semantic recall went dark on any restored estate (a fresh
        // process serving a persisted estate fell back to query-blind locus
        // recall). Mirrors LocusKit.DrawerStore's primitive-tolerant readers.
        // This is why InMemory-backed tests never caught it.
        guard let id = decodeRowUUID(row["id"]),
              case let .text(sourceID) = row["source_id"] ?? .null,
              case let .int(startOffset) = row["start_offset"] ?? .null,
              case let .int(length) = row["length"] ?? .null,
              case let .text(text) = row["text"] ?? .null,
              let hlc = decodeRowHLC(row["hlc"]) else {
            return nil
        }
        // metadata is a JSON column: `.json` on the InMemory backend, `.blob`
        // (the raw JSON bytes) on the SQLite backend. Accept both; absent or
        // unparseable metadata is an empty map, never a decode failure.
        var metadata: [String: String] = [:]
        switch row["metadata"] ?? .null {
        case let .json(data), let .blob(data):
            metadata = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        default:
            break
        }
        return Chunk(
            id: id,
            sourceID: sourceID,
            startOffset: Int(startOffset),
            length: Int(length),
            text: text,
            hlc: hlc,
            metadata: metadata
        )
    }

    /// Decodes a UUID from a row column that may arrive as either `.uuid` (the
    /// InMemory backend preserves the inserted TypedValue) or `.text` (the
    /// SQLite backend, where a UUID column is physically TEXT and round-trips as
    /// a string). Returns nil for any other case or an unparseable string.
    static func decodeRowUUID(_ value: TypedValue?) -> UUID? {
        switch value ?? .null {
        case let .uuid(u): return u
        case let .text(s): return UUID(uuidString: s)
        default: return nil
        }
    }

    /// Decodes an HLC from a row column that may arrive as either `.hlc` (the
    /// InMemory backend preserves the inserted TypedValue) or `.int` (the SQLite
    /// backend, where an HLC column stores the packed UInt64 as INTEGER and
    /// round-trips as a signed `.int`). The packed form is reconstructed via the
    /// bit pattern so it survives the signed/unsigned round trip losslessly.
    static func decodeRowHLC(_ value: TypedValue?) -> HLC? {
        switch value ?? .null {
        case let .hlc(h): return h
        case let .int(i): return HLC(packed: UInt64(bitPattern: i))
        default: return nil
        }
    }
}
