// CorpusProviderCountsStore.swift
//
// Persistence for a trainable embedding provider's INCREMENTALLY-MAINTAINED
// statistics ("counts"): the raw accumulated state a distributional provider
// (RI/PPMI/LSA/NMF) builds from the corpus — vocabulary, document-frequencies,
// co-occurrence counts, RI context vectors — kept as an opaque per-provider
// blob plus two cheap, queryable trigger columns.
//
// The opaque counts are ADDITIVE provider statistics. Standalone CorpusKit may
// publish that blob at bounded ingest/reindex boundaries. Attached GLK keeps the
// published blob frozen between provider publications and records only compact
// canonical-content references; it never copies GLK Drawer text into this lane.
// The independently updated integer anchors let the governor observe durable
// growth without rewriting or decoding an estate-scale blob for every change.
//
// ## Schema (one row per (modelID, modelVersion))
//   corpus_provider_counts (
//     model_id      TEXT NOT NULL,
//     model_version TEXT NOT NULL,
//     counts        BLOB NOT NULL,    -- opaque per-provider serialized counts
//     doc_count     INTEGER NOT NULL, -- durable monotonic document anchor
//     vocab_size    INTEGER NOT NULL, -- durable monotonic vocabulary anchor
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
//   - doc_count / vocab_size: durable growth-trigger anchors, committed in the
//     same transaction as attached reference admission. Between publications
//     they intentionally describe the maintained live state, not merely the
//     frozen `counts` blob. INTEGER, not a Bool — there are no Bool stored
//     columns in this schema (schema-invariants rule).
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
    /// Canonical content identities admitted into this provider generation.
    public let documentCount: Int
    /// Durable, nondecreasing vocabulary-growth anchor.
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

/// A crash-durable, reference-only counts record. Ordinary rows are deltas
/// folded after the provider's persisted base counts snapshot. A short-lived
/// `isSubsumed` marker closes the opposite side of the publication boundary:
/// content visible to a training snapshot before its queue/direct admission
/// commits is already represented by the replacement base and must not be
/// folded again when that delayed admission resumes. Canonical text remains
/// owned by the content source.
public struct PersistedCountsReference: Sendable, Equatable {
    public let modelID: String
    public let modelVersion: String
    public let contentID: String
    public let revision: Int64
    public let digest: String
    public let updatedAt: Date
    public let isSubsumed: Bool
    /// Sorted SHA-256 digests of terms that were not present in the published
    /// provider generation. This is the complete identity-scoped growth
    /// contribution accumulated across revisions of this content ID. It carries
    /// no canonical text and is discarded at the next provider publication.
    public let growthTermDigests: [String]

