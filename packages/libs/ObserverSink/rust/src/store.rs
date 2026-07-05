//! StatsStore — SQLite stats-store schema, open/migrate, and retention.
//!
//! Mirrors Swift's `StatsStore` type exactly:
//!   - Same three tables (metric_samples, event_samples, control).
//!   - Same column names and types.
//!   - All timestamps stored as TEXT (ISO-8601 UTC).
//!   - Retention methods take a caller-supplied cutoff — no clock reads inside.
//!   - Monitoring flag: "monitoring" row in `control` table, value "1"/"0".
//!
//! ## Thread safety
//!
//! `StatsStore` wraps a `persistence_kit::SqliteStorage` behind an `Arc<Mutex>`.
//! The `rusqlite` connection is serialised behind a `Mutex` inside `SqliteStorage`,
//! so concurrent `receive` calls from multiple threads are safe.

use std::collections::BTreeMap;
use std::sync::Arc;

use chrono::{DateTime, TimeZone, Utc};
use persistence_kit::{
    BackendConfiguration, ColumnDeclaration, ColumnType, EstateConfiguration, IndexDeclaration,
    Migration, OrderDirection, SchemaDeclaration, SchemaOperation, SqliteStorage, Storage,
    StoragePredicate, StorageRow, TableDeclaration, TypedValue, Column,
    OrderClause as PkOrderClause,
};
use uuid::Uuid;

// ─────────────────────────────────────────────────────────────────────────────
// Schema constants — mirrors StatsStoreSchema in Swift.
// Gather all string literals here so a rename is one-place.
// ─────────────────────────────────────────────────────────────────────────────

/// Column and table name constants for the stats store.
/// Mirrors Swift's `StatsStoreSchema` enum.
pub struct StatsStoreSchema;

impl StatsStoreSchema {
    // Table names

    /// Metric observations table.
    pub const METRIC_SAMPLES_TABLE: &'static str = "metric_samples";

    /// Topology events table.
    pub const EVENT_SAMPLES_TABLE: &'static str = "event_samples";

    /// Control table (key-value pairs: monitoring flag + retention metadata).
    pub const CONTROL_TABLE: &'static str = "control";

    // Shared column names

    /// TEXT (ISO-8601 UTC) — epoch-seconds ts from StatSample, encoded at boundary.
    pub const TS_COLUMN: &'static str = "ts";

    /// TEXT — consumer dropbox identifier.
    pub const DROPBOX_ID_COLUMN: &'static str = "dropbox_id";

    // metric_samples columns

    /// TEXT NOT NULL — dot-separated metric name.
    pub const NAME_COLUMN: &'static str = "name";

    /// REAL NOT NULL — measured quantity.
    pub const VALUE_COLUMN: &'static str = "value";

    /// TEXT NOT NULL — JSON-encoded tag map.
    pub const TAGS_COLUMN: &'static str = "tags";

    // event_samples columns

    /// TEXT NOT NULL — EventKind raw string: "capture" or "think".
    pub const KIND_COLUMN: &'static str = "kind";

    /// INTEGER NOT NULL — NounType ordinal.
    pub const NOUN_TYPE_COLUMN: &'static str = "noun_type";

    /// TEXT NOT NULL — row UUID string from the estate (substrate entity UUID).
    /// Named "estate_row_id" to avoid collision with the synthetic primary key "row_id".
    pub const ROW_ID_COLUMN: &'static str = "estate_row_id";

    /// TEXT NOT NULL — estate identifier string.
    pub const ESTATE_COLUMN: &'static str = "estate";

    // control table columns

    /// TEXT NOT NULL PRIMARY KEY — control key.
    pub const KEY_COLUMN: &'static str = "key";

    /// TEXT NOT NULL — control value.
    pub const CONTROL_VALUE_COLUMN: &'static str = "value";

    // Well-known control row keys

    /// Key for the global monitoring on/off flag. Value "1" = on, "0" = off.
    pub const MONITORING_KEY: &'static str = "monitoring";

    /// Key for the ISO-8601 timestamp of the last retention pass cutoff.
    pub const RETENTION_CUTOFF_KEY: &'static str = "retention_cutoff";

    /// Key for the monitoring source marker.
    ///
    /// Value "default" means the monitoring flag was set by the wave 8.1 seed or
    /// one-time migration — the operator has NOT explicitly chosen a value, so a
    /// future migration is allowed to override it.
    /// Value "user" means the operator explicitly called `setMonitoringEnabled` and
    /// the migration MUST NOT revert that choice on re-open.
    ///
    /// Mirrors Swift `StatsStore.monitoringSourceKey`.
    pub const MONITORING_SOURCE_KEY: &'static str = "monitoring_source";

    // topology_snapshots table (v2)

    /// One row per estate. Latest-wins upsert via estate PRIMARY KEY.
    pub const TOPOLOGY_SNAPSHOTS_TABLE: &'static str = "topology_snapshots";

    /// TEXT NOT NULL — ISO-8601 UTC timestamp of when the governor produced the snapshot.
    pub const GENERATED_AT_COLUMN: &'static str = "generated_at";

    /// TEXT NOT NULL — JSON-encoded ARIAGraphPayload bytes. Served verbatim by /api/graph.
    pub const PAYLOAD_COLUMN: &'static str = "payload";

    /// TEXT NULL (v3) — stable topology-inputs fingerprint for the persisted snapshot.
    /// The autonomic governor writes this alongside the payload so that, on restart,
    /// it can compare the persisted fingerprint against freshly-computed topology
    /// inputs WITHOUT re-reading all drawers/tunnels/facts when nothing changed.
    /// Nullable so snapshots written without a fingerprint read back as None.
    /// Mirrors Swift `StatsStoreSchema.topologyFingerprintColumn`.
    pub const TOPOLOGY_FINGERPRINT_COLUMN: &'static str = "topology_fingerprint";
}

// ─────────────────────────────────────────────────────────────────────────────
// Schema declaration — mirrors Swift's `StatsStore.schema`
// ─────────────────────────────────────────────────────────────────────────────

