// StatsStore.swift
//
// The SQLite stats-store schema, open/migrate, and retention.
//
// Schema design (MANAGER_1.0_PLAN.md §1, §4):
//
//   metric_samples  — metric observations (name, value, tags as JSON, ts)
//   event_samples   — topology events (kind, noun_type, row_id, estate, ts)
//   control         — global on/off flag row + retention metadata
//
// The `control` table holds at most one row (key "monitoring") plus
// a second row (key "retention_cutoff") recording the ISO-8601 cutoff
// timestamp that the last retention pass used. Both are present after
// StatsStore.open() — upserted on every open so the values are always
// readable without a null check.
//
// Timestamp invariant (CLAUDE.md schema rule):
//   All ts columns are stored as TEXT (ISO-8601 UTC).
//   The `ts: Double` (epoch seconds) from StatSample is converted at the
//   store boundary (encode_ts / decode_ts). No REAL timestamp columns exist.
//
// Retention:
//   deleteMetricsBefore(cutoff:) and deleteEventsBefore(cutoff:) delete rows
//   with ts < cutoff. Both take the cutoff as a parameter — no Date() call
//   inside any engine. Determinism is required.
//
// Dropbox identity:
//   Each consumer (one per process / app instance) passes a `dropboxID`
//   string when inserting rows. This identifies the source and allows the
//   manager to separate traffic by consumer. The manager is the sole owner
//   of the stats store file; consumers write their dropbox rows directly
//   (SQLite WAL handles concurrent writers).
//
// Monitoring on/off flag:
//   The `control` table holds a row with key="monitoring" and value="1" (on)
//   or "0" (off). PersistenceStatsSink reads this row on each receive() call
//   and short-circuits when value="0". The manager writes the row; the sink
//   reads it. No memory-mapped flag — the row is the signal (confirmed default
//   per MANAGER_1.0_PLAN.md §5 item 3, Bob 2026-06-06).

import Foundation
import OSLog
import PersistenceKit
import PersistenceKitSQLite

// MARK: - Schema constants

/// Column and table name constants for the stats store.
/// Gathered here so typos produce compile errors rather than silent empty queries.
public enum StatsStoreSchema {

    // MARK: Table names

    /// Metric observations (name, value, tags-JSON, ts, dropbox_id).
    public static let metricSamplesTable = "metric_samples"

    /// Topology events (kind, noun_type, row_id, estate, ts, dropbox_id).
    public static let eventSamplesTable = "event_samples"

    /// Control table (key, value pairs — monitoring flag + retention metadata).
    public static let controlTable = "control"

    // MARK: Shared column names

    /// TEXT (ISO-8601 UTC) — epoch-seconds ts from StatSample, encoded at the store boundary.
    public static let tsColumn = "ts"

    /// TEXT — identifies the source consumer (dropbox) that produced this row.
    public static let dropboxIDColumn = "dropbox_id"

    // MARK: metric_samples columns

    /// TEXT NOT NULL — dot-separated metric name (e.g. "locus.capture.latency_ms").
    public static let nameColumn = "name"

    /// REAL NOT NULL — the measured quantity.
    public static let valueColumn = "value"

    /// TEXT NOT NULL — JSON-encoded tag map {"key":"value"}.
    public static let tagsColumn = "tags"

    // MARK: event_samples columns

    /// TEXT NOT NULL — EventKind raw string: "capture" or "think".
    public static let kindColumn = "kind"

    /// INTEGER NOT NULL — NounType ordinal from SubstrateTypes.
    public static let nounTypeColumn = "noun_type"

    /// TEXT NOT NULL — row UUID string from the estate (the substrate entity's own UUID).
    /// Named `estate_row_id` to avoid collision with the synthetic primary key `row_id`.
    public static let rowIDColumn = "estate_row_id"

    /// TEXT NOT NULL — estate identifier string.
    public static let estateColumn = "estate"

    // MARK: control table columns

    /// TEXT NOT NULL PRIMARY KEY — the control key (e.g. "monitoring").
    public static let keyColumn = "key"

    /// TEXT NOT NULL — the control value (e.g. "1" for on, "0" for off).
    public static let controlValueColumn = "value"

    // MARK: Well-known control row keys

    /// Key for the global monitoring on/off flag. Value "1" = on, "0" = off.
    public static let monitoringKey = "monitoring"

    /// Key for the monitoring source. Value "default" = system-seeded default,
    /// "user" = explicitly set by the user. Absent on estates opened before
    /// the monitoring-default-ON change (wave 8.1); treated as "default" when
    /// absent so the one-time migration can correct old "0" seeds to "1".
    ///
    /// Write "user" when the monitoring flag is changed via `moot_estate_monitoring`
    /// or the moot-mgr toggle so subsequent re-opens do not silently reset it.
    public static let monitoringSourceKey = "monitoring_source"

    /// Key for the timestamp of the last retention pass (ISO-8601 TEXT).
    /// Set to "1970-01-01T00:00:00.000Z" (epoch zero) on first open to
    /// indicate no retention has run yet.
    public static let retentionCutoffKey = "retention_cutoff"

    // MARK: topology_snapshots table (v2)

    /// The topology_snapshots table name. One row per estate; latest-wins upsert.
    public static let topologySnapshotsTable = "topology_snapshots"

    /// TEXT NOT NULL — ISO-8601 UTC timestamp of when the governor produced the snapshot.
    public static let generatedAtColumn = "generated_at"

    /// TEXT NOT NULL — JSON-encoded ARIAGraphPayload bytes. Served verbatim by /api/graph.
    public static let payloadColumn = "payload"

    /// TEXT NULL (v3) — stable topology-inputs fingerprint for the persisted snapshot.
    /// The autonomic governor writes this alongside the payload so that, on restart,
    /// it can compare the persisted fingerprint against freshly-computed topology
    /// inputs WITHOUT re-reading all drawers/tunnels/facts when nothing changed.
    /// The fingerprint is a process-independent stable hash (FNV-1a), never Swift's
    /// salted `hashValue`. Nullable so v2 rows migrated forward read back as nil
    /// (treated as "unknown" → governor recomputes once, then writes the fingerprint).
    public static let topologyFingerprintColumn = "topology_fingerprint"
}

