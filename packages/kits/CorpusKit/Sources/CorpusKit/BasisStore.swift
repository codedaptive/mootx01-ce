// BasisStore.swift
//
// Persistence for a trained embedding provider's serialized basis blob
// (mission 6a-ii-β). The "trained brain" of a distributional provider
// (RI/PPMI/LSA/NMF) is a versioned byte blob produced by the 6a-i codec
// via `TrainableEmbeddingBasis.serializeBasis()`. This store persists that
// blob so the dense lane is trained-ready immediately after a process
// restart, without re-running training on every open.
//
// Schema (single table, one row per (modelID, modelVersion)):
//   corpus_provider_basis (
//     model_id            TEXT NOT NULL,
//     model_version       TEXT NOT NULL,
//     basis               BLOB NOT NULL,
//     trained_at          TEXT NOT NULL,   -- ISO8601, never REAL
//     trained_chunk_count INTEGER NOT NULL -- chunks the basis was trained on
//   )  PRIMARY KEY (model_id, model_version)
//
// ## Why each column
//
//   - model_id / model_version: the basis is only valid for the exact
//     provider it was trained for. A blob trained under "corpus-ri-v1"
//     must never be loaded into a provider keyed "corpus-ppmi-v1" — the
//     codec magic would reject it, but keying the row by (modelID,
//     modelVersion) makes the load query unambiguous and matches the same
//     (modelID, modelVersion) tuple every vector row is keyed under.
//   - basis: the 6a-i serialized blob. BLOB (not TEXT) because it is raw
//     little-endian bytes, not text; storing it as TEXT would force a
//     lossy/avoidable encoding round-trip.
//   - trained_at: WHEN the basis was last (re)trained. TEXT ISO8601 per the
//     schema invariant (human readability, string sortability, timezone
//     correctness) — NEVER REAL/Unix-timestamp. Determinism: the value is
//     the `now` the caller passed into `reindex`/`ingest`, never `Date()`.
//   - trained_chunk_count: how many chunks the basis was trained on. This is
//     the staleness anchor for the DOCUMENTED FOLLOW-UP growth-threshold
//     auto-retrain knob (β scope deliberately stops at first-ingest +
//     explicit reindex). `reindex` records the current count; a future
//     policy can compare it against the live chunk count to decide whether a
//     retrain is warranted. INTEGER, not a Bool flag — there are no Bool
//     stored columns in this schema (schema-invariants rule).
//
// The table is NOT append-only: `reindex` UPSERTs the basis row in place
// when a trainable provider is retrained, so a (modelID, modelVersion)
// always resolves to the single newest basis. There is therefore exactly
// one basis row per provider key — no row accumulation, no orphans.
//
// Layering: this store lives in CorpusKit core and depends only on
// PersistenceKit + SubstrateTypes, exactly like BundleStore. It never
// imports CorpusKitProviders — the blob bytes are opaque here; only the
// trainable provider (reached through the TrainableEmbeddingBasis seam)
// interprets them.

import Foundation
import PersistenceKit
import SubstrateTypes

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. The basis blob is produced
// by the 6a-i codec via the TrainableEmbeddingBasis seam; this store
// only persists and returns the opaque bytes. It computes nothing.
// ─────────────────────────────────────────────────────────────────

/// A persisted trained-basis row: the serialized blob plus the metadata that
/// keys and dates it.
public struct PersistedBasis: Sendable, Equatable {
    /// The provider modelID the basis was trained for.
    public let modelID: String
    /// The provider modelVersion the basis was trained for.
    public let modelVersion: String
    /// The 6a-i serialized basis blob.
    public let basis: Data
    /// When the basis was last (re)trained (the `now` passed by the caller).
    public let trainedAt: Date
    /// How many chunks the basis was trained on (staleness anchor).
    public let trainedChunkCount: Int

    public init(modelID: String,
                modelVersion: String,
                basis: Data,
                trainedAt: Date,
                trainedChunkCount: Int) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.basis = basis
        self.trainedAt = trainedAt
        self.trainedChunkCount = trainedChunkCount
    }
}