fn make_schema() -> SchemaDeclaration {
    // Helper: ColumnDeclaration constructors mirror Swift's ColumnDeclaration extension.
    fn col_uuid(name: &str) -> ColumnDeclaration {
        ColumnDeclaration {
            name: name.to_string(),
            column_type: ColumnType::Uuid,
            nullable: false,
            default_value: None,
            role: None,
        }
    }
    fn col_text(name: &str) -> ColumnDeclaration {
        ColumnDeclaration {
            name: name.to_string(),
            column_type: ColumnType::Text,
            nullable: false,
            default_value: None,
            role: None,
        }
    }
    fn col_text_nullable(name: &str) -> ColumnDeclaration {
        ColumnDeclaration {
            name: name.to_string(),
            column_type: ColumnType::Text,
            nullable: true,
            default_value: None,
            role: None,
        }
    }
    fn col_float(name: &str) -> ColumnDeclaration {
        ColumnDeclaration {
            name: name.to_string(),
            column_type: ColumnType::Float,
            nullable: false,
            default_value: None,
            role: None,
        }
    }
    fn col_int(name: &str) -> ColumnDeclaration {
        ColumnDeclaration {
            name: name.to_string(),
            column_type: ColumnType::Int,
            nullable: false,
            default_value: None,
            role: None,
        }
    }
    fn col_timestamp(name: &str) -> ColumnDeclaration {
        ColumnDeclaration {
            name: name.to_string(),
            column_type: ColumnType::Timestamp,
            nullable: false,
            default_value: None,
            role: None,
        }
    }

    SchemaDeclaration {
        kit_id: "ObserverSink".to_string(),
        version: StatsStore::SCHEMA_VERSION,
        tables: vec![
            // MARK: metric_samples
            //
            // One row per metric observation. `tags` is JSON TEXT for the flat
            // string-string map. `ts` is TEXT (ISO-8601) per the schema invariant.
            TableDeclaration {
                name: StatsStoreSchema::METRIC_SAMPLES_TABLE.to_string(),
                columns: vec![
                    col_uuid("row_id"),
                    col_text(StatsStoreSchema::NAME_COLUMN),
                    col_float(StatsStoreSchema::VALUE_COLUMN),
                    col_text(StatsStoreSchema::TAGS_COLUMN),
                    col_timestamp(StatsStoreSchema::TS_COLUMN),
                    col_text(StatsStoreSchema::DROPBOX_ID_COLUMN),
                ],
                primary_key: vec!["row_id".to_string()],
                unique_constraints: vec![],
                generated_columns: vec![],
                append_only: false,
                hashable: false,
            },

            // MARK: event_samples
            //
            // One row per topology event. `estate_row_id` is the substrate
            // entity's UUID string (distinct from the synthetic PK "row_id").
            TableDeclaration {
                name: StatsStoreSchema::EVENT_SAMPLES_TABLE.to_string(),
                columns: vec![
                    col_uuid("row_id"),
                    col_text(StatsStoreSchema::KIND_COLUMN),
                    col_int(StatsStoreSchema::NOUN_TYPE_COLUMN),
                    col_text(StatsStoreSchema::ROW_ID_COLUMN),   // estate_row_id
                    col_text(StatsStoreSchema::ESTATE_COLUMN),
                    col_timestamp(StatsStoreSchema::TS_COLUMN),
                    col_text(StatsStoreSchema::DROPBOX_ID_COLUMN),
                ],
                primary_key: vec!["row_id".to_string()],
                unique_constraints: vec![],
                generated_columns: vec![],
                append_only: false,
                hashable: false,
            },

            // MARK: control
            //
            // Key-value pairs. key is the primary key (upsert semantics).
            TableDeclaration {
                name: StatsStoreSchema::CONTROL_TABLE.to_string(),
                columns: vec![
                    col_text(StatsStoreSchema::KEY_COLUMN),
                    col_text(StatsStoreSchema::CONTROL_VALUE_COLUMN),
                ],
                primary_key: vec![StatsStoreSchema::KEY_COLUMN.to_string()],
                unique_constraints: vec![],
                generated_columns: vec![],
                append_only: false,
                hashable: false,
            },

            // MARK: topology_snapshots (v2)
            //
            // One row per estate. The autonomic governor upserts here after each
            // topology-recompute duty cycle. `estate` is the PRIMARY KEY so each
            // write overwrites the previous row — no history accumulation.
            // `generated_at` is TEXT (ISO-8601 UTC) per the schema timestamp invariant.
            // `payload` is TEXT storing JSON-encoded ARIAGraphPayload bytes served verbatim.
            //
            // Added by v1→v2 migration (table); topology_fingerprint added by v2→v3.
            TableDeclaration {
                name: StatsStoreSchema::TOPOLOGY_SNAPSHOTS_TABLE.to_string(),
                columns: vec![
                    // Estate identifier — one row per estate, primary key.
                    col_text(StatsStoreSchema::ESTATE_COLUMN),
                    // ISO-8601 TEXT timestamp when the governor produced this snapshot.
                    col_timestamp(StatsStoreSchema::GENERATED_AT_COLUMN),
                    // JSON payload bytes (TEXT). Served verbatim; no decode on read path.
                    col_text(StatsStoreSchema::PAYLOAD_COLUMN),
                    // Stable topology-inputs fingerprint (v3). Nullable — pre-v3 rows
                    // and snapshots written without a fingerprint read back as None.
                    col_text_nullable(StatsStoreSchema::TOPOLOGY_FINGERPRINT_COLUMN),
                ],
                primary_key: vec![StatsStoreSchema::ESTATE_COLUMN.to_string()],
                unique_constraints: vec![],
                generated_columns: vec![],
                append_only: false,
                hashable: false,
            },
        ],
        indices: vec![
            // Index on metric_samples.ts for fast retention deletes.
            IndexDeclaration {
                name: "idx_metric_samples_ts".to_string(),
                table: StatsStoreSchema::METRIC_SAMPLES_TABLE.to_string(),
                columns: vec![StatsStoreSchema::TS_COLUMN.to_string()],
                unique: false,
            },
            // Index on event_samples.ts for fast retention deletes.
            IndexDeclaration {
                name: "idx_event_samples_ts".to_string(),
                table: StatsStoreSchema::EVENT_SAMPLES_TABLE.to_string(),
                columns: vec![StatsStoreSchema::TS_COLUMN.to_string()],
                unique: false,
            },
        ],
        migrations: vec![
            // v1 → v2: add topology_snapshots table.
            // Additive migration — no existing rows are touched. The new table
            // starts empty; the governor populates it on its first duty cycle.
            Migration {
                from_version: 1,
                to_version: 2,
                operations: vec![
                    SchemaOperation::CreateTable(TableDeclaration {
                        name: StatsStoreSchema::TOPOLOGY_SNAPSHOTS_TABLE.to_string(),
                        columns: vec![
                            col_text(StatsStoreSchema::ESTATE_COLUMN),
                            col_timestamp(StatsStoreSchema::GENERATED_AT_COLUMN),
                            col_text(StatsStoreSchema::PAYLOAD_COLUMN),
                        ],
                        primary_key: vec![StatsStoreSchema::ESTATE_COLUMN.to_string()],
                        unique_constraints: vec![],
                        generated_columns: vec![],
                        append_only: false,
                        hashable: false,
                    }),
                ],
            },
            // v2 → v3: add the nullable topology_fingerprint column.
            // Additive migration — existing snapshot rows keep their payload and
            // read back the fingerprint as None (governor recomputes once, then
            // backfills the fingerprint on its next topology duty cycle).
            //
            // NOTE: the SQLite backend creates every table at the latest schema on
            // open (CREATE TABLE IF NOT EXISTS) and does not replay these operations,
            // so a fresh SQLite DB already carries the column; the InMemory backend
            // replays them (idempotently). This entry mirrors the Swift declaration.
            Migration {
                from_version: 2,
                to_version: 3,
                operations: vec![
                    SchemaOperation::AddColumn {
                        table: StatsStoreSchema::TOPOLOGY_SNAPSHOTS_TABLE.to_string(),
                        column: col_text_nullable(StatsStoreSchema::TOPOLOGY_FINGERPRINT_COLUMN),
                    },
                ],
            },
        ],
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ISO-8601 helpers — mirrors Swift's `StatsStore.iso8601Formatter`
// ─────────────────────────────────────────────────────────────────────────────

/// Minimum and maximum Unix epoch seconds that map to displayable ISO-8601
/// years in the 0001–9999 range.  PersistenceKit's timestamp encoder
/// enforces the same bounds; matching them here keeps TEXT timestamps
/// consistent across all write paths.
///
/// MIN_EPOCH: 0001-01-01T00:00:00Z (year 0001)
/// MAX_EPOCH: 9999-12-31T23:59:59Z (year 9999)
const MIN_EPOCH_SECS: i64 = -62_135_596_800;
const MAX_EPOCH_SECS: i64 =  253_402_300_799;

/// Encode epoch seconds (f64) to ISO-8601 UTC TEXT with millisecond precision.
/// Mirrors Swift: `DateFormatter` with `"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"`.
///
/// Clamps the timestamp to years 0001–9999 before formatting, matching
/// PersistenceKit's epoch clamping. Out-of-range epoch values (negative
/// extremes, NaN, infinity) produce malformed TEXT years outside the four-digit
/// range that ISO-8601 mandates, which breaks SQLite's datetime() functions and
/// downstream parsers. Clamping prevents that without rejecting the write.
pub(crate) fn epoch_to_iso8601(secs: f64) -> String {
    // Saturating cast: in Rust ≥ 1.45, f64-as-i64 saturates at i64 bounds
    // for out-of-range values (including ±∞ and NaN → 0). The subsequent
    // clamp then brings the value into the year 0001–9999 epoch window.
    let whole_secs = (secs.floor() as i64).clamp(MIN_EPOCH_SECS, MAX_EPOCH_SECS);
    let nanos = ((secs - secs.floor()).clamp(0.0, 0.999_999_999) * 1_000_000_000.0) as u32;
    match Utc.timestamp_opt(whole_secs, nanos) {
        chrono::LocalResult::Single(dt) => dt.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string(),
        _ => "1970-01-01T00:00:00.000Z".to_string(),
    }
}

/// Decode an ISO-8601 UTC TEXT timestamp back to epoch seconds (f64).
/// Returns 0.0 on parse failure.
pub(crate) fn iso8601_to_epoch(s: &str) -> f64 {
    // Try RFC-3339 parse (superset of ISO-8601 with trailing 'Z').
    s.parse::<DateTime<Utc>>()
        .map(|dt| dt.timestamp() as f64 + dt.timestamp_subsec_millis() as f64 / 1000.0)
        .unwrap_or(0.0)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tag JSON helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Encode a BTreeMap<String, String> tag map to JSON TEXT.
/// Uses BTreeMap for deterministic key ordering (mirrors Swift's `.sortedKeys`).
pub(crate) fn encode_tags_json(tags: &BTreeMap<String, String>) -> String {
    if tags.is_empty() {
        return "{}".to_string();
    }
    serde_json::to_string(tags).unwrap_or_else(|_| "{}".to_string())
}

/// Decode a JSON TEXT string back to BTreeMap<String, String>.
/// Returns an empty map on parse failure.
pub(crate) fn decode_tags_json(json: &str) -> BTreeMap<String, String> {
    serde_json::from_str(json).unwrap_or_default()
}

// ─────────────────────────────────────────────────────────────────────────────
// StatsStore
// ─────────────────────────────────────────────────────────────────────────────

/// Manages the SQLite stats store.
///
/// Mirrors Swift's `StatsStore` class:
/// - Schema declaration + open/migrate.
/// - Monitoring flag read/write.
/// - `insert_metric` / `insert_event`.
/// - `query_metrics` / `query_events`.
/// - `delete_metrics_before` / `delete_events_before` (retention).
///
/// All methods take `&self` (the underlying storage is synchronised internally
/// by `SqliteStorage`'s `Mutex`-backed connection).
pub struct StatsStore {
    storage: Arc<SqliteStorage>,
}

impl StatsStore {
    /// Current schema version for ObserverSink.
    /// Mirrors `StatsStore.schemaVersion` in Swift.
    /// v1: initial schema (metric_samples, event_samples, control).
    /// v2: added topology_snapshots table (one row per estate, latest-wins upsert).
    /// v3: added topology_snapshots.topology_fingerprint (nullable) so the governor
    ///     can skip the full topology read on restart when inputs are unchanged.
    pub const SCHEMA_VERSION: i32 = 3;

    // MARK: - Initialisation

    /// Create a `StatsStore` backed by a SQLite database at `path`.
    ///
    /// Call `open()` before performing any I/O.
    ///
    /// - `path`: Filesystem path to the SQLite database file. Created if absent.
    pub fn new(path: &str) -> Result<Self, persistence_kit::StorageError> {
        let storage = SqliteStorage::new(EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string(),
                busy_timeout_secs: 5.0,
            },
        ))?;
        Ok(StatsStore {
            storage: Arc::new(storage),
        })
    }

    // MARK: - Lifecycle

    /// Open the store and apply schema / migrations.
    ///
    /// Seeds the default control rows only if absent (seed-if-absent, NOT upsert).
    ///
    /// Rationale: upsert would overwrite an operator-set "monitoring" value on
    /// every process restart, resetting the persistent on/off switch on each
    /// relaunch. Seeding only when the row is missing means the first open installs
    /// the defaults and every subsequent open is a no-op for those rows. Mirrors
    /// Swift `StatsStore.open()` / `seedControlIfAbsent` exactly.
    ///
    /// Wave 8.1: monitoring defaults ON for new estates (seed "1", not "0") and
    /// a companion "monitoring_source" row is seeded as "default". The one-time
    /// migration below flips existing estates that were seeded at "0" by a pre-8.1
    /// binary — but only if the operator has not explicitly set monitoring via
    /// `setMonitoringEnabled` (source != "user"). Mirrors Swift `StatsStore.open()`.
    pub fn open(&self) -> Result<(), persistence_kit::StorageError> {
        let schema = make_schema();
        self.storage.open(&schema)?;

        // Seed "monitoring" = "1" (on by default, wave 8.1) only if absent.
        // Overwriting would reset the operator's on/off switch on every restart.
        self.seed_control_if_absent(
            StatsStoreSchema::MONITORING_KEY,
            "1",
        )?;

        // Seed "monitoring_source" = "default" only if absent.
        // The source marker distinguishes a seed/migration value ("default") from
        // an explicit operator choice ("user"). setMonitoringEnabled writes "user"
        // so the migration below never reverts an explicit operator decision.
        self.seed_control_if_absent(
            StatsStoreSchema::MONITORING_SOURCE_KEY,
            "default",
        )?;

        // Wave 8.1 one-time migration: flip monitoring "0" → "1" for estates
        // that were seeded by a pre-8.1 binary (default-off seed), BUT only when
        // the operator has not explicitly chosen a value (source != "user").
        // If the operator turned monitoring off intentionally, we must not revert
        // that choice here — the "user" marker is the guard.
        let current_monitoring = self.read_control_value(StatsStoreSchema::MONITORING_KEY)?;
        let current_source = self.read_control_value(StatsStoreSchema::MONITORING_SOURCE_KEY)?;
        let source_is_default = current_source.as_deref().map_or(true, |s| s != "user");
        if current_monitoring.as_deref() == Some("0") && source_is_default {
            // Pre-8.1 seeded "0" with no operator override → upgrade to "1".
            self.upsert_control_value(StatsStoreSchema::MONITORING_KEY, "1")?;
        }

        // Seed "retention_cutoff" = epoch-zero ISO-8601 only if absent.
        // Epoch zero indicates no retention pass has run yet.
        self.seed_control_if_absent(
            StatsStoreSchema::RETENTION_CUTOFF_KEY,
            "1970-01-01T00:00:00.000Z",
        )?;

        Ok(())
    }

    /// Read a single control-table value by key. Returns None if the key is absent.
    fn read_control_value(&self, key: &str) -> Result<Option<String>, persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let predicate = StoragePredicate::Eq(
            Column {
                table: StatsStoreSchema::CONTROL_TABLE.to_string(),
                name: StatsStoreSchema::KEY_COLUMN.to_string(),
            },
            TypedValue::Text(key.to_string()),
        );
        let rows = rs.query(StatsStoreSchema::CONTROL_TABLE, Some(&predicate), &[], Some(1), None)?;
        Ok(rows.first().and_then(|row| {
            match row.values.get(StatsStoreSchema::CONTROL_VALUE_COLUMN) {
                Some(TypedValue::Text(v)) => Some(v.clone()),
                _ => None,
            }
        }))
    }

    /// Upsert a control-table row, replacing the value if the key already exists.
    fn upsert_control_value(&self, key: &str, value: &str) -> Result<(), persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let mut row = BTreeMap::new();
        row.insert(StatsStoreSchema::KEY_COLUMN.to_string(), TypedValue::Text(key.to_string()));
        row.insert(StatsStoreSchema::CONTROL_VALUE_COLUMN.to_string(), TypedValue::Text(value.to_string()));
        rs.upsert(StatsStoreSchema::CONTROL_TABLE, row, &[StatsStoreSchema::KEY_COLUMN.to_string()])?;
        Ok(())
    }

    /// Insert a control row only if no row with that key already exists.
    ///
    /// This is the seed-if-absent primitive. It mirrors Swift's
    /// `seedControlIfAbsent(key:value:)` — check existence first, insert only
    /// when the row is missing. An existing operator-set value (e.g. monitoring=1)
    /// is preserved across re-opens.
    fn seed_control_if_absent(
        &self,
        key: &str,
        value: &str,
    ) -> Result<(), persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let predicate = StoragePredicate::Eq(
            Column {
                table: StatsStoreSchema::CONTROL_TABLE.to_string(),
                name: StatsStoreSchema::KEY_COLUMN.to_string(),
            },
            TypedValue::Text(key.to_string()),
        );
        // Query with limit=1; if a row exists already, return without inserting.
        let existing = rs.query(
            StatsStoreSchema::CONTROL_TABLE,
            Some(&predicate),
            &[],
            Some(1),
            None,
        )?;
        if !existing.is_empty() {
            return Ok(());
        }
        let mut row = BTreeMap::new();
        row.insert(
            StatsStoreSchema::KEY_COLUMN.to_string(),
            TypedValue::Text(key.to_string()),
        );
        row.insert(
            StatsStoreSchema::CONTROL_VALUE_COLUMN.to_string(),
            TypedValue::Text(value.to_string()),
        );
        rs.insert(StatsStoreSchema::CONTROL_TABLE, row)?;
        Ok(())
    }

    /// Close the store cleanly. Idempotent.
    pub fn close(&self) -> Result<(), persistence_kit::StorageError> {
        self.storage.close()
    }

    // MARK: - Monitoring flag

    /// Read the current monitoring enabled state from the control table.
    ///
    /// Returns `true` if the "monitoring" row has value "1", `false` otherwise.
    /// Mirrors Swift `StatsStore.isMonitoringEnabled()`.
    pub fn is_monitoring_enabled(&self) -> Result<bool, persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let predicate = StoragePredicate::Eq(
            Column {
                table: StatsStoreSchema::CONTROL_TABLE.to_string(),
                name: StatsStoreSchema::KEY_COLUMN.to_string(),
            },
            TypedValue::Text(StatsStoreSchema::MONITORING_KEY.to_string()),
        );
        let rows = rs.query(
            StatsStoreSchema::CONTROL_TABLE,
            Some(&predicate),
            &[],
            Some(1),
            None,
        )?;
        if let Some(row) = rows.first() {
            if let Some(TypedValue::Text(v)) =
                row.values.get(StatsStoreSchema::CONTROL_VALUE_COLUMN)
            {
                return Ok(v == "1");
            }
        }
        Ok(false)
    }

    /// Set the monitoring flag.
    ///
    /// Writing the flag also writes `monitoring_source` = "user" so the wave 8.1
    /// one-time migration in `open()` knows not to revert an explicit operator
    /// choice. Mirrors Swift `StatsStore.setMonitoringEnabled(_:)`.
    pub fn set_monitoring_enabled(&self, enabled: bool) -> Result<(), persistence_kit::StorageError> {
        // Write the monitoring flag.
        self.upsert_control_value(
            StatsStoreSchema::MONITORING_KEY,
            if enabled { "1" } else { "0" },
        )?;
        // Mark the choice as operator-explicit so the one-time migration in open()
        // never reverts it on the next process start.
        self.upsert_control_value(StatsStoreSchema::MONITORING_SOURCE_KEY, "user")?;
        Ok(())
    }

    // MARK: - Write: metric samples

    /// Insert one metric observation.
    ///
    /// `ts` (epoch seconds f64) is encoded as ISO-8601 TEXT at this boundary.
    /// Mirrors Swift `StatsStore.insertMetric(name:value:tags:ts:dropboxID:)`.
    pub fn insert_metric(
        &self,
        name: &str,
        value: f64,
        tags: &BTreeMap<String, String>,
        ts: f64,
        dropbox_id: &str,
    ) -> Result<(), persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let mut row = BTreeMap::new();
        row.insert("row_id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
        row.insert(
            StatsStoreSchema::NAME_COLUMN.to_string(),
            TypedValue::Text(name.to_string()),
        );
        row.insert(
            StatsStoreSchema::VALUE_COLUMN.to_string(),
            TypedValue::Float(value),
        );
        row.insert(
            StatsStoreSchema::TAGS_COLUMN.to_string(),
            TypedValue::Text(encode_tags_json(tags)),
        );
        // Epoch-seconds ts encoded as ISO-8601 TEXT with millisecond precision
        // (schema invariant). Swift uses `.timestamp(Date(timeIntervalSince1970: ts))`
        // which preserves sub-second precision; we must do the same via our ISO-8601
        // encoder which formats with %.3f fractional seconds.
        row.insert(
            StatsStoreSchema::TS_COLUMN.to_string(),
            TypedValue::Text(epoch_to_iso8601(ts)),
        );
        row.insert(
            StatsStoreSchema::DROPBOX_ID_COLUMN.to_string(),
            TypedValue::Text(dropbox_id.to_string()),
        );
        rs.insert(StatsStoreSchema::METRIC_SAMPLES_TABLE, row)?;
        Ok(())
    }

    // MARK: - Write: event samples

    /// Insert one topology event.
    ///
    /// `kind` is the EventKind raw string ("capture" or "think").
    /// Mirrors Swift `StatsStore.insertEvent(kind:nounType:rowID:estate:ts:dropboxID:)`.
    pub fn insert_event(
        &self,
        kind: &str,
        noun_type: i64,
        row_id: &str,
        estate: &str,
        ts: f64,
        dropbox_id: &str,
    ) -> Result<(), persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let mut row = BTreeMap::new();
        row.insert("row_id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
        row.insert(
            StatsStoreSchema::KIND_COLUMN.to_string(),
            TypedValue::Text(kind.to_string()),
        );
        row.insert(
            StatsStoreSchema::NOUN_TYPE_COLUMN.to_string(),
            TypedValue::Int(noun_type),
        );
        row.insert(
            StatsStoreSchema::ROW_ID_COLUMN.to_string(),   // estate_row_id
            TypedValue::Text(row_id.to_string()),
        );
        row.insert(
            StatsStoreSchema::ESTATE_COLUMN.to_string(),
            TypedValue::Text(estate.to_string()),
        );
        // ISO-8601 TEXT with millisecond precision (matches metric insert path).
        row.insert(
            StatsStoreSchema::TS_COLUMN.to_string(),
            TypedValue::Text(epoch_to_iso8601(ts)),
        );
        row.insert(
            StatsStoreSchema::DROPBOX_ID_COLUMN.to_string(),
            TypedValue::Text(dropbox_id.to_string()),
        );
        rs.insert(StatsStoreSchema::EVENT_SAMPLES_TABLE, row)?;
        Ok(())
    }

    // MARK: - Read

    /// Query metric samples, optionally filtering by dropbox.
    ///
    /// Returns rows ordered by `ts` ascending.
    /// Mirrors Swift `StatsStore.queryMetrics(dropboxID:)`.
    pub fn query_metrics(
        &self,
        dropbox_id: Option<&str>,
    ) -> Result<Vec<MetricRow>, persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let predicate = dropbox_id.map(|id| {
            StoragePredicate::Eq(
                Column {
                    table: StatsStoreSchema::METRIC_SAMPLES_TABLE.to_string(),
                    name: StatsStoreSchema::DROPBOX_ID_COLUMN.to_string(),
                },
                TypedValue::Text(id.to_string()),
            )
        });
        let order = vec![PkOrderClause {
            column: Column {
                table: StatsStoreSchema::METRIC_SAMPLES_TABLE.to_string(),
                name: StatsStoreSchema::TS_COLUMN.to_string(),
            },
            direction: OrderDirection::Ascending,
        }];
        let rows = rs.query(
            StatsStoreSchema::METRIC_SAMPLES_TABLE,
            predicate.as_ref(),
            &order,
            None,
            None,
        )?;
        Ok(rows.into_iter().filter_map(MetricRow::from_storage_row).collect())
    }

    /// Query event samples, optionally filtering by dropbox.
    ///
    /// Returns rows ordered by `ts` ascending.
    /// Mirrors Swift `StatsStore.queryEvents(dropboxID:)`.
    pub fn query_events(
        &self,
        dropbox_id: Option<&str>,
    ) -> Result<Vec<EventRow>, persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let predicate = dropbox_id.map(|id| {
            StoragePredicate::Eq(
                Column {
                    table: StatsStoreSchema::EVENT_SAMPLES_TABLE.to_string(),
                    name: StatsStoreSchema::DROPBOX_ID_COLUMN.to_string(),
                },
                TypedValue::Text(id.to_string()),
            )
        });
        let order = vec![PkOrderClause {
            column: Column {
                table: StatsStoreSchema::EVENT_SAMPLES_TABLE.to_string(),
                name: StatsStoreSchema::TS_COLUMN.to_string(),
            },
            direction: OrderDirection::Ascending,
        }];
        let rows = rs.query(
            StatsStoreSchema::EVENT_SAMPLES_TABLE,
            predicate.as_ref(),
            &order,
            None,
            None,
        )?;
        Ok(rows.into_iter().filter_map(EventRow::from_storage_row).collect())
    }

    /// Query metric samples matching any of the given `names`, optionally
    /// filtered by `dropbox_id`.
    ///
    /// Returns rows ordered by `ts` ascending.
    /// Mirrors Swift `StatsStore.queryMetricsByNames(_:dropboxID:)`.
    pub fn query_metrics_by_names(
        &self,
        names: &[&str],
        dropbox_id: Option<&str>,
    ) -> Result<Vec<MetricRow>, persistence_kit::StorageError> {
        if names.is_empty() {
            return Ok(vec![]);
        }
        let rs = self.storage.row_store();
        let name_col = Column {
            table: StatsStoreSchema::METRIC_SAMPLES_TABLE.to_string(),
            name: StatsStoreSchema::NAME_COLUMN.to_string(),
        };
        let name_predicate = StoragePredicate::In(
            name_col,
            names.iter().map(|n| TypedValue::Text(n.to_string())).collect(),
        );
        let predicate = if let Some(id) = dropbox_id {
            let db_col = Column {
                table: StatsStoreSchema::METRIC_SAMPLES_TABLE.to_string(),
                name: StatsStoreSchema::DROPBOX_ID_COLUMN.to_string(),
            };
            StoragePredicate::And(vec![
                name_predicate,
                StoragePredicate::Eq(db_col, TypedValue::Text(id.to_string())),
            ])
        } else {
            name_predicate
        };
        let order = vec![PkOrderClause {
            column: Column {
                table: StatsStoreSchema::METRIC_SAMPLES_TABLE.to_string(),
                name: StatsStoreSchema::TS_COLUMN.to_string(),
            },
            direction: OrderDirection::Ascending,
        }];
        let rows = rs.query(
            StatsStoreSchema::METRIC_SAMPLES_TABLE,
            Some(&predicate),
            &order,
            None,
            None,
        )?;
        Ok(rows.into_iter().filter_map(MetricRow::from_storage_row).collect())
    }

    /// Count total metric rows without reading their content.
    ///
    /// Delegates to `RowStore.count(table:predicate:)` — maps to SQL `COUNT(*)`
    /// with no row decoding.
    /// Mirrors Swift `StatsStore.countMetrics()`.
    pub fn count_metrics(&self) -> Result<usize, persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        rs.count(StatsStoreSchema::METRIC_SAMPLES_TABLE, None)
    }

    // MARK: - Retention

    /// Delete metric samples with `ts` strictly before `cutoff_epoch_secs`.
    ///
    /// The cutoff is caller-supplied (no clock read inside the engine).
    /// Also updates the "retention_cutoff" control row.
    /// Mirrors Swift `StatsStore.deleteMetricsBefore(cutoff:now:)`.
    ///
    /// Returns the number of rows deleted.
    pub fn delete_metrics_before(
        &self,
        cutoff_epoch_secs: f64,
        _now_epoch_secs: f64,
    ) -> Result<usize, persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        // Delete rows where ts (stored as ISO-8601 TEXT) < cutoff.
        // PersistenceKit's SQLite backend compares TEXT timestamps lexicographically.
        // ISO-8601 UTC strings sort lexicographically (year-month-day-hour...) so
        // the comparison is correct without a CAST.
        let cutoff_iso = epoch_to_iso8601(cutoff_epoch_secs);
        let predicate = StoragePredicate::Lt(
            Column {
                table: StatsStoreSchema::METRIC_SAMPLES_TABLE.to_string(),
                name: StatsStoreSchema::TS_COLUMN.to_string(),
            },
            TypedValue::Text(cutoff_iso.clone()),
        );
        let deleted = rs.delete(StatsStoreSchema::METRIC_SAMPLES_TABLE, &predicate)?;
        self.record_retention_cutoff(&cutoff_iso)?;
        Ok(deleted)
    }

    /// Delete event samples with `ts` strictly before `cutoff_epoch_secs`.
    ///
    /// Same semantics as `delete_metrics_before`.
    /// Mirrors Swift `StatsStore.deleteEventsBefore(cutoff:now:)`.
    pub fn delete_events_before(
        &self,
        cutoff_epoch_secs: f64,
        _now_epoch_secs: f64,
    ) -> Result<usize, persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let cutoff_iso = epoch_to_iso8601(cutoff_epoch_secs);
        let predicate = StoragePredicate::Lt(
            Column {
                table: StatsStoreSchema::EVENT_SAMPLES_TABLE.to_string(),
                name: StatsStoreSchema::TS_COLUMN.to_string(),
            },
            TypedValue::Text(cutoff_iso.clone()),
        );
        let deleted = rs.delete(StatsStoreSchema::EVENT_SAMPLES_TABLE, &predicate)?;
        self.record_retention_cutoff(&cutoff_iso)?;
        Ok(deleted)
    }

    // MARK: - DB-layer health

    /// Capture a point-in-time snapshot of the store's own SQLite backend health.
    ///
    /// Mirrors Swift `StatsStore.storageStats(now:)`.
    ///
    /// The manager (`moot-mgr`) calls this to report the stats store's own DB-layer
    /// health (WAL frame count, file size, page/freelist counts) in its status surface.
    /// This is the store's *own* storage — distinct from any observed estate's storage.
    ///
    /// `SqliteStorage` directly implements `StorageIntrospection` (from
    /// `persistence_kit`), so `self.storage.stats(now_secs)` is a direct call with
    /// no downcast required. The method always returns `Some(StorageStats)` for the
    /// SQLite backend; the `Option` return mirrors the Swift surface which returns
    /// `nil` for a hypothetical non-introspectable backend (preserving parity).
    ///
    /// Determinism: `now_secs` is the Unix timestamp (seconds) to stamp on the
    /// snapshot. The caller owns the clock — never call `SystemTime::now()` inside
    /// this engine. Mirrors Swift's `now: Date` parameter convention.
    ///
    /// Field mapping vs Swift `StorageStats`:
    ///   Swift field                  | Rust field
    ///   -----------------------------|------------------------------
    ///   logicalSizeBytes (Int64)     | logical_size_bytes: i64
    ///   pageSize (Int?)              | page_size: Option<i32>
    ///   pageCount (Int?)             | page_count: Option<i32>
    ///   freelistPageCount (Int?)     | freelist_page_count: Option<i32>
    ///   walFrameCount (Int?)         | wal_frame_count: Option<i32>
    ///   cacheHitRatio (Double?)      | cache_hit_ratio: Option<f64>
    ///   transactionCommitCount       | transaction_commit_count: Option<i64>
    ///   transactionRollbackCount     | transaction_rollback_count: Option<i64>
    ///   deadlockCount (Int64?)       | deadlock_count: Option<i64>
    ///   lockContention (Bool?)       | lock_contention: Option<bool>
    ///   rowCount (Int?)              | row_count: Option<usize>
    ///   blobCount (Int?)             | blob_count: Option<usize>
    ///   capturedAt (Date → epoch)    | captured_at_secs: i64
    ///
    /// Note: vectorCount / vector_count was removed from StorageStats in ADR-008.
    /// The field no longer exists on either the Swift or Rust struct.
    ///
    /// Returns `Some(StorageStats)` on success, or `None` if the backend does not
    /// implement `StorageIntrospection` (cannot occur for the `SqliteStorage` backend,
    /// but the option keeps the API honest for future backends).
    pub fn storage_stats(
        &self,
        now_secs: i64,
    ) -> Result<Option<persistence_kit::StorageStats>, persistence_kit::StorageError> {
        // SqliteStorage implements StorageIntrospection directly — call stats() inline.
        // The Option wrapper mirrors Swift's `guard let introspectable = storage as?
        // StorageIntrospection else { return nil }` pattern; here it always succeeds for
        // the SQLite backend, but the surface remains honest.
        use persistence_kit::StorageIntrospection;
        let stats = self.storage.stats(now_secs)?;
        Ok(Some(stats))
    }

    // MARK: - Topology snapshot (v2)

    /// Write or replace the topology snapshot for `estate`.
    ///
    /// The autonomic governor calls this after each topology-recompute duty cycle.
    /// Uses `estate` as the PRIMARY KEY upsert conflict target — only one row per
    /// estate exists at any time (latest-wins, no history).
    ///
    /// `generated_at_secs` is the Unix timestamp (seconds) of when the governor
    /// produced the snapshot. Stored as ISO-8601 TEXT (schema timestamp invariant).
    /// No `SystemTime::now()` call inside the store (determinism rule).
    ///
    /// `payload` is the JSON-encoded ARIAGraphPayload string.
    ///
    /// Rust's `&str` type guarantees valid UTF-8 at compile time, which is
    /// strictly stronger than Swift's runtime `String(data:encoding:)` guard.
    /// Both ports reject invalid UTF-8 before storage — Swift at runtime, Rust
    /// at the type-system level. Callers with raw bytes should use
    /// `write_topology_snapshot_bytes` which performs lossy UTF-8 conversion.
    ///
    /// `fingerprint` is the stable topology-inputs fingerprint (FNV-1a based,
    /// process independent) so a restarting governor can skip the full topology
    /// read when inputs are unchanged. `None` leaves the column null (e.g.
    /// callers that do not compute a fingerprint).
    ///
    /// Mirrors Swift `StatsStore.writeTopologySnapshot(estate:generatedAt:payload:fingerprint:)`.
    pub fn write_topology_snapshot(
        &self,
        estate: &str,
        generated_at_secs: f64,
        payload: &str,
        fingerprint: Option<&str>,
    ) -> Result<(), persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let generated_at_iso = epoch_to_iso8601(generated_at_secs);
        let mut row = BTreeMap::new();
        row.insert(
            StatsStoreSchema::ESTATE_COLUMN.to_string(),
            TypedValue::Text(estate.to_string()),
        );
        // ISO-8601 TEXT per schema timestamp invariant.
        row.insert(
            StatsStoreSchema::GENERATED_AT_COLUMN.to_string(),
            TypedValue::Text(generated_at_iso),
        );
        row.insert(
            StatsStoreSchema::PAYLOAD_COLUMN.to_string(),
            TypedValue::Text(payload.to_string()),
        );
        // Null when the caller supplies no fingerprint.
        row.insert(
            StatsStoreSchema::TOPOLOGY_FINGERPRINT_COLUMN.to_string(),
            match fingerprint {
                Some(fp) => TypedValue::Text(fp.to_string()),
                None => TypedValue::Null,
            },
        );
        rs.upsert(
            StatsStoreSchema::TOPOLOGY_SNAPSHOTS_TABLE,
            row,
            &[StatsStoreSchema::ESTATE_COLUMN.to_string()],
        )?;
        Ok(())
    }

    /// Bytes variant of `write_topology_snapshot`. Accepts raw bytes and
    /// performs lossy UTF-8 conversion (invalid bytes → U+FFFD). Use when
    /// the caller cannot guarantee valid UTF-8 at compile time.
    pub fn write_topology_snapshot_bytes(
        &self,
        estate: &str,
        generated_at_secs: f64,
        payload: &[u8],
        fingerprint: Option<&str>,
    ) -> Result<(), persistence_kit::StorageError> {
        let payload_str = String::from_utf8_lossy(payload);
        self.write_topology_snapshot(estate, generated_at_secs, &payload_str, fingerprint)
    }

    /// Read the latest topology snapshot bytes for `estate`, or — with
    /// `None` — the newest snapshot across ALL estates (the moot-mgr
    /// dashboard's default "all estates" view reads without an estate key;
    /// the governor writes one row per estate and the newest `generated_at`
    /// wins).
    ///
    /// Returns `None` when no snapshot has been written yet (governor has
    /// not completed its first duty cycle). The caller should return a
    /// `structurePending: true` response in this case.
    ///
    /// Mirrors Swift `StatsStore.latestTopologySnapshot(estate:) -> Data?`.
    pub fn latest_topology_snapshot(
        &self,
        estate: Option<&str>,
    ) -> Result<Option<String>, persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let predicate = estate.map(|est| {
            StoragePredicate::Eq(
                Column {
                    table: StatsStoreSchema::TOPOLOGY_SNAPSHOTS_TABLE.to_string(),
                    name: StatsStoreSchema::ESTATE_COLUMN.to_string(),
                },
                TypedValue::Text(est.to_string()),
            )
        });
        let rows = rs.query(
            StatsStoreSchema::TOPOLOGY_SNAPSHOTS_TABLE,
            predicate.as_ref(),
            &[],
            None,
            None,
        )?;
        // PRIMARY KEY lookup yields ≤1 row; the None-estate path picks the
        // newest generated_at across estates. The column is written as TEXT
        // ISO-8601; the SQLite backend decodes it back as Timestamp(ms) (epoch
        // MILLISECONDS). For ordering purposes the units don't matter as long as
        // they are consistent within a backend — both Timestamp(ms) and the
        // Text path (which returns seconds as i64) are monotonically comparable
        // for finding the max. Absent/unparseable sorts oldest.
        fn generated_at(row: &persistence_kit::StorageRow) -> i64 {
            match row.values.get(StatsStoreSchema::GENERATED_AT_COLUMN) {
                // SQLite path: Timestamp(ms) — use raw ms for comparison (monotonic).
                Some(TypedValue::Timestamp(ms)) => *ms,
                // InMemory path: read back as Text → convert to seconds as i64.
                Some(TypedValue::Text(s)) => iso8601_to_epoch(s) as i64,
                _ => i64::MIN,
            }
        }
        let newest = rows.iter().max_by_key(|row| generated_at(row));
        if let Some(row) = newest {
            if let Some(TypedValue::Text(payload)) =
                row.values.get(StatsStoreSchema::PAYLOAD_COLUMN)
            {
                return Ok(Some(payload.clone()));
            }
        }
        Ok(None)
    }

    /// Read the persisted topology fingerprint for `estate`.
    ///
    /// The autonomic governor calls this once on startup so it can compare the
    /// persisted topology-inputs fingerprint against freshly-computed inputs and
    /// skip the full drawer/tunnel/fact read when they match. Returns `None` when
    /// no snapshot exists yet, when the row predates v3 (column null), or when a
    /// snapshot was written without a fingerprint.
    ///
    /// Mirrors Swift `StatsStore.loadTopologyFingerprint(estate:) -> String?`.
    pub fn load_topology_fingerprint(
        &self,
        estate: &str,
    ) -> Result<Option<String>, persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let predicate = StoragePredicate::Eq(
            Column {
                table: StatsStoreSchema::TOPOLOGY_SNAPSHOTS_TABLE.to_string(),
                name: StatsStoreSchema::ESTATE_COLUMN.to_string(),
            },
            TypedValue::Text(estate.to_string()),
        );
        let rows = rs.query(
            StatsStoreSchema::TOPOLOGY_SNAPSHOTS_TABLE,
            Some(&predicate),
            &[],
            None,
            None,
        )?;
        // PRIMARY KEY lookup yields ≤1 row. The column is written as Text or Null;
        // any non-text representation (null, absent) yields None.
        if let Some(row) = rows.first() {
            if let Some(TypedValue::Text(fp)) =
                row.values.get(StatsStoreSchema::TOPOLOGY_FINGERPRINT_COLUMN)
            {
                return Ok(Some(fp.clone()));
            }
        }
        Ok(None)
    }

    // MARK: - Internal helpers

    fn record_retention_cutoff(&self, cutoff_iso: &str) -> Result<(), persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let mut row = BTreeMap::new();
        row.insert(
            StatsStoreSchema::KEY_COLUMN.to_string(),
            TypedValue::Text(StatsStoreSchema::RETENTION_CUTOFF_KEY.to_string()),
        );
        row.insert(
            StatsStoreSchema::CONTROL_VALUE_COLUMN.to_string(),
            TypedValue::Text(cutoff_iso.to_string()),
        );
        rs.upsert(
            StatsStoreSchema::CONTROL_TABLE,
            row,
            &[StatsStoreSchema::KEY_COLUMN.to_string()],
        )?;
        Ok(())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Row result types — mirror Swift MetricRow / EventRow