// MARK: - StatsStore

/// Manages the SQLite stats store for the MOOTx01 manager pipeline.
///
/// `StatsStore` owns the schema declaration, migrations, and the high-level
/// write/query/retention methods that `PersistenceStatsSink` and the manager
/// process use. It wraps a `SQLiteStorage` instance.
///
/// ## Usage
///
/// ```swift
/// let store = try StatsStore(url: statsDBURL)
/// try await store.open()
///
/// // Write a metric row (done automatically by PersistenceStatsSink)
/// try await store.insertMetric(name: "locus.op", value: 1.0, tags: [:],
///                               ts: now, dropboxID: "my-app")
///
/// // Roll off old data (caller-supplied cutoff — no Date() here)
/// try await store.deleteMetricsBefore(cutoff: cutoffDate)
/// ```
///
/// - Note: All timestamps are stored as TEXT (ISO-8601 UTC). The `ts: Double`
///   (epoch seconds) from `StatSample` is converted at the boundary.
///   No REAL timestamp columns exist in this schema.
public final class StatsStore: Sendable {

    // MARK: - Private state

    private let storage: SQLiteStorage
    private let logger = Logger(subsystem: "com.mootx01.kit", category: "ObserverSink")

    // MARK: - Schema version

    /// The current schema version for ObserverSink.
    /// Bumping this value requires a Migration entry to be added to `schema`.
    /// v1: initial schema (metric_samples, event_samples, control).
    /// v2: added topology_snapshots table (one row per estate, latest-wins upsert).
    /// v3: added topology_snapshots.topology_fingerprint (nullable) so the governor
    ///     can skip the full topology read on restart when inputs are unchanged.
    public static let schemaVersion = 3

    // MARK: - Schema declaration

    /// The PersistenceKit schema declaration for the stats store.
    ///
    /// Four tables (v2):
    /// - `metric_samples`: metric observations (name, value, tags JSON, ts, dropbox_id)
    /// - `event_samples`: topology events (kind, noun_type, row_id, estate, ts, dropbox_id)
    /// - `control`: global monitoring flag + retention metadata (key-value pairs)
    /// - `topology_snapshots`: one row per estate holding the latest governor-computed
    ///   topology payload (estate TEXT PRIMARY KEY, generated_at TEXT, payload TEXT).
    ///   The autonomic governor writes here on its topology duty cycle; ARIA /api/graph
    ///   and moot-mgr serve bytes from this table directly (no compute on read).
    ///
    /// Version 1: initial schema — metric_samples, event_samples, control.
    /// Version 2: additive migration — topology_snapshots table added.
    /// Version 3: additive migration — topology_snapshots.topology_fingerprint added.
    public static let schema = SchemaDeclaration(
        kitID: "ObserverSink",
        version: schemaVersion,
        tables: [
            // MARK: metric_samples
            //
            // One row per metric observation emitted via Intellectus.report(.metric(...)).
            // `tags` is stored as JSON TEXT so the schema accommodates any tag map without
            // a secondary table. The store boundary encodes/decodes [String:String] to/from
            // JSON. `ts` is TEXT (ISO-8601) per the schema invariant.
            TableDeclaration(
                name: StatsStoreSchema.metricSamplesTable,
                columns: [
                    // Synthetic UUID primary key — the store assigns it; callers never supply it.
                    .uuid("row_id"),
                    // Metric identity and measurement.
                    .text(StatsStoreSchema.nameColumn),
                    .float(StatsStoreSchema.valueColumn),
                    // JSON-encoded tag map. TEXT (not a native JSON column) for broadest
                    // SQLite compat; the JSON structure is simple (flat string-string map).
                    .text(StatsStoreSchema.tagsColumn),
                    // Timestamp as TEXT (ISO-8601 UTC). Epoch-seconds Double is encoded at
                    // the store boundary (epochSecondsToISO8601 / iso8601ToEpochSeconds).
                    .timestamp(StatsStoreSchema.tsColumn),
                    // Identifies which consumer produced this row.
                    .text(StatsStoreSchema.dropboxIDColumn),
                ],
                primaryKey: ["row_id"]
            ),

            // MARK: event_samples
            //
            // One row per topology event emitted via Intellectus.report(.event(...)).
            // `kind` is stored as the EventKind raw string ("capture" or "think") so
            // the manager can filter or group without needing to decode an integer ordinal.
            // `noun_type` is stored as INTEGER (Int64) matching SubstrateTypes NounType
            // ordinal semantics. `ts` is TEXT (ISO-8601) per the schema invariant.
            TableDeclaration(
                name: StatsStoreSchema.eventSamplesTable,
                columns: [
                    .uuid("row_id"),
                    // EventKind raw string: "capture" or "think".
                    .text(StatsStoreSchema.kindColumn),
                    // NounType ordinal (Int) from SubstrateTypes, passed as Int here
                    // to keep IntellectusLib zero-dependency at the emission site.
                    .int(StatsStoreSchema.nounTypeColumn),
                    // Row UUID string from the estate (the substrate entity's UUID).
                    // Column name is "estate_row_id" to avoid collision with the
                    // synthetic primary key "row_id".
                    .text(StatsStoreSchema.rowIDColumn),
                    // Estate identifier string.
                    .text(StatsStoreSchema.estateColumn),
                    .timestamp(StatsStoreSchema.tsColumn),
                    .text(StatsStoreSchema.dropboxIDColumn),
                ],
                primaryKey: ["row_id"]
            ),

            // MARK: control
            //
            // Key-value store for global state:
            //   "monitoring" → "1" (on) | "0" (off)
            //   "retention_cutoff" → ISO-8601 TEXT of the last retention pass cutoff
            //
            // The manager writes "monitoring"; the sink reads it. The manager writes
            // "retention_cutoff" after each retention pass so the dashboard can display
            // when the last roll-off occurred without querying the sample tables.
            //
            // The table uses key as the primary key (upsert semantics for updates).
            TableDeclaration(
                name: StatsStoreSchema.controlTable,
                columns: [
                    // Control key — primary key.
                    .text(StatsStoreSchema.keyColumn),
                    // Control value — always TEXT; callers parse as needed.
                    .text(StatsStoreSchema.controlValueColumn),
                ],
                primaryKey: [StatsStoreSchema.keyColumn]
            ),

            // MARK: topology_snapshots (v2)
            //
            // One row per estate. The autonomic governor upserts here after each
            // topology-recompute duty cycle. `estate` is the PRIMARY KEY so the
            // latest-wins upsert overwrites the previous row without accumulating
            // history (history is not needed — only the current snapshot is served).
            //
            // `generated_at` is TEXT (ISO-8601 UTC) per the schema timestamp invariant.
            // `payload` is TEXT storing the JSON-encoded ARIAGraphPayload bytes produced
            // by the governor. The HTTP server and moot-mgr serve these bytes verbatim —
            // no re-encoding on read.
            //
            // Added by v1→v2 migration (table); topology_fingerprint added by v2→v3.
            TableDeclaration(
                name: StatsStoreSchema.topologySnapshotsTable,
                columns: [
                    // Estate identifier — one row per estate, primary key.
                    .text(StatsStoreSchema.estateColumn),
                    // ISO-8601 TEXT timestamp of when the governor produced this snapshot.
                    .timestamp(StatsStoreSchema.generatedAtColumn),
                    // JSON payload bytes (TEXT). Served verbatim; no decode on read path.
                    .text(StatsStoreSchema.payloadColumn),
                    // Stable topology-inputs fingerprint (v3). Nullable — pre-v3 rows
                    // and snapshots written without a fingerprint read back as nil.
                    .text(StatsStoreSchema.topologyFingerprintColumn, nullable: true),
                ],
                primaryKey: [StatsStoreSchema.estateColumn]
            ),
        ],
        indices: [
            // Index on metric_samples.ts for fast retention deletes.
            // Retention queries are `DELETE WHERE ts < cutoff` — a full table
            // scan without this index costs O(n) on every retention pass.
            IndexDeclaration(
                name: "idx_metric_samples_ts",
                table: StatsStoreSchema.metricSamplesTable,
                columns: [StatsStoreSchema.tsColumn]
            ),
            // Index on event_samples.ts for fast retention deletes (same rationale).
            IndexDeclaration(
                name: "idx_event_samples_ts",
                table: StatsStoreSchema.eventSamplesTable,
                columns: [StatsStoreSchema.tsColumn]
            ),
        ],
        migrations: [
            // v1 → v2: add topology_snapshots table.
            // Additive migration — no existing rows are touched. The new table
            // starts empty; the governor populates it on its next duty cycle.
            Migration(
                fromVersion: 1,
                toVersion: 2,
                operations: [
                    .createTable(TableDeclaration(
                        name: StatsStoreSchema.topologySnapshotsTable,
                        columns: [
                            .text(StatsStoreSchema.estateColumn),
                            .timestamp(StatsStoreSchema.generatedAtColumn),
                            .text(StatsStoreSchema.payloadColumn),
                        ],
                        primaryKey: [StatsStoreSchema.estateColumn]
                    )),
                ]
            ),
            // v2 → v3: add the nullable topology_fingerprint column.
            // Additive migration — existing snapshot rows keep their payload and
            // read back the fingerprint as nil (governor recomputes once, then
            // backfills the fingerprint on its next topology duty cycle).
            Migration(
                fromVersion: 2,
                toVersion: 3,
                operations: [
                    .addColumn(
                        table: StatsStoreSchema.topologySnapshotsTable,
                        column: .text(StatsStoreSchema.topologyFingerprintColumn, nullable: true)
                    ),
                ]
            ),
        ]
    )

