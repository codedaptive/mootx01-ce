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
    OrderDirection, SchemaDeclaration, SqliteStorage, Storage,
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
        }
    }
    fn col_text(name: &str) -> ColumnDeclaration {
        ColumnDeclaration {
            name: name.to_string(),
            column_type: ColumnType::Text,
            nullable: false,
            default_value: None,
        }
    }
    fn col_float(name: &str) -> ColumnDeclaration {
        ColumnDeclaration {
            name: name.to_string(),
            column_type: ColumnType::Float,
            nullable: false,
            default_value: None,
        }
    }
    fn col_int(name: &str) -> ColumnDeclaration {
        ColumnDeclaration {
            name: name.to_string(),
            column_type: ColumnType::Int,
            nullable: false,
            default_value: None,
        }
    }
    fn col_timestamp(name: &str) -> ColumnDeclaration {
        ColumnDeclaration {
            name: name.to_string(),
            column_type: ColumnType::Timestamp,
            nullable: false,
            default_value: None,
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
        migrations: vec![],
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ISO-8601 helpers — mirrors Swift's `StatsStore.iso8601Formatter`
// ─────────────────────────────────────────────────────────────────────────────

/// Encode epoch seconds (f64) to ISO-8601 UTC TEXT with millisecond precision.
/// Mirrors Swift: `DateFormatter` with `"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"`.
pub(crate) fn epoch_to_iso8601(secs: f64) -> String {
    let whole_secs = secs.floor() as i64;
    let nanos = ((secs - secs.floor()) * 1_000_000_000.0) as u32;
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
    pub const SCHEMA_VERSION: i32 = 1;

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
    /// Seeds the default control rows ("monitoring"="0", "retention_cutoff"=epoch-zero)
    /// ONLY IF ABSENT — seed-if-absent, NOT upsert.
    ///
    /// Rationale: upsert would overwrite an operator-set "monitoring" value on
    /// every process restart, resetting the persistent on/off switch to "0" each
    /// time the manager relaunches. Seeding only when the row is missing means the
    /// first open installs the defaults and every subsequent open is a no-op for
    /// those rows. Mirrors Swift `StatsStore.open()` / `seedControlIfAbsent` exactly
    /// (fix landed in Swift commit 852821cc).
    ///
    /// Mirrors Swift `StatsStore.open()`.
    pub fn open(&self) -> Result<(), persistence_kit::StorageError> {
        let schema = make_schema();
        self.storage.open(&schema)?;

        // Seed "monitoring" = "0" (off by default) only if absent.
        // The manager sets this to "1" when it starts accepting subscribers.
        // Overwriting would reset the operator's on/off switch on every restart.
        self.seed_control_if_absent(
            StatsStoreSchema::MONITORING_KEY,
            "0",
        )?;

        // Seed "retention_cutoff" = epoch-zero ISO-8601 only if absent.
        // Epoch zero ("1970-01-01T00:00:00.000Z") indicates no retention pass
        // has run yet. Overwriting would erase the last-known retention timestamp.
        self.seed_control_if_absent(
            StatsStoreSchema::RETENTION_CUTOFF_KEY,
            "1970-01-01T00:00:00.000Z",
        )?;

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
    /// Mirrors Swift `StatsStore.setMonitoringEnabled(_:)`.
    pub fn set_monitoring_enabled(&self, enabled: bool) -> Result<(), persistence_kit::StorageError> {
        let rs = self.storage.row_store();
        let mut row = BTreeMap::new();
        row.insert(
            StatsStoreSchema::KEY_COLUMN.to_string(),
            TypedValue::Text(StatsStoreSchema::MONITORING_KEY.to_string()),
        );
        row.insert(
            StatsStoreSchema::CONTROL_VALUE_COLUMN.to_string(),
            TypedValue::Text(if enabled { "1" } else { "0" }.to_string()),
        );
        rs.upsert(
            StatsStoreSchema::CONTROL_TABLE,
            row,
            &[StatsStoreSchema::KEY_COLUMN.to_string()],
        )?;
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
        // Epoch-seconds ts encoded as ISO-8601 TEXT (schema invariant).
        row.insert(
            StatsStoreSchema::TS_COLUMN.to_string(),
            TypedValue::Timestamp(ts as i64),
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
        row.insert(
            StatsStoreSchema::TS_COLUMN.to_string(),
            TypedValue::Timestamp(ts as i64),
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
    ///   vectorCount (Int?)           | vector_count: Option<usize>
    ///   capturedAt (Date → epoch)    | captured_at_secs: i64
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
        // Timestamp is stored as Timestamp(i64 epoch seconds) by the SQLite backend
        // after decoding from ISO-8601 TEXT. Convert back to f64.
        let ts_epoch = match row.values.get(StatsStoreSchema::TS_COLUMN)? {
            TypedValue::Timestamp(secs) => *secs as f64,
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
        let ts_epoch = match row.values.get(StatsStoreSchema::TS_COLUMN)? {
            TypedValue::Timestamp(secs) => *secs as f64,
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
