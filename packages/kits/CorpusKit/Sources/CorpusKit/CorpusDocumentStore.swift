// CorpusDocumentStore.swift
//
// The standalone canonical document store (GLK shared-content 1.1, P1).
//
// In standalone mode CorpusKit is a complete RAG database that OWNS its
// canonical documents. This store realizes `CorpusContentStore` over two
// tables:
//
//   corpus_documents        — one row per canonical document:
//                             (content_id PK, revision, digest, text,
//                              created_at, updated_at). The ONLY place
//                             standalone CorpusKit persists verbatim text.
//   corpus_content_changes  — the durable change journal backing the
//                             cursor contract: (seq PK, content_id,
//                             revision, digest?, kind, changed_at). Rows
//                             carry identity/revision/digest only, never
//                             text. The cursor is the last consumed seq.
//
// Neither table exists in attached mode — the attached profile has no
// canonical content table at all (LocusKit Drawers are canonical, and the
// GLK adapter serves the same `CorpusContentSource` surface from them).
//
// Rust twin: `rust/src/document_store.rs`.

import Foundation
import PersistenceKit

/// Standalone canonical content authority over `corpus_documents`.
public actor CorpusDocumentStore: CorpusContentStore {

    /// Change kinds journaled in `corpus_content_changes.kind`.
    private enum ChangeKind: Int64 {
        case upsert = 0
        case remove = 1
    }

    /// The standalone canonical-content schema. Applied via
    /// `storage.migrate(to:)`; part of the STANDALONE profile only
    /// (`CorpusSchemaProfile.standaloneDeclaration`).
    ///
    /// Version history:
    ///   v1 — Initial layout: (content_id, revision, digest, text,
    ///        created_at, updated_at) + corpus_content_changes journal.
    ///   v2 — Dual-text indexing (MISSION_11X_RECALL_GAP_01 Stream A):
    ///        adds `dense_text TEXT NULL` to corpus_documents. NULL means
    ///        "use the lexical `text` column for dense embedding too" —
    ///        the default for all standalone consumers that do not supply a
    ///        separate dense-composition representation. The migration is
    ///        purely additive; existing rows behave identically (NULL dense
    ///        text falls back to the lexical text everywhere).
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitDocuments",
        version: 2,
        tables: [
            TableDeclaration(
                name: "corpus_documents",
                columns: [
                    .text("content_id", nullable: false),
                    .int("revision", nullable: false),
                    .text("digest", nullable: false),
                    .text("text", nullable: false),
                    // Dense-composition text for the float vector lane. NULL
                    // means fall back to `text` for both BM25 and dense
                    // embedding. Non-NULL lets a caller supply a distinct
                    // representation (e.g. a stopword-stripped or summarised
                    // form) while keeping the original text for BM25 and
                    // as the returned ranked payload.
                    .text("dense_text", nullable: true),
                    .timestamp("created_at", nullable: false),
                    .timestamp("updated_at", nullable: false)
                ],
                primaryKey: ["content_id"]
            ),
            TableDeclaration(
                name: "corpus_content_changes",
                columns: [
                    .int("seq", nullable: false),
                    .text("content_id", nullable: false),
                    .int("revision", nullable: false),
                    // Digest of the upserted revision; NULL for removes.
                    .text("digest", nullable: true),
                    .int("kind", nullable: false),
                    .timestamp("changed_at", nullable: false)
                ],
                primaryKey: ["seq"]
            )
        ],
        indices: [
            IndexDeclaration(
                name: "idx_corpus_content_changes_content",
                table: "corpus_content_changes",
                columns: ["content_id"]
            )
        ],
        migrations: [
            // v1 → v2: add dense_text column (additive; NULL = use lexical text).
            Migration(fromVersion: 1, toVersion: 2, operations: [
                .addColumn(table: "corpus_documents",
                           column: .text("dense_text", nullable: true))
            ])
        ]
    )

    private let storage: any Storage
    /// Next journal sequence. Loaded lazily from MAX(seq)+1 on first write
    /// so a reopened store continues the feed without gaps or reuse.
    private var nextSeq: Int64?

    public init(storage: any Storage) {
        self.storage = storage
    }

    // MARK: - CorpusContentStore (mutation)

    @discardableResult
    public func put(
        _ text: String, id: CorpusContentID, now: Date
    ) async throws -> CorpusContentRecord {
        try await put(text, denseCompositionText: nil, id: id, now: now)
    }

    /// Insert or update canonical content with an optional dense-composition
    /// text for the float vector lane. The `denseCompositionText` is stored
    /// in `corpus_documents.dense_text` (NULL when nil) and returned in every
    /// subsequent `record(for:)` call so the engine can recompose the dense
    /// vector on any retrain or reindex without external input.
    ///
    /// Idempotence: if BOTH `text` AND `denseCompositionText` are unchanged
    /// from the persisted row, the call is a no-op (same record, no revision
    /// bump, no journal entry). A change to either bumps the revision.
    @discardableResult
    public func put(
        _ text: String, denseCompositionText: String?,
        id: CorpusContentID, now: Date
    ) async throws -> CorpusContentRecord {
        let digest = CorpusContentDigest.digest(text)
        if let existing = try await record(for: id) {
            // Idempotence anchor: both lexical text (same digest) AND dense
            // text must match for a no-op. A changed dense text without a
            // changed lexical text still bumps the revision — the dense
            // vector must be recomposed and the coverage row invalidated.
            if existing.digest == digest,
               existing.denseCompositionText == denseCompositionText {
                return existing
            }
            let bumped = CorpusContentRecord(
                id: id, revision: existing.revision + 1, digest: digest, text: text,
                denseCompositionText: denseCompositionText)
            _ = try await storage.rowStore.update(
                table: "corpus_documents",
                values: [
                    "revision": .int(bumped.revision),
                    "digest": .text(digest),
                    "text": .text(text),
                    "dense_text": denseCompositionText.map { .text($0) } ?? .null,
                    "updated_at": .timestamp(now)
                ],
                where: .eq(Column(table: "corpus_documents", name: "content_id"), .text(id)))
            try await journal(.upsert, id: id, revision: bumped.revision, digest: digest, now: now)
            return bumped
        }
        let fresh = CorpusContentRecord(
            id: id, revision: 1, digest: digest, text: text,
            denseCompositionText: denseCompositionText)
        _ = try await storage.rowStore.insert(table: "corpus_documents", values: [
            "content_id": .text(id),
            "revision": .int(fresh.revision),
            "digest": .text(digest),
            "text": .text(text),
            "dense_text": denseCompositionText.map { .text($0) } ?? .null,
            "created_at": .timestamp(now),
            "updated_at": .timestamp(now)
        ])
        try await journal(.upsert, id: id, revision: fresh.revision, digest: digest, now: now)
        return fresh
    }

    public func remove(id: CorpusContentID, now: Date) async throws {
        guard let existing = try await record(for: id) else { return }
        _ = try await storage.rowStore.delete(
            table: "corpus_documents",
            where: .eq(Column(table: "corpus_documents", name: "content_id"), .text(id)))
        try await journal(.remove, id: id, revision: existing.revision, digest: nil, now: now)
    }

    // MARK: - CorpusContentSource (read)

    public func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        let rows = try await storage.rowStore.query(
            table: "corpus_documents",
            where: .eq(Column(table: "corpus_documents", name: "content_id"), .text(id)),
            orderBy: [], limit: 1, offset: nil)
        guard let row = rows.first,
              case let .int(revision)? = row["revision"],
              case let .text(digest)? = row["digest"],
              case let .text(text)? = row["text"] else { return nil }
        // dense_text is NULL when not set (existing rows and all puts that
        // did not supply a dense-composition text). nil → effectiveDenseText
        // falls back to text, preserving identical behavior for existing callers.
        let denseText: String?
        if case let .text(dt)? = row["dense_text"] { denseText = dt } else { denseText = nil }
        return CorpusContentRecord(
            id: id, revision: revision, digest: digest, text: text,
            denseCompositionText: denseText)
    }

    /// Optimized batch fetch using a single WHERE…IN query. Overrides the
    /// protocol default (N serial reads) for the standalone store path.
    public func records(for ids: [CorpusContentID]) async throws -> [CorpusContentID: CorpusContentRecord] {
        guard !ids.isEmpty else { return [:] }
        let rows = try await storage.rowStore.query(
            table: "corpus_documents",
            where: .in(Column(table: "corpus_documents", name: "content_id"),
                       ids.map { .text($0) }),
            orderBy: [], limit: nil, offset: nil)
        var result: [CorpusContentID: CorpusContentRecord] = [:]
        for row in rows {
            guard case let .text(contentID)? = row["content_id"],
                  case let .int(revision)? = row["revision"],
                  case let .text(digest)? = row["digest"],
                  case let .text(text)? = row["text"] else { continue }
            let denseText: String?
            if case let .text(dt)? = row["dense_text"] { denseText = dt } else { denseText = nil }
            result[contentID] = CorpusContentRecord(
                id: contentID, revision: revision, digest: digest, text: text,
                denseCompositionText: denseText)
        }
        return result
    }

    public func changes(
        since cursor: String?, limit: Int
    ) async throws -> CorpusContentChangeBatch {
        guard limit > 0 else { return .empty }
        let after: Int64
        if let cursor {
            guard let parsed = Int64(cursor) else {
                throw CorpusKitError.decodingFailure(
                    "corpus content cursor is not a journal sequence: \(cursor)")
            }
            after = parsed
        } else {
            after = 0
        }
        let rows = try await storage.rowStore.query(
            table: "corpus_content_changes",
            where: .gt(Column(table: "corpus_content_changes", name: "seq"), .int(after)),
            orderBy: [OrderClause(column: Column(table: "corpus_content_changes", name: "seq"))],
            limit: limit, offset: nil)
        var changes: [CorpusContentChange] = []
        var lastSeq = after
        for row in rows {
            guard case let .int(seq)? = row["seq"],
                  case let .text(contentID)? = row["content_id"],
                  case let .int(revision)? = row["revision"],
                  case let .int(kindRaw)? = row["kind"],
                  let kind = ChangeKind(rawValue: kindRaw) else { continue }
            lastSeq = seq
            switch kind {
            case .upsert:
                guard case let .text(digest)? = row["digest"] else { continue }
                changes.append(.upsert(id: contentID, revision: revision, digest: digest))
            case .remove:
                changes.append(.remove(id: contentID, revision: revision))
            }
        }
        return CorpusContentChangeBatch(
            changes: changes,
            nextCursor: changes.isEmpty ? nil : String(lastSeq))
    }

    public func activeContentIDs() async throws -> [CorpusContentID] {
        let rows = try await storage.rowStore.query(
            table: "corpus_documents", where: nil, orderBy: [], limit: nil, offset: nil)
        return rows.compactMap { row in
            if case let .text(id)? = row["content_id"] { return id }
            return nil
        }.sorted()
    }

    // MARK: - Journal

    private func journal(
        _ kind: ChangeKind, id: CorpusContentID, revision: Int64,
        digest: String?, now: Date
    ) async throws {
        let seq: Int64
        if let next = nextSeq {
            seq = next
        } else {
            // MAX(seq) via a single descending-ordered row read.
            let rows = try await storage.rowStore.query(
                table: "corpus_content_changes",
                where: nil,
                orderBy: [OrderClause(
                    column: Column(table: "corpus_content_changes", name: "seq"),
                    direction: .descending)],
                limit: 1, offset: nil)
            if let row = rows.first, case let .int(maxSeq)? = row["seq"] {
                seq = maxSeq + 1
            } else {
                seq = 1
            }
        }
        _ = try await storage.rowStore.insert(table: "corpus_content_changes", values: [
            "seq": .int(seq),
            "content_id": .text(id),
            "revision": .int(revision),
            "digest": digest.map { TypedValue.text($0) } ?? .null,
            "kind": .int(kind.rawValue),
            "changed_at": .timestamp(now)
        ])
        nextSeq = seq + 1
    }
}