    // MARK: - Initialisation

    /// Create a `StatsStore` backed by a SQLite database at `url`.
    ///
    /// Call `open()` before performing any I/O.
    ///
    /// - Parameter url: Filesystem path to the SQLite database file.
    ///   The file is created if it does not exist (SQLite creates it on open).
    /// - Throws: `StorageError` if the connection cannot be established.
    public init(url: URL) throws {
        self.storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)
        ))
    }

    // MARK: - Lifecycle

    /// Open the store and apply the schema / migrations.
    ///
    /// After `open()` returns, the three tables and two indices exist.
    /// The control table is seeded with the default "monitoring"="0" and
    /// "retention_cutoff"="1970-01-01T00:00:00.000Z" rows ONLY if they are
    /// absent — an existing operator-set value is preserved.
    ///
    /// Idempotent: calling `open()` on an already-opened store is safe — the
    /// schema migration is forward-only and no-ops if the version is current.
    /// Re-opening across process restarts preserves the monitoring flag (the
    /// manager's persistent on/off switch must survive a restart).
    ///
    /// - Throws: `StorageError` on schema apply failure.
    public func open() async throws {
        try await storage.open(schema: StatsStore.schema)

        // Seed default control rows only if absent (seed-if-absent, NOT upsert).
        // Upsert would overwrite an operator-set value on every open, resetting
        // the monitoring flag on each manager restart — wrong for a persistent
        // switch. Seeding only when the row is missing makes the first open
        // install the defaults and every subsequent open a no-op.
        //   - "monitoring" defaults to "1" (ON) per wave 8.1 — matching the
        //     stated product behavior that monitoring is on by default.
        //   - "monitoring_source" defaults to "default" so later code can
        //     distinguish "user explicitly set this" from "system seeded it".
        //   - "retention_cutoff" defaults to epoch zero so the manager can
        //     display "never" before the first retention pass.
        let isNewMonitoringSeed = try await seedControlIfAbsent(
            key: StatsStoreSchema.monitoringKey, value: "1"
        )
        if isNewMonitoringSeed {
            // Seed the source marker alongside the monitoring flag — only
            // when monitoring itself was just seeded (fresh estate). On an
            // existing estate the marker is handled by the one-time migration
            // below, or by the user-flip path in set_monitoring_enabled.
            try await seedControlIfAbsent(
                key: StatsStoreSchema.monitoringSourceKey, value: "default"
            )
        }
        try await seedControlIfAbsent(
            key: StatsStoreSchema.retentionCutoffKey,
            // Epoch zero in ISO-8601: indicates no retention pass has run yet.
            value: "1970-01-01T00:00:00.000Z"
        )

        // Wave 8.1 one-time migration: estates seeded before monitoring-default-ON
        // shipped had monitoring="0" and no monitoring_source row. Migrate them to
        // "1" unless the user explicitly set a value (monitoring_source == "user").
        // This runs once: after migration, monitoring_source becomes "default",
        // so subsequent re-opens find source=="default" and monitoring=="1" and
        // skip the migration body.
        if !isNewMonitoringSeed {
            // Existing estate: check current monitoring and source values.
            let currentMonitoring = try await readControlValue(key: StatsStoreSchema.monitoringKey)
            let currentSource = try await readControlValue(key: StatsStoreSchema.monitoringSourceKey)
            if currentMonitoring == "0" && (currentSource == nil || currentSource == "default") {
                // Monitoring was off by old default and user has not touched it.
                // Flip to on and mark the source as "default" so this branch
                // is skipped on the next open.
                try await upsertControlValue(key: StatsStoreSchema.monitoringKey, value: "1")
                try await upsertControlValue(key: StatsStoreSchema.monitoringSourceKey, value: "default")
                logger.info("StatsStore: one-time migration — monitoring default ON (was 0, source absent/default)")
            } else if currentSource == nil {
                // Existing estate with monitoring already ON (or explicitly OFF by user
                // but source marker is absent): seed the source marker for future reads.
                // If monitoring is "0" and source is nil, the block above already ran;
                // this arm handles monitoring="1" + source=nil (old ON estates pre-wave-8.1).
                let sourceValue = (currentMonitoring == "0") ? "user" : "default"
                try await upsertControlValue(key: StatsStoreSchema.monitoringSourceKey, value: sourceValue)
            }
        }

        logger.info("StatsStore opened at version \(StatsStore.schemaVersion)")
    }

    /// Insert a control row only if no row with that key already exists.
    ///
    /// Preserves an existing value (e.g. an operator-set monitoring flag)
    /// across re-opens. The existence check + insert run on the actor-isolated
    /// store; the manager process is single-instance so there is no competing
    /// writer racing the seed.
    ///
    /// Returns `true` when the row was inserted (first open), `false` when
    /// the row already existed (re-open). Callers use this to differentiate
    /// fresh-estate seeding from existing-estate migration paths.
    @discardableResult
    private func seedControlIfAbsent(key: String, value: String) async throws -> Bool {
        let existing = try await storage.rowStore.query(
            table: StatsStoreSchema.controlTable,
            where: .eq(
                Column(table: StatsStoreSchema.controlTable, name: StatsStoreSchema.keyColumn),
                .text(key)
            )
        )
        guard existing.isEmpty else { return false }
        _ = try await storage.rowStore.insert(
            table: StatsStoreSchema.controlTable,
            values: [
                StatsStoreSchema.keyColumn: .text(key),
                StatsStoreSchema.controlValueColumn: .text(value),
            ]
        )
        return true
    }

    /// Read a control row value by key. Returns `nil` when the row is absent.
    ///
    /// Used by the wave 8.1 migration to inspect monitoring + source state.
    private func readControlValue(key: String) async throws -> String? {
        let rows = try await storage.rowStore.query(
            table: StatsStoreSchema.controlTable,
            where: .eq(
                Column(table: StatsStoreSchema.controlTable, name: StatsStoreSchema.keyColumn),
                .text(key)
            )
        )
        guard let row = rows.first else { return nil }
        if case .text(let v) = row[StatsStoreSchema.controlValueColumn] { return v }
        return nil
    }

    /// Insert or update a control row (upsert). Used by the wave 8.1 migration
    /// and by `setMonitoringEnabled` to write user-triggered changes.
    private func upsertControlValue(key: String, value: String) async throws {
        let existing = try await storage.rowStore.query(
            table: StatsStoreSchema.controlTable,
            where: .eq(
                Column(table: StatsStoreSchema.controlTable, name: StatsStoreSchema.keyColumn),
                .text(key)
            )
        )
        if existing.isEmpty {
            _ = try await storage.rowStore.insert(
                table: StatsStoreSchema.controlTable,
                values: [
                    StatsStoreSchema.keyColumn: .text(key),
                    StatsStoreSchema.controlValueColumn: .text(value),
                ]
            )
        } else {
            _ = try await storage.rowStore.update(
                table: StatsStoreSchema.controlTable,
                values: [StatsStoreSchema.controlValueColumn: .text(value)],
                where: .eq(
                    Column(table: StatsStoreSchema.controlTable, name: StatsStoreSchema.keyColumn),
                    .text(key)
                )
            )
        }
    }

    /// Close the store cleanly.
    ///
    /// Idempotent. Safe to call multiple times.
    public func close() async {
        await storage.close()
    }

    // MARK: - Monitoring flag

    /// Read the current monitoring enabled state from the control table.
    ///
    /// Returns `true` if the "monitoring" row has value "1", `false` otherwise.
    /// This is the authoritative read — the sink calls this on each `receive(_:)`.
    ///
    /// The read is cheap (primary-key lookup on a tiny table). If the row
    /// is absent (e.g. store not yet opened), returns `false` (safe default).
    ///
    /// - Throws: `StorageError` on I/O failure.
    public func isMonitoringEnabled() async throws -> Bool {
        let rows = try await storage.rowStore.query(
            table: StatsStoreSchema.controlTable,
            where: .eq(
                Column(table: StatsStoreSchema.controlTable, name: StatsStoreSchema.keyColumn),
                .text(StatsStoreSchema.monitoringKey)
            )
        )
        guard let row = rows.first,
              let valueTyped = row[StatsStoreSchema.controlValueColumn],
              case let .text(v) = valueTyped
        else { return false }
        return v == "1"
    }

    /// Set the monitoring flag.
    ///
    /// The manager calls this to broadcast the global on/off signal.
    /// Consumers' sinks read it on each `receive(_:)` call.
    ///
    /// - Parameter enabled: `true` to enable monitoring; `false` to disable.
    /// - Throws: `StorageError` on I/O failure.
    /// Sets the monitoring enabled flag and records that the user explicitly
    /// chose this value (`monitoring_source = "user"`). Writing the source
    /// marker prevents the wave 8.1 one-time migration from reverting a
    /// user-set "off" back to "on" on subsequent re-opens.
    public func setMonitoringEnabled(_ enabled: Bool) async throws {
        try await storage.rowStore.upsert(
            table: StatsStoreSchema.controlTable,
            values: [
                StatsStoreSchema.keyColumn: .text(StatsStoreSchema.monitoringKey),
                StatsStoreSchema.controlValueColumn: .text(enabled ? "1" : "0"),
            ],
            conflictColumns: [StatsStoreSchema.keyColumn]
        )
        // Mark as user-sourced so the wave 8.1 migration does not silently
        // flip it back to the default on the next open.
        try await upsertControlValue(key: StatsStoreSchema.monitoringSourceKey, value: "user")
    }

    // MARK: - Write: metric samples

    /// Insert one metric observation.
    ///
    /// Called by `PersistenceStatsSink` when a `.metric(...)` sample arrives.
    /// The `ts` Double (epoch seconds) is converted to ISO-8601 TEXT at this
    /// boundary — no REAL timestamp is stored.
    ///
    /// - Parameters:
    ///   - name:       Dot-separated metric name.
    ///   - value:      Measured quantity.
    ///   - tags:       String key-value context. Encoded as JSON TEXT.
    ///   - ts:         Caller-supplied epoch seconds (from StatSample.ts).
    ///   - dropboxID:  Identifier of the consumer that produced this sample.
    /// - Throws: `StorageError` on I/O failure.
    public func insertMetric(
        name: String,
        value: Double,
        tags: [String: String],
        ts: Double,
        dropboxID: String
    ) async throws {
        let tagsJSON = encodeTagsJSON(tags)
        _ = try await storage.rowStore.insert(
            table: StatsStoreSchema.metricSamplesTable,
            values: [
                "row_id": .uuid(UUID()),
                StatsStoreSchema.nameColumn: .text(name),
                StatsStoreSchema.valueColumn: .float(value),
                StatsStoreSchema.tagsColumn: .text(tagsJSON),
                // Epoch-seconds ts encoded as ISO-8601 TEXT (schema invariant).
                StatsStoreSchema.tsColumn: .timestamp(Date(timeIntervalSince1970: ts)),
                StatsStoreSchema.dropboxIDColumn: .text(dropboxID),
            ]
        )
    }

    // MARK: - Write: event samples

    /// Insert one topology event.
    ///
    /// Called by `PersistenceStatsSink` when an `.event(...)` sample arrives.
    ///
    /// - Parameters:
    ///   - kind:       EventKind raw string ("capture" or "think").
    ///   - nounType:   NounType ordinal from SubstrateTypes.
    ///   - rowID:      Row UUID string from the estate.
    ///   - estate:     Estate identifier string.
    ///   - ts:         Caller-supplied epoch seconds.
    ///   - dropboxID:  Identifier of the consumer that produced this sample.
    /// - Throws: `StorageError` on I/O failure.
    public func insertEvent(
        kind: String,
        nounType: Int,
        rowID: String,
        estate: String,
        ts: Double,
        dropboxID: String
    ) async throws {
        _ = try await storage.rowStore.insert(
            table: StatsStoreSchema.eventSamplesTable,
            values: [
                "row_id": .uuid(UUID()),
                StatsStoreSchema.kindColumn: .text(kind),
                StatsStoreSchema.nounTypeColumn: .int(Int64(nounType)),
                StatsStoreSchema.rowIDColumn: .text(rowID),
                StatsStoreSchema.estateColumn: .text(estate),
                StatsStoreSchema.tsColumn: .timestamp(Date(timeIntervalSince1970: ts)),
                StatsStoreSchema.dropboxIDColumn: .text(dropboxID),
            ]
        )
    }

    // MARK: - Topology snapshot (v2)

    /// Write or replace the topology snapshot for `estate`.
    ///
    /// The autonomic governor calls this after each topology-recompute duty cycle.
    /// The table uses `estate` as its PRIMARY KEY, so each call overwrites the
    /// previous row — only the current snapshot is kept (latest-wins, no history).
    ///
    /// `generatedAt` is stored as TEXT (ISO-8601 UTC) per the schema timestamp
    /// invariant. `payload` is the JSON-encoded ARIAGraphPayload bytes produced by
    /// the governor; the HTTP server serves them verbatim without re-encoding.
    ///
    /// - Parameters:
    ///   - estate:      Estate identifier string (PRIMARY KEY).
    ///   - generatedAt: Caller-supplied timestamp of when the governor produced this
    ///                  snapshot. No `Date()` call inside the store (determinism rule).
    ///   - payload:     JSON payload bytes. Stored as UTF-8 TEXT.
    ///   - fingerprint: Stable topology-inputs fingerprint (FNV-1a based, process
    ///                  independent) so a restarting governor can skip the full
    ///                  topology read when inputs are unchanged. `nil` leaves the
    ///                  column null (e.g. callers that do not compute a fingerprint).
    /// - Throws: `StorageError` on I/O failure.
    public func writeTopologySnapshot(
        estate: String,
        generatedAt: Date,
        payload: Data,
        fingerprint: String? = nil
    ) async throws {
        guard let payloadStr = String(data: payload, encoding: .utf8) else {
            // Payload must be valid UTF-8 JSON; the governor always produces valid UTF-8.
            throw StorageError.invalidQuery(detail: "topology snapshot payload is not valid UTF-8")
        }
        try await storage.rowStore.upsert(
            table: StatsStoreSchema.topologySnapshotsTable,
            values: [
                StatsStoreSchema.estateColumn: .text(estate),
                // ISO-8601 TEXT per schema invariant.
                StatsStoreSchema.generatedAtColumn: .timestamp(generatedAt),
                StatsStoreSchema.payloadColumn: .text(payloadStr),
                // Null when the caller supplies no fingerprint.
                StatsStoreSchema.topologyFingerprintColumn:
                    fingerprint.map { .text($0) } ?? .null,
            ],
            conflictColumns: [StatsStoreSchema.estateColumn]
        )
    }

    /// Read the latest topology snapshot bytes for `estate`.
    ///
    /// Returns `nil` when no snapshot has been written yet for this estate
    /// (governor has not completed its first duty cycle, or monitoring is
    /// disabled). The caller should return a `structurePending: true` response
    /// in this case.
    ///
    /// - Parameter estate: Estate identifier string (PRIMARY KEY lookup), or
    ///   `nil` for the newest snapshot across ALL estates. The moot-mgr
    ///   dashboard's default ("all estates") view reads with nil — it does
    ///   not know estate UUIDs; the governor writes one row per estate and
    ///   the newest `generated_at` wins.
    /// - Returns: The raw JSON payload `Data`, or `nil` if absent.
    /// - Throws: `StorageError` on I/O failure.
    public func latestTopologySnapshot(estate: String?) async throws -> Data? {
        let predicate: StoragePredicate? = estate.map { est in
            .eq(
                Column(table: StatsStoreSchema.topologySnapshotsTable,
                       name: StatsStoreSchema.estateColumn),
                .text(est)
            )
        }
        let rows = try await storage.rowStore.query(
            table: StatsStoreSchema.topologySnapshotsTable,
            where: predicate
        )
        // PRIMARY KEY lookup yields ≤1 row; the nil-estate path picks the
        // newest generated_at across estates. The column is written as
        // `.timestamp`, but the storage backend's read-back type differs:
        // InMemory returns `.timestamp`, SQLite returns `.text` (ISO-8601).
        // tolerate BOTH (otherwise SQLite ties every row and an arbitrary one
        // wins — a bug InMemory tests hide).
        let newest = rows.max { a, b in
            generatedAtInstant(a[StatsStoreSchema.generatedAtColumn])
                < generatedAtInstant(b[StatsStoreSchema.generatedAtColumn])
        }
        guard let row = newest,
              let payloadTyped = row[StatsStoreSchema.payloadColumn],
              case let .text(payloadStr) = payloadTyped
        else { return nil }
        return payloadStr.data(using: .utf8)
    }

    /// Read the persisted topology fingerprint for `estate`.
    ///
    /// The autonomic governor calls this once on startup so it can compare the
    /// persisted topology-inputs fingerprint against freshly-computed inputs and
    /// skip the full drawer/tunnel/fact read when they match. Returns `nil` when
    /// no snapshot exists yet, when the row predates v3 (column null), or when a
    /// snapshot was written without a fingerprint.
    ///
    /// - Parameter estate: Estate identifier string (PRIMARY KEY lookup).
    /// - Returns: The stored fingerprint string, or `nil` if absent/null.
    /// - Throws: `StorageError` on I/O failure.
    public func loadTopologyFingerprint(estate: String) async throws -> String? {
        let rows = try await storage.rowStore.query(
            table: StatsStoreSchema.topologySnapshotsTable,
            where: .eq(
                Column(table: StatsStoreSchema.topologySnapshotsTable,
                       name: StatsStoreSchema.estateColumn),
                .text(estate)
            )
        )
        // PRIMARY KEY lookup yields ≤1 row. The column is written as `.text` or
        // `.null`; the backend may read it back as `.text` (SQLite/InMemory) — any
        // non-text representation (null, absent) yields nil.
        guard let row = rows.first,
              let cell = row[StatsStoreSchema.topologyFingerprintColumn],
              case let .text(fingerprint) = cell
        else { return nil }
        return fingerprint
    }

    /// The `generated_at` cell as a comparable instant, tolerating both
    /// read-back representations: InMemory returns `.timestamp(Date)`; SQLite
    /// returns `.text` (ISO-8601 UTC). The old code matched only `.timestamp`,
    /// so under SQLite every row tied at `.distantPast` and an arbitrary one
    /// won — a bug InMemory tests hide. Absent / unparseable sorts oldest.
    private func generatedAtInstant(_ value: TypedValue?) -> Date {
        switch value {
        case let .timestamp(d)?: return d
        case let .text(s)?: return Self.iso8601Formatter.date(from: s) ?? .distantPast
        default: return .distantPast
        }
    }

    // MARK: - Read: metric samples

    /// Query metric samples, optionally filtering by dropbox.
    ///
    /// Returns rows ordered by `ts` ascending (oldest first).
    ///
    /// - Parameter dropboxID: If non-nil, only rows from this dropbox are returned.
    /// - Returns: Array of `MetricRow` structs.
    /// - Throws: `StorageError` on I/O failure.
    public func queryMetrics(dropboxID: String? = nil) async throws -> [MetricRow] {
        let predicate: StoragePredicate? = dropboxID.map { id in
            .eq(Column(table: StatsStoreSchema.metricSamplesTable,
                       name: StatsStoreSchema.dropboxIDColumn), .text(id))
        }
        let rows = try await storage.rowStore.query(
            table: StatsStoreSchema.metricSamplesTable,
            where: predicate,
            orderBy: [OrderClause(column: Column(
                table: StatsStoreSchema.metricSamplesTable,
                name: StatsStoreSchema.tsColumn
            ), direction: .ascending)],
            limit: nil,
            offset: nil
        )
        return rows.compactMap(MetricRow.init(storageRow:))
    }

    /// Query metric samples whose `name` is in `names`.
    ///
    /// Issues a `WHERE name IN (...)` predicate — reads only the named rows
    /// rather than the full table. Use this in all hot read-API paths instead of
    /// `queryMetrics(dropboxID:)` + Swift-side filter.
    ///
    /// - Parameters:
    ///   - names: The set of metric names to retrieve. If empty, returns [] immediately.
    ///   - dropboxID: Optional additional filter by dropbox. nil = all dropboxes.
    /// - Returns: Matching rows ordered by ts ascending (oldest first).
    /// - Throws: `StorageError` on I/O failure.
    public func queryMetricsByNames(
        _ names: Set<String>,
        dropboxID: String? = nil
    ) async throws -> [MetricRow] {
        guard !names.isEmpty else { return [] }

        // StoragePredicate.in emits `WHERE name IN ('n1', 'n2', ...)` — the SQLite
        // query planner reads only rows matching the named set; no full-table scan.
        let nameCol = Column(
            table: StatsStoreSchema.metricSamplesTable,
            name: StatsStoreSchema.nameColumn)
        let namePredicate = StoragePredicate.in(nameCol, names.map { .text($0) })

        let predicate: StoragePredicate
        if let id = dropboxID {
            let dbCol = Column(
                table: StatsStoreSchema.metricSamplesTable,
                name: StatsStoreSchema.dropboxIDColumn)
            predicate = .and([namePredicate, .eq(dbCol, .text(id))])
        } else {
            predicate = namePredicate
        }

        let rows = try await storage.rowStore.query(
            table: StatsStoreSchema.metricSamplesTable,
            where: predicate,
            orderBy: [OrderClause(column: Column(
                table: StatsStoreSchema.metricSamplesTable,
                name: StatsStoreSchema.tsColumn
            ), direction: .ascending)],
            limit: nil,
            offset: nil
        )
        return rows.compactMap(MetricRow.init(storageRow:))
    }

    /// Count total metric rows without reading their content.
    ///
    /// Used by `serverPayload()` to report `totalMetrics` without a full-row decode.
    /// Delegates to `RowStore.count(table:where:)` — maps to a SQL `COUNT(*)` with
    /// no row decoding.
    ///
    /// - Returns: Total number of rows in `metric_samples`.
    /// - Throws: `StorageError` on I/O failure.
    public func countMetrics() async throws -> Int {
        // COUNT(*) with no predicate — cheapest possible aggregate; no row decoding.
        try await storage.rowStore.count(
            table: StatsStoreSchema.metricSamplesTable,
            where: nil
        )
    }

    /// Query event samples, optionally filtering by dropbox.
    ///
    /// Returns rows ordered by `ts` ascending (oldest first).
    ///
    /// - Parameter dropboxID: If non-nil, only rows from this dropbox are returned.
    /// - Returns: Array of `EventRow` structs.
    /// - Throws: `StorageError` on I/O failure.
    public func queryEvents(dropboxID: String? = nil) async throws -> [EventRow] {
        let predicate: StoragePredicate? = dropboxID.map { id in
            .eq(Column(table: StatsStoreSchema.eventSamplesTable,
                       name: StatsStoreSchema.dropboxIDColumn), .text(id))
        }
        let rows = try await storage.rowStore.query(
            table: StatsStoreSchema.eventSamplesTable,
            where: predicate,
            orderBy: [OrderClause(column: Column(
                table: StatsStoreSchema.eventSamplesTable,
                name: StatsStoreSchema.tsColumn
            ), direction: .ascending)],
            limit: nil,
            offset: nil
        )
        return rows.compactMap(EventRow.init(storageRow:))
    }

    // MARK: - Retention

    /// Delete metric samples with `ts` strictly before `cutoff`.
    ///
    /// The caller supplies the cutoff — no `Date()` call inside this engine.
    /// The manager calls this on its retention schedule, passing a caller-held
    /// `Date` computed from `Date.now.addingTimeInterval(-retentionWindow)`.
    ///
    /// After deletion, the "retention_cutoff" control row is updated to record
    /// the cutoff timestamp so the dashboard can display when the last roll-off ran.
    ///
    /// - Parameters:
    ///   - cutoff:    Delete rows strictly older than this timestamp.
    ///   - now:       The caller's current time (used to update the control row).
    /// - Returns: Number of rows deleted.
    /// - Throws: `StorageError` on I/O failure.
    @discardableResult
    public func deleteMetricsBefore(cutoff: Date, now: Date) async throws -> Int {
        let deleted = try await storage.rowStore.delete(
            table: StatsStoreSchema.metricSamplesTable,
            where: .lt(
                Column(table: StatsStoreSchema.metricSamplesTable,
                       name: StatsStoreSchema.tsColumn),
                .timestamp(cutoff)
            )
        )
        try await recordRetentionCutoff(cutoff, now: now)
        return deleted
    }

    /// Delete event samples with `ts` strictly before `cutoff`.
    ///
    /// Same semantics as `deleteMetricsBefore(cutoff:now:)`.
    ///
    /// - Parameters:
    ///   - cutoff:    Delete rows strictly older than this timestamp.
    ///   - now:       The caller's current time (used to update the control row).
    /// - Returns: Number of rows deleted.
    /// - Throws: `StorageError` on I/O failure.
    @discardableResult
    public func deleteEventsBefore(cutoff: Date, now: Date) async throws -> Int {
        let deleted = try await storage.rowStore.delete(
            table: StatsStoreSchema.eventSamplesTable,
            where: .lt(
                Column(table: StatsStoreSchema.eventSamplesTable,
                       name: StatsStoreSchema.tsColumn),
                .timestamp(cutoff)
            )
        )
        try await recordRetentionCutoff(cutoff, now: now)
        return deleted
    }

    // MARK: - DB-layer health

    /// Capture a point-in-time snapshot of the store's own backend health.
    ///
    /// The manager (`moot-mgr`) calls this to report the stats store's own
    /// DB-layer health (WAL frame count, file size, page/freelist counts) in
    /// its status surface. This is the store's *own* storage — distinct from
    /// any observed estate's storage.
    ///
    /// Implemented via the backing storage's `StorageIntrospection`
    /// capability. The SQLite backend conforms directly, so this always
    /// returns a value; the optional return type is kept for API stability.
    ///
    /// - Parameter now: The timestamp to stamp on the snapshot (determinism
    ///   rule: the caller owns the clock; no `Date()` inside the store).
    /// - Returns: A `StorageStats` snapshot, or `nil` if the backend does not
    ///   support introspection.
    /// - Throws: `StorageError` on I/O failure while gathering statistics.
    public func storageStats(now: Date) async throws -> StorageStats? {
        // SQLiteStorage conforms to StorageIntrospection directly.
        let introspectable = storage as StorageIntrospection
        return try await introspectable.stats(now: now)
    }

    // MARK: - Internal helpers

    /// Update the "retention_cutoff" control row.
    /// Records the ISO-8601 string of `cutoff` for display by the manager dashboard.
    private func recordRetentionCutoff(_ cutoff: Date, now: Date) async throws {
        // `now` is accepted for determinism (the caller owns the clock).
        // Currently we record the cutoff (not now) so the dashboard shows
        // "data older than X was rolled off" rather than "rolloff ran at X".
        // This is the more useful value for the 5-view dashboard (§4 Phase 3).
        let iso = Self.iso8601Formatter.string(from: cutoff)
        try await storage.rowStore.upsert(
            table: StatsStoreSchema.controlTable,
            values: [
                StatsStoreSchema.keyColumn: .text(StatsStoreSchema.retentionCutoffKey),
                StatsStoreSchema.controlValueColumn: .text(iso),
            ],
            conflictColumns: [StatsStoreSchema.keyColumn]
        )
    }

    // MARK: - ISO-8601 formatting

    /// Shared ISO-8601 formatter. Thread-safe (DateFormatter is not, but
    /// this is a static constant so it is initialised once and never mutated).
    ///
    /// Format: "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'" — UTC, millisecond precision.
    /// Matches the format used by SQLiteStorage's timestamp codec so round-trip
    /// reads reproduce the original value.
    static let iso8601Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    // MARK: - JSON tag encoding

    /// Encode a [String: String] tag map to a compact JSON string.
    ///
    /// An empty tag map encodes as "{}". Tags with non-encodable characters
    /// fall back to "{}" (silent; the metric is still stored without tags).
    ///
    /// The Rust port uses `serde_json::to_string` with the same BTreeMap<String,String>
    /// semantics — key order may differ but the decoder reconstructs the same map.
    private func encodeTagsJSON(_ tags: [String: String]) -> String {
        guard !tags.isEmpty else { return "{}" }
        guard let data = try? JSONSerialization.data(
            withJSONObject: tags,
            options: [.sortedKeys]   // .sortedKeys for determinism (consistent encoding)
        ),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    /// Decode a JSON string back into a [String: String] tag map.
    ///
    /// Returns an empty dictionary on parse failure (forward-compatible —
    /// an unknown future tag format is silently treated as empty tags).
    static func decodeTagsJSON(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: String]
        else { return [:] }
        return dict
    }
}

