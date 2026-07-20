---
title: ObserverSink Interface
version: v1.1
status: active
spec_type: kit
authors: MOOTx01 maintainers
date: 2026-06-06
relates_to:
  - docs/reference/OBSERVERSINK_SPEC.md
  - docs/reference/PERSISTENCEKIT_SPEC.md
---

# ObserverSink Interface

The public API surface of `ObserverSink`.

---

## Swift

### `StatsStore`

```swift
public final class StatsStore: Sendable {

    // MARK: - Schema

    /// Schema version 5. Bump with a Migration when the schema changes.
    public static let schemaVersion: Int

    /// PersistenceKit SchemaDeclaration (metric_samples, event_samples, control).
    public static let schema: SchemaDeclaration

    // MARK: - Lifecycle

    /// Create a StatsStore backed by SQLite at `url`.
    /// Call `open()` before I/O.
    public init(url: URL) throws

    /// Open the store, apply schema/migrations, seed default control rows.
    /// Idempotent.
    public func open() async throws

    /// Close the store cleanly. Idempotent.
    public func close() async

    // MARK: - Monitoring flag

    /// Read the global monitoring flag from the control table.
    /// Returns true iff the "monitoring" row has value "1".
    public func isMonitoringEnabled() async throws -> Bool

    /// Set the global monitoring flag (manager calls this).
    public func setMonitoringEnabled(_ enabled: Bool) async throws

    // MARK: - Write

    /// Insert one metric sample.
    /// ts is epoch seconds (Double); stored as ISO-8601 TEXT.
    public func insertMetric(
        name: String,
        value: Double,
        tags: [String: String],
        ts: Double,
        dropboxID: String
    ) async throws

    /// Insert one topology event.
    /// kind is the EventKind raw string ("capture" or "think").
    public func insertEvent(
        kind: String,
        nounType: Int,
        rowID: String,
        estate: String,
        ts: Double,
        dropboxID: String
    ) async throws

    // MARK: - Read

    /// Query metric samples, optionally filtered by dropbox. Ordered by ts ascending.
    public func queryMetrics(dropboxID: String?) async throws -> [MetricRow]

    /// Query metric samples whose name is in `names` via SQL `WHERE name IN (...)`.
    /// Returns [] immediately if `names` is empty.
    /// When `limit` is nil, ordered by ts ascending (full history).
    /// When `limit` is non-nil, ordered by ts descending (most-recent first, capped).
    /// Use in hot read-API paths instead of queryMetrics + Swift-side filter.
    public func queryMetricsByNames(
        _ names: Set<String>,
        dropboxID: String? = nil,
        limit: Int? = nil
    ) async throws -> [MetricRow]

    /// Return the single most-recent MetricRow for each (name, dropboxID) pair.
    /// Pairs with no matching rows are skipped.
    /// Issues one `WHERE name=? AND dropbox_id=? ORDER BY ts DESC LIMIT 1` indexed
    /// query per pair — O(log n) per pair regardless of total table size.
    public func queryLatestMetricsByNamesAndDropboxes(
        _ names: Set<String>,
        dropboxIDs: [String]
    ) async throws -> [MetricRow]

    /// Return per-dropbox aggregate (count + last ts ISO-8601) for the given IDs.
    /// A dropbox with zero rows is still returned (metricCount=0, lastMetricTs=nil).
    /// Uses indexed COUNT(*) and single-row ts-DESC LIMIT 1 probes — no full-table decode.
    public func queryMetricAggregatesByDropbox(
        forDropboxIDs dropboxIDs: [String]
    ) async throws -> [DropboxMetricAggregate]

    /// Count total metric rows without decoding row content.
    /// Delegates to RowStore.count(table:where:) — SQL COUNT(*).
    public func countMetrics() async throws -> Int

    /// Query event samples, optionally filtered by dropbox. Ordered by ts ascending.
    public func queryEvents(dropboxID: String?) async throws -> [EventRow]

    // MARK: - Topology snapshot (v2)

    /// Write or replace the topology snapshot for `estate`.
    /// Uses `estate` as the PRIMARY KEY upsert conflict target (latest-wins, no history).
    /// `generatedAt` is stored as ISO-8601 TEXT. `payload` is stored verbatim.
    /// `fingerprint` is an optional stable topology-inputs fingerprint (FNV-1a);
    /// nil stores NULL, allowing the governor to skip the full topology read on restart
    /// when inputs are unchanged.
    public func writeTopologySnapshot(
        estate: String,
        generatedAt: Date,
        payload: Data,
        fingerprint: String?
    ) async throws

    /// Read the latest topology snapshot payload for `estate`, or the newest across
    /// all estates when `estate` is nil. Returns nil when no snapshot has been written.
    public func latestTopologySnapshot(estate: String?) async throws -> Data?

    /// Read the persisted topology fingerprint for `estate`.
    /// Returns nil when no snapshot exists, when the row predates v3, or when
    /// the snapshot was written without a fingerprint.
    public func loadTopologyFingerprint(estate: String) async throws -> String?

    // MARK: - DB-layer health

    /// Capture a point-in-time snapshot of the store's own SQLite backend health
    /// (WAL frame count, file size, page/freelist counts). Caller supplies `now`
    /// for determinism — no Date() call inside the store.
    /// Returns nil if the backend does not support introspection (cannot occur for
    /// the SQLite backend).
    public func storageStats(now: Date) async throws -> StorageStats?

    // MARK: - Retention

    /// Delete metric rows with ts < cutoff.
    /// Updates the "retention_cutoff" control row.
    /// Caller supplies cutoff and now — no Date() inside.
    @discardableResult
    public func deleteMetricsBefore(cutoff: Date, now: Date) async throws -> Int

    /// Delete event rows with ts < cutoff.
    @discardableResult
    public func deleteEventsBefore(cutoff: Date, now: Date) async throws -> Int
}
```

