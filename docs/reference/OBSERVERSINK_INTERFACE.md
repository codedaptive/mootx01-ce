---
title: ObserverSink Interface
version: 1.0.0
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

    /// Schema version 1. Bump with a Migration when the schema changes.
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
    /// Returns [] immediately if `names` is empty. Ordered by ts ascending.
    /// Use in hot read-API paths instead of queryMetrics + Swift-side filter.
    public func queryMetricsByNames(
        _ names: Set<String>,
        dropboxID: String?
    ) async throws -> [MetricRow]

    /// Count total metric rows without decoding row content.
    /// Delegates to RowStore.count(table:where:) — SQL COUNT(*).
    public func countMetrics() async throws -> Int

    /// Query event samples, optionally filtered by dropbox. Ordered by ts ascending.
    public func queryEvents(dropboxID: String?) async throws -> [EventRow]

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
    public static let retentionCutoffKey: String      // "retention_cutoff"
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
    /// Checks the store monitoring flag first. Dispatches async Task for I/O.
    /// Errors logged, never thrown. Never blocks the caller.
    public func receive(_ sample: StatSample)
}
```

---

## Rust

### `StatsStore`

```rust
pub struct StatsStore { /* private */ }

impl StatsStore {
    /// Current schema version.
    pub const SCHEMA_VERSION: i32;

    /// Create a StatsStore backed by SQLite at `path`.
    pub fn new(path: &str) -> Result<Self, StorageError>;

    /// Open the store, apply schema, seed control rows.
    pub fn open(&self) -> Result<(), StorageError>;

    /// Close the store.
    pub fn close(&self) -> Result<(), StorageError>;

    // Monitoring flag
    pub fn is_monitoring_enabled(&self) -> Result<bool, StorageError>;
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

    pub fn query_events(
        &self,
        dropbox_id: Option<&str>,
    ) -> Result<Vec<EventRow>, StorageError>;

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
    pub const MONITORING_KEY: &'static str;         // "monitoring"
    pub const RETENTION_CUTOFF_KEY: &'static str;   // "retention_cutoff"
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
| Filtered metric query | `queryMetricsByNames(_:dropboxID:)` | _(pending Rust parity)_ | public / — | Swift-only; Rust parity pending. SQL IN predicate; returns named rows only. | `ObserverSinkConformanceTests.swift` | Swift-only |
| Metric count | `countMetrics()` | _(pending Rust parity)_ | public / — | Swift-only; Rust parity pending. SQL COUNT(*); no row decoding. | `ObserverSinkConformanceTests.swift` | Swift-only |
| Metric row | `MetricRow` | `MetricRow` | public / pub | Swift `ts: Date` (decoded from ISO-8601) / Rust `ts_epoch: f64`; `rowID: UUID` / `row_id: Uuid`; same fields otherwise | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Event row | `EventRow` | `EventRow` | public / pub | Swift `nounType: Int`/`ts: Date` / Rust `noun_type: i64`/`ts_epoch: f64`; Swift `rowIDStr` / Rust `estate_row_id`; same fields otherwise | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Schema-name namespace | `StatsStoreSchema` (enum-of-statics) | `StatsStoreSchema` (unit struct + consts) | public / pub | Swift caseless enum of `static let` / Rust `pub struct` with `pub const`s; same string values (see schema-constants table below) | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |
| Persistence stats sink | `PersistenceStatsSink` | `PersistenceStatsSink` | public / pub | Swift `struct: StatsSink` (async Task for I/O) / Rust `struct impl StatsSink` (sync); both gate on the store monitoring flag and never throw to the caller | `conformance.rs` / `ObserverSinkConformanceTests.swift` | Confirmed |

No DRIFT and no Apple-platform-bound (Exempt) types: every ObserverSink
public type ships in both ports. `StatsSink` and `StatSample` are the
contract surface of IntellectusLib (documented in its own concordance) and
are referenced here, not redeclared.

---

## Schema constants parity table

| Swift | Rust | Value |
|---|---|---|
| `StatsStoreSchema.metricSamplesTable` | `StatsStoreSchema::METRIC_SAMPLES_TABLE` | `"metric_samples"` |
| `StatsStoreSchema.eventSamplesTable` | `StatsStoreSchema::EVENT_SAMPLES_TABLE` | `"event_samples"` |
| `StatsStoreSchema.controlTable` | `StatsStoreSchema::CONTROL_TABLE` | `"control"` |
| `StatsStoreSchema.tsColumn` | `StatsStoreSchema::TS_COLUMN` | `"ts"` |
| `StatsStoreSchema.dropboxIDColumn` | `StatsStoreSchema::DROPBOX_ID_COLUMN` | `"dropbox_id"` |
| `StatsStoreSchema.nameColumn` | `StatsStoreSchema::NAME_COLUMN` | `"name"` |
| `StatsStoreSchema.valueColumn` | `StatsStoreSchema::VALUE_COLUMN` | `"value"` |
| `StatsStoreSchema.tagsColumn` | `StatsStoreSchema::TAGS_COLUMN` | `"tags"` |
| `StatsStoreSchema.kindColumn` | `StatsStoreSchema::KIND_COLUMN` | `"kind"` |
| `StatsStoreSchema.nounTypeColumn` | `StatsStoreSchema::NOUN_TYPE_COLUMN` | `"noun_type"` |
| `StatsStoreSchema.rowIDColumn` | `StatsStoreSchema::ROW_ID_COLUMN` | `"estate_row_id"` |
| `StatsStoreSchema.estateColumn` | `StatsStoreSchema::ESTATE_COLUMN` | `"estate"` |
| `StatsStoreSchema.monitoringKey` | `StatsStoreSchema::MONITORING_KEY` | `"monitoring"` |
| `StatsStoreSchema.retentionCutoffKey` | `StatsStoreSchema::RETENTION_CUTOFF_KEY` | `"retention_cutoff"` |
