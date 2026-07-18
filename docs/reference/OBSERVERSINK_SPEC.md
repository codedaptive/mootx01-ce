---
title: ObserverSink Specification
version: v1.1
status: active
date: 2026-06-14
description: The PersistenceKit-backed telemetry sink that persists IntellectusLib stat samples into an SQLite stats store, with schema, retention, and a monitoring on/off signal.
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/PERSISTENCEKIT_SPEC.md
---

# ObserverSink Specification

## 1. Purpose

`ObserverSink` is the reusable PersistenceKit-backed telemetry sink for the
MOOTx01 manager pipeline. It provides:

1. **`StatsStore`** — the SQLite stats-store: schema, open/migrate, and retention.
2. **`PersistenceStatsSink`** — a `StatsSink` conformance that serialises each
   `StatSample` from `IntellectusLib` into the `StatsStore`.

`ObserverSink` provides the `emit → IntellectusLib → PersistenceKit store →
readback` pipeline: stat samples emitted through IntellectusLib are durably
persisted and can be read back from the SQLite stats store.

Both Swift and Rust ports ship together and are conformance-gated via matching
integration tests.

---

## 2. Module location

```
packages/libs/ObserverSink/
├── Package.swift                      ← Swift package (swift-tools-version:6.2)
├── Sources/ObserverSink/
│   ├── StatsStore.swift               ← schema (v5, four tables) + lifecycle + CRUD
│   └── PersistenceStatsSink.swift     ← StatsSink conformance
├── Tests/ObserverSinkTests/
│   └── ObserverSinkConformanceTests.swift
└── rust/
    ├── Cargo.toml
    ├── src/
    │   ├── lib.rs
    │   ├── store.rs                   ← Rust StatsStore
    │   └── sink.rs                    ← Rust PersistenceStatsSink
    └── tests/
        └── conformance.rs
```

---

## 3. Dependencies

| Dependency | Direction | Rationale |
|---|---|---|
| `IntellectusLib` | ObserverSink depends on | Provides `StatsSink` protocol and `StatSample` datum |
| `PersistenceKit` + `PersistenceKitSQLite` | ObserverSink depends on | Provides `Storage` protocol and `SQLiteStorage` backend |

Layering is correct and non-inverting: ObserverSink depends on the kits below
it (IntellectusLib, PersistenceKit) and nothing depends back on it.

---

## 4. Schema

Four SQLite tables. All timestamps are stored as **TEXT (ISO-8601 UTC)**; no
REAL timestamp columns exist. This is a hard schema invariant across the
substrate: date storage is always TEXT, never a Unix-epoch REAL.

### 4.1 `metric_samples`

Stores metric observations from `StatSample.metric(name:value:tags:ts:)`.

| Column | Type | Notes |
|---|---|---|
| `row_id` | UUID TEXT PK | Synthetic primary key assigned by store |
| `name` | TEXT NOT NULL | Dot-separated metric name |
| `value` | REAL NOT NULL | Measured quantity |
| `tags` | TEXT NOT NULL | JSON-encoded `[String: String]` tag map |
| `ts` | TEXT NOT NULL | ISO-8601 UTC (see encoding note below) |
| `dropbox_id` | TEXT NOT NULL | Identifier of the consumer that emitted the sample |

Storage is always TEXT (ISO-8601 UTC). The Swift port takes a `Date` and the
Rust port takes `f64` epoch seconds; each port converts its native time value
to the ISO-8601 string at the store boundary before insertion. There is never
a REAL timestamp column (invariant I-1).

Index: `idx_metric_samples_ts` on `ts` (retention delete performance).

### 4.2 `event_samples`

Stores topology events from `StatSample.event(kind:nounType:rowID:estate:ts:)`.

| Column | Type | Notes |
|---|---|---|
| `row_id` | UUID TEXT PK | Synthetic primary key |
| `kind` | TEXT NOT NULL | EventKind raw string: `"capture"` or `"think"` |
| `noun_type` | INTEGER NOT NULL | NounType ordinal from SubstrateTypes |
| `estate_row_id` | TEXT NOT NULL | The substrate entity's row UUID string |
| `estate` | TEXT NOT NULL | Estate identifier string |
| `ts` | TEXT NOT NULL | ISO-8601 UTC |
| `dropbox_id` | TEXT NOT NULL | Consumer dropbox identifier |

Column named `estate_row_id` (not `row_id`) to avoid collision with the
synthetic primary key.

Index: `idx_event_samples_ts` on `ts`.

### 4.3 `control`

Key-value pairs for global state. Primary key is `key` (upsert semantics).

| Column | Type | Notes |
|---|---|---|
| `key` | TEXT NOT NULL PK | Control key |
| `value` | TEXT NOT NULL | Control value |

Well-known rows:

| Key | Value | Semantics |
|---|---|---|
| `"monitoring"` | `"1"` / `"0"` | Global monitoring on/off flag (manager writes, sink reads). Defaults to `"1"` (ON) for new estates (wave 8.1). |
| `"monitoring_source"` | `"default"` / `"user"` / `"unknown"` | Records the origin of the current monitoring value. `"default"` = system-seeded; `"user"` = explicitly set via `setMonitoringEnabled`; `"unknown"` = ambiguous pre-wave-8.1 opt-out preserved without change. The wave 8.1 migration uses this to distinguish seed values from explicit user choices. |
| `"retention_cutoff"` | ISO-8601 TEXT | Cutoff timestamp of the last retention pass. Defaults to epoch zero (`"1970-01-01T00:00:00.000Z"`) to indicate no pass has run. |

All three rows are seeded on `StatsStore.open()` using seed-if-absent semantics: the row
is inserted only when absent. An existing value (e.g. an operator-set monitoring flag)
is preserved across re-opens. Subsequent opens are no-ops for those rows.

### 4.4 `topology_snapshots` (v2)

Added by the v1→v2 migration. Stores the latest governor-computed topology payload
for each estate. One row per estate; the autonomic governor upserts after each
topology-recompute duty cycle.

| Column | Type | Notes |
|---|---|---|
| `estate` | TEXT NOT NULL PK | Estate identifier (PRIMARY KEY; one row per estate, latest-wins upsert) |
| `generated_at` | TEXT NOT NULL | ISO-8601 UTC timestamp of when the governor produced the snapshot |
| `payload` | TEXT NOT NULL | JSON-encoded ARIAGraphPayload bytes; served verbatim by `/api/graph` and moot-mgr |
| `topology_fingerprint` | TEXT NULL | Stable topology-inputs fingerprint (FNV-1a, process-independent). Added by v2→v3 migration. Nullable: pre-v3 rows and snapshots written without a fingerprint store NULL. |

The fingerprint lets a restarting governor compare the persisted inputs fingerprint against
freshly-computed inputs and skip the full drawer/tunnel/fact read when they match.

---

## 5. Schema version

`StatsStore.schemaVersion = 5` (Swift) / `StatsStore::SCHEMA_VERSION = 5` (Rust).

Schema version is stored in PersistenceKit's internal `_schema_versions` table,
keyed by `kitID = "ObserverSink"`. Future schema changes require a `Migration`
entry in the `SchemaDeclaration`.

Version history:

- **v1**: Initial schema — `metric_samples`, `event_samples`, `control`.
- **v2**: Added `topology_snapshots` table (one row per estate, latest-wins upsert;
  `estate`, `generated_at`, `payload`).
- **v3**: Added `topology_snapshots.topology_fingerprint` nullable column so the
  autonomic governor can skip the full topology read on restart when inputs are unchanged.
- **v4**: Added `idx_metric_samples_dropbox_id` index on `metric_samples.dropbox_id`
  for O(log n) per-dropbox COUNT(*) queries (deployed when 6M-row hot-dropbox tables
  caused 504 timeouts on full scans).
- **v5**: Replaced `idx_metric_samples_dropbox_id` with composite index
  `idx_metric_samples_dropbox_name_ts` (dropbox_id, name, ts DESC) so that
  per-(dropbox, name) ORDER BY ts DESC LIMIT 1 probes used by
  `queryLatestMetricsByNamesAndDropboxes` become pure index seeks. Reduced dashboard
  `/api/estates` latency from 3.8–4.3 s to sub-second on a 2.76M-row table.

---

## 6. Monitoring on/off signal

The global monitoring flag is a row in the `control` table (`key = "monitoring"`).

- **Default**: `"1"` (ON) for new estates, seeded by `StatsStore.open()` (wave 8.1
  behavior). Existing estates with a pre-wave-8.1 default-off seed are migrated to
  `"1"` on the next open, unless the operator explicitly set the flag via
  `setMonitoringEnabled` (indicated by `monitoring_source = "user"`).
- **Manager writes** the flag to `"1"` when enabling monitoring and to `"0"` when
  disabling it. Writing also records `monitoring_source = "user"` so subsequent
  re-opens do not revert the operator's choice.
- **`PersistenceStatsSink`** reads this row on every `receive(_:)` call. If the
  value is `"0"`, the sample is discarded without I/O.

This **flag-row signal mechanism** lets monitoring be toggled centrally: the
flag lives in durable storage, so any consumer that reads it on each
`receive(_:)` call observes the current state without coordination.

Note: `Intellectus.isEnabled` (IntellectusLib level) provides a first short-circuit
gate that prevents `receive(_:)` from being called at all when monitoring is
disabled at the IntellectusLib level. The store flag provides a second layer:
the manager can turn off the store flag without requiring every consumer to be
restarted.

