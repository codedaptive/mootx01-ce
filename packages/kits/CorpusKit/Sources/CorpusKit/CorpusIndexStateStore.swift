// CorpusIndexStateStore.swift
//
// The revision/digest/cursor checkpoint lane (GLK shared-content 1.1, P1).
//
// `corpus_index_state` records, per canonical content ID, which
// (revision, digest, indexVersion) the derived indexes currently reflect
// and the last applied source cursor. It carries NO text. It is derived,
// rebuildable state — present in BOTH schema profiles (standalone and
// attached), and the idempotence anchor of the indexing contract: an
// upsert is idempotent on (id, revision, digest, indexVersion); a worker
// that observes a mismatch between its job and the CURRENT record rejects
// the job WITHOUT advancing this checkpoint.
//
// v2 (bitmap adoption): adds `operational_bitmap BITMAP NOT NULL DEFAULT 0`
// for the per-row state cache (removed, has_dense_text, lexically_indexed,
// coverage_mask, basis_generation). Also creates the `corpus_bitmap_generation`
// singleton table for the global basis-generation counter. See
// CorpusIndexStateOperational.swift and CorpusKit/docs/BITMAP_LAYOUT.md for
// the full bit layout and registry.
//
// Rust twin: `rust/src/index_state_store.rs`.

import Foundation
import PersistenceKit

/// One checkpoint row.
public struct CorpusIndexState: Sendable, Equatable {
    public let contentID: CorpusContentID
    /// The content revision the derived rows currently reflect.
    public let revision: Int64
    /// The content digest the derived rows currently reflect.
    public let digest: String
    /// The engine/index layout version the rows were produced under.
    public let indexVersion: Int64
    /// The last applied source cursor, when the write came from draining a
    /// change feed; nil for direct (non-feed) indexing.
    public let appliedCursor: String?
    public let updatedAt: Date
    /// Per-row state cache bitmap (see CorpusIndexStateOperational.swift).
    /// Default 0 — no lifecycle bits, no coverage, no generation.
    /// The engine is responsible for setting all bits; the store only
    /// persists and retrieves the value the engine supplies.
    public let operationalBitmap: Int64

    public init(
        contentID: CorpusContentID, revision: Int64, digest: String,
        indexVersion: Int64, appliedCursor: String?, updatedAt: Date,
        operationalBitmap: Int64 = 0
    ) {
        self.contentID = contentID
        self.revision = revision
        self.digest = digest
        self.indexVersion = indexVersion
        self.appliedCursor = appliedCursor
        self.updatedAt = updatedAt
        self.operationalBitmap = operationalBitmap
    }
}

