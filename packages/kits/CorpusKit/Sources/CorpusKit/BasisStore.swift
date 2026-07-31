// BasisStore.swift
//
// Persistence for a trained embedding provider's serialized basis blob
// (mission 6a-ii-β). The "trained brain" of a distributional provider
// (RI/PPMI/LSA/NMF) is a versioned byte blob produced by the 6a-i codec
// via `TrainableEmbeddingBasis.serializeBasis()`. This store persists that
// blob so the dense lane is trained-ready immediately after a process
// restart, without re-running training on every open.
//
// Schema (single table, one row per (modelID, modelVersion, partIndex)):
//   corpus_provider_basis (
//     model_id            TEXT NOT NULL,
//     model_version       TEXT NOT NULL,
//     part_index          INTEGER NOT NULL DEFAULT 0,  -- chunk sequence number
//     basis               BLOB NOT NULL,              -- chunk bytes
//     trained_at          TEXT NOT NULL,              -- ISO8601, never REAL
//     trained_chunk_count INTEGER NOT NULL            -- chunks the basis was trained on
//   )  PRIMARY KEY (model_id, model_version, part_index)
//
// ## Why chunked storage
//
//   SQLite's SQLITE_LIMIT_LENGTH caps a single bound value at ~1 GB. A
//   large-vocabulary (≥122 k term) corpus produces a basis blob that
//   approaches or exceeds this cap. Binding one giant blob to
//   sqlite3_bind_blob therefore fails with SQLITE_TOOBIG, which surfaces
//   as `backendError("bind blob")`. Chunking splits the blob into parts
//   of at most `chunkSizeLimit` bytes before storage and reassembles them
//   on load. Part identity is carried by `part_index` (0-based), which is
//   also the third component of the composite primary key.
//
// ## Why each column
//
//   - model_id / model_version: the basis is only valid for the exact
//     provider it was trained for. A blob trained under "corpus-ri-v1"
//     must never be loaded into a provider keyed "corpus-ppmi-v1" — the
//     codec magic would reject it, but keying the row by (modelID,
//     modelVersion) makes the load query unambiguous and matches the same
//     (modelID, modelVersion) tuple every vector row is keyed under.
//   - part_index: 0-based chunk sequence number. All parts for the same
//     provider key are loaded in ascending part_index order and
//     concatenated. A single-chunk basis has exactly one row at index 0.
//   - basis: one chunk of the 6a-i serialized blob. BLOB (not TEXT) because
//     it is raw little-endian bytes; TEXT would force a lossy/avoidable
//     encoding round-trip.
//   - trained_at: WHEN the basis was last (re)trained. TEXT ISO8601 per the
//     schema invariant (human readability, string sortability, timezone
//     correctness) — NEVER REAL/Unix-timestamp. Determinism: the value is
//     the `now` the caller passed into `reindex`/`ingest`, never `Date()`.
//     Stored identically on every part row for a given provider key.
//   - trained_chunk_count: how many chunks the basis was trained on. This is
//     the staleness anchor for the DOCUMENTED FOLLOW-UP growth-threshold
//     auto-retrain knob (β scope deliberately stops at first-ingest +
//     explicit reindex). `reindex` records the current count; a future
//     policy can compare it against the live chunk count to decide whether a
//     retrain is warranted. INTEGER, not a Bool flag — there are no Bool
//     stored columns in this schema (schema-invariants rule). Stored
//     identically on every part row for a given provider key.
//
// ## Write path
//
//   `upsert` deletes all existing part rows for the provider key, then
//   inserts fresh part rows for each chunk — all within one serializable
//   transaction. This delete-then-insert pattern ensures:
//   (a) No orphaned part rows from a prior basis persist on retrain.
//   (b) The new basis becomes visible atomically (no torn read of a
//       mixed old/new basis).
//
// ## Read path
//
//   `load` queries all rows for (model_id, model_version) ordered by
//   part_index ascending and concatenates the `basis` columns. Metadata
//   (trained_at, trained_chunk_count) is read from the first part row.
//
// ## Schema history
//
//   v2: single-blob row; PRIMARY KEY (model_id, model_version). Added
//       nullable ext JSON column for forward-compat.
//   v3: adds part_index; PRIMARY KEY becomes (model_id, model_version,
//       part_index). Removes the 1 GB single-bind ceiling (ee#49).
//       NO DATA EXISTS TO MIGRATE — the v2→v3 migration is present for
//       schema protocol correctness only and will never run on a real estate.
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
    /// The 6a-i serialized basis blob (all parts reassembled into one Data).
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
/// Blobs are split into parts of at most `chunkByteLimit` bytes to avoid
/// SQLite's `SQLITE_LIMIT_LENGTH` ceiling (~1 GB per bound value). Each part
/// is one row; `load` reassembles them in `part_index` order.
///
/// One logical basis per (modelID, modelVersion). `upsert` writes/replaces
/// all parts; `load` reads them back reassembled; `deleteAll` wipes every
/// basis row as part of `Corpus.destroyRecallIndex()`. The store interprets
/// none of the bytes — only the trainable provider does, via the
/// TrainableEmbeddingBasis seam.
public actor BasisStore {

    /// Maximum bytes per storage part. 256 MB keeps each SQLite bind well
    /// below the 1 GB SQLITE_LIMIT_LENGTH ceiling even after WAL overhead.
    /// Overridden at init for test seaming (pass a small value to exercise
    /// the multi-part path without allocating a real 256 MB blob).
    public static let chunkSizeLimit: Int = 256 * 1024 * 1024

    let storage: any Storage
    /// Per-instance chunk ceiling. Defaults to `chunkSizeLimit`; tests pass a
    /// small value (e.g. 64 bytes) to exercise multi-part paths cheaply.
    let chunkByteLimit: Int

    /// Additive schema declaration for the basis-persistence table.
    ///
    /// v3 adds `part_index` as the third component of the primary key,
    /// lifting the single-blob 1 GB ceiling by chunking large bases into
    /// multiple rows (ee#49). Schema history: v2 = single-blob, v3 = chunked.
    ///
    /// The v2→v3 migration is present for schema protocol correctness. It adds
    /// the `part_index` column but cannot change the PK constraint in SQLite
    /// (ALTER TABLE does not support PK changes). Since NO DATA EXISTS TO
    /// MIGRATE, this limitation is immaterial — all real estates are created
    /// fresh at v3 and always have the 3-column PK.
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "CorpusKitBasis",
        version: 3,
        tables: [
            TableDeclaration(
                name: "corpus_provider_basis",
                columns: [
                    .text("model_id", nullable: false),
                    .text("model_version", nullable: false),
                    // 0-based chunk sequence number. All rows for the same
                    // (model_id, model_version) are loaded in this order and
                    // concatenated to reconstruct the full basis blob.
                    ColumnDeclaration(name: "part_index", type: .int, nullable: false, defaultValue: .int(0)),
                    // BLOB: one chunk of the raw little-endian 6a-i basis bytes.
                    .blob("basis", nullable: false),
                    // TIMESTAMP maps to TEXT ISO8601 (schema invariant) — never REAL.
                    // Stored identically on every part row for the same provider key.
                    .timestamp("trained_at", nullable: false),
                    // INTEGER staleness anchor — NOT a Bool flag.
                    // Stored identically on every part row for the same provider key.
                    .int("trained_chunk_count", nullable: false),
                    // Nullable forward-compat JSON slot (introduced in v2). 1.0 omits
                    // it on upsert and never reads it.
                    .json("ext", nullable: true)
                ],
                primaryKey: ["model_id", "model_version", "part_index"]
                // appendOnly defaults to false: a retrain replaces all parts.
            )
        ],
        indices: [],
        migrations: [
            // v2 → v3: add the part_index column (default 0 preserves existing
            // single-blob rows as part 0 of a 1-part basis). The PK constraint
            // cannot be changed via ALTER TABLE in SQLite; since NO DATA EXISTS
            // TO MIGRATE this is acceptable — all real estates start at v3.
            Migration(
                fromVersion: 2,
                toVersion: 3,
                operations: [
                    .addColumn(
                        table: "corpus_provider_basis",
                        column: ColumnDeclaration(name: "part_index", type: .int, nullable: false, defaultValue: .int(0))
                    )
                ]
            )
        ]
    )

    /// Create a BasisStore backed by `storage`.
    ///
    /// - Parameters:
    ///   - storage: the PersistenceKit storage backend.
    ///   - chunkByteLimit: maximum bytes per storage part. Defaults to
    ///     `BasisStore.chunkSizeLimit` (256 MB). Pass a smaller value in
    ///     tests to exercise the multi-part path without a large allocation.
    public init(storage: any Storage, chunkByteLimit: Int = BasisStore.chunkSizeLimit) {
        self.storage = storage
        self.chunkByteLimit = chunkByteLimit
    }

    /// Insert or replace the basis for a provider key.
    ///
    /// The blob is split into chunks of at most `chunkByteLimit` bytes. All
    /// existing parts for (modelID, modelVersion) are deleted, then fresh parts
    /// are inserted — within a single serializable transaction so the basis
    /// becomes visible atomically.
    ///
    /// - Parameter row: the basis row to persist.
    public func upsert(_ row: PersistedBasis) async throws {
        let limit = chunkByteLimit
        try await storage.transaction(isolation: .serializable) { txn in
            try await BasisStore.writePartsInto(txn.rowStore, row: row, chunkByteLimit: limit)
        }
    }

    /// Transaction-scoped variant: write through the CALLER'S row store so the
    /// basis parts commit atomically with sibling writes (e.g. the corrective
    /// pass's basis+counts atomic commit). The caller is responsible for
    /// transaction scoping.
    public func upsert(_ row: PersistedBasis, into rowStore: any RowStore) async throws {
        try await BasisStore.writePartsInto(rowStore, row: row, chunkByteLimit: chunkByteLimit)
    }

    /// Load the persisted basis for a provider key, or nil if none is stored.
    ///
    /// Queries all part rows in part_index order and concatenates their `basis`
    /// columns. Metadata (trained_at, trained_chunk_count) is taken from the
    /// first part row — all parts carry identical metadata.
    ///
    /// - Parameters:
    ///   - modelID: the provider modelID.
    ///   - modelVersion: the provider modelVersion.
    /// - Returns: the reassembled basis, or nil when no basis has been
    ///   trained+persisted for this provider key yet.
    public func load(modelID: String, modelVersion: String) async throws -> PersistedBasis? {
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_basis",
            where: .and([
                .eq(Column(table: "corpus_provider_basis", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_basis", name: "model_version"), .text(modelVersion))
            ]),
            orderBy: [OrderClause(column: Column(table: "corpus_provider_basis", name: "part_index"), direction: .ascending)],
            limit: nil,
            offset: nil
        )
        guard let firstRow = rows.first else { return nil }

        // Read metadata from the first part row (all parts carry the same values).
        guard case let .text(storedModelID) = firstRow["model_id"] ?? .null,
              case let .text(storedModelVersion) = firstRow["model_version"] ?? .null,
              let trainedAt = Self.decodeDate(firstRow["trained_at"]),
              case let .int(chunkCount) = firstRow["trained_chunk_count"] ?? .null else {
            // A row that fails any required field is a data-integrity failure —
            // return nil rather than fabricating a basis.
            return nil
        }

        // Concatenate all part blobs in ascending part_index order.
        var assembled = Data()
        for row in rows {
            guard case let .blob(partData) = row["basis"] ?? .null else {
                // A missing or malformed basis column on any part is a
                // data-integrity failure — the basis would be truncated.
                return nil
            }
            assembled.append(partData)
        }

        return PersistedBasis(
            modelID: storedModelID,
            modelVersion: storedModelVersion,
            basis: assembled,
            trainedAt: trainedAt,
            trainedChunkCount: Int(chunkCount)
        )
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

    // MARK: - Private helpers

    /// Delete all existing part rows for a provider key, then insert fresh parts.
    ///
    /// Extracted as a static helper so both the transaction-wrapping `upsert(_:)`
    /// and the caller-scoped `upsert(_:into:)` share the same logic without
    /// capturing `self`.
    ///
    /// - Parameters:
    ///   - rowStore: the row store to write through (transaction-scoped by caller).
    ///   - row: the basis row to persist.
    ///   - chunkByteLimit: maximum bytes per part.
    private static func writePartsInto(
        _ rowStore: any RowStore,
        row: PersistedBasis,
        chunkByteLimit: Int
    ) async throws {
        let keyPredicate = StoragePredicate.and([
            .eq(Column(table: "corpus_provider_basis", name: "model_id"), .text(row.modelID)),
            .eq(Column(table: "corpus_provider_basis", name: "model_version"), .text(row.modelVersion))
        ])

        // Delete all existing parts for this provider key before inserting the
        // new ones. This is the "upsert by replace" pattern: since the new basis
        // may have a different number of parts than the old one, a targeted
        // upsert on part_index would leave orphaned parts from the old basis.
        _ = try await rowStore.delete(table: "corpus_provider_basis", where: keyPredicate)

        // Split the basis blob into parts of at most chunkByteLimit bytes.
        // A basis that fits within the limit is stored as a single part (index 0).
        let chunks = row.basis.chunks(ofSize: chunkByteLimit)
        for (index, chunk) in chunks.enumerated() {
            // Each part carries the full metadata so that a load from any
            // contiguous prefix is unambiguous (though a load always reads all parts).
            _ = try await rowStore.insert(
                table: "corpus_provider_basis",
                values: [
                    "model_id": .text(row.modelID),
                    "model_version": .text(row.modelVersion),
                    "part_index": .int(Int64(index)),
                    "basis": .blob(chunk),
                    "trained_at": .timestamp(row.trainedAt),
                    "trained_chunk_count": .int(Int64(row.trainedChunkCount))
                ]
            )
        }
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

// MARK: - Data chunking helper

private extension Data {
    /// Split the receiver into sequential slices of at most `size` bytes each.
    /// An empty Data yields a single empty slice (preserving the invariant that
    /// there is always at least one storage part per basis). A Data whose
    /// byte-count divides evenly produces exactly `count / size` slices;
    /// otherwise the final slice contains the remainder bytes.
    func chunks(ofSize size: Int) -> [Data] {
        precondition(size > 0, "chunk size must be positive")
        if isEmpty { return [Data()] }
        var result: [Data] = []
        var offset = startIndex
        while offset < endIndex {
            let end = index(offset, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(self[offset..<end])
            offset = end
        }
        return result
    }
}
