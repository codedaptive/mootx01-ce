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
// with a .createTable operation; new columns use .addColumn; new indices use
// .addIndex.
// The `tables` array reflects the FULL schema at the current version;
// the `indices` array declares ALL indices that must exist after ensure();
// migrations fill in the delta for devices already at a prior version.
//
// Current side tables:
//   v1 — _ck_sync_meta       LWW row-HLC per-record metadata (CloudKit pull)
//   v2 — _ck_outbox          Durable outbound queue (R4, CVK-ICLOUD P1-M4)
//   v3 — _ck_change_token    Persisted CloudKit server change token (R5, CVK-ICLOUD P1-M5,
//                             consolidated from TokenStore.swift in P1-M6 adjudication A11)
//         _ck_outbox          Gains retry_count and is_parked columns (R6, CVK-ICLOUD P1-M6)
//   v6 — _ck_sync_meta_cols  Per-column HLC side table for fieldLevelLWW (B-8, CVK-ICLOUD P2-M1)
//         _ck_outbox          Gains column_hlcs blob column (JSON-encoded ColumnHLCMap)
//   v7 — _ck_pending_skew    Schema-skew pending queue (R9, CVK-ICLOUD P3-M4)
//   v8 — idx_ck_outbox_table_row  Secondary index on _ck_outbox(table_name, row_key)
//                                  (CVK-WB5 perf Q3). Accelerates OutboxStore.append's
//                                  coalescing lookup: the WHERE (table_name = ?, row_key = ?)
//                                  predicate does a sequential scan on unindexed estates.
//                                  With this composite index, the coalescing query becomes
//                                  an O(log N) index seek instead of O(N) scan.
//   v9 — _ck_device_identity  Device-slot registry (N2, CVK-WB12 A11 final consolidation).
//                              Consolidated from DeviceIdentityStore.swift's separate
//                              SchemaDeclaration (formerly kitID "ConvergenceKit" v1).
//                              DeviceIdentityStore.ensureSchema(storage:) now delegates to
//                              CKSideSchema.ensure(storage:). Migration is additive: the
//                              v8→v9 .createTable uses IF NOT EXISTS semantics — devices
//                              that already have _ck_device_identity from the legacy
//                              DeviceIdentityStore.ensureSchema path advance the version
//                              counter without recreating the table.
// Earmarks now superseded:
//   v4 — _ck_device_identity  Device-slot registry (N2) ← earmark superseded by v6→v7 jump;
//                              table consolidated at v9 (CVK-WB12, A11 final — DONE)
//   v5 — _ck_pending_skew     Schema-skew pending queue (R9) ← landed at v7 instead (see below)
//
// WHY v7 for _ck_pending_skew (not v5):
// v4 and v5 were earmarked before P2-M1 landed. P2-M1 added _ck_sync_meta_cols
// at v6 using a v3→v6 jump (skipping the earmarks). Since v6 is already
// deployed, _ck_pending_skew must land at v7 via a v6→v7 migration. The
// version counter is monotonically increasing and need not be contiguous.
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
    /// per-record success. Process death or transport failure leaves entries
    /// here; they are drained on the next enable() and pushed in the next push
    /// cycle. Added in v2. `retry_count` and `is_parked` columns added in v3
    /// (CVK-ICLOUD P1-M6 R6 support). `column_hlcs` blob added in v6
    /// (CVK-ICLOUD P2-M1 fieldLevelLWW support).
    public static let outboxTable = "_ck_outbox"

    /// Persisted CKServerChangeToken per CloudKit zone. Populated after every
    /// successful pull so the next process launch resumes from where the
    /// previous one left off rather than re-pulling the full zone.
    /// Added in v3 (consolidated from TokenStore.swift's separate declaration
    /// under kitID "ConvergenceKitCloudKit"; the read/write helpers stay in
    /// TokenStore.swift — only the schema declaration has moved here, per
    /// adjudication A11, CVK-ICLOUD P1-M6).
    public static let changeTokenTable = "_ck_change_token"

    /// Per-column HLC side table for the `fieldLevelLWW` conflict policy.
    ///
    /// Schema: (table_name TEXT, primary_key TEXT, column_name TEXT,
    ///          col_hlc INT); PRIMARY KEY (table_name, primary_key, column_name).
    ///
    /// One row per (table, row, column) triple. Populated by ColumnHLCStore
    /// after every winning fieldLevelLWW apply. Consulted by the inbound apply
    /// path to determine which columns from the incoming record should overwrite
    /// local state. Added in v6 (CVK-ICLOUD P2-M1).
    public static let syncMetaColsTable = "_ck_sync_meta_cols"

    /// Pending-skew queue for future-schema records (R9, CVK-ICLOUD P3-M4).
    ///
    /// Schema: (id UUID PK, table_name TEXT, row_key TEXT,
    ///          schema_version INT, received_at TEXT, payload BLOB).
    ///
    /// One row per held record. Populated by PendingSkewQueue.enqueue when
    /// a pull receives a record whose schemaVersion > manifest.schemaVersion.
    /// Drained by SkewReplay.drainReady at enable() time when schema_version
    /// equals the newly-enabled manifest version. Added in v7.
    public static let pendingSkewTable = "_ck_pending_skew"

    /// Device-slot registry side table (N2). Persists this device's
    /// (deviceUUID, slot, epoch, claimedAt) sync identity per estate.
    ///
    /// Schema: (id TEXT PK, device_uuid TEXT, slot INT, epoch INT,
    ///          claimed_at TEXT); single row keyed by the sentinel "self".
    ///
    /// Read/write helpers live in DeviceIdentityStore.swift; only the
    /// schema declaration lives here (per A11 consolidation, CVK-WB12).
    /// Added in v9.
    public static let deviceIdentityTable = "_ck_device_identity"

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

        // _ck_outbox schema (v6 — includes retry_count, is_parked from P1-M6
        // and column_hlcs blob from P2-M1 fieldLevelLWW):
        //   id           — UUID primary key for per-record confirm().
        //   table_name   — application table the change belongs to.
        //   row_key      — UUID as TEXT (primary key of the application row).
        //   event        — change kind: "insert", "update", or "delete".
        //                  Stored as TEXT, not Bool, per schema invariant.
        //   values       — JSON-encoded SyncValueMap for insert/update; absent
        //                  (null) for delete events.
        //   hlc          — packed HLC (Int64) used for coalescing: when two changes for
        //                  the same (table_name, row_key) are appended, only the
        //                  entry with the higher HLC survives.
        //   enqueued_at  — ISO8601 wall-clock string for observability.
        //   retry_count  — cumulative count of failed push attempts.
        //                  Int, default 0 (not Bool per schema invariants).
        //   is_parked    — 1 when the entry has permanently failed (quota or size
        //                  exceeded). Int, default 0 (not Bool per schema invariants).
        //   column_hlcs  — JSON-encoded ColumnHLCMap for fieldLevelLWW outbox entries.
        //                  Null for entries written before v6 or for non-fieldLevelLWW
        //                  tables. The push path decodes this and passes it to
        //                  CKRecordMapping to populate _syncColumnHLCs in the CKRecord.
        let retryCountDecl  = ColumnDeclaration(name: "retry_count",  type: .int,  nullable: false,
                                                defaultValue: .int(0))
        let isParkDecl      = ColumnDeclaration(name: "is_parked",    type: .int,  nullable: false,
                                                defaultValue: .int(0))
        let columnHLCsDecl  = ColumnDeclaration(name: "column_hlcs",  type: .blob, nullable: true)

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
                retryCountDecl,
                isParkDecl,
                columnHLCsDecl,
            ],
            primaryKey: ["id"]
        )

        // _ck_change_token schema (consolidated from TokenStore.swift, v3):
        //   zone_name  — sole primary key; one row per CloudKit zone.
        //   token      — NSKeyedArchiver blob of a CKServerChangeToken.
        //   updated_at — ISO8601 wall-clock string for debugging.
        //                Date storage is TEXT (ISO8601) per schema invariants.
        let changeTokenDecl = TableDeclaration(
            name: changeTokenTable,
            columns: [
                ColumnDeclaration(name: "zone_name",  type: .text, nullable: false),
                ColumnDeclaration(name: "token",      type: .blob, nullable: false),
                ColumnDeclaration(name: "updated_at", type: .text, nullable: false),
            ],
            primaryKey: ["zone_name"]
        )

        // _ck_sync_meta_cols schema (v6 — per-column HLC for fieldLevelLWW):
        //   table_name  — application table name.
        //   primary_key — row UUID as TEXT.
        //   column_name — application column name.
        //   col_hlc     — packed HLC (Int64, same layout as sync_hlc in _ck_sync_meta).
        //                 Read/written by ColumnHLCStore; consulted by ApplyInbound
        //                 for the .fieldLevelLWW policy arm.
        let syncMetaColsDecl = TableDeclaration(
            name: syncMetaColsTable,
            columns: [
                ColumnDeclaration(name: "table_name",  type: .text, nullable: false),
                ColumnDeclaration(name: "primary_key", type: .text, nullable: false),
                ColumnDeclaration(name: "column_name", type: .text, nullable: false),
                ColumnDeclaration(name: "col_hlc",     type: .int,  nullable: false,
                                  defaultValue: .int(0)),
            ],
            primaryKey: ["table_name", "primary_key", "column_name"]
        )

        // _ck_pending_skew schema (v7 — schema-skew pending queue, R9, CVK-ICLOUD P3-M4):
        //   id             — UUID primary key assigned at enqueue time.
        //   table_name     — application table the record belongs to.
        //   row_key        — UUID as TEXT (primary key of the application row).
        //   schema_version — schemaVersion from the wire record (sender's version).
        //                    INT, not Bool, per schema invariants.
        //   received_at    — ISO8601 wall-clock TEXT for oldest-eviction ordering.
        //                    Date storage is TEXT (ISO8601) per schema invariants.
        //   payload        — JSON-encoded SyncRecord (full wire format; round-trips
        //                    through JSONDecoder().decode(SyncRecord.self, from:)).
        let pendingSkewDecl = TableDeclaration(
            name: pendingSkewTable,
            columns: [
                ColumnDeclaration(name: "id",             type: .uuid, nullable: false),
                ColumnDeclaration(name: "table_name",     type: .text, nullable: false),
                ColumnDeclaration(name: "row_key",        type: .text, nullable: false),
                ColumnDeclaration(name: "schema_version", type: .int,  nullable: false,
                                  defaultValue: .int(0)),
                ColumnDeclaration(name: "received_at",    type: .text, nullable: false),
                ColumnDeclaration(name: "payload",        type: .blob, nullable: false),
            ],
            primaryKey: ["id"]
        )

        // _ck_device_identity schema (v9 — A11 final consolidation, CVK-WB12):
        //   id          — fixed sentinel TEXT key; always "self" for this device/estate.
        //   device_uuid — stable device UUID as TEXT (UUID.uuidString). Generated once
        //                 on first enable() for this device/estate pair.
        //   slot        — the HLC node-ID slot (1–15) claimed via CloudKit CAS by
        //                 SlotClaimOperation. INT, not Bool, per schema invariants.
        //   epoch       — epoch counter matching the registry record; bumped when the
        //                 slot is evicted and reclaimed. Starts at 1 on first mint.
        //                 INT64 range; default 1.
        //   claimed_at  — ISO8601 wall-clock TEXT when this slot/epoch was first
        //                 claimed. DATE STORAGE INVARIANT: TEXT ISO8601, never REAL.
        //
        // Columns are IDENTICAL to those previously declared in
        // DeviceIdentityStore.ensureSchema — no renames, no type changes.
        // The v8→v9 migration uses .createTable with IF NOT EXISTS semantics:
        // devices that already have the table from the legacy path advance
        // the counter without recreating the table.
        let deviceIdentityDecl = TableDeclaration(
            name: deviceIdentityTable,
            columns: [
                // Fixed sentinel key — always "self" for this device.
                ColumnDeclaration(name: "id",          type: .text, nullable: false),
                // Device UUID as a TEXT string (UUID.uuidString).
                ColumnDeclaration(name: "device_uuid", type: .text, nullable: false),
                // Slot number 1–15 stored as Int64.
                ColumnDeclaration(name: "slot",        type: .int,  nullable: false),
                // Epoch counter; starts at 1 on first mint.
                ColumnDeclaration(name: "epoch",       type: .int,  nullable: false,
                                  defaultValue: .int(1)),
                // DATE STORAGE INVARIANT: TEXT ISO8601, never REAL.
                // Storing as unix float would lose sub-second precision
                // and prevent human readability in DB browsers.
                ColumnDeclaration(name: "claimed_at",  type: .text, nullable: false),
            ],
            primaryKey: ["id"]
        )

        // Secondary index on _ck_outbox(table_name, row_key).
        //
        // WHY this index (CVK-WB5 perf Q3):
        // OutboxStore.append issues a WHERE (table_name = ?, row_key = ?) query per
        // write to detect an existing entry for coalescing. Without an index, the
        // storage engine scans every row in _ck_outbox on each append. With this
        // composite index, the coalescing lookup becomes an O(log N) seek instead
        // of O(N) scan — meaningful at large outbox sizes (hot-row workloads,
        // offline accumulation).
        //
        // Declared in SchemaDeclaration.indices (not inside TableDeclaration) so the
        // backend emits CREATE INDEX IF NOT EXISTS at open(schema:) time for fresh
        // installs. The v7→v8 migration adds it for devices already deployed.
        let outboxTableRowIndex = IndexDeclaration(
            name: "idx_ck_outbox_table_row",
            table: outboxTable,
            columns: ["table_name", "row_key"]
        )

        return SchemaDeclaration(
            kitID: "ConvergenceKit",
            version: 9,
            tables: [syncMetaDecl, outboxDecl, changeTokenDecl, syncMetaColsDecl,
                     pendingSkewDecl, deviceIdentityDecl],
            indices: [outboxTableRowIndex],
            migrations: [
                // v1 → v2: add durable outbox table.
                // The tables array handles v0 → v9 fresh installs via IF NOT EXISTS.
                Migration(fromVersion: 1, toVersion: 2, operations: [
                    .createTable(outboxDecl),
                ]),
                // v2 → v3:
                //   - Consolidate _ck_change_token (previously declared under
                //     kitID "ConvergenceKitCloudKit" v1 in TokenStore.swift).
                //     createTable is IF NOT EXISTS; devices that already have the
                //     table from TokenStore.ensure simply advance this counter.
                //   - Add retry_count and is_parked to _ck_outbox (R6, P1-M6).
                Migration(fromVersion: 2, toVersion: 3, operations: [
                    .createTable(changeTokenDecl),
                    .addColumn(table: outboxTable, column: retryCountDecl),
                    .addColumn(table: outboxTable, column: isParkDecl),
                ]),
                // v3 → v6: field-level LWW support (B-8, CVK-ICLOUD P2-M1).
                //   - Add _ck_sync_meta_cols table (per-column HLC side table).
                //   - Add column_hlcs blob to _ck_outbox (sender stamps column HLCs
                //     at capture time; push path passes them to CKRecordMapping).
                // WHY from v3 directly to v6:
                // v4 (_ck_device_identity, N2) and v5 (_ck_pending_skew, R9) were
                // earmarked but the P2-M1 mission jumped to v6, skipping both.
                // Devices already at v3 advance to v6 via this migration.
                Migration(fromVersion: 3, toVersion: 6, operations: [
                    .createTable(syncMetaColsDecl),
                    .addColumn(table: outboxTable, column: columnHLCsDecl),
                ]),
                // v6 → v7: schema-skew pending queue (R9, CVK-ICLOUD P3-M4).
                //   - Add _ck_pending_skew table. Holds future-schema records
                //     from pull cycles until a schema update makes them applicable.
                //     Cap at 512 entries (Playground Rule 8 relief valve);
                //     oldest entries evicted by PendingSkewQueue.evictIfNeeded.
                Migration(fromVersion: 6, toVersion: 7, operations: [
                    .createTable(pendingSkewDecl),
                ]),
                // v7 → v8: secondary index on _ck_outbox(table_name, row_key).
                //   (CVK-WB5 perf Q3). Devices at v7 receive the index here;
                //   fresh installs get it from SchemaDeclaration.indices above.
                Migration(fromVersion: 7, toVersion: 8, operations: [
                    .addIndex(outboxTableRowIndex),
                ]),
                // v8 → v9: A11 final consolidation — fold _ck_device_identity
                //   into CKSideSchema (CVK-WB12). Previously declared under
                //   kitID "ConvergenceKit" v1 in DeviceIdentityStore.swift.
                //   createTable is IF NOT EXISTS: devices that already have the
                //   table from the legacy DeviceIdentityStore.ensureSchema path
                //   advance the version counter without recreating the table.
                //   Column set is identical to the legacy declaration — no
                //   renames, no type changes, no Bool columns added.
                Migration(fromVersion: 8, toVersion: 9, operations: [
                    .createTable(deviceIdentityDecl),
                ]),
            ]
        )
    }()

    // MARK: - Public ensure

    /// Ensure all ConvergenceKit side tables exist on `storage`. Idempotent;
    /// safe to call on every enable(). Uses migrate(to:), which is additive
    /// (IF NOT EXISTS on all backends) and never replaces the application schema.
    ///
    /// From v3 onward, this call also ensures _ck_change_token; a separate
    /// TokenStore.ensure(storage:) call in enable() is no longer needed.
    /// From v6 onward, this call also ensures _ck_sync_meta_cols for
    /// fieldLevelLWW column HLC tracking.
    /// From v9 onward, this call also ensures _ck_device_identity; a separate
    /// DeviceIdentityStore.ensureSchema(storage:) call in enable() is no longer
    /// needed (the method now delegates here for call-site stability).
    public static func ensure(storage: any Storage) async throws {
        try await storage.migrate(to: declaration)
    }
}
