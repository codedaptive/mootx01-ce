// MatrixSnapshotStore.swift
//
// On-disk persistence for the matrix tier (F, C, O, T population statistics)
// plus its companion calibration registry, kept as a SQLite TABLE in the
// estate's own storage — never memory-only, never a sidecar file.
//
// ## Why this exists
//
// The matrix tier is a large derived accelerator: F/C/O/T counts folded from
// the whole unified audit log. Before this store, the only persistence option
// was a JSON sidecar file (MatrixPersistence's `.snapshotted(file:)` mode), and
// the launch path ignored it entirely — `rebuildDerivedAccelerators` ALWAYS did
// a full `fullRebuild` from the complete audit log on every cold start. On a
// 40k-drawer estate that full fold is a multi-minute single-threaded CPU pass
// (TemporalCausalityFold over the entire log) that starves the resident's
// cooperative executor and blocks the first MCP call.
//
// This store closes that gap the spec way: the tier is persisted to disk at an
// HLC watermark and, on launch, LOADED and folded forward over only the audit
// tail past the watermark (MatrixTier.incrementalUpdate) — proven cell-for-cell
// equal to a from-scratch rebuild by the conformance test in MatrixTierTests.
// A full rebuild is the cold-start / schema-mismatch fallback only.
//
// ## Schema (one row per estate)
//   matrix_snapshot (
//     estate_id      TEXT NOT NULL,    -- estate UUID; one snapshot per estate
//     schema_version INTEGER NOT NULL, -- MatrixSnapshot format gate (cheap read)
//     snapshot       BLOB NOT NULL,    -- JSON-encoded MatrixSnapshot
//     last_hlc       TEXT NOT NULL,    -- F/O/C cursor watermark (human-readable)
//     updated_at     TEXT NOT NULL,    -- ISO8601 (schema invariant); never REAL
//     ext            JSON NULL         -- ADR-012 forward-compat slot
//   )  PRIMARY KEY (estate_id)
//
// ## Why each column
//   - estate_id: one matrix snapshot per estate. The estate UUID keys it,
//     identically to how the manifest and every estate-scoped row key.
//   - schema_version: surfaced as its OWN column (not just inside the blob) so a
//     format change can be detected with a single cheap query and the row
//     rejected (→ caller does a full rebuild) WITHOUT deserializing the blob.
//     INTEGER, not a Bool — there are no Bool stored columns (schema-invariants).
//   - snapshot: the JSON-encoded MatrixSnapshot (tier + calibration + watermark).
//     BLOB because the matrix dictionaries serialize to a sizeable opaque
//     payload; the store interprets none of it.
//   - last_hlc: the F/O/C cursor (tier.lastHLC) rendered human-readable. A cheap
//     surface for diagnostics ("how far has the persisted matrix advanced?");
//     the authoritative cursor lives inside the blob.
//   - updated_at: WHEN the snapshot was last persisted (the caller's `now`).
//     TEXT ISO8601 per the schema invariant; never Date() in an engine.
//
// The table is NOT append-only: each save UPSERTs the estate's single row, so an
// estate always resolves to its one current matrix snapshot.
//
// Layering: GeniusLocusKit composition layer; depends only on PersistenceKit +
// SubstrateTypes, exactly like CorpusKit's BasisStore / CorpusProviderCountsStore.

import Foundation
import PersistenceKit
import SubstrateTypes
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// This store persists and returns a JSON-encoded MatrixSnapshot blob.
// It computes nothing — no folds, no rebuilds, no statistics. The
// matrix math lives in MatrixTier / SubstrateML.
// ─────────────────────────────────────────────────────────────────