// ─────────────────────────────────────────────────────────────────────────────

/// A decoded metric sample row from the `metric_samples` table.
/// Mirrors Swift `MetricRow`.
pub struct MetricRow {
    pub row_id: Uuid,
    pub name: String,
    pub value: f64,
    /// Decoded tag map (BTreeMap for deterministic ordering in tests).
    pub tags: BTreeMap<String, String>,
    /// Timestamp as epoch seconds (decoded from ISO-8601 TEXT).
    pub ts_epoch: f64,
    pub dropbox_id: String,
}

impl MetricRow {
    fn from_storage_row(row: StorageRow) -> Option<Self> {
        let row_id = match row.values.get("row_id")? {
            TypedValue::Uuid(u) => *u,
            _ => return None,
        };
        let name = match row.values.get(StatsStoreSchema::NAME_COLUMN)? {
            TypedValue::Text(s) => s.clone(),
            _ => return None,
        };
        let value = match row.values.get(StatsStoreSchema::VALUE_COLUMN)? {
            TypedValue::Float(f) => *f,
            _ => return None,
        };
        let tags_str = match row.values.get(StatsStoreSchema::TAGS_COLUMN)? {
            TypedValue::Text(s) => s.clone(),
            _ => return None,
        };
        // The SQLite backend decodes TEXT ISO-8601 timestamp columns as
        // TypedValue::Timestamp(ms) where the i64 is epoch MILLISECONDS, not seconds.
        // Divide by 1000 to recover epoch seconds (f64) matching the caller's expectation.
        let ts_epoch = match row.values.get(StatsStoreSchema::TS_COLUMN)? {
            TypedValue::Timestamp(ms) => *ms as f64 / 1000.0,
            TypedValue::Text(s) => iso8601_to_epoch(s),
            _ => return None,
        };
        let dropbox_id = match row.values.get(StatsStoreSchema::DROPBOX_ID_COLUMN)? {
            TypedValue::Text(s) => s.clone(),
            _ => return None,
        };
        Some(MetricRow {
            row_id,
            name,
            value,
            tags: decode_tags_json(&tags_str),
            ts_epoch,
            dropbox_id,
        })
    }
}

