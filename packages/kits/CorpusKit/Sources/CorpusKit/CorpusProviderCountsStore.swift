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
import MootProductIdentity
import OSLog
import PersistenceKit
import SubstrateTypes

/// Store-level log: the format-version gate in `restoreCounts(into:)` reports
/// a refused counts blob here so an operator can see why a provider retrained
/// from the corpus instead of restoring its counts.
private let countsLog = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "CorpusKit")

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
    /// v4 (CORPUS-COUNTS-01) adds the integer-keyed pair that replaces the
    /// term-keyed v3 shape for new writes:
    ///   - `corpus_provider_term_dictionary` — one row per unique term across
    ///     ALL models: `term_id INTEGER PK`, `term TEXT`, `models INTEGER`
    ///     (bitmask, bit = the model's registry integer). The string is stored
    ///     once; the bitmask answers "which models know this term" with no
    ///     join over a small table.
    ///   - `corpus_provider_term_payload` — PK `(model_id INTEGER,
    ///     term_id INTEGER)`, `vector BLOB`. No version column: a model
    ///     version bump drops its payload rows and sets the reindex latch —
    ///     the rebuild regenerates them (REINDEX_REQUIRED_MIGRATION_DESIGN §3).
    ///
    /// A bitmask on the payload's model field was considered and REJECTED
    /// (design §2.3): a payload row belongs to exactly one model, the key is
    /// single-valued, and a bitwise AND cannot use an index — it would turn a
    /// B-tree seek into a ~92K-row scan per model. The bitmask earns its keep
    /// only in the dictionary, where a term genuinely spans models.
    ///
    /// The v3→v4 migration is two CREATEs and nothing else — no read, no
    /// rewrite, no bulk transform in the open path (that shape is ee#49).
    /// Legacy v3 vocab rows and legacy counts blobs are dropped by the
    /// `mootx01 upgrade` step, which then sets the reindex latch; the read
    /// path below prefers the v4 pair and falls back to v3 rows / the legacy
    /// blob so an un-upgraded estate keeps working untouched.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitCounts",
        version: 4,
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
            vocabTable,
            termDictionaryTable,
            termPayloadTable
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
            ),
            // v3 → v4: create the integer-keyed pair. CREATEs only — the drop
            // of legacy rows happens in `mootx01 upgrade`, never at open
            // (ee#49: no bulk work in the estate-open path).
            Migration(
                fromVersion: 3,
                toVersion: 4,
                operations: [
                    .createTable(termDictionaryTable),
                    .createTable(termPayloadTable)
                ]
            )
        ]
    )

    /// One row per unique term across all models (v4). Shared by the
    /// declaration and the v3→v4 migration so the two can never drift apart.
    static let termDictionaryTable = TableDeclaration(
        name: "corpus_provider_term_dictionary",
        columns: [
            // INTEGER PRIMARY KEY: SQLite rowid alias — term ids are allocated
            // by insertion, dense, and stable for the life of the estate.
            .int("term_id", nullable: false),
            .text("term", nullable: false),
            // Bitmask of models that know this term: bit = the model's
            // registry integer (see `modelRegistry`). INTEGER state, not a
            // Bool column — multi-valued membership is what bitmasks are for.
            .int("models", nullable: false)
        ],
        primaryKey: ["term_id"]
    )

    /// Per-(model, term) payload bytes (v4). `vector` carries the provider's
    /// own per-term bytes verbatim (for RandomIndexing: 2048 little-endian
    /// f32, 8192 bytes) — nothing recomputes, cross-port byte equality holds.
    /// No model_version column: a version bump drops the model's rows and
    /// sets the reindex latch instead of versioning them in place.
    static let termPayloadTable = TableDeclaration(
        name: "corpus_provider_term_payload",
        columns: [
            .int("model_id", nullable: false),
            .int("term_id", nullable: false),
            .blob("vector", nullable: false)
        ],
        primaryKey: ["model_id", "term_id"]
    )

    /// The model → integer registry for the v4 pair.
    ///
    /// In-code and deterministic (both ports carry the identical table): the
    /// provider set is code-defined, so its integer assignment is too — the
    /// ruled storage shape is two tables, and a mapping table for four rows
    /// would be a third. The integer doubles as the dictionary bitmask's bit
    /// index (`models & (1 << id)`). An unknown modelID throws rather than
    /// auto-assigning: extending the registry is a deliberate, reviewed act,
    /// and every derived row is rebuildable via the reindex latch if an
    /// assignment ever has to change.
    static let modelRegistry: [String: Int] = [
        "random-indexing-v1": 0,
        "ppmi-v1": 1,
        "lsa-v1": 2,
        "nmf-v1": 3
    ]

    /// Registry lookup that fails loudly on an unregistered model.
    static func modelInt(for modelID: String) throws -> Int {
        guard let id = modelRegistry[modelID] else {
            throw CorpusKitError.modelUnavailable(
                "modelID '\(modelID)' is not in CorpusProviderCountsStore.modelRegistry — "
                + "add it (both ports) before persisting term payloads for it")
        }
        return id
    }

    // MARK: - Migration invalidation sentinel

    /// An empty `Data` blob written into `corpus_provider_counts.counts` by the
    /// upgrade step to signal "this provider's counts have been invalidated and
    /// must be rebuilt from the full corpus".
    ///
    /// The upgrade step cannot synthesise a per-provider counts header from scratch
    /// (it would need to know the exact provider format and current vocabulary),
    /// and it cannot delete the row because the companion `doc_count` / `vocab_size`
    /// columns are the durable growth-trigger anchors that the governor reads
    /// without deserialising the blob. Leaving those anchors in place lets the
    /// governor continue to observe estate size even during the rebuild window.
    ///
    /// An empty blob is the right signal because no valid serialised counts blob is
    /// ever empty — every format starts with a magic header. That makes the
    /// empty-blob sentinel unambiguous and keeps the scope narrow: a non-empty but
    /// undecodable blob must still throw (real corruption, not a sentinel), so the
    /// predicate cannot widen to "any undecodable blob". Writer and reader share
    /// the same predicate through `isInvalidatedCounts` so they cannot drift.
    public static let invalidatedCountsSentinel: Data = Data()

    /// Returns true when `bytes` carries the migration invalidation sentinel.
    ///
    /// Call this — never inline the `isEmpty` check — so writer and reader share
    /// one definition and cannot drift apart independently.
    public static func isInvalidatedCounts(_ bytes: Data) -> Bool { bytes.isEmpty }

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
        into rowStore: any RowStore,
        clearsInvalidation: Bool = false
    ) async throws {
        // Sentinel-preserving flush guard.
        //
        // After a `mootx01 upgrade` step the migration writes the invalidation sentinel
        // (an empty blob) into `corpus_provider_counts.counts` to mean "counts
        // invalidated, rebuild from zero". The live accumulator at that moment is empty
        // — the upgrade runs before any new ingest has contributed counts. If we flush
        // now we serialise a VALID empty-state blob over the sentinel: the reader then
        // decodes it as a real (zero-vocabulary) basis and publishes that zero basis
        // over the trained basis the migration left intact, silently erasing prior
        // training. The restore path returns true and the caller guard that was supposed
        // to route to the full-corpus retrain cannot fire.
        //
        // The fix: if the provider has accumulated nothing AND the stored row still
        // carries the sentinel, skip the flush entirely. The sentinel stays on disk,
        // the next restore returns false, and the caller routes to the full corpus
        // retrain as the migration intended.
        //
        // Test the in-memory vocabulary size FIRST (free, no I/O). Only if it is zero
        // do we pay the storage read to check the sentinel. An accumulator with even
        // one term is a genuine flush that must proceed regardless of what is on disk.
        // Only a FULL-CORPUS retrain may clear the sentinel. Everything else
        // leaves it alone, whatever the accumulator holds.
        //
        // The earlier version of this guard also required
        // `provider.countsVocabularySize == 0`, on the reasoning that "an
        // accumulator with even one term is a genuine flush". That reasoning is
        // wrong in the window this sentinel exists to cover. Between the
        // migration and the queued full reindex, ANY ingest — one MCP write is
        // enough — gives the fresh accumulator a term. The flush then proceeds
        // and replaces the sentinel with a valid PARTIAL blob. Because the
        // migration preserves the old `doc_count` anchor, the population guard
        // can later find document count equal to the active chunk count, accept
        // the partial counts, and publish a basis trained only on
        // post-migration content — silently dropping the preexisting corpus
        // from the index until some later full rebuild.
        //
        // So the discriminator is the WRITE PATH, not the accumulator's size.
        // `clearsInvalidation` defaults to false so a new call site fails safe:
        // a path that forgets to declare itself preserves the sentinel, which
        // costs a rebuild, rather than dropping it, which costs recall.
        if !clearsInvalidation,
           let existing = try await load(modelID: modelID, modelVersion: modelVersion, from: rowStore),
           Self.isInvalidatedCounts(existing.counts) {
            // The stored row still carries the invalidation sentinel and this is
            // not the retrain that earns the right to replace it. Leave it: the
            // next restore returns false and routes to the full corpus retrain
            // the migration queued.
            return
        }
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
            // v4: the integer-keyed pair is the write target. Clear any v3
            // term rows for this key so the pair is unambiguously the truth
            // (the read side prefers v4 and would otherwise shadow them).
            try await replaceTermPayloads(
                modelID: modelID, terms: decomposed.terms, into: rowStore)
            try await deleteVocab(
                modelID: modelID, modelVersion: modelVersion, into: rowStore)
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
            // provider that never did). Clear term rows in BOTH layouts so
            // the blob is unambiguously the whole truth for this key.
            try await deleteVocab(
                modelID: modelID, modelVersion: modelVersion, into: rowStore)
            try await deleteTermPayloads(modelID: modelID, into: rowStore)
        }
    }

    /// Restore `provider`'s maintained counts, preferring term rows and
    /// falling back to the legacy single blob.
    ///
    /// The preference order is, in sequence:
    ///   1. Migration invalidation sentinel — returns false immediately.
    ///   2. v4 integer-keyed term rows — the current layout for new writes.
    ///   3. v3 term rows — upgraded estates not yet re-persisted in v4.
    ///   4. Legacy single blob — estates predating the term table.
    ///
    /// The fallback chain is what lets an upgraded estate keep working untouched:
    /// no bulk migration runs, the blob is read exactly as before, and the
    /// provider converts to term rows on its next persist.
    ///
    /// A non-empty but undecodable blob still throws — real corruption must
    /// fail loudly rather than converting to a silent sentinel.
    ///
    /// - Returns: `false` when no row exists for this provider key (start from
    ///   zero), or when the stored row carries the migration invalidation sentinel
    ///   (rebuild from scratch is required). Returns `true` when counts were
    ///   successfully restored into `provider`.
    @discardableResult
    public func restoreCounts(
        into provider: any TrainableEmbeddingBasis,
        modelID: String,
        modelVersion: String
    ) async throws -> Bool {
        guard let persisted = try await load(modelID: modelID, modelVersion: modelVersion) else {
            return false
        }
        // Sentinel intercept: placed before the v4 branch because the upgrade step
        // does NOT delete the v4 term-dictionary or term-payload rows — they can
        // outlive the invalidated blob. Without this check the v4 branch would
        // attempt to pass an empty header to the provider's `expectMagic`, which
        // throws "truncated blob reading magic". Returning false here lets the
        // caller route to a full corpus retrain as the migration intended.
        if Self.isInvalidatedCounts(persisted.counts) {
            return false
        }
        // Format-version gate: a counts blob written by another codec generation
        // for this provider (same magic, other version byte) cannot be restored —
        // its layout is not the one `provider` reads. Treat it exactly like the
        // sentinel: "no usable counts, rebuild from the corpus". The caller's
        // corpus-path retrain then re-persists counts in the current format.
        // `provider` is a freshly constructed instance by contract (every caller
        // reconstructs one from the empty factory blob before restoring into it),
        // so its `serializeCounts()` is the small header-only frame to compare.
        if BasisBlobFrame.isStaleVersion(persisted: persisted.counts, current: provider.serializeCounts()) {
            countsLog.error(
                "counts for \(modelID, privacy: .public)@\(modelVersion, privacy: .public) are format v\(BasisBlobFrame.formatVersion(of: persisted.counts) ?? 0, privacy: .public); this build writes v\(BasisBlobFrame.formatVersion(of: provider.serializeCounts()) ?? 0, privacy: .public). Treating as no counts; the corpus-path retrain rebuilds them.")
            return false
        }
        // Preference order: v4 integer-keyed pair → v3 term rows → legacy
        // blob. Each earlier layout being empty means "not written in that
        // layout yet", never "empty vocabulary" — the fallbacks are what let
        // an un-upgraded estate keep working untouched.
        let v4Terms = try await loadTermPayloads(modelID: modelID)
        if !v4Terms.isEmpty {
            try provider.restoreCounts(header: persisted.counts, terms: v4Terms)
            return true
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

    // MARK: - Integer-keyed term pair (v4, CORPUS-COUNTS-01)

    /// Replace the stored per-term payloads for a model with `terms`,
    /// maintaining the term dictionary (string stored once, bitmask updated).
    /// Terms absent from the incoming set have this model's bit cleared in
    /// their dictionary row; rows whose bitmask reaches zero are deleted so
    /// content that has been removed from the corpus does not persist in the
    /// estate through its derived term text.
    ///
    /// Term ids are allocated explicitly as max(term_id)+n — deterministic,
    /// port-parallel, and independent of any driver's last-insert-rowid
    /// surface. The whole dictionary is loaded once (it is small by design)
    /// so the per-term work is in-memory; writes are one upsert per NEW or
    /// bit-changed dictionary row plus one payload upsert per term — no
    /// single bind scales with vocabulary.
    public func replaceTermPayloads(
        modelID: String,
        terms: [(term: String, vector: Data)],
        into rowStore: any RowStore
    ) async throws {
        let model = try Self.modelInt(for: modelID)
        let bit = Int64(1) << Int64(model)

        // Load the dictionary once: term → (term_id, models bitmask).
        var dict: [String: (id: Int64, models: Int64)] = [:]
        var maxID: Int64 = 0
        let dictRows = try await rowStore.query(
            table: "corpus_provider_term_dictionary",
            where: .isTrue, orderBy: [], limit: nil, offset: nil)
        for row in dictRows {
            guard case let .int(id) = row["term_id"] ?? .null,
                  case let .text(term) = row["term"] ?? .null,
                  case let .int(models) = row["models"] ?? .null
            else { continue }
            dict[term] = (id: id, models: models)
            maxID = max(maxID, id)
        }

        // Replace this model's payload generation atomically with the caller's
        // row store (same delete-then-insert idiom as replaceVocab).
        _ = try await rowStore.delete(
            table: "corpus_provider_term_payload",
            where: .eq(Column(table: "corpus_provider_term_payload", name: "model_id"),
                       .int(Int64(model))))

        for entry in terms {
            let termID: Int64
            if let existing = dict[entry.term] {
                termID = existing.id
                if existing.models & bit == 0 {
                    _ = try await rowStore.upsert(
                        table: "corpus_provider_term_dictionary",
                        values: [
                            "term_id": .int(existing.id),
                            "term": .text(entry.term),
                            "models": .int(existing.models | bit)
                        ],
                        conflictColumns: ["term_id"])
                    dict[entry.term] = (id: existing.id, models: existing.models | bit)
                }
            } else {
                maxID += 1
                termID = maxID
                _ = try await rowStore.upsert(
                    table: "corpus_provider_term_dictionary",
                    values: [
                        "term_id": .int(termID),
                        "term": .text(entry.term),
                        "models": .int(bit)
                    ],
                    conflictColumns: ["term_id"])
                dict[entry.term] = (id: termID, models: bit)
            }
            _ = try await rowStore.upsert(
                table: "corpus_provider_term_payload",
                values: [
                    "model_id": .int(Int64(model)),
                    "term_id": .int(termID),
                    "vector": .blob(entry.vector)
                ],
                conflictColumns: ["model_id", "term_id"])
        }

        // Clear this model's bit from every dictionary entry whose term is absent
        // from the incoming set. The payload delete above removes payload rows for
        // dropped terms; this step ensures the dictionary also forgets them.
        //
        // A dictionary row carries the term text of the corpus content that introduced
        // it. Leaving the model's bit set after that content is deleted would mean the
        // content's tokens remain reachable through derived structure. The guarantee is
        // that deleted content is not reachable through any derived structure.
        //
        // The cleanup runs after the id-allocation loop. The maxID high-water mark is
        // already final, so no id allocated within this call is reassigned during cleanup.
        //
        // Legacy-estate note: an estate written before this change may carry over-claimed
        // bits (model bit set with no corresponding payload row). The first post-fix write
        // for a given model repairs that model's bits across the dictionary. Bits belonging
        // to a model that never writes again remain set, keeping those rows alive —
        // conservative, because no row is deleted while any model might still reference it.
        // Ordered by term id so the emitted write sequence is a function of the
        // stored state alone — dictionary iteration order is not, and both ports
        // must be able to produce the same sequence for the same estate.
        let incomingTerms: Set<String> = Set(terms.map(\.term))
        let staleEntries = dict
            .filter { $0.value.models & bit != 0 && !incomingTerms.contains($0.key) }
            .sorted { $0.value.id < $1.value.id }
        for (term, entry) in staleEntries {
            let clearedModels = entry.models & ~bit
            if clearedModels == 0 {
                // No model claims this term any longer. Delete the row: the term text
                // belongs to content that is no longer in the corpus.
                // Term-id reuse is safe under the corrected invariant: models == 0
                // holds only when no payload row anywhere references this term_id.
                _ = try await rowStore.delete(
                    table: "corpus_provider_term_dictionary",
                    where: .eq(Column(table: "corpus_provider_term_dictionary", name: "term_id"),
                               .int(entry.id)))
            } else {
                // At least one other model still claims this term. Clear only this
                // model's bit, leaving the row for those other models.
                _ = try await rowStore.upsert(
                    table: "corpus_provider_term_dictionary",
                    values: [
                        "term_id": .int(entry.id),
                        "term": .text(term),
                        "models": .int(clearedModels)
                    ],
                    conflictColumns: ["term_id"])
            }
        }
    }

    /// Every stored term/vector pair for a model from the v4 integer-keyed
    /// pair. EMPTY both when the model has no v4 rows and when the estate
    /// predates v4 — callers treat empty as "fall back to v3 rows / blob",
    /// never as "the vocabulary is empty".
    public func loadTermPayloads(
        modelID: String
    ) async throws -> [(term: String, vector: Data)] {
        guard let model = Self.modelRegistry[modelID] else { return [] }
        let payloadRows = try await storage.rowStore.query(
            table: "corpus_provider_term_payload",
            where: .eq(Column(table: "corpus_provider_term_payload", name: "model_id"),
                       .int(Int64(model))),
            orderBy: [], limit: nil, offset: nil)
        guard !payloadRows.isEmpty else { return [] }

        // Join-free: dictionary filtered by this model's bit, id → term.
        var termByID: [Int64: String] = [:]
        let dictRows = try await storage.rowStore.query(
            table: "corpus_provider_term_dictionary",
            where: .isTrue, orderBy: [], limit: nil, offset: nil)
        let bit = Int64(1) << Int64(model)
        for row in dictRows {
            guard case let .int(id) = row["term_id"] ?? .null,
                  case let .text(term) = row["term"] ?? .null,
                  case let .int(models) = row["models"] ?? .null,
                  models & bit != 0
            else { continue }
            termByID[id] = term
        }

        return payloadRows.compactMap { row in
            guard case let .int(id) = row["term_id"] ?? .null,
                  case let .blob(vector) = row["vector"] ?? .null,
                  let term = termByID[id]
            else { return nil }
            return (term: term, vector: vector)
        }
    }

    /// Drop a model's v4 payload rows and remove its claim from the term dictionary.
    /// Dictionary rows whose bitmask reaches zero after the bit is cleared are deleted:
    /// a term row carries text from corpus content, and content that is gone must not
    /// remain reachable through any derived structure. Rows with a non-zero remaining
    /// bitmask are updated in place — those terms are still claimed by at least one
    /// other model.
    public func deleteTermPayloads(
        modelID: String, into rowStore: any RowStore
    ) async throws {
        guard let model = Self.modelRegistry[modelID] else { return }
        let bit = Int64(1) << Int64(model)
        _ = try await rowStore.delete(
            table: "corpus_provider_term_payload",
            where: .eq(Column(table: "corpus_provider_term_payload", name: "model_id"),
                       .int(Int64(model))))
        let dictRows = try await rowStore.query(
            table: "corpus_provider_term_dictionary",
            where: .isTrue, orderBy: [], limit: nil, offset: nil)
        for row in dictRows {
            guard case let .int(id) = row["term_id"] ?? .null,
                  case let .text(term) = row["term"] ?? .null,
                  case let .int(models) = row["models"] ?? .null,
                  models & bit != 0
            else { continue }
            let clearedModels = models & ~bit
            if clearedModels == 0 {
                // No model claims this term any longer. Delete the row: the term
                // text belongs to content that is no longer in the corpus, and
                // deleted content must not remain reachable through any derived structure.
                _ = try await rowStore.delete(
                    table: "corpus_provider_term_dictionary",
                    where: .eq(Column(table: "corpus_provider_term_dictionary", name: "term_id"),
                               .int(id)))
            } else {
                // At least one other model still claims this term. Clear only this
                // model's bit and update the row in place.
                _ = try await rowStore.upsert(
                    table: "corpus_provider_term_dictionary",
                    values: [
                        "term_id": .int(id),
                        "term": .text(term),
                        "models": .int(clearedModels)
                    ],
                    conflictColumns: ["term_id"])
            }
        }
    }

    /// Load the full persisted counts for a provider key, or nil if none.
    public func load(modelID: String, modelVersion: String) async throws -> PersistedCounts? {
        try await load(modelID: modelID, modelVersion: modelVersion, from: storage.rowStore)
    }

    /// Query `corpus_provider_counts` through a caller-supplied row store and
    /// return the decoded row, or nil when no row exists for this key.
    ///
    /// Both the public `load` and the flush guard in `persistCounts` share this
    /// single query definition. `load` passes `storage.rowStore` for standalone
    /// reads. The flush guard passes the caller's transaction row store so the
    /// precondition check reads the same transactional view the write will land
    /// in — writes made earlier in that transaction are visible to the check.
    private func load(
        modelID: String,
        modelVersion: String,
        from rowStore: any RowStore
    ) async throws -> PersistedCounts? {
        let rows = try await rowStore.query(
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
        // ALL term tables — v3 vocab AND the v4 dictionary/payload pair — are
        // this store's state, so a wholesale clear must include every one.
        // Missing any would leave a previous generation's vocabulary behind
        // after destroyRecallIndex or the shared-content migration's
        // derived-state wipe — worse for the v4 pair, which the restore path
        // PREFERS over the blob.
        _ = try await storage.rowStore.delete(
            table: "corpus_provider_vocab",
            where: .isTrue
        )
        _ = try await storage.rowStore.delete(
            table: "corpus_provider_term_dictionary",
            where: .isTrue
        )
        _ = try await storage.rowStore.delete(
            table: "corpus_provider_term_payload",
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
