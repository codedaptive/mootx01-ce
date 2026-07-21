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

    public init(
        contentID: CorpusContentID, revision: Int64, digest: String,
        indexVersion: Int64, appliedCursor: String?, updatedAt: Date
    ) {
        self.contentID = contentID
        self.revision = revision
        self.digest = digest
        self.indexVersion = indexVersion
        self.appliedCursor = appliedCursor
        self.updatedAt = updatedAt
    }
}

/// Durable store over `corpus_index_state`.
public actor CorpusIndexStateStore {

    /// Additive checkpoint schema — separate kit ID like the other sidecar
    /// stores; included in both profiles by `CorpusSchemaProfile`.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitIndexState",
        version: 1,
        tables: [
            TableDeclaration(
                name: "corpus_index_state",
                columns: [
                    .text("content_id", nullable: false),
                    .int("revision", nullable: false),
                    .text("digest", nullable: false),
                    .int("index_version", nullable: false),
                    .text("applied_cursor", nullable: true),
                    .timestamp("updated_at", nullable: false)
                ],
                primaryKey: ["content_id"]
            )
        ]
    )

    private let storage: any Storage

    public init(storage: any Storage) {
        self.storage = storage
    }

    /// Upsert the checkpoint for one content ID. Idempotent — writing the
    /// same (revision, digest, indexVersion) again is harmless.
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
                "updated_at": .timestamp(state.updatedAt)
            ],
            conflictColumns: ["content_id"])
    }

    /// The checkpoint for one content ID, or nil when never indexed.
    public func state(for contentID: CorpusContentID) async throws -> CorpusIndexState? {
        let rows = try await storage.rowStore.query(
            table: "corpus_index_state",
            where: .eq(Column(table: "corpus_index_state", name: "content_id"), .text(contentID)),
            orderBy: [], limit: 1, offset: nil)
        guard let row = rows.first else { return nil }
        return Self.decode(contentID: contentID, row: row)
    }

    /// Every checkpointed content ID, ascending — the reconciliation set
    /// migration verification compares against the canonical ID set.
    public func allStates() async throws -> [CorpusIndexState] {
        let rows = try await storage.rowStore.query(
            table: "corpus_index_state", where: nil, orderBy: [], limit: nil, offset: nil)
        return rows.compactMap { row -> CorpusIndexState? in
            guard case let .text(contentID)? = row["content_id"] else { return nil }
            return Self.decode(contentID: contentID, row: row)
        }.sorted { $0.contentID < $1.contentID }
    }

    /// Clear one content ID's checkpoint (the remove path: a remove clears
    /// the ID's derived state and records the applied source cursor at the
    /// caller's level).
    public func clear(contentID: CorpusContentID) async throws {
        _ = try await storage.rowStore.delete(
            table: "corpus_index_state",
            where: .eq(Column(table: "corpus_index_state", name: "content_id"), .text(contentID)))
    }

    /// Clear every checkpoint (index rebuild from scratch).
    public func clearAll() async throws {
        _ = try await storage.rowStore.delete(
            table: "corpus_index_state",
            where: .like(Column(table: "corpus_index_state", name: "content_id"), "%"))
    }

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
        return CorpusIndexState(
            contentID: contentID, revision: revision, digest: digest,
            indexVersion: indexVersion, appliedCursor: appliedCursor, updatedAt: updatedAt)
    }

    /// Decode a TIMESTAMP column tolerant of `.timestamp` (InMemory) and
    /// `.text` ISO8601 (SQLite, where TIMESTAMP is physically TEXT) — the
    /// same primitive-tolerance discipline as `BasisStore.decodeDate`.
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