/// A decoded event sample row from the `event_samples` table.
/// Mirrors Swift `EventRow`.
pub struct EventRow {
    pub row_id: Uuid,
    pub kind: String,
    pub noun_type: i64,
    pub estate_row_id: String,
    pub estate: String,
    pub ts_epoch: f64,
    pub dropbox_id: String,
}

impl EventRow {
    fn from_storage_row(row: StorageRow) -> Option<Self> {
        let row_id = match row.values.get("row_id")? {
            TypedValue::Uuid(u) => *u,
            _ => return None,
        };
        let kind = match row.values.get(StatsStoreSchema::KIND_COLUMN)? {
            TypedValue::Text(s) => s.clone(),
            _ => return None,
        };
        let noun_type = match row.values.get(StatsStoreSchema::NOUN_TYPE_COLUMN)? {
            TypedValue::Int(i) => *i,
            _ => return None,
        };
        let estate_row_id = match row.values.get(StatsStoreSchema::ROW_ID_COLUMN)? {
            TypedValue::Text(s) => s.clone(),
            _ => return None,
        };
        let estate = match row.values.get(StatsStoreSchema::ESTATE_COLUMN)? {
            TypedValue::Text(s) => s.clone(),
            _ => return None,
        };
        // Timestamp is stored as TEXT ISO-8601; the SQLite backend decodes it as
        // TypedValue::Timestamp(ms) — epoch MILLISECONDS. Divide by 1000 → seconds.
        let ts_epoch = match row.values.get(StatsStoreSchema::TS_COLUMN)? {
            TypedValue::Timestamp(ms) => *ms as f64 / 1000.0,
            TypedValue::Text(s) => iso8601_to_epoch(s),
            _ => return None,
        };
        let dropbox_id = match row.values.get(StatsStoreSchema::DROPBOX_ID_COLUMN)? {
            TypedValue::Text(s) => s.clone(),
            _ => return None,
        };
        Some(EventRow {
            row_id,
            kind,
            noun_type,
            estate_row_id,
            estate,
            ts_epoch,
            dropbox_id,
        })
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests — epoch_to_iso8601 clamping
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod epoch_iso_tests {
    use super::epoch_to_iso8601;

    /// A normal epoch (Unix time for 2024-01-01T00:00:00Z) must produce a
    /// valid 4-digit-year ISO-8601 string.
    #[test]
    fn normal_epoch_produces_valid_iso8601() {
        let s = epoch_to_iso8601(1_704_067_200.0); // 2024-01-01T00:00:00Z
        assert!(s.starts_with("2024-"), "expected year 2024, got: {s}");
        assert!(s.ends_with('Z'), "must end with Z");
    }

    /// An epoch value far in the past (year < 0001) must be clamped to
    /// year 0001, not produce a negative-year string or panic.
    #[test]
    fn far_past_epoch_clamped_to_year_0001() {
        let s = epoch_to_iso8601(-1e18); // far before 0001-01-01
        assert!(s.starts_with("0001-"), "expected year 0001, got: {s}");
    }

    /// An epoch value far in the future (year > 9999) must be clamped to
    /// year 9999, not produce a 5-digit-year string or panic.
    #[test]
    fn far_future_epoch_clamped_to_year_9999() {
        let s = epoch_to_iso8601(1e18); // far after 9999-12-31
        assert!(s.starts_with("9999-"), "expected year 9999, got: {s}");
    }

    /// f64::MAX must not panic — saturating cast to i64 then clamp handles it.
    #[test]
    fn f64_max_does_not_panic() {
        let s = epoch_to_iso8601(f64::MAX);
        assert!(!s.is_empty(), "f64::MAX must not produce an empty string");
        assert!(s.starts_with("9999-"), "f64::MAX should clamp to year 9999, got: {s}");
    }

    /// f64::NEG_INFINITY must not panic.
    #[test]
    fn neg_infinity_does_not_panic() {
        let s = epoch_to_iso8601(f64::NEG_INFINITY);
        assert!(!s.is_empty(), "NEG_INFINITY must not produce an empty string");
        assert!(s.starts_with("0001-"), "NEG_INFINITY should clamp to year 0001, got: {s}");
    }

    /// NaN must not panic — the saturating cast of NaN to i64 in Rust >= 1.45
    /// produces 0, which lies within the 0001–9999 epoch window.
    #[test]
    fn nan_does_not_panic() {
        let s = epoch_to_iso8601(f64::NAN);
        assert!(!s.is_empty(), "NaN must not produce an empty string");
        assert!(s.ends_with('Z'), "must end with Z");
    }

    /// The produced ISO-8601 string must always have a 4-digit year.
    #[test]
    fn output_always_has_4_digit_year_component() {
        for secs in [
            -62_135_596_800.0_f64, // MIN_EPOCH_SECS (year 0001)
            253_402_300_799.0_f64, // MAX_EPOCH_SECS (year 9999)
            0.0_f64,               // Unix epoch (year 1970)
        ] {
            let s = epoch_to_iso8601(secs);
            let year_part = &s[..4];
            assert_eq!(year_part.len(), 4, "year must be 4 digits in {s}");
            assert!(year_part.chars().all(|c| c.is_ascii_digit()),
                    "year must be all digits in {s}");
        }
    }
}
