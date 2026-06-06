// VectorStore.swift
//
// Storage layer for VectorKit, backed by PersistenceKit. One row per
// (drawerID, modelID) pair in the "vectors" table; the row's
// stable id is preserved across upserts on the same pair.
//
// Refactored 2026-05-19 (mission 6) per
// DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md section 4.6: replaced
// direct SQLite I/O with PersistenceKit's RowStore + VectorIndex
// protocols. Backends (SQLite + sqlite-vec, PostgreSQL + pgvector,
// InMemory) are selected at the application layer via
// EstateConfiguration.
//
// VECTORKIT_REPORT_001 (2026-06-06): added IntellectusLib self-report
// telemetry to addVector, findNearest, and findByKeyword. The emit calls
// are placed at operation boundaries, after the result is computed, so
// the mathematical behavior is unchanged. When monitoring is disabled
// (the default), the Intellectus.report(_:) call short-circuits after
// a single Atomic<Bool> load; the startTime clock read is the only
// unconditional overhead added per operation.

import EngramLib
import Foundation
import IntellectusLib
import OSLog
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

/// Storage for model-tagged vectors. Wraps a PersistenceKit Storage
/// instance; the kit does not see backend selection.
///
/// Concurrency: VectorStore is an actor. RowStore calls are async;
/// the public API mirrors PersistenceKit's async surface.
///
/// Schema declaration (provided to Storage.open):
/// ```
/// vectors (
///   id            UUID PRIMARY KEY,
///   drawer_id     TEXT NOT NULL,
///   model_id      TEXT NOT NULL,
///   model_version TEXT NOT NULL,
///   engram        BLOB NOT NULL,   -- 32 bytes (4 x UInt64 LE)
///   filed_at      TIMESTAMP NOT NULL
/// )
/// ```
/// UNIQUE constraint on (drawer_id, model_id) per spec I-4: one
/// vector per drawer per model.
///
/// Telemetry: emits `vectorkit.*` metrics via IntellectusLib when
/// monitoring is enabled. Off by default; the emit call is a
/// short-circuited no-op (single Atomic<Bool> load) when disabled.
public actor VectorStore {

    private let log = Logger(subsystem: "com.mootx01.kit", category: "VectorStore")
    let storage: any Storage

    /// Schema declaration consumed by Storage.open(schema:).
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "VectorKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "vectors",
                columns: [
                    .uuid("id"),
                    .text("drawer_id", nullable: false),
                    .text("model_id", nullable: false),
                    .text("model_version", nullable: false),
                    .blob("engram", nullable: false),
                    .timestamp("filed_at", nullable: false)
                ],
                primaryKey: ["id"],
                uniqueConstraints: [["drawer_id", "model_id"]]
            )
        ],
        indices: [
            IndexDeclaration(
                name: "idx_vectors_drawer",
                table: "vectors",
                columns: ["drawer_id"],
                unique: false
            ),
            IndexDeclaration(
                name: "idx_vectors_model_drawer",
                table: "vectors",
                columns: ["model_id", "drawer_id"],
                unique: false
            )
        ]
    )

    /// Construct against an already-opened Storage.
    /// The caller is responsible for calling
    /// `storage.open(schema: VectorStore.schemaDeclaration)` before
    /// using the store.
    public init(storage: any Storage) {
        self.storage = storage
    }

    /// Upsert a vector. If a row already exists for
    /// (drawerID, modelID), the existing row is updated in place;
    /// otherwise a new row is created.
    ///
    /// Telemetry: emits `vectorkit.index.insert_latency_ms` (wall time
    /// for the upsert round-trip) when monitoring is enabled. The emit
    /// is at the operation boundary — after the upsert completes — so
    /// it never affects the stored value or any error thrown.
    public func addVector(
        drawerID: String,
        engram: Engram,
        modelID: String,
        modelVersion: String,
        filedAt: Date
    ) async throws {
        // Capture start time before the I/O. One Date() read per
        // call; the computed latency is only forwarded to the sink
        // when monitoring is enabled (inside the @autoclosure guard).
        let startTime = Date().timeIntervalSince1970

        let bytes = Data(engram.wireBytes)
        let values: [String: TypedValue] = [
            "id": .uuid(UUID()),
            "drawer_id": .text(drawerID),
            "model_id": .text(modelID),
            "model_version": .text(modelVersion),
            "engram": .blob(bytes),
            "filed_at": .timestamp(filedAt)
        ]
        _ = try await storage.rowStore.upsert(
            table: "vectors",
            values: values,
            conflictColumns: ["drawer_id", "model_id"]
        )

        // Emit insert latency at the operation boundary.
        // The model_id tag identifies which embedding model indexed
        // this vector, so per-model insert cost is queryable.
        // Off-path: single Atomic<Bool> load when monitoring is disabled.
        let endTime = Date().timeIntervalSince1970
        Intellectus.report(.metric(
            name: "vectorkit.index.insert_latency_ms",
            value: (endTime - startTime) * 1000.0,
            tags: ["kit": "VectorKit", "model_id": modelID],
            ts: endTime
        ))
    }

    /// Fetch the engram stored under (drawerID, modelID), or nil
    /// if no row exists.
    public func getVector(
        drawerID: String,
        modelID: String
    ) async throws -> Engram? {
        let predicate = StoragePredicate.and([
            .eq(Column(table: "vectors", name: "drawer_id"), .text(drawerID)),
            .eq(Column(table: "vectors", name: "model_id"), .text(modelID))
        ])
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: predicate,
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first,
              case let .blob(bytes) = row["engram"] ?? .null else {
            return nil
        }
        return try Engram(wireBytes: Array(bytes))
    }

    /// Return every row for drawerID, ordered by filed_at ASC.
    public func vectors(forDrawerID drawerID: String) async throws -> [StoredVector] {
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .eq(Column(table: "vectors", name: "drawer_id"), .text(drawerID)),
            orderBy: [
                OrderClause(
                    column: Column(table: "vectors", name: "filed_at"),
                    direction: .ascending
                )
            ],
            limit: nil,
            offset: nil
        )
        var out: [StoredVector] = []
        for row in rows {
            guard let stored = Self.storedVector(from: row) else { continue }
            out.append(stored)
        }
        return out
    }

    /// k-nearest-neighbours by Hamming distance over the engram bit
    /// representation. Returns up to `limit` matches sorted by distance
    /// ascending, with ties broken by drawerID ascending for
    /// deterministic output.
    ///
    /// Delegates top-K selection to `EngramLib.findNearest`, which
    /// calls `hammingTopK` (O(N log k)). The O(N) row fetch from the
    /// RowStore remains at this layer pending a VectorIndex migration
    /// (sqlite-vec or pgvector) that would push the limit into the
    /// storage backend.
    ///
    /// Telemetry: emits `vectorkit.search.latency_ms` (wall time for
    /// the full scan + top-K) and `vectorkit.search.result_count`
    /// (number of matches returned, up to `limit`) when monitoring is
    /// enabled. Both metrics are emitted at the operation boundary,
    /// after the result is computed; the return value is unchanged.
    public func findNearest(
        probe: Engram,
        modelID: String,
        limit: Int
    ) async throws -> [VectorMatch] {
        // Capture start time before the I/O and sort.
        let startTime = Date().timeIntervalSince1970

        // O(N) row fetch: no vector index at this layer. A future mission wires
        // sqlite-vec (SQLite) or pgvector (PostgreSQL) to push the limit into
        // the storage layer and reduce this to O(k).
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .eq(Column(table: "vectors", name: "model_id"), .text(modelID)),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        let stored = rows.compactMap { Self.storedVector(from: $0) }
        let matches = EngramLib.findNearest(
            probe: probe,
            in: stored.map(\.engram),
            k: limit
        )
        // Map Match.index back to stored[index] for drawerID and modelID.
        // Apply drawerID tie-break for determinism parity with the prior implementation.
        let result = matches
            .map { m in
                VectorMatch(drawerID: stored[m.index].drawerID,
                            distance: m.distance,
                            modelID: stored[m.index].modelID)
            }
            .sorted {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                return $0.drawerID < $1.drawerID
            }

        // Emit search metrics at the operation boundary, after the result is
        // computed. The autoclosure is evaluated only when monitoring is enabled.
        // latency_ms covers the full operation (row fetch + Hamming top-K + sort).
        // result_count is the final result set size (≤ limit).
        let endTime = Date().timeIntervalSince1970
        let resultCount = result.count
        Intellectus.report(.metric(
            name: "vectorkit.search.latency_ms",
            value: (endTime - startTime) * 1000.0,
            tags: ["kit": "VectorKit", "model_id": modelID],
            ts: endTime
        ))
        Intellectus.report(.metric(
            name: "vectorkit.search.result_count",
            value: Double(resultCount),
            tags: ["kit": "VectorKit", "model_id": modelID],
            ts: endTime
        ))

        return result
    }

    /// Keyword pre-filter: returns drawer IDs whose drawer_id
    /// contains the query as a substring. Matches the v0 FTS5
    /// behavior at a coarser granularity (substring rather than
    /// tokenized BM25). Full BM25 keyword scoring is CorpusKit's
    /// responsibility per the kit graph; VectorKit retains this
    /// surface for hybrid-retrieval callers that need a quick
    /// keyword pass against drawer identifiers.
    ///
    /// Telemetry: emits `vectorkit.search.keyword_result_count`
    /// (number of distinct drawer IDs returned) when monitoring is
    /// enabled. Emitted at the operation boundary, after deduplication.
    public func findByKeyword(_ query: String, limit: Int) async throws -> [String] {
        let rows = try await storage.rowStore.query(
            table: "vectors",
            where: .like(Column(table: "vectors", name: "drawer_id"), "%\(query)%"),
            orderBy: [
                OrderClause(
                    column: Column(table: "vectors", name: "drawer_id"),
                    direction: .ascending
                )
            ],
            limit: limit,
            offset: nil
        )
        var seen = Set<String>()
        var out: [String] = []
        for row in rows {
            if case let .text(drawerID) = row["drawer_id"] ?? .null {
                if seen.insert(drawerID).inserted {
                    out.append(drawerID)
                }
            }
        }

        // Emit keyword search result count at the operation boundary.
        // Off-path: single Atomic<Bool> load when monitoring is disabled.
        let count = out.count
        Intellectus.report(.metric(
            name: "vectorkit.search.keyword_result_count",
            value: Double(count),
            tags: ["kit": "VectorKit"],
            ts: Date().timeIntervalSince1970
        ))

        return out
    }

    /// Delete the row at (drawerID, modelID). No-op if not present.
    public func deleteVector(drawerID: String, modelID: String) async throws {
        _ = try await storage.rowStore.delete(
            table: "vectors",
            where: .and([
                .eq(Column(table: "vectors", name: "drawer_id"), .text(drawerID)),
                .eq(Column(table: "vectors", name: "model_id"), .text(modelID))
            ])
        )
    }

    // MARK: - Lifecycle (GLK_PROVISION_001)

    /// Destroy all vector rows in this store.
    ///
    /// Deletes every row from the `vectors` table. Called by
    /// `GeniusLocusKit.destroy(storage:corpusStorage:handle:)` as part of the
    /// coordinated estate teardown path. After this call the backing storage
    /// still exists (schema intact) but contains no vector data.
    ///
    /// The caller (GLK) is responsible for closing the estate through LocusKit
    /// before calling this method. This method does not close or remove the
    /// backing storage file — that is the caller's responsibility.
    ///
    /// Marked `public` so GLK can reach it; not exposed on the ARIA surface
    /// (no ARIA verb maps to raw store destruction — that is an admin-plane
    /// operation gated through GLK's destroy verb).
    public func destroyAllVectors() async throws {
        // Delete every row from the vectors table. Storage.rowStore.delete
        // with an always-true predicate (id is never null) clears all rows.
        _ = try await storage.rowStore.delete(
            table: "vectors",
            // Use a predicate that matches every row: rows whose id is not
            // the empty string (ids are UUID strings, always non-empty).
            where: .like(Column(table: "vectors", name: "id"), "%")
        )
        log.info("VectorStore.destroyAllVectors: all rows deleted")
    }

    // MARK: - Row decode helper

    static func storedVector(from row: StorageRow) -> StoredVector? {
        guard case let .uuid(id) = row["id"] ?? .null,
              case let .text(drawerID) = row["drawer_id"] ?? .null,
              case let .text(modelID) = row["model_id"] ?? .null,
              case let .text(modelVersion) = row["model_version"] ?? .null,
              case let .blob(bytes) = row["engram"] ?? .null,
              case let .timestamp(filedAt) = row["filed_at"] ?? .null else {
            return nil
        }
        guard let engram = try? Engram(wireBytes: Array(bytes)) else {
            return nil
        }
        return StoredVector(
            id: id.uuidString,
            drawerID: drawerID,
            modelID: modelID,
            modelVersion: modelVersion,
            engram: engram,
            filedAt: filedAt
        )
    }
}