    public init(
        modelID: String, modelVersion: String, contentID: String,
        revision: Int64, digest: String, updatedAt: Date,
        isSubsumed: Bool = false,
        growthTermDigests: [String] = []
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.contentID = contentID
        self.revision = revision
        self.digest = digest
        self.updatedAt = updatedAt
        self.isSubsumed = isSubsumed
        self.growthTermDigests = growthTermDigests.sorted()
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
    private static let subsumedReferenceExt =
        Data(#"{"kind":"subsumed"}"#.utf8)

    private struct ReferenceExtension: Codable {
        let kind: String
        let terms: [String]?
    }

    /// Canonical ASCII JSON. Term identities are lowercase SHA-256 hex, so no
    /// JSON escaping or cross-runtime Unicode policy can alter persisted bytes.
    private static func growthReferenceExt(_ terms: [String]) -> Data? {
        let sorted = Array(Set(terms.filter { term in
            term.utf8.count == 64 && term.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
        })).sorted()
        guard !sorted.isEmpty else { return nil }
        let quoted = sorted.map { "\"\($0)\"" }.joined(separator: ",")
        return Data("{\"kind\":\"growth\",\"terms\":[\(quoted)]}".utf8)
    }

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
                "updated_at": .timestamp(row.updatedAt),
                "ext": row.isSubsumed
                    ? .json(Self.subsumedReferenceExt)
                    : Self.growthReferenceExt(row.growthTermDigests)
                        .map(TypedValue.json) ?? .null
            ],
            conflictColumns: ["model_id", "model_version", "content_id"]
        )
    }

    /// The pending reference for one canonical identity, if any. The digest
    /// distinguishes an idempotent re-admission from a revision.
    public func referenceFor(
        modelID: String, modelVersion: String, contentID: String
    ) async throws -> PersistedCountsReference? {
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
        return rows.first.flatMap(Self.decodeReference)
    }

    /// Batch-fetch pending references for a set of canonical identities within
    /// one provider generation. Issues a single `WHERE content_id IN (...)` query
    /// rather than N individual `referenceFor` calls — the O(N) → O(1) I/O
    /// reduction that `commitQueueBatch` needs for large drain passes.
    ///
    /// Returns a dictionary keyed by contentID. Missing entries (content IDs with
    /// no existing reference) are absent from the dictionary, matching the
    /// semantics of `referenceFor` returning `nil`.
    ///
    /// - Parameters:
    ///   - modelID: Provider model identifier.
    ///   - modelVersion: Provider model version.
    ///   - contentIDs: The set of content IDs to fetch. Empty → empty dictionary.
    public func referencesFor(
        modelID: String, modelVersion: String, contentIDs: [String]
    ) async throws -> [String: PersistedCountsReference] {
        guard !contentIDs.isEmpty else { return [:] }
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_count_references",
            where: .and([
                .eq(Column(table: "corpus_provider_count_references", name: "model_id"),
                    .text(modelID)),
                .eq(Column(table: "corpus_provider_count_references", name: "model_version"),
                    .text(modelVersion)),
                .in(Column(table: "corpus_provider_count_references", name: "content_id"),
                    contentIDs.map { .text($0) }),
            ]),
            orderBy: [], limit: nil, offset: nil)
        var result: [String: PersistedCountsReference] = [:]
        for row in rows {
            if let ref = Self.decodeReference(row) {
                result[ref.contentID] = ref
            }
        }
        return result
    }

    /// Persist the maintained-count anchors (document count + vocabulary) on
    /// the provider's counts row WITHOUT rewriting the base blob. Committed in
    /// the SAME transaction as the reference mutation they reflect, so the
    /// governor's threshold decision is restart-deterministic. Returns false
    /// when the generation has no counts row yet (bootstrap edge).
    public func updateAnchors(
        modelID: String, modelVersion: String,
        documentCount: Int, vocabSize: Int,
        into rowStore: any RowStore
    ) async throws -> Bool {
        let updated = try await rowStore.update(
            table: "corpus_provider_counts",
            values: [
                "doc_count": .int(Int64(documentCount)),
                "vocab_size": .int(Int64(vocabSize)),
            ],
            where: .and([
                .eq(Column(table: "corpus_provider_counts", name: "model_id"),
                    .text(modelID)),
                .eq(Column(table: "corpus_provider_counts", name: "model_version"),
                    .text(modelVersion)),
            ]))
        return updated > 0
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

    /// Delete one exact identity reference through the caller's transaction.
    /// Delayed admission uses this to consume a training-snapshot marker in
    /// the same commit that advances the corresponding content checkpoint.
    public func deleteReference(
        modelID: String, modelVersion: String, contentID: String,
        into rowStore: any RowStore
    ) async throws {
        _ = try await rowStore.delete(
            table: "corpus_provider_count_references",
            where: .and([
                .eq(Column(table: "corpus_provider_count_references", name: "model_id"),
                    .text(modelID)),
                .eq(Column(table: "corpus_provider_count_references", name: "model_version"),
                    .text(modelVersion)),
                .eq(Column(table: "corpus_provider_count_references", name: "content_id"),
                    .text(contentID)),
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
        let decodedExtension: (isSubsumed: Bool, terms: [String]) = {
            let data: Data?
            switch row["ext"] ?? .null {
            case let .json(value), let .blob(value):
                data = value
            default:
                data = nil
            }
            guard let data else { return (false, []) }
            if data == Self.subsumedReferenceExt { return (true, []) }
            guard let ext = try? JSONDecoder().decode(ReferenceExtension.self, from: data),
                  ext.kind == "growth"
            else { return (false, []) }
            let terms = Array(Set(ext.terms ?? [])).filter { term in
                term.utf8.count == 64 && term.utf8.allSatisfy {
                    ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                }
            }.sorted()
            return (false, terms)
        }()
        return PersistedCountsReference(
            modelID: modelID, modelVersion: modelVersion, contentID: contentID,
            revision: revision, digest: digest, updatedAt: updatedAt,
            isSubsumed: decodedExtension.isSubsumed,
            growthTermDigests: decodedExtension.terms)
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
