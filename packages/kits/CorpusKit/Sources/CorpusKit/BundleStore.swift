// BundleStore.swift
//
// Storage for RAG chunks (the "content half" of a content-plus-
// vector bundle). The vector half lives in VectorKit's vectors
// table; the bundle store maintains the chunks table and the
// join via (chunk.id == vector.drawerID) by convention.
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

import Foundation
import PersistenceKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

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
    public func insert(_ chunks: [Chunk]) async throws {
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
        guard case let .uuid(id) = row["id"] ?? .null,
              case let .text(sourceID) = row["source_id"] ?? .null,
              case let .int(startOffset) = row["start_offset"] ?? .null,
              case let .int(length) = row["length"] ?? .null,
              case let .text(text) = row["text"] ?? .null,
              case let .hlc(hlc) = row["hlc"] ?? .null else {
            return nil
        }
        var metadata: [String: String] = [:]
        if case let .json(data) = row["metadata"] ?? .null {
            metadata = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
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
}