/// Storage for a trained embedding provider's serialized basis blob.
///
/// One row per (modelID, modelVersion). `upsert` writes/replaces the row;
/// `load` reads it back; `deleteAll` wipes every basis row as part of
/// `Corpus.destroyRecallIndex()`. The store interprets none of the bytes —
/// only the trainable provider does, via the TrainableEmbeddingBasis seam.
public actor BasisStore {

    let storage: any Storage

    /// Additive schema declaration for the basis-persistence table.
    ///
    /// Mirrors BundleStore/VectorStore's declaration pattern. `appendOnly` is
    /// false: a retrain UPSERTs the existing (modelID, modelVersion) row, so
    /// the table holds at most one basis per provider key.
    ///
    /// v2 adds the nullable `.json` `ext` forward-compat slot (ADR-012):
    /// reserves the slot for future per-basis typed metadata (training
    /// hyperparameters, provenance) without a migration. 1.0 writes NULL /
    /// omits it on upsert and never reads it.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitBasis",
        version: 2,
        tables: [
            TableDeclaration(
                name: "corpus_provider_basis",
                columns: [
                    .text("model_id", nullable: false),
                    .text("model_version", nullable: false),
                    // BLOB: the raw little-endian 6a-i basis bytes.
                    .blob("basis", nullable: false),
                    // TIMESTAMP maps to TEXT ISO8601 (schema invariant) — never REAL.
                    .timestamp("trained_at", nullable: false),
                    // INTEGER staleness anchor — NOT a Bool flag.
                    .int("trained_chunk_count", nullable: false),
                    // ADR-012 forward-compat slot. Nullable `.json`, present
                    // from schema v2. Reserves the slot, not a shape. 1.0 omits
                    // it on upsert and never reads it.
                    .json("ext", nullable: true)
                ],
                primaryKey: ["model_id", "model_version"]
                // appendOnly defaults to false: a retrain UPSERTs the row in place.
            )
        ],
        indices: []
    )

    public init(storage: any Storage) {
        self.storage = storage
    }

    /// Insert or replace the basis row for a provider key.
    ///
    /// Keyed by the composite primary key (model_id, model_version): a
    /// retrain replaces the prior basis in place rather than accumulating
    /// rows. The `trainedAt` value is the caller's `now` (determinism) and
    /// `trainedChunkCount` is the chunk count the basis was trained on.
    ///
    /// - Parameter row: the basis row to persist.
    public func upsert(_ row: PersistedBasis) async throws {
        let values: [String: TypedValue] = [
            "model_id": .text(row.modelID),
            "model_version": .text(row.modelVersion),
            "basis": .blob(row.basis),
            "trained_at": .timestamp(row.trainedAt),
            "trained_chunk_count": .int(Int64(row.trainedChunkCount))
        ]
        // ON CONFLICT (model_id, model_version) DO UPDATE: upsert replaces the
        // non-conflict columns (basis, trained_at, trained_chunk_count) of the
        // existing row for the same provider key, so a retrain overwrites the
        // prior basis in place rather than accumulating rows.
        _ = try await storage.rowStore.upsert(
            table: "corpus_provider_basis",
            values: values,
            conflictColumns: ["model_id", "model_version"]
        )
    }

    /// Load the persisted basis for a provider key, or nil if none is stored.
    ///
    /// - Parameters:
    ///   - modelID: the provider modelID.
    ///   - modelVersion: the provider modelVersion.
    /// - Returns: the persisted basis row, or nil when no basis has been
    ///   trained+persisted for this provider key yet.
    public func load(modelID: String, modelVersion: String) async throws -> PersistedBasis? {
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_basis",
            where: .and([
                .eq(Column(table: "corpus_provider_basis", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_basis", name: "model_version"), .text(modelVersion))
            ]),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first else { return nil }
        return Self.decode(row)
    }

    /// Delete every basis row. Used by `Corpus.destroyRecallIndex()` so a
    /// destroyed corpus leaves no orphaned trained basis behind. `.isTrue` is
    /// the always-match predicate (delete requires a non-optional predicate).
    public func deleteAll() async throws {
        _ = try await storage.rowStore.delete(
            table: "corpus_provider_basis",
            where: .isTrue
        )
    }

    // MARK: - Decode

    /// Decode a basis row, tolerant of BOTH the semantic TypedValue forms the
    /// InMemory backend preserves AND the primitive forms the SQLite backend
    /// hands back on read. This is the same primitive-tolerance discipline
    /// BundleStore.decodeChunk uses: a semantic-only reader silently drops every
    /// persisted row on reopen (the SQLite backend returns a TIMESTAMP column as
    /// `.text` ISO8601, not `.timestamp`), so semantic recall would go dark on
    /// any restored estate. Per-column tolerance:
    ///   - model_id / model_version: `.text` on both backends.
    ///   - basis: `.blob` on both backends (a BLOB column).
    ///   - trained_at: `.timestamp` (InMemory) or `.text` ISO8601 (SQLite,
    ///     where a TIMESTAMP column is physically TEXT). Parsed via `decodeDate`.
    ///   - trained_chunk_count: `.int` on both backends.
    /// A row that fails any field match yields nil rather than a fabricated basis.
    static func decode(_ row: StorageRow) -> PersistedBasis? {
        guard case let .text(modelID) = row["model_id"] ?? .null,
              case let .text(modelVersion) = row["model_version"] ?? .null,
              case let .blob(basis) = row["basis"] ?? .null,
              let trainedAt = decodeDate(row["trained_at"]),
              case let .int(chunkCount) = row["trained_chunk_count"] ?? .null else {
            return nil
        }
        return PersistedBasis(
            modelID: modelID,
            modelVersion: modelVersion,
            basis: basis,
            trainedAt: trainedAt,
            trainedChunkCount: Int(chunkCount)
        )
    }

    /// Decode the trained_at column to a Date, tolerant of `.timestamp` (the
    /// InMemory backend) and `.text` (the SQLite backend, where a TIMESTAMP
    /// column is physically TEXT ISO8601 and round-trips as a string). The
    /// SQLite backend writes the fractional-second form ("...:SS.sssZ"), so the
    /// fractional-seconds parser is tried first, then the plain whole-second
    /// form. The formatters are constructed locally (Swift 6 strict concurrency
    /// disallows shared non-Sendable global formatters); this is not a hot path
    /// — `load` is called on corpus open and after each reindex only.
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
