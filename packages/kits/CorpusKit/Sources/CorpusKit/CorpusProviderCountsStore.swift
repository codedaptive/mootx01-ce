// CorpusProviderCountsStore.swift
//
// Persistence for a trainable embedding provider's INCREMENTALLY-MAINTAINED
// statistics ("counts"): the raw accumulated state a distributional provider
// (RI/PPMI/LSA/NMF) builds from the corpus — vocabulary, document-frequencies,
// co-occurrence counts, RI context vectors — kept as an opaque per-provider
// blob plus two cheap, queryable trigger columns.
//
// ## Why this exists (the counts-table change set)
//
// The counts are ADDITIVE: a new chunk appends terms, increments
// document-frequencies, accumulates co-occurrence. This store persists
// them so they can be MAINTAINED as we go — incremented once per chunk
// on write. The current code does persist maintained counts, but
// Corpus.reindex still reads active chunks and trains from chunk texts;
// the count-table-backed retrain path is not yet wired.
//
// This is HALF A of the change set (the maintained table). HALF B — re-projecting
// existing chunk vectors when a basis actually changes (the coordinate swap) —
// is a separate concern (shadow-swap) and is not handled here.
//
// ## Schema (one row per (modelID, modelVersion))
//   corpus_provider_counts (
//     model_id      TEXT NOT NULL,
//     model_version TEXT NOT NULL,
//     counts        BLOB NOT NULL,    -- opaque per-provider serialized counts
//     doc_count     INTEGER NOT NULL, -- documents (chunks) folded into the counts
//     vocab_size    INTEGER NOT NULL, -- distinct terms in the vocabulary
//     updated_at    TEXT NOT NULL,    -- ISO8601 (schema invariant); never REAL
//     ext           JSON NULL         -- nullable entity ext slots forward-compat slot
//   )  PRIMARY KEY (model_id, model_version)
//
// ## Why each column
//   - model_id / model_version: counts are valid only for the exact provider
//     that accumulated them — keyed identically to the basis row and to every
//     vector row.
//   - counts: the raw accumulated state, serialized by the provider itself
//     (the provider owns the byte format, exactly as it owns the basis blob).
//     BLOB, not TEXT — raw little-endian bytes.
//   - doc_count / vocab_size: surfaced as their OWN columns (not just inside the
//     blob) so the vocab-growth retrain trigger can read them with a single
//     cheap query, WITHOUT deserializing the (potentially large) counts blob.
//     The trigger compares the live corpus growth against the last-factored
//     anchor; these are that anchor's cheap read surface. INTEGER, not a Bool —
//     there are no Bool stored columns in this schema (schema-invariants rule).
//   - updated_at: WHEN the counts were last persisted. TEXT ISO8601 per the
//     schema invariant; the caller's `now`, never Date() in the engine.
//
// The table is NOT append-only: each incremental update UPSERTs the row in place,
// so a provider key always resolves to its single current counts row.
//
// Layering: CorpusKit core; depends only on PersistenceKit + SubstrateTypes,
// exactly like BasisStore. It never imports CorpusKitProviders — the counts
// bytes are opaque here; only the provider interprets them.

import Foundation
import PersistenceKit
import SubstrateTypes

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// This store persists and returns opaque counts bytes produced by the
// provider's own serializer. It computes nothing — no tokenization, no
// factorization, no statistics. Those live in the providers
// (CorpusKitProviders) and SubstrateML.
// ─────────────────────────────────────────────────────────────────

/// A persisted provider-counts row: the opaque accumulated-statistics blob plus
/// the metadata that keys it and the two cheap trigger anchors.
public struct PersistedCounts: Sendable, Equatable {
    /// The provider modelID the counts were accumulated for.
    public let modelID: String
    /// The provider modelVersion the counts were accumulated for.
    public let modelVersion: String
    /// The provider-serialized accumulated counts (opaque to this store).
    public let counts: Data
    /// Documents (chunks) folded into the counts — growth-trigger anchor.
    public let documentCount: Int
    /// Distinct vocabulary terms — growth-trigger anchor.
    public let vocabSize: Int
    /// When the counts were last persisted (the caller's `now`).
    public let updatedAt: Date

    public init(modelID: String,
                modelVersion: String,
                counts: Data,
                documentCount: Int,
                vocabSize: Int,
                updatedAt: Date) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.counts = counts
        self.documentCount = documentCount
        self.vocabSize = vocabSize
        self.updatedAt = updatedAt
    }
}

/// The growth anchors for a provider key — read without deserializing the blob.
public struct CountsGrowthAnchor: Sendable, Equatable {
    public let documentCount: Int
    public let vocabSize: Int
}

/// A crash-durable, reference-only delta folded after the provider's persisted
/// base counts snapshot. Canonical text remains owned by the content source and
/// is resolved by identity when the accumulator is rebuilt after reopen.
public struct PersistedCountsReference: Sendable, Equatable {
    public let modelID: String
    public let modelVersion: String
    public let contentID: String
    public let revision: Int64
    public let digest: String
    public let updatedAt: Date