### `MetricRow`

```swift
public struct MetricRow: Sendable {
    public let rowID: UUID        // synthetic primary key
    public let name: String
    public let value: Double
    public let tags: [String: String]
    public let ts: Date           // decoded from ISO-8601 storage
    public let dropboxID: String
}
```

### `EventRow`

```swift
public struct EventRow: Sendable {
    public let rowID: UUID        // synthetic primary key
    public let kind: String       // "capture" or "think"
    public let nounType: Int      // NounType ordinal
    public let rowIDStr: String   // estate entity's row UUID string
    public let estate: String
    public let ts: Date
    public let dropboxID: String
}
```

### `DropboxMetricAggregate`

```swift
public struct DropboxMetricAggregate: Sendable {
    public let dropboxID: String
    public let metricCount: Int
    public let lastMetricTs: String?   // ISO-8601 UTC string, or nil when count is 0

    public init(dropboxID: String, metricCount: Int, lastMetricTs: String?)
}
```

### `StatsStoreSchema`

```swift
public enum StatsStoreSchema {
    // Table names
    public static let metricSamplesTable: String   // "metric_samples"
    public static let eventSamplesTable: String    // "event_samples"
    public static let controlTable: String         // "control"

    // Column names (shared)
    public static let tsColumn: String             // "ts"
    public static let dropboxIDColumn: String      // "dropbox_id"

    // metric_samples columns
    public static let nameColumn: String           // "name"
    public static let valueColumn: String          // "value"
    public static let tagsColumn: String           // "tags"

    // event_samples columns
    public static let kindColumn: String           // "kind"
    public static let nounTypeColumn: String       // "noun_type"
    public static let rowIDColumn: String          // "estate_row_id"
    public static let estateColumn: String         // "estate"

    // control table columns
    public static let keyColumn: String            // "key"
    public static let controlValueColumn: String   // "value"

    // Well-known control keys
    public static let monitoringKey: String        // "monitoring"
    public static let monitoringSourceKey: String  // "monitoring_source"
    public static let retentionCutoffKey: String   // "retention_cutoff"

    // topology_snapshots table (v2)
    public static let topologySnapshotsTable: String       // "topology_snapshots"
    public static let generatedAtColumn: String            // "generated_at"
    public static let payloadColumn: String                // "payload"
    public static let topologyFingerprintColumn: String    // "topology_fingerprint"
}
```

### `PersistenceStatsSink`

