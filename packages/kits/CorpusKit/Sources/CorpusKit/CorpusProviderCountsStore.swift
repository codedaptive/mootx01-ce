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
    /// v3 adds `corpus_provider_vocab`: one row per vocabulary term, so a
    /// provider's term→vector map no longer has to be one blob whose size
    /// scales with vocabulary.
    ///
    /// Why: `corpus_provider_counts.counts` held the entire serialized map.
    /// Measured on real estates, 736,844,490 B at ~89.8K terms and
    /// 1,009,861,855 B at ~123K terms — the latter exceeded SQLite's 1e9
    /// bind ceiling and bricked a daemon (ee#49). Raising the ceiling bought
    /// headroom but left the real cost: every incremental update rewrote the
    /// whole blob (O(N·vocab), which is why persistence is batched at all).
    ///
    /// The change is ADDITIVE — a new table, not a reshape of
    /// `corpus_provider_counts`. Mutating the existing table is how the basis
    /// store ended up needing a full v3→v4 rebuild: `ALTER TABLE` cannot
    /// change a primary key, and the claim that no fielded estate would need
    /// migrating was false. The PK here is correct in the CREATE.
    ///
    /// There is deliberately NO bulk data migration. The read path prefers
    /// term rows and falls back to the legacy blob, so an upgraded estate
    /// keeps working untouched and converts on its next write. A one-shot
    /// transformation of a multi-gigabyte estate inside the open path is
    /// exactly the shape of failure this whole incident chain was.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitCounts",
        version: 3,
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
            ),
            // One row per vocabulary term. `vector` carries the provider's own
            // per-term bytes verbatim — the same bytes the blob format writes
            // for that term — so nothing recomputes and cross-port byte
            // equality is unaffected.
            //
            // `term` is stored as TEXT. The attached-mode profile guard about
            // text columns concerns canonical CONTENT text ownership and
            // erasure, not tokens: `iix_termfreqs` in the same profile is
            // already PRIMARY KEY (term TEXT, item_id) and maps each term to
            // the document containing it, which is strictly more revealing
            // than a de-duplicated vocabulary. Terms are also already
            // plaintext inside the existing blob.
            vocabTable
        ],
        indices: [],
        migrations: [
            // v2 → v3: create the term table. Additive only — no existing row
            // is read, rewritten, or moved. This is the first migration this
            // kit has ever had; keeping it to a CREATE is deliberate.
            Migration(
                fromVersion: 2,
                toVersion: 3,
                operations: [.createTable(vocabTable)]
            )
        ]
    )

    /// The term-keyed vocabulary table, shared by the declaration and its
    /// v2→v3 migration so the two can never drift apart.
    static let vocabTable = TableDeclaration(
        name: "corpus_provider_vocab",
        columns: [
            .text("model_id", nullable: false),
            .text("model_version", nullable: false),
            .text("term", nullable: false),
            // The provider's per-term payload, byte-identical to what the
            // blob format writes for this term (for RandomIndexing: 2048
            // little-endian f32, 8192 bytes).
            .blob("vector", nullable: false),
            .json("ext", nullable: true)
        ],
        primaryKey: ["model_id", "model_version", "term"]
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

    // MARK: - Provider-aware persist / restore

    /// Persist `provider`'s maintained counts, splitting them into term rows
    /// when the provider supports it and writing one blob when it does not.
    ///
    /// This is the ONLY place that decides between the two layouts. The three
    /// write paths (training commit, batch-boundary persist, and maintained-
    /// counts persist) all route through it, because a provider that is
    /// term-split on one path and blob-written on another would leave the two
    /// representations disagreeing about the same provider key — and the read
    /// side prefers term rows, so the blob write would silently lose.
    public func persistCounts(
        provider: any TrainableEmbeddingBasis,
        modelID: String,
        modelVersion: String,
        documentCount: Int,
        vocabSize: Int,
        updatedAt: Date,
        into rowStore: any RowStore
    ) async throws {
        if let decomposed = provider.decomposeCounts() {
            // `header` is a complete, decodable counts blob carrying an empty
            // map, so the column stays NOT NULL and a reader that ignores term
            // rows still succeeds.
            try await upsert(
                PersistedCounts(
                    modelID: modelID,
                    modelVersion: modelVersion,
                    counts: decomposed.header,
                    documentCount: documentCount,
                    vocabSize: vocabSize,
                    updatedAt: updatedAt),
                into: rowStore)
            try await replaceVocab(
                modelID: modelID, modelVersion: modelVersion,
                terms: decomposed.terms, into: rowStore)
        } else {
            try await upsert(
                PersistedCounts(
                    modelID: modelID,
                    modelVersion: modelVersion,
                    counts: provider.serializeCounts(),
                    documentCount: documentCount,
                    vocabSize: vocabSize,
                    updatedAt: updatedAt),
                into: rowStore)
            // A provider can stop decomposing (or a key can be reused by a
            // provider that never did). Clear any term rows so the blob is
            // unambiguously the whole truth for this key.
            try await deleteVocab(
                modelID: modelID, modelVersion: modelVersion, into: rowStore)
        }
    }

    /// Restore `provider`'s maintained counts, preferring term rows and
    /// falling back to the legacy single blob.
    ///
    /// The fallback is what lets an upgraded estate keep working untouched:
    /// no bulk migration runs, the blob is read exactly as before, and the
    /// provider converts to term rows on its next persist.
    ///
    /// - Returns: false when nothing is stored for this provider key, which
    ///   callers already treat as "start from zero".
    @discardableResult
    public func restoreCounts(
        into provider: any TrainableEmbeddingBasis,
        modelID: String,
        modelVersion: String
    ) async throws -> Bool {
        guard let persisted = try await load(modelID: modelID, modelVersion: modelVersion) else {
            return false
        }
        let terms = try await loadVocab(modelID: modelID, modelVersion: modelVersion)
        if terms.isEmpty {
            // Legacy layout, or a provider that does not decompose.
            try provider.restoreCounts(from: persisted.counts)
        } else {
            try provider.restoreCounts(header: persisted.counts, terms: terms)
        }
        return true
    }

    // MARK: - Term-keyed vocabulary

    /// Replace the stored vocabulary for a provider key with `terms`.
    ///
    /// Delete-then-insert inside the caller's row store so a retrain becomes
    /// visible atomically with its counts and basis rows, and never leaves a
    /// union of an old and new generation. Each bound value is one term's
    /// vector (8192 B for RandomIndexing), so no single bind scales with
    /// vocabulary — which is the entire point of the table.
    public func replaceVocab(
        modelID: String,
        modelVersion: String,
        terms: [(term: String, vector: Data)],
        into rowStore: any RowStore
    ) async throws {
        try await deleteVocab(modelID: modelID, modelVersion: modelVersion, into: rowStore)
        for entry in terms {
            _ = try await rowStore.upsert(
                table: "corpus_provider_vocab",
                values: [
                    "model_id": .text(modelID),
                    "model_version": .text(modelVersion),
                    "term": .text(entry.term),
                    "vector": .blob(entry.vector)
                ],
                conflictColumns: ["model_id", "model_version", "term"]
            )
        }
    }

    /// Every stored term/vector pair for a provider key.
    ///
    /// Returns an EMPTY array both when the provider has no vocabulary and
    /// when this estate predates the term table — callers must treat empty as
    /// "fall back to the legacy blob", never as "the vocabulary is empty".
    /// Order is unspecified: the blob writer sorts by UTF-8 bytes for
    /// cross-port determinism, but the reader builds a dictionary and is
    /// order-independent.
    public func loadVocab(
        modelID: String, modelVersion: String
    ) async throws -> [(term: String, vector: Data)] {
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_vocab",
            where: .and([
                .eq(Column(table: "corpus_provider_vocab", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_vocab", name: "model_version"), .text(modelVersion))
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        return rows.compactMap { row in
            guard case let .text(term) = row["term"] ?? .null,
                  case let .blob(vector) = row["vector"] ?? .null
            else { return nil }
            return (term: term, vector: vector)
        }
    }

    /// Drop the stored vocabulary for a provider key.
    public func deleteVocab(
        modelID: String, modelVersion: String, into rowStore: any RowStore
    ) async throws {
        _ = try await rowStore.delete(
            table: "corpus_provider_vocab",
            where: .and([
                .eq(Column(table: "corpus_provider_vocab", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_vocab", name: "model_version"), .text(modelVersion))
            ])
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
        // The term table is part of this store's state, so a wholesale clear
        // must include it. Missing this would leave a previous generation's
        // vocabulary behind after destroyRecallIndex or the shared-content
        // migration's derived-state wipe, and the next load would read term
        // rows that no longer match the counts row beside them.
        _ = try await storage.rowStore.delete(
            table: "corpus_provider_vocab",
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
