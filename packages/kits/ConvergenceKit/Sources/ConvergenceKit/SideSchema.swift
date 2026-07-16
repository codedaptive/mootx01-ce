// SideSchema.swift
//
// Single SchemaDeclaration authority for ALL ConvergenceKit side tables.
//
// WHY ONE DECLARATION:
// Side tables owned by ConvergenceKit use the _ck_* prefix and must share one
// SchemaDeclaration (kitID "ConvergenceKit", single version counter, additive
// migrations). Fragmenting across multiple SchemaDeclarations would require
// callers to know which version counter governs each table, creating an
// ordering hazard: two independent schemas could declare _ck_* tables whose
// version counters advance separately and whose cross-table invariants are
// invisible to the migration engine. One SchemaDeclaration, one counter, one
// ensure(storage:) call — the migration path is always unambiguous.
//
// Governance: each additional _ck_* table increments the version. Migrations
// are additive — a new table is added via Migration(fromVersion:toVersion:)
// with a .createTable operation. The `tables` array reflects the FULL schema
// at the current version; migrations fill in the delta for devices already at
// a prior version.
//
// Current side tables:
//   v1 — _ck_sync_meta    LWW row-HLC per-record metadata (CloudKit pull)
//   v2 — _ck_outbox       Durable outbound queue (R4, CVK-ICLOUD P1-M4)
// Planned additions in later missions:
//   v3 — _ck_change_token Persisted CloudKit server change token (R5)
//   v4 — _ck_device_identity Device-slot registry (N2)
//   v5 — _ck_pending_skew Schema-skew pending queue (R9)
//
// Call ensure(storage:) once per enable(); it is idempotent — all backends
// use IF NOT EXISTS semantics via migrate(to:).

import Foundation
import PersistenceKit

// MARK: - CKSideSchema

/// Namespace for ConvergenceKit's consolidated side-table schema.
///
/// Only `ensure(storage:)` and the table name constants are public; the full
/// `SchemaDeclaration` is internal — callers use the ensure function, not the
/// declaration directly.
public enum CKSideSchema {

    // MARK: - Table name constants

    /// Side table that persists per-row sync HLC for the `lastWriterWinsByHLC`
    /// conflict policy. The CloudKit pull path writes here after every winning
    /// apply so that the next inbound can compare HLCs without reading the
    /// application row itself.
    public static let syncMetaTable = "_ck_sync_meta"

    /// Durable outbound queue. Entries are appended by the observer and
    /// confirmed (deleted) by PushCycle only after the transport reports
    /// success. Process death or transport failure leaves entries here; they
    /// are drained on the next enable() and pushed in the next push cycle.
    public static let outboxTable = "_ck_outbox"

    // MARK: - Schema declaration (internal — callers use ensure)

    static let declaration: SchemaDeclaration = {
        let syncMetaDecl = TableDeclaration(
            name: syncMetaTable,
            columns: [
                ColumnDeclaration(name: "table_name",     type: .text, nullable: false),
                ColumnDeclaration(name: "primary_key",    type: .text, nullable: false),
                ColumnDeclaration(name: "sync_hlc",       type: .int,  nullable: false,
                                  defaultValue: .int(0)),
                ColumnDeclaration(name: "schema_version", type: .int,  nullable: false,
                                  defaultValue: .int(0)),
                // is_deleted: 1 when this entry records a delete tombstone HLC that
                // must outlive the row for A6 stale-resurrect protection. Used by
                // tombstone GC to identify entries eligible for compaction after
                // SyncTombstone.gcRetentionSeconds. Int, not Bool (schema invariants).
                ColumnDeclaration(name: "is_deleted",     type: .int,  nullable: false,
                                  defaultValue: .int(0)),
                ColumnDeclaration(name: "kit_id",         type: .text, nullable: false,
                                  defaultValue: .text("")),
            ],
            primaryKey: ["table_name", "primary_key"]
        )

        // _ck_outbox schema:
        //   id          — UUID primary key for per-record confirm().
        //   table_name  — application table the change belongs to.
        //   row_key     — UUID as TEXT (primary key of the application row).
        //   event       — change kind: "insert", "update", or "delete".
        //                 Stored as TEXT, not Bool, per schema invariant.
        //   values      — JSON-encoded SyncValueMap for insert/update; absent
        //                 (null) for delete events.
        //   hlc         — packed HLC (Int64, 48-bit physical | 12-bit logical |
        //                 4-bit node) used for coalescing: when two changes for
        //                 the same (table_name, row_key) are appended, only the
        //                 entry with the higher HLC survives.
        //   enqueued_at — ISO8601 wall-clock string for observability.
        let outboxDecl = TableDeclaration(
            name: outboxTable,
            columns: [
                ColumnDeclaration(name: "id",          type: .uuid, nullable: false),
                ColumnDeclaration(name: "table_name",  type: .text, nullable: false),
                ColumnDeclaration(name: "row_key",     type: .text, nullable: false),
                ColumnDeclaration(name: "event",       type: .text, nullable: false),
                ColumnDeclaration(name: "values",      type: .blob, nullable: true),
                ColumnDeclaration(name: "hlc",         type: .int,  nullable: false,
                                  defaultValue: .int(0)),
                ColumnDeclaration(name: "enqueued_at", type: .text, nullable: false),
            ],
            primaryKey: ["id"]
        )

        return SchemaDeclaration(
            kitID: "ConvergenceKit",
            version: 2,
            tables: [syncMetaDecl, outboxDecl],
            // Migration delta for devices already at v1 (initial "ConvergenceKit"
            // schema containing only _ck_sync_meta). The tables array handles the
            // v0 → v2 fresh-install path via IF NOT EXISTS creation.
            migrations: [
                Migration(fromVersion: 1, toVersion: 2, operations: [
                    .createTable(outboxDecl),
                ])
            ]
        )
    }()

    // MARK: - Public ensure

    /// Ensure all ConvergenceKit side tables exist on `storage`. Idempotent;
    /// safe to call on every enable(). Uses migrate(to:), which is additive
    /// (IF NOT EXISTS on all backends) and never replaces the application schema.
    public static func ensure(storage: any Storage) async throws {
        try await storage.migrate(to: declaration)
    }
}