```swift
public struct PersistenceStatsSink: StatsSink {

    /// Create a PersistenceStatsSink.
    /// - store: Must be opened before samples arrive.
    /// - dropboxID: Stable identifier for this consumer (e.g. "aria-mcp-<uuid>").
    public init(store: StatsStore, dropboxID: String)

    /// Deliver one sample to the store.
    ///
    /// Checks the store monitoring flag first. Dispatches async Task for I/O.
    /// Errors logged, never thrown. Never blocks the caller.
    ///
    /// **Backpressure cap (Swift only)**: if more than 64 Tasks are already
    /// in-flight, the sample is silently dropped and the call returns
    /// immediately — no log is emitted and no error is reported. This bounds
    /// memory growth under sustained high-rate emission (issue #48). The
    /// 64-slot cap is generous for any realistic workload. Callers that need
    /// guaranteed delivery under backpressure must queue samples ahead of
    /// this sink. The Rust leg is synchronous and has no equivalent cap.
    public func receive(_ sample: StatSample)
}
```

---

## Rust

### `StatsStore`

```rust
pub struct StatsStore { /* private */ }

impl StatsStore {
    /// Current schema version (5).
    pub const SCHEMA_VERSION: i32;

    /// Create a StatsStore backed by SQLite at `path`.
    pub fn new(path: &str) -> Result<Self, StorageError>;

    /// Open the store, apply schema, seed control rows (seed-if-absent).
    pub fn open(&self) -> Result<(), StorageError>;

    /// Close the store. Idempotent.
    pub fn close(&self) -> Result<(), StorageError>;

    // Monitoring flag
    pub fn is_monitoring_enabled(&self) -> Result<bool, StorageError>;
    /// Also writes monitoring_source = "user" to protect the choice from
    /// the wave 8.1 one-time migration on subsequent re-opens.
    pub fn set_monitoring_enabled(&self, enabled: bool) -> Result<(), StorageError>;

    // Write
    pub fn insert_metric(
        &self,
        name: &str,
        value: f64,
        tags: &BTreeMap<String, String>,
        ts: f64,
        dropbox_id: &str,
    ) -> Result<(), StorageError>;

    pub fn insert_event(
        &self,
        kind: &str,
        noun_type: i64,
        row_id: &str,
        estate: &str,
        ts: f64,
        dropbox_id: &str,
    ) -> Result<(), StorageError>;

    // Read
    pub fn query_metrics(
        &self,
        dropbox_id: Option<&str>,
    ) -> Result<Vec<MetricRow>, StorageError>;

    /// Query metrics matching any of `names`, optionally filtered by dropbox.
    /// When `limit` is None, ordered by ts ascending (full history).
    /// When `limit` is Some, ordered by ts descending (most-recent first, capped).
    pub fn query_metrics_by_names(
        &self,
        names: &[&str],
        dropbox_id: Option<&str>,
        limit: Option<usize>,
    ) -> Result<Vec<MetricRow>, StorageError>;

    /// Return the single most-recent MetricRow for each (name, dropbox_id) pair.
    /// Issues one indexed query per pair — O(log n) regardless of total table size.
    pub fn query_latest_metrics_by_names_and_dropboxes(
        &self,
        names: &[&str],
        dropbox_ids: &[&str],
    ) -> Result<Vec<MetricRow>, StorageError>;

    /// Return per-dropbox aggregate (count + last ts ISO-8601) for the given IDs.
    /// A dropbox with zero rows is still returned (metric_count=0, last_metric_ts=None).
    pub fn query_metric_aggregates_by_dropbox(
        &self,
        dropbox_ids: &[&str],
    ) -> Result<Vec<DropboxMetricAggregate>, StorageError>;

    /// Count total metric rows — SQL COUNT(*), no row decoding.
    pub fn count_metrics(&self) -> Result<usize, StorageError>;

    pub fn query_events(
        &self,
        dropbox_id: Option<&str>,
    ) -> Result<Vec<EventRow>, StorageError>;

    // Topology snapshot (v2)

    /// Write or replace the topology snapshot for `estate` (latest-wins upsert).
    /// `generated_at_secs` is Unix epoch seconds; stored as ISO-8601 TEXT.
    /// `payload` must be valid UTF-8 (guaranteed at compile time by &str).
    /// `fingerprint` is an optional stable topology-inputs fingerprint; None stores NULL.
    pub fn write_topology_snapshot(
        &self,
        estate: &str,
        generated_at_secs: f64,
        payload: &str,
        fingerprint: Option<&str>,
    ) -> Result<(), StorageError>;

    /// Bytes variant of `write_topology_snapshot`. Performs lossy UTF-8 conversion
    /// (invalid bytes → U+FFFD). Use when the caller cannot guarantee valid UTF-8.
    pub fn write_topology_snapshot_bytes(
        &self,
        estate: &str,
        generated_at_secs: f64,
        payload: &[u8],
        fingerprint: Option<&str>,
    ) -> Result<(), StorageError>;

    /// Read the latest topology snapshot payload (JSON string) for `estate`, or the
    /// newest across all estates when `estate` is None. Returns None when absent.
    pub fn latest_topology_snapshot(
        &self,
        estate: Option<&str>,
    ) -> Result<Option<String>, StorageError>;

    /// Read the persisted topology fingerprint for `estate`. Returns None when
    /// absent, when the row predates v3, or when written without a fingerprint.
    pub fn load_topology_fingerprint(
        &self,
        estate: &str,
    ) -> Result<Option<String>, StorageError>;

    // DB-layer health

    /// Capture a point-in-time snapshot of the store's own SQLite backend health.
    /// `now_secs` is Unix epoch seconds (caller supplies the clock).
    /// Returns Some(StorageStats) for the SQLite backend; None is a forward-compat stub.
    pub fn storage_stats(
        &self,
        now_secs: i64,
    ) -> Result<Option<StorageStats>, StorageError>;

    // Retention
    pub fn delete_metrics_before(
        &self,
        cutoff_epoch_secs: f64,
        now_epoch_secs: f64,
    ) -> Result<usize, StorageError>;

    pub fn delete_events_before(
        &self,
        cutoff_epoch_secs: f64,
        now_epoch_secs: f64,
    ) -> Result<usize, StorageError>;
}
```