/// Durable store over `corpus_index_state` and the `corpus_bitmap_generation`
/// singleton (the global basis-generation counter for coverage invalidation).
public actor CorpusIndexStateStore {

    /// Checkpoint schema — v2 adds `operational_bitmap` and the
    /// `corpus_bitmap_generation` singleton.
    ///
    /// Version history:
    ///   v1 — Initial layout: (content_id, revision, digest, index_version,
    ///        applied_cursor, updated_at) + PK on content_id.
    ///   v2 — Bitmap adoption: adds `operational_bitmap BITMAP NOT NULL DEFAULT 0`
    ///        to corpus_index_state; creates corpus_bitmap_generation singleton
    ///        for the global basis-generation counter.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitIndexState",
        version: 2,
        tables: [
            TableDeclaration(
                name: "corpus_index_state",
                columns: [
                    .text("content_id", nullable: false),
                    .int("revision", nullable: false),
                    .text("digest", nullable: false),
                    .int("index_version", nullable: false),
                    .text("applied_cursor", nullable: true),
                    .timestamp("updated_at", nullable: false),
                    // Operational bitmap: per-row state cache. Layout in
                    // CorpusIndexStateOperational.swift. Default 0 = no bits set.
                    // The engine sets bits at write time; the store stores them.
                    .bitmap("operational_bitmap", default: 0)
                ],
                primaryKey: ["content_id"]
            ),
            // Singleton table for the global basis-generation counter (4-bit
            // field, values 0–15). One row with singleton_id=1. Created in
            // v2 migration alongside the operational_bitmap column.
            TableDeclaration(
                name: "corpus_bitmap_generation",
                columns: [
                    // Singleton sentinel — always 1.
                    .int("singleton_id", nullable: false),
                    // Global counter; incremented each basis retrain. Wraps at
                    // 16 (4-bit field in the content rows); a full-sweep clears
                    // all coverage bits on wraparound.
                    ColumnDeclaration(
                        name: "basis_generation",
                        type: .int, nullable: false,
                        defaultValue: .int(0))
                ],
                primaryKey: ["singleton_id"]
            )
        ],
        migrations: [
            // v1 → v2: add operational_bitmap column; create generation singleton table.
            Migration(fromVersion: 1, toVersion: 2, operations: [
                .addColumn(
                    table: "corpus_index_state",
                    column: .bitmap("operational_bitmap", default: 0)),
                .createTable(
                    TableDeclaration(
                        name: "corpus_bitmap_generation",
                        columns: [
                            .int("singleton_id", nullable: false),
                            ColumnDeclaration(
                                name: "basis_generation",
                                type: .int, nullable: false,
                                defaultValue: .int(0))
                        ],
                        primaryKey: ["singleton_id"]))
            ])
        ]
    )

    private let storage: any Storage

    public init(storage: any Storage) {
        self.storage = storage
    }

    // MARK: - Checkpoint writes

    /// Upsert the checkpoint for one content ID. Idempotent — writing the
    /// same (revision, digest, indexVersion) again is harmless.
    /// The engine supplies the complete `operationalBitmap` value;
    /// the store stores it verbatim.
    public func advance(_ state: CorpusIndexState) async throws {
        try await advance(state, into: storage.rowStore)
    }

    /// Transaction-scoped checkpoint write. Queue batches use this to commit
    /// maintained provider counts and every corresponding content/cursor
    /// checkpoint as one last-write transaction.
    public func advance(_ state: CorpusIndexState, into rowStore: any RowStore) async throws {
        _ = try await rowStore.upsert(
            table: "corpus_index_state",
            values: [
                "content_id": .text(state.contentID),
                "revision": .int(state.revision),
                "digest": .text(state.digest),
                "index_version": .int(state.indexVersion),
                "applied_cursor": state.appliedCursor.map { TypedValue.text($0) } ?? .null,
                "updated_at": .timestamp(state.updatedAt),
                "operational_bitmap": .bitmap(state.operationalBitmap)
            ],
            conflictColumns: ["content_id"])
    }

    // MARK: - Soft-remove path

    /// Soft-delete a content row: set `removed=1` and clear all other
    /// lifecycle/coverage bits. The row is RETAINED as a tombstone so
    /// the active-content filter (`isLexicallyIndexed && !isRemoved`)
    /// can distinguish removed from never-indexed rows. No-op when the
    /// row does not exist.
    ///
    /// Call sites: `CorpusContentEngine.clearDerivedState(id:)`.
    public func softRemove(contentID: CorpusContentID, now: Date) async throws {
        guard let existing = try await state(for: contentID) else { return }
        _ = try await storage.rowStore.upsert(
            table: "corpus_index_state",
            values: [
                "content_id": .text(contentID),
                // Reset revision/digest so the idempotence gate fires on re-ingest.
                "revision": .int(0),
                "digest": .text(""),
                "index_version": .int(0),
                "applied_cursor": existing.appliedCursor.map { TypedValue.text($0) } ?? .null,
                "updated_at": .timestamp(now),
                // removed=1; all other bits cleared (no lexical, no coverage, no generation).
                "operational_bitmap": .bitmap(softRemovedBitmap())
            ],
            conflictColumns: ["content_id"])
    }

    // MARK: - Bitmap update (coverage bits)

    /// Update only the `operational_bitmap` for an existing row.
    /// Used by coverage write paths to stamp coverage bits and
    /// generation without touching other checkpoint fields.
    /// No-op when the row does not exist.
    public func updateBitmap(contentID: CorpusContentID, bitmap: Int64) async throws {
        _ = try await storage.rowStore.update(
            table: "corpus_index_state",
            values: ["operational_bitmap": .bitmap(bitmap)],
            where: .eq(Column(table: "corpus_index_state", name: "content_id"),
                       .text(contentID)))
    }

    /// Transaction-scoped bitmap update.
    public func updateBitmap(
        contentID: CorpusContentID, bitmap: Int64, into rowStore: any RowStore
    ) async throws {
        _ = try await rowStore.update(
            table: "corpus_index_state",
            values: ["operational_bitmap": .bitmap(bitmap)],
            where: .eq(Column(table: "corpus_index_state", name: "content_id"),
                       .text(contentID)))
    }

    // MARK: - Queries

    /// The checkpoint for one content ID, or nil when never indexed.
    public func state(for contentID: CorpusContentID) async throws -> CorpusIndexState? {
        let rows = try await storage.rowStore.query(
            table: "corpus_index_state",
            where: .eq(Column(table: "corpus_index_state", name: "content_id"), .text(contentID)),
            orderBy: [], limit: 1, offset: nil)
        guard let row = rows.first else { return nil }
        return Self.decode(contentID: contentID, row: row)
    }

    /// Every checkpointed state row, ascending by content ID.
    /// The reconciliation set migration verification compares against the canonical ID set.
    public func allStates() async throws -> [CorpusIndexState] {
        let rows = try await storage.rowStore.query(
            table: "corpus_index_state", where: nil, orderBy: [], limit: nil, offset: nil)
        return rows.compactMap { row -> CorpusIndexState? in
            guard case let .text(contentID)? = row["content_id"] else { return nil }
            return Self.decode(contentID: contentID, row: row)
        }.sorted { $0.contentID < $1.contentID }
    }

    /// Every state row where `isLexicallyIndexed == true` and
    /// `isRemoved == false`, excluding the feedCursorRowID sentinel.
    /// This is the active-content set used by backfill and batch-train paths.
    public func activeIndexedStates() async throws -> [CorpusIndexState] {
        try await allStates().filter {
            $0.isLexicallyIndexed && !$0.isRemoved
        }
    }

    // MARK: - Deletions (hard expunge only — normal remove path is softRemove)

    /// Hard-delete one content ID's checkpoint (expunge path only).
    /// The standard remove path is `softRemove(contentID:now:)`.
    public func clear(contentID: CorpusContentID) async throws {
        _ = try await storage.rowStore.delete(
            table: "corpus_index_state",
            where: .eq(Column(table: "corpus_index_state", name: "content_id"), .text(contentID)))
    }

    /// Hard-delete every checkpoint (index rebuild from scratch).
    public func clearAll() async throws {
        _ = try await storage.rowStore.delete(
            table: "corpus_index_state", where: .isTrue)
    }

    // MARK: - Global basis-generation counter

    /// Read the current global basis-generation value (0–15).
    /// Returns 0 when the singleton row does not exist yet (first open
    /// before any retrain).
    public func basisGeneration() async throws -> Int64 {
        let rows = try await storage.rowStore.query(
            table: "corpus_bitmap_generation",
            where: .eq(Column(table: "corpus_bitmap_generation", name: "singleton_id"), .int(1)),
            orderBy: [], limit: 1, offset: nil)
        guard let row = rows.first, case let .int(gen)? = row["basis_generation"] else {
            return 0
        }
        return gen
    }

    /// Increment the global basis-generation counter, wrapping at 16.
    /// Returns the NEW generation value. Called by the engine after each
    /// basis retrain. When the counter wraps to 0 (generation reaches 15
    /// then rolls over), ALL content rows' coverage bits become stale by
    /// generation mismatch — the engine triggers the wraparound full-sweep.
    @discardableResult
    public func incrementBasisGeneration() async throws -> Int64 {
        let current = try await basisGeneration()
        let next = (current + 1) % indexGenerationModulus
        _ = try await storage.rowStore.upsert(
            table: "corpus_bitmap_generation",
            values: [
                "singleton_id": .int(1),
                "basis_generation": .int(next)
            ],
            conflictColumns: ["singleton_id"])
        return next
    }

    /// Reset the global basis-generation counter to 0 and clear all
    /// coverage bits and generation stamps from every content row.
    ///
    /// This is the wraparound "full sweep" invoked when the counter wraps
    /// from 15 back to 0 (see BITMAP_LAYOUT.md §Wraparound). The sweep is
    /// O(n) in the row count but is expected to be rare (once every 16
    /// basis retrains). After the sweep, the first backfill pass re-stamps
    /// coverage + generation for each row under the new generation=0 counter.
    public func resetGenerationSweep() async throws {
        // Reset the singleton counter to 0.
        _ = try await storage.rowStore.upsert(
            table: "corpus_bitmap_generation",
            values: ["singleton_id": .int(1), "basis_generation": .int(0)],
            conflictColumns: ["singleton_id"])
        // Clear coverage_mask (bits 4–11) and basis_generation (bits 12–15) from
        // every content row. O(n) scan; rare in practice.
        let all = try await allStates()
        for state in all {
            let cleared = state.clearingCoverageAndGeneration()
            guard cleared != state.operationalBitmap else { continue }
            _ = try await storage.rowStore.update(
                table: "corpus_index_state",
                values: ["operational_bitmap": .bitmap(cleared)],
                where: .eq(Column(table: "corpus_index_state", name: "content_id"),
                           .text(state.contentID)))
        }
    }

    // MARK: - Decoding

    private static func decode(contentID: String, row: StorageRow) -> CorpusIndexState? {
        guard case let .int(revision)? = row["revision"],
              case let .text(digest)? = row["digest"],
              case let .int(indexVersion)? = row["index_version"] else { return nil }
        let appliedCursor: String?
        if case let .text(cursor)? = row["applied_cursor"] {
            appliedCursor = cursor
        } else {
            appliedCursor = nil
        }
        guard let updatedAt = decodeDate(row["updated_at"]) else { return nil }
        // operational_bitmap: decode the bitmap column; tolerate absence for
        // rows migrated before the DEFAULT is applied in InMemory backends
        // (SQLite always provides the column DEFAULT after migration).
        let operationalBitmap: Int64
        switch row["operational_bitmap"] {
        case let .bitmap(bm)?:
            operationalBitmap = bm
        case let .int(bm)?:
            // Defensive: InMemory test backends may surface the column as .int
            // when DEFAULT 0 was applied via the schema migration path.
            operationalBitmap = bm
        default:
            operationalBitmap = 0
        }
        return CorpusIndexState(
            contentID: contentID, revision: revision, digest: digest,
            indexVersion: indexVersion, appliedCursor: appliedCursor, updatedAt: updatedAt,
            operationalBitmap: operationalBitmap)
    }

    /// Decode a TIMESTAMP column tolerant of `.timestamp` (InMemory) and
    /// `.text` ISO8601 (SQLite, where TIMESTAMP is physically TEXT) — the
    /// same primitive-tolerance discipline used in `BasisStore.decodeDate`.
    private static func decodeDate(_ value: TypedValue?) -> Date? {
        switch value ?? .null {
        case let .timestamp(d):
            return d
        case let .text(s):
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
        default:
            return nil
        }
    }
}