// MARK: - Row result types

/// A decoded metric sample row from the `metric_samples` table.
public struct MetricRow: Sendable {
    /// Row's synthetic UUID (assigned by the store, not the emitter).
    public let rowID: UUID
    /// Dot-separated metric name.
    public let name: String
    /// Measured quantity.
    public let value: Double
    /// String key-value context.
    public let tags: [String: String]
    /// Timestamp (converted back from ISO-8601 storage).
    public let ts: Date
    /// Consumer dropbox identifier.
    public let dropboxID: String

    /// Initialise from a `StorageRow`. Returns `nil` if required columns are absent or wrong type.
    init?(storageRow row: StorageRow) {
        guard
            let rowIDTyped = row["row_id"], case let .uuid(id) = rowIDTyped,
            let nameTyped = row[StatsStoreSchema.nameColumn], case let .text(n) = nameTyped,
            let valueTyped = row[StatsStoreSchema.valueColumn], case let .float(v) = valueTyped,
            let tagsTyped = row[StatsStoreSchema.tagsColumn], case let .text(tagsStr) = tagsTyped,
            let tsTyped = row[StatsStoreSchema.tsColumn], case let .timestamp(t) = tsTyped,
            let dropboxTyped = row[StatsStoreSchema.dropboxIDColumn],
            case let .text(dbox) = dropboxTyped
        else { return nil }
        self.rowID = id
        self.name = n
        self.value = v
        self.tags = StatsStore.decodeTagsJSON(tagsStr)
        self.ts = t
        self.dropboxID = dbox
    }
}