    public init(
        modelID: String, modelVersion: String, contentID: String,
        revision: Int64, digest: String, updatedAt: Date
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.contentID = contentID
        self.revision = revision
        self.digest = digest
        self.updatedAt = updatedAt
    }
}

/// Storage for a trainable embedding provider's maintained counts.
///
/// One row per (modelID, modelVersion). `upsert` writes/replaces it; `load`
/// reads the full row; `growthAnchor` reads only the cheap doc/vocab counts for
/// the retrain trigger; `deleteAll` wipes every row as part of
/// `Corpus.destroyRecallIndex()`. The store interprets none of the bytes.
public actor CorpusProviderCountsStore {

    let storage: any Storage

    /// Additive schema declaration for the maintained-counts table. Mirrors the
    /// BasisStore declaration pattern. `appendOnly` is false: an incremental
    /// update UPSERTs the existing (modelID, modelVersion) row, so the table
    /// holds at most one counts row per provider key. The `.json` `ext` slot is
    /// the nullable entity ext slots forward-compat reservation (written NULL / omitted in 1.0).
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitCounts",
        version: 2,
        tables: [
            TableDeclaration(
                name: "corpus_provider_counts",
                columns: [
                    .text("model_id", nullable: false),
                    .text("model_version", nullable: false),
                    // BLOB: the provider-serialized raw counts bytes.
                    .blob("counts", nullable: false),
                    // INTEGER growth anchors — NOT Bool flags.
                    .int("doc_count", nullable: false),
                    .int("vocab_size", nullable: false),
                    // TIMESTAMP maps to TEXT ISO8601 (schema invariant) — never REAL.
                    .timestamp("updated_at", nullable: false),
                    // nullable entity ext slots forward-compat slot; nullable, omitted on upsert in 1.0.
                    .json("ext", nullable: true)
                ],
                primaryKey: ["model_id", "model_version"]
                // appendOnly defaults to false: an update UPSERTs the row in place.
            ),
            TableDeclaration(
                name: "corpus_provider_count_references",
                columns: [
                    .text("model_id", nullable: false),
                    .text("model_version", nullable: false),
                    .text("content_id", nullable: false),
                    .int("revision", nullable: false),
                    .text("digest", nullable: false),
                    .timestamp("updated_at", nullable: false),
                    .json("ext", nullable: true)
                ],
                primaryKey: ["model_id", "model_version", "content_id"]
            )
        ],
        indices: []
    )

    public init(storage: any Storage) {
        self.storage = storage
    }

    /// Insert or replace the counts row for a provider key.
    ///
    /// Keyed by the composite primary key (model_id, model_version): an
    /// incremental update replaces the prior counts in place rather than
    /// accumulating rows. `updatedAt` is the caller's `now` (determinism).
    public func upsert(_ row: PersistedCounts) async throws {
        try await upsert(row, into: storage.rowStore)
    }

    /// Transaction-scoped variant: write through the CALLER's row store so
    /// the counts row commits atomically with its basis row (the corrective
    /// pass's basis+counts atomic commit).
    public func upsert(_ row: PersistedCounts, into rowStore: any RowStore) async throws {
        let values: [String: TypedValue] = [
            "model_id": .text(row.modelID),
            "model_version": .text(row.modelVersion),
            "counts": .blob(row.counts),
            "doc_count": .int(Int64(row.documentCount)),
            "vocab_size": .int(Int64(row.vocabSize)),
            "updated_at": .timestamp(row.updatedAt)
        ]
        _ = try await rowStore.upsert(
            table: "corpus_provider_counts",
            values: values,
            conflictColumns: ["model_id", "model_version"]
        )
    }

    /// Load the full persisted counts for a provider key, or nil if none.
    public func load(modelID: String, modelVersion: String) async throws -> PersistedCounts? {
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_counts",
            where: .and([
                .eq(Column(table: "corpus_provider_counts", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_counts", name: "model_version"), .text(modelVersion))
            ]),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first else { return nil }
        return Self.decode(row)
    }

    /// Read only the growth anchors (doc/vocab counts) for a provider key,
    /// without deserializing the counts blob. This is the cheap read the
    /// vocab-growth retrain trigger uses each time it evaluates staleness.
    public func growthAnchor(modelID: String, modelVersion: String) async throws -> CountsGrowthAnchor? {
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_counts",
            where: .and([
                .eq(Column(table: "corpus_provider_counts", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_counts", name: "model_version"), .text(modelVersion))
            ]),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first,
              case let .int(docCount) = row["doc_count"] ?? .null,
              case let .int(vocabSize) = row["vocab_size"] ?? .null else { return nil }
        return CountsGrowthAnchor(documentCount: Int(docCount), vocabSize: Int(vocabSize))
    }

    /// Append an idempotent reference delta through a caller-owned transaction.
    /// The row deliberately contains no canonical text or token inventory.
    public func upsertReference(
        _ row: PersistedCountsReference, into rowStore: any RowStore
    ) async throws {
        _ = try await rowStore.upsert(
            table: "corpus_provider_count_references",
            values: [
                "model_id": .text(row.modelID),
                "model_version": .text(row.modelVersion),
                "content_id": .text(row.contentID),
                "revision": .int(row.revision),
                "digest": .text(row.digest),
                "updated_at": .timestamp(row.updatedAt)
            ],
            conflictColumns: ["model_id", "model_version", "content_id"]
        )
    }

    /// Whether this provider generation already carries a pending delta for a
    /// canonical identity. The serialized queue batch uses this to keep a
    /// remove/re-add idempotent in memory as well as on disk.
    public func hasReference(
        modelID: String, modelVersion: String, contentID: String
    ) async throws -> Bool {
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_count_references",
            where: .and([
                .eq(Column(table: "corpus_provider_count_references", name: "model_id"),
                    .text(modelID)),
                .eq(Column(table: "corpus_provider_count_references", name: "model_version"),
                    .text(modelVersion)),
                .eq(Column(table: "corpus_provider_count_references", name: "content_id"),
                    .text(contentID)),
            ]),
            orderBy: [], limit: 1, offset: nil)
        return !rows.isEmpty
    }

    /// Load deterministic reference deltas for one exact provider generation.
    public func references(modelID: String, modelVersion: String) async throws
        -> [PersistedCountsReference]
    {
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_count_references",
            where: .and([
                .eq(Column(table: "corpus_provider_count_references", name: "model_id"),
                    .text(modelID)),
                .eq(Column(table: "corpus_provider_count_references", name: "model_version"),
                    .text(modelVersion))
            ]),
            orderBy: [], limit: nil, offset: nil)
        return rows.compactMap(Self.decodeReference).sorted {
            ($0.contentID, $0.revision, $0.digest) < ($1.contentID, $1.revision, $1.digest)
        }
    }

    /// A full-corpus provider retrain subsumes its queued deltas. Delete them
    /// in the same transaction that publishes the replacement basis+counts.
    public func deleteReferences(
        modelID: String, modelVersion: String, into rowStore: any RowStore
    ) async throws {
        _ = try await rowStore.delete(
            table: "corpus_provider_count_references",
            where: .and([
                .eq(Column(table: "corpus_provider_count_references", name: "model_id"),
                    .text(modelID)),
                .eq(Column(table: "corpus_provider_count_references", name: "model_version"),
                    .text(modelVersion))
            ]))
    }

    /// Delete every counts row. Used by `Corpus.destroyRecallIndex()` so a
    /// destroyed corpus leaves no orphaned counts behind.
    public func deleteAll() async throws {
        _ = try await storage.rowStore.delete(
            table: "corpus_provider_count_references",
            where: .isTrue
        )
        _ = try await storage.rowStore.delete(
            table: "corpus_provider_counts",
            where: .isTrue
        )
    }

    // MARK: - Decode

    /// Decode a counts row, tolerant of BOTH the semantic TypedValue forms the
    /// InMemory backend preserves AND the primitive forms the SQLite backend
    /// returns on read (a TIMESTAMP column is physically TEXT ISO8601). A
    /// semantic-only reader would silently drop every row on reopen and the
    /// maintained counts would be lost on restart. A row failing any field match
    /// yields nil rather than fabricated counts.
    static func decode(_ row: StorageRow) -> PersistedCounts? {
        guard case let .text(modelID) = row["model_id"] ?? .null,
              case let .text(modelVersion) = row["model_version"] ?? .null,
              case let .blob(counts) = row["counts"] ?? .null,
              case let .int(docCount) = row["doc_count"] ?? .null,
              case let .int(vocabSize) = row["vocab_size"] ?? .null,
              let updatedAt = decodeDate(row["updated_at"]) else {
            return nil
        }
        return PersistedCounts(
            modelID: modelID,
            modelVersion: modelVersion,
            counts: counts,
            documentCount: Int(docCount),
            vocabSize: Int(vocabSize),
            updatedAt: updatedAt
        )
    }

    private static func decodeReference(_ row: StorageRow) -> PersistedCountsReference? {
        guard case let .text(modelID) = row["model_id"] ?? .null,
              case let .text(modelVersion) = row["model_version"] ?? .null,
              case let .text(contentID) = row["content_id"] ?? .null,
              case let .int(revision) = row["revision"] ?? .null,
              case let .text(digest) = row["digest"] ?? .null,
              let updatedAt = decodeDate(row["updated_at"])
        else { return nil }
        return PersistedCountsReference(
            modelID: modelID, modelVersion: modelVersion, contentID: contentID,
            revision: revision, digest: digest, updatedAt: updatedAt)
    }

    /// Decode `updated_at` tolerant of `.timestamp` (InMemory) and `.text`
    /// ISO8601 (SQLite, where a TIMESTAMP column is physically TEXT). The SQLite
    /// backend writes the fractional-second form, so that parser is tried first,
    /// then the whole-second form. Formatters are local (Swift 6 strict
    /// concurrency disallows shared non-Sendable globals); not a hot path.
    private static func decodeDate(_ value: TypedValue?) -> Date? {
        switch value ?? .null {
        case let .timestamp(d):
            return d
        case let .text(s):
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: s) { return d }
            let whole = ISO8601DateFormatter()
            whole.formatOptions = [.withInternetDateTime]
            return whole.date(from: s)
        default:
            return nil
        }
    }
}