### `MetricRow`

```rust
pub struct MetricRow {
    pub row_id: Uuid,
    pub name: String,
    pub value: f64,
    pub tags: BTreeMap<String, String>,
    pub ts_epoch: f64,   // epoch seconds decoded from ISO-8601 storage
    pub dropbox_id: String,
}
```

### `EventRow`

```rust
pub struct EventRow {
    pub row_id: Uuid,
    pub kind: String,           // "capture" or "think"
    pub noun_type: i64,
    pub estate_row_id: String,  // substrate entity's row UUID string
    pub estate: String,
    pub ts_epoch: f64,
    pub dropbox_id: String,
}
```

### `DropboxMetricAggregate`

```rust
#[derive(Debug, Clone)]
pub struct DropboxMetricAggregate {
    pub dropbox_id: String,
    pub metric_count: usize,
    pub last_metric_ts: Option<String>,   // ISO-8601 UTC, or None when count is 0
}
```

### `StatsStoreSchema`

```rust
pub struct StatsStoreSchema;

impl StatsStoreSchema {
    pub const METRIC_SAMPLES_TABLE: &'static str;   // "metric_samples"
    pub const EVENT_SAMPLES_TABLE: &'static str;    // "event_samples"
    pub const CONTROL_TABLE: &'static str;          // "control"
    pub const TS_COLUMN: &'static str;              // "ts"
    pub const DROPBOX_ID_COLUMN: &'static str;      // "dropbox_id"
    pub const NAME_COLUMN: &'static str;            // "name"
    pub const VALUE_COLUMN: &'static str;           // "value"
    pub const TAGS_COLUMN: &'static str;            // "tags"
    pub const KIND_COLUMN: &'static str;            // "kind"
    pub const NOUN_TYPE_COLUMN: &'static str;       // "noun_type"
    pub const ROW_ID_COLUMN: &'static str;          // "estate_row_id"
    pub const ESTATE_COLUMN: &'static str;          // "estate"
    pub const KEY_COLUMN: &'static str;             // "key"
    pub const CONTROL_VALUE_COLUMN: &'static str;   // "value"
    pub const MONITORING_KEY: &'static str;             // "monitoring"
    pub const MONITORING_SOURCE_KEY: &'static str;      // "monitoring_source"
    pub const RETENTION_CUTOFF_KEY: &'static str;       // "retention_cutoff"

    // topology_snapshots table (v2)
    pub const TOPOLOGY_SNAPSHOTS_TABLE: &'static str;   // "topology_snapshots"
    pub const GENERATED_AT_COLUMN: &'static str;        // "generated_at"
    pub const PAYLOAD_COLUMN: &'static str;             // "payload"
    pub const TOPOLOGY_FINGERPRINT_COLUMN: &'static str; // "topology_fingerprint"
}
```