---

## 7. Retention

Retention removes rows older than a caller-supplied cutoff. No `Date()` is ever
called inside any engine — determinism is required.

- `StatsStore.deleteMetricsBefore(cutoff: Date, now: Date) -> Int`
- `StatsStore.deleteEventsBefore(cutoff: Date, now: Date) -> Int`

The manager calls these on its retention schedule, passing a `Date` computed
from `Date.now.addingTimeInterval(-retentionWindow)`. After deletion, the
`"retention_cutoff"` control row is updated with the ISO-8601 string of `cutoff`.

Rust equivalents:
- `StatsStore::delete_metrics_before(cutoff_epoch_secs: f64, now_epoch_secs: f64)`
- `StatsStore::delete_events_before(cutoff_epoch_secs: f64, now_epoch_secs: f64)`

---

## 8. `PersistenceStatsSink` — sink design

| Property | Value |
|---|---|
| Protocol | `StatsSink` (IntellectusLib) |
| State | Holds a `StatsStore` reference and a `dropboxID` string. The `dropboxID` is the stable identifier of the consumer feeding this sink; every row it writes is stamped with it so samples from multiple consumers sharing one store can be distinguished. |
| `receive(_:)` | Synchronous entry, checks store flag, dispatches I/O |

### Swift port

`receive(_:)` is synchronous and non-blocking. Each sample is dispatched to an
unstructured `Task` for async store I/O (required because `SQLiteStorage` is
actor-isolated). Errors from the `Task` are logged at `.error` level; never thrown.

**In-flight cap (backpressure, issue #48)**: before dispatching a Task, the
Swift port checks an `InFlightCounter` capped at 64. If the cap is already
reached, `receive(_:)` returns immediately and the sample is silently dropped —
no log is emitted and no error is reported. This bounds Task backlog and memory
growth under sustained high-rate emission. 64 concurrent inserts is generous for
any realistic workload. Telemetry loss under extreme backpressure is acceptable
for the stats-recording use case.

### Rust port

`receive` is fully synchronous (the `StatsSink` trait is synchronous; `SqliteStorage`
is mutex-backed synchronous I/O). No thread spawning. Errors are printed to `stderr`.
The Rust leg has no in-flight cap because there are no Tasks to bound.

This is intentional — Rust and Swift have different concurrency models. The core
behavior is the same on both legs: gate on the monitoring flag → insert if on →
discard if off → never panic. Swift additionally gates on the in-flight cap before
dispatching a Task; the Rust leg goes directly to the flag check.

---

## 9. Conformance tests

Both ports ship matching integration tests:

- Swift: `ObserverSinkConformanceTests.swift` (34 tests, Swift Testing)
- Rust: `tests/conformance.rs` (29 tests, `#[test]`)

Tests cover:
1. Schema version constant correct
2. Control rows seeded on open (monitoring defaults ON per wave 8.1)
3. Monitoring flag write-read round-trip
4. Metric emit → stored → readback (name, value, tags, ts, dropboxID match)
5. Event emit → stored → readback (kind, nounType, rowID, estate, ts match)
6. Monitoring off → sink discards samples
7. `deleteMetricsBefore` rolls off old rows, keeps new rows
8. `deleteEventsBefore` rolls off old event rows, keeps new rows
9. Tag map JSON round-trip (3-entry map)
10. Empty tag map round-trip

---

## 10. Invariants

- **I-1**: All `ts` columns are TEXT (ISO-8601 UTC). No REAL timestamp columns.
- **I-2**: No `Date()` / `SystemTime::now()` call inside any engine method.
  All time values are caller-supplied.
- **I-3**: `receive(_:)` must never throw or panic. Store errors are logged,
  not propagated.
- **I-4**: Both Swift and Rust ports must pass their conformance tests before
  either can be merged.
- **I-5**: The `estate_row_id` column name is stable — renaming would break
  existing databases. This is a schema invariant.

---

## 11. Future evolution

- **Recent window (shipped)**: The bounded in-process recent window is provided
  by IntellectusLib's `RecentWindowSink`, which the resident observer program
  installs as the global sink and configures to *forward* each sample to
  `PersistenceStatsSink`. So one installed sink both retains a bounded recent
  window (liveness proof) and persists durably. The window bound is 256 samples
  by default.
- **Batch-flush (anticipated)**: Batch-flush in `PersistenceStatsSink`. If
  benchmarks show per-sample Task overhead is measurable, a 100-sample batch on
  a 1-second timer would reduce SQLite write amplification.
- **Postgres backend**: `StatsStore` will gain a Postgres variant when
  multi-host aggregation is required. The `SchemaDeclaration` already describes
  the tables portably; only the `EstateConfiguration.backend` changes.