/// SQLite-backed persistence for an estate's matrix tier snapshot.
///
/// One row per estate. `upsert` writes/replaces it; `load` reads and decodes the
/// snapshot (rejecting a schema-version mismatch by returning nil so the caller
/// falls back to a full rebuild); `deleteAll` wipes every row. The store
/// interprets none of the blob bytes.
public actor MatrixSnapshotStore {

    let storage: any Storage

    /// Additive schema declaration for the matrix-snapshot table, under its own
    /// kitID so it migrates independently of the GLK composite (the same pattern
    /// CorpusProviderCountsStore / RemovedSourceStore use). `appendOnly` is false:
    /// a save UPSERTs the estate's row, so the table holds at most one snapshot
    /// per estate. The `.json` `ext` slot is the ADR-012 forward-compat slot
    /// (written NULL / omitted in 1.0).
    public static let schemaDeclaration = SchemaDeclaration(
        kitID: "GeniusLocusKitMatrix",
        version: 1,
        tables: [
            TableDeclaration(
                name: "matrix_snapshot",
                columns: [
                    .text("estate_id", nullable: false),
                    // INTEGER format gate — NOT a Bool flag.
                    .int("schema_version", nullable: false),
                    // BLOB: the JSON-encoded MatrixSnapshot bytes.
                    .blob("snapshot", nullable: false),
                    // The F/O/C cursor, human-readable; diagnostics surface.
                    .text("last_hlc", nullable: false),
                    // TIMESTAMP maps to TEXT ISO8601 (schema invariant) — never REAL.
                    .timestamp("updated_at", nullable: false),
                    // ADR-012 forward-compat slot; nullable, omitted on upsert in 1.0.
                    .json("ext", nullable: true)
                ],
                primaryKey: ["estate_id"]
                // appendOnly defaults to false: a save UPSERTs the row in place.
            )
        ],
        indices: []
    )

    public init(storage: any Storage) {
        self.storage = storage
    }

    /// Insert or replace the matrix snapshot for an estate.
    ///
    /// Keyed by estate_id: a save replaces the prior snapshot in place rather than
    /// accumulating rows. `now` is the caller's clock (determinism — the engine
    /// never calls Date()).
    public func upsert(
        estateID: UUID,
        snapshot: MatrixSnapshot,
        now: Date
    ) async throws {
        let blob: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            blob = try encoder.encode(snapshot)
        } catch {
            throw MatrixPersistenceError.snapshotEncodeFailed(reason: "\(error)")
        }
        let values: [String: TypedValue] = [
            "estate_id": .text(estateID.uuidString),
            "schema_version": .int(Int64(snapshot.schemaVersion)),
            "snapshot": .blob(blob),
            "last_hlc": .text(Self.encodeHLC(snapshot.tier.lastHLC)),
            "updated_at": .timestamp(now)
        ]
        _ = try await storage.rowStore.upsert(
            table: "matrix_snapshot",
            values: values,
            conflictColumns: ["estate_id"]
        )
    }

    /// Load and decode the matrix snapshot for an estate, or nil if none exists
    /// or the persisted format does not match the current schema version.
    ///
    /// A schema-version mismatch returns nil (not an error): the snapshot is a
    /// rebuildable cache, so the caller simply falls back to a full rebuild. A
    /// blob that fails to decode likewise returns nil rather than throwing —
    /// fail-soft to a rebuild, never fabricate a partial tier.
    public func load(estateID: UUID) async throws -> MatrixSnapshot? {
        let rows = try await storage.rowStore.query(
            table: "matrix_snapshot",
            where: .eq(Column(table: "matrix_snapshot", name: "estate_id"),
                       .text(estateID.uuidString)),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first else { return nil }
        // Cheap gate first: reject a foreign schema version without decoding the
        // (potentially large) blob.
        guard case let .int(version) = row["schema_version"] ?? .null,
              Int(version) == MatrixSnapshot.currentSchemaVersion else {
            return nil
        }
        guard case let .blob(blob) = row["snapshot"] ?? .null else { return nil }
        do {
            let decoded = try JSONDecoder().decode(MatrixSnapshot.self, from: blob)
            // Defence in depth: the blob carries its own schemaVersion; if it
            // disagrees with the column, treat as stale and rebuild.
            guard decoded.schemaVersion == MatrixSnapshot.currentSchemaVersion
            else { return nil }
            return decoded
        } catch {
            return nil
        }
    }

    /// Delete every matrix snapshot row. Mirrors the other stores' `deleteAll`
    /// for teardown paths that wipe an estate's derived state.
    public func deleteAll() async throws {
        _ = try await storage.rowStore.delete(
            table: "matrix_snapshot",
            where: .isTrue
        )
    }

    // MARK: - HLC encoding (diagnostics column only)

    /// Render an HLC to the `last_hlc` diagnostics column. The authoritative
    /// cursor lives inside the JSON blob (`tier.lastHLC`); this is a
    /// human-readable mirror, so a compact stable form is sufficient.
    private static func encodeHLC(_ hlc: HLC) -> String {
        "\(hlc.physicalTime).\(hlc.logicalCount).\(hlc.nodeID)"
    }
}