### `PersistenceStatsSink`

```rust
pub struct PersistenceStatsSink { /* private */ }

impl PersistenceStatsSink {
    /// Create a PersistenceStatsSink.
    /// store must already be opened.
    pub fn new(store: Arc<StatsStore>, dropbox_id: String) -> Self;
}

impl StatsSink for PersistenceStatsSink {
    /// Synchronous. Checks the store monitoring flag, inserts if on.
    /// Errors printed to stderr, never panicked.
    fn receive(&self, sample: StatSample);
}
```

---

## Swift/Rust Concordance

The complete top-level public surface of ObserverSink, one row per public
concept, each present in BOTH ports. The Swift and Rust shapes were read from
the sections above; the schema-name constants are itemised separately in the
schema-constants parity table that follows. Status `Confirmed` means the two
ports agree under the conformance suite cited.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Stats store | `StatsStore` (final class) | `StatsStore` (struct) | public / pub | Swift `async` actor-safe `final class` / Rust sync `struct`; same SQLite schema + control rows | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Filtered metric query | `queryMetricsByNames(_:dropboxID:limit:)` | `query_metrics_by_names` | public / pub | SQL IN predicate on name set; optional dropbox filter; optional limit (when set, ordering flips to ts DESC). Swift `Set<String>` / Rust `&[&str]`. | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Metric count | `countMetrics()` | `count_metrics` | public / pub | SQL COUNT(*) on `metric_samples`; no row decoding. | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Latest-per-pair query | `queryLatestMetricsByNamesAndDropboxes(_:dropboxIDs:)` | `query_latest_metrics_by_names_and_dropboxes` | public / pub | One indexed `WHERE name=? AND dropbox_id=? ORDER BY ts DESC LIMIT 1` per (name, dropboxID) pair; O(log n) per pair. | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Dropbox aggregates | `queryMetricAggregatesByDropbox(forDropboxIDs:)` | `query_metric_aggregates_by_dropbox` | public / pub | Indexed COUNT(*) + single-row ts probe per dropbox; returns `DropboxMetricAggregate`. | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Dropbox metric aggregate | `DropboxMetricAggregate` (struct) | `DropboxMetricAggregate` (struct) | public / pub | Swift `lastMetricTs: String?` / Rust `last_metric_ts: Option<String>`; `metricCount: Int` / `metric_count: usize`; same semantics. | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Topology snapshot write | `writeTopologySnapshot(estate:generatedAt:payload:fingerprint:)` | `write_topology_snapshot` + `write_topology_snapshot_bytes` | public / pub | Swift takes `Date` + `Data`; Rust takes `f64` epoch secs + `&str` (bytes variant via lossy UTF-8). Latest-wins upsert on estate PK. Fingerprint column nullable. | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Topology snapshot read | `latestTopologySnapshot(estate:)` | `latest_topology_snapshot` | public / pub | Swift returns `Data?`; Rust returns `Option<String>` (UTF-8 payload). Both return nil/None when no snapshot yet. nil estate selects newest across all estates. | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Topology fingerprint | `loadTopologyFingerprint(estate:)` | `load_topology_fingerprint` | public / pub | Returns nil/None when absent, row predates v3, or no fingerprint written. | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| DB-layer health | `storageStats(now:)` | `storage_stats(now_secs:)` | public / pub | Swift `now: Date` / Rust `now_secs: i64` (epoch seconds). Returns `StorageStats?` / `Option<StorageStats>`. Always Some for SQLite backend. | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Metric row | `MetricRow` | `MetricRow` | public / pub | Swift `ts: Date` (decoded from ISO-8601) / Rust `ts_epoch: f64`; `rowID: UUID` / `row_id: Uuid`; same fields otherwise | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Event row | `EventRow` | `EventRow` | public / pub | Swift `nounType: Int`/`ts: Date` / Rust `noun_type: i64`/`ts_epoch: f64`; Swift `rowIDStr` / Rust `estate_row_id`; same fields otherwise | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Schema-name namespace | `StatsStoreSchema` (enum-of-statics) | `StatsStoreSchema` (unit struct + consts) | public / pub | Swift caseless enum of `static let` / Rust `pub struct` with `pub const`s; same string values (see schema-constants table below) | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Persistence stats sink | `PersistenceStatsSink` | `PersistenceStatsSink` | public / pub | Swift `struct: StatsSink` (async Task for I/O; 64-slot in-flight cap — samples dropped silently when cap is reached) / Rust `struct impl StatsSink` (sync; no in-flight cap); both gate on the store monitoring flag and never throw to the caller | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |

Shape differences across ports:
- `write_topology_snapshot_bytes` is Rust-only (Swift rejects invalid UTF-8 at runtime; Rust provides a lossy-conversion variant as a separate function).
- `StorageStats` is re-exported from `persistence_kit` in the Rust crate so callers of `storage_stats` need not declare a direct `persistence_kit` dependency.
- Rust `StatsStore::close` returns `Result<(), StorageError>`; Swift `StatsStore.close()` is `async` and returns `Void` (errors are absorbed).
- `PersistenceStatsSink.receive(_:)` has a 64-slot in-flight Task cap in Swift (issue #48): when the cap is reached the sample is dropped silently (no log, no error). The Rust leg is synchronous and has no equivalent cap.

`StatsSink` and `StatSample` are the contract surface of IntellectusLib (documented in its own concordance) and are referenced here, not redeclared.

---

## Schema constants parity table

| Swift | Rust | Value |
|---|---|---|
| `StatsStoreSchema.metricSamplesTable` | `StatsStoreSchema::METRIC_SAMPLES_TABLE` | `"metric_samples"` |
| `StatsStoreSchema.eventSamplesTable` | `StatsStoreSchema::EVENT_SAMPLES_TABLE` | `"event_samples"` |
| `StatsStoreSchema.controlTable` | `StatsStoreSchema::CONTROL_TABLE` | `"control"` |
| `StatsStoreSchema.topologySnapshotsTable` | `StatsStoreSchema::TOPOLOGY_SNAPSHOTS_TABLE` | `"topology_snapshots"` |
| `StatsStoreSchema.tsColumn` | `StatsStoreSchema::TS_COLUMN` | `"ts"` |
| `StatsStoreSchema.dropboxIDColumn` | `StatsStoreSchema::DROPBOX_ID_COLUMN` | `"dropbox_id"` |
| `StatsStoreSchema.nameColumn` | `StatsStoreSchema::NAME_COLUMN` | `"name"` |
| `StatsStoreSchema.valueColumn` | `StatsStoreSchema::VALUE_COLUMN` | `"value"` |
| `StatsStoreSchema.tagsColumn` | `StatsStoreSchema::TAGS_COLUMN` | `"tags"` |
| `StatsStoreSchema.kindColumn` | `StatsStoreSchema::KIND_COLUMN` | `"kind"` |
| `StatsStoreSchema.nounTypeColumn` | `StatsStoreSchema::NOUN_TYPE_COLUMN` | `"noun_type"` |
| `StatsStoreSchema.rowIDColumn` | `StatsStoreSchema::ROW_ID_COLUMN` | `"estate_row_id"` |
| `StatsStoreSchema.estateColumn` | `StatsStoreSchema::ESTATE_COLUMN` | `"estate"` |
| `StatsStoreSchema.keyColumn` | `StatsStoreSchema::KEY_COLUMN` | `"key"` |
| `StatsStoreSchema.controlValueColumn` | `StatsStoreSchema::CONTROL_VALUE_COLUMN` | `"value"` |
| `StatsStoreSchema.monitoringKey` | `StatsStoreSchema::MONITORING_KEY` | `"monitoring"` |
| `StatsStoreSchema.monitoringSourceKey` | `StatsStoreSchema::MONITORING_SOURCE_KEY` | `"monitoring_source"` |
| `StatsStoreSchema.retentionCutoffKey` | `StatsStoreSchema::RETENTION_CUTOFF_KEY` | `"retention_cutoff"` |
| `StatsStoreSchema.generatedAtColumn` | `StatsStoreSchema::GENERATED_AT_COLUMN` | `"generated_at"` |
| `StatsStoreSchema.payloadColumn` | `StatsStoreSchema::PAYLOAD_COLUMN` | `"payload"` |
| `StatsStoreSchema.topologyFingerprintColumn` | `StatsStoreSchema::TOPOLOGY_FINGERPRINT_COLUMN` | `"topology_fingerprint"` |