/// A decoded event sample row from the `event_samples` table.
public struct EventRow: Sendable {
    /// Row's synthetic UUID.
    public let rowID: UUID
    /// EventKind raw string: "capture" or "think".
    public let kind: String
    /// NounType ordinal from SubstrateTypes.
    public let nounType: Int
    /// Row UUID string from the estate.
    public let rowIDStr: String
    /// Estate identifier string.
    public let estate: String
    /// Timestamp (converted back from ISO-8601 storage).
    public let ts: Date
    /// Consumer dropbox identifier.
    public let dropboxID: String

    /// Initialise from a `StorageRow`. Returns `nil` if required columns are absent or wrong type.
    init?(storageRow row: StorageRow) {
        guard
            let rowIDTyped = row["row_id"], case let .uuid(id) = rowIDTyped,
            let kindTyped = row[StatsStoreSchema.kindColumn], case let .text(k) = kindTyped,
            let nounTypeTyped = row[StatsStoreSchema.nounTypeColumn],
            case let .int(nt) = nounTypeTyped,
            let rowIDStrTyped = row[StatsStoreSchema.rowIDColumn],
            case let .text(rid) = rowIDStrTyped,
            let estateTyped = row[StatsStoreSchema.estateColumn],
            case let .text(est) = estateTyped,
            let tsTyped = row[StatsStoreSchema.tsColumn], case let .timestamp(t) = tsTyped,
            let dropboxTyped = row[StatsStoreSchema.dropboxIDColumn],
            case let .text(dbox) = dropboxTyped
        else { return nil }
        self.rowID = id
        self.kind = k
        self.nounType = Int(nt)
        self.rowIDStr = rid
        self.estate = est
        self.ts = t
        self.dropboxID = dbox
    }
}
