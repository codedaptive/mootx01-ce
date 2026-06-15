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
//     created_at   TIMESTAMP NOT NULL
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
// behaviour is unchanged. When monitoring is disabled (the default),
// the Intellectus.report(_:) call short-circuits after a single
// Atomic<Bool> load.

import Foundation
import IntellectusLib
import SubstrateTypes
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

public actor BundleStore {

    let storage: any Storage

    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKit",
        version: 1,
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
                    .timestamp("created_at", nullable: false)
                ],
                primaryKey: ["id"],
                appendOnly: true
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

    public init(storage: any Storage) {
        self.storage = storage
    }

    /// Insert a batch of chunks. Idempotent on primary key:
    /// re-inserting a chunk with the same id is a no-op.
    ///
    /// The table is append-only, so the idempotent path is a plain
    /// insert that tolerates a duplicate-key rejection rather than an
    /// upsert. An upsert with a non-empty update set compiles to
    /// `INSERT ... ON CONFLICT DO UPDATE`, whose UPDATE branch the
    /// append-only trigger aborts; a plain insert hits the primary-key
    /// constraint instead and surfaces StorageError.duplicateKey,
    /// which is caught here and treated as the documented no-op. The
    /// first write of a given id wins; a later insert of the same id
    /// is dropped, which is correct because chunks are immutable and
    /// content-addressed.
    ///
    /// Telemetry: emits `corpuskit.ingest.latency_ms` (wall time for the
    /// full batch insert) and `corpuskit.ingest.chunk_count` (number of
    /// chunks in the batch, including idempotent no-ops) when monitoring is
    /// enabled. Both are emitted at the operation boundary — after the last
    /// insert attempt completes — so they cannot affect the stored values or
    /// any thrown error. Off-path: single Atomic<Bool> load per call.
    public func insert(_ chunks: [Chunk]) async throws {
        guard !chunks.isEmpty else { return }

        // Capture start time before the I/O. One Date() read per
        // call; the computed latency is forwarded to the sink only when
        // monitoring is enabled (inside the @autoclosure guard).
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
            do {
                _ = try await storage.rowStore.insert(
                    table: "chunks",
                    values: values
                )
            } catch StorageError.duplicateKey {
                // Idempotent no-op: the chunk is already stored. Chunks
                // are immutable, so there is nothing to reconcile.
                continue
            }
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
    }

    public func get(id: UUID) async throws -> Chunk? {
        let rows = try await storage.rowStore.query(
            table: "chunks",
            where: .eq(Column(table: "chunks", name: "id"), .uuid(id)),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first else { return nil }
        return Self.decodeChunk(row)
    }

    public func getMany(ids: [UUID]) async throws -> [Chunk] {
        guard !ids.isEmpty else { return [] }
        let values = ids.map { TypedValue.uuid($0) }
        let rows = try await storage.rowStore.query(
            table: "chunks",
            where: .in(Column(table: "chunks", name: "id"), values),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        return rows.compactMap(Self.decodeChunk)
    }

    public func chunksForSource(_ sourceID: String) async throws -> [Chunk] {
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
            offset: nil
        )
        return rows.compactMap(Self.decodeChunk)
    }

    public func count() async throws -> Int {
        try await storage.rowStore.count(table: "chunks", where: nil)
    }

    public func allChunks() async throws -> [Chunk] {
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
            offset: nil
        )
        return rows.compactMap(Self.decodeChunk)
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
