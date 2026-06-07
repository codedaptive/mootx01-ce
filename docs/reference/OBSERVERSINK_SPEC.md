---
title: ObserverSink Specification
version: 1.0
status: active
spec_type: kit
authors: MOOTx01 maintainers
date: 2026-06-06
relates_to:
  - docs/decisions/DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.md
  - docs/reference/PERSISTENCEKIT_SPEC.md
---

# ObserverSink Specification v1.0

## 1. Purpose

`ObserverSink` is the reusable PersistenceKit-backed telemetry sink for the
MOOTx01 manager pipeline. It provides:

1. **`StatsStore`** — the SQLite stats-store: schema, open/migrate, and retention.
2. **`PersistenceStatsSink`** — a `StatsSink` conformance that serialises each
   `StatSample` from `IntellectusLib` into the `StatsStore`.

`ObserverSink` is the `Phase 0.5` building block that de-risks the
`emit → IntellectusLib → PersistenceKit store → readback` pipeline before
the full Manager spine (Phase 1) is wired. See `MANAGER_1.0_PLAN.md §3`.

Both Swift and Rust ports ship together and are conformance-gated via matching
integration tests.

---

## 2. Module location

```
packages/libs/ObserverSink/
├── Package.swift                      ← Swift package (swift-tools-version:6.2)
├── Sources/ObserverSink/
│   ├── StatsStore.swift               ← schema + lifecycle + CRUD
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

Layering is correct and non-inverting. The in-repo dependency additions follow
`DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28`.

---

## 4. Schema

Three SQLite tables. All timestamps stored as **TEXT (ISO-8601 UTC)**; no REAL
timestamp columns exist (schema invariant, `CLAUDE.md`).

### 4.1 `metric_samples`

Stores metric observations from `StatSample.metric(name:value:tags:ts:)`.

| Column | Type | Notes |
|---|---|---|
| `row_id` | UUID TEXT PK | Synthetic primary key assigned by store |
| `name` | TEXT NOT NULL | Dot-separated metric name |
| `value` | REAL NOT NULL | Measured quantity |
| `tags` | TEXT NOT NULL | JSON-encoded `[String: String]` tag map |
| `ts` | TEXT NOT NULL | ISO-8601 UTC; epoch-seconds Double encoded at boundary |
| `dropbox_id` | TEXT NOT NULL | Consumer dropbox identifier |

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
| `"monitoring"` | `"1"` / `"0"` | Global monitoring on/off flag (manager writes, sink reads) |
| `"retention_cutoff"` | ISO-8601 TEXT | Cutoff timestamp of the last retention pass |

Both rows are seeded on `StatsStore.open()` (upsert, idempotent).

---

## 5. Schema version

`StatsStore.schemaVersion = 1` (Swift) / `StatsStore::SCHEMA_VERSION = 1` (Rust).

Schema version is stored in PersistenceKit's internal `_schema_versions` table,
keyed by `kitID = "ObserverSink"`. Future schema changes require a `Migration`
entry in the `SchemaDeclaration`.

---

## 6. Monitoring on/off signal

The global monitoring flag is a row in the `control` table (`key = "monitoring"`).

- **Manager writes** the flag to `"1"` when it starts accepting subscribers and
  to `"0"` when it shuts down or the last subscriber drops.
- **`PersistenceStatsSink`** reads this row on every `receive(_:)` call. If the
  value is `"0"`, the sample is discarded without I/O.

This is the **flag-row signal mechanism** confirmed by Bob (2026-06-06,
`MANAGER_1.0_PLAN.md §5` item 3).

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
| State | Holds a `StatsStore` reference and a `dropboxID` string |
| `receive(_:)` | Synchronous entry, checks store flag, dispatches I/O |

### Swift port

`receive(_:)` is synchronous and non-blocking. Each sample is dispatched to an
unstructured `Task` for async store I/O (required because `SQLiteStorage` is
actor-isolated). Errors from the `Task` are logged at `.error` level; never thrown.

### Rust port

`receive` is fully synchronous (the `StatsSink` trait is synchronous; `SqliteStorage`
is mutex-backed synchronous I/O). No thread spawning. Errors are printed to `stderr`.

This is intentional — Rust and Swift have different concurrency models. The
observable behavior (check flag → insert if on → discard if off → never panic)
is identical.

---

## 9. Conformance tests

Both ports ship matching integration tests:

- Swift: `ObserverSinkConformanceTests.swift` (10 tests, Swift Testing)
- Rust: `tests/conformance.rs` (10 tests, `#[test]`)

Tests cover:
1. Schema version constant correct
2. Control rows seeded on open (monitoring defaults off)
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

- **v1.1 (anticipated)**: Ring buffer + batch-flush in `PersistenceStatsSink`.
  If benchmarks show per-sample Task overhead is measurable, a 100-sample
  batch on a 1-second timer would reduce SQLite write amplification.
- **Postgres backend**: `StatsStore` will gain a Postgres variant when the
  fleet manager needs multi-host aggregation. The `SchemaDeclaration` already
  describes the tables portably; only the `EstateConfiguration.backend` changes.
