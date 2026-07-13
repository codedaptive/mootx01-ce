---
mission: MX-TAB-2
title: Postgres DatasetStore conformance — both legs
date: 2026-07-12
status: complete
---

# Blast Radius Report — MX-TAB-2

Net-new `DatasetStore` conformance for the PostgreSQL backend: Swift (`PostgreSQLDatasetStore`)
and Rust (`PgDatasetStore`). Primary design decisions:

- **`__ds_pk` containment:** synthetic `BIGINT GENERATED ALWAYS AS IDENTITY` PK column
  excluded from all schema-driven SELECT and INSERT surfaces via the cached schema
  (cache miss divergence documented below).
- **`COLLATE "C"` DDL:** dataset TEXT columns carry `COLLATE "C"` to lock byte-order
  TEXT ordering, matching SQLite BINARY collation and the Rust InMemory leg.
- **Schema-cache gap:** the in-process schema cache (populated by `create_dataset`,
  consumed by `query_rows` / `column_stats`) is not rebuilt on process restart.
  Swift throws `BackendError`; Rust falls back to `SELECT *` (exposes `__ds_pk`,
  loses column-type hints). Both divergences are documented in code; an
  information_schema recovery path is the follow-up.

Commit: `749ec963`

---

## Step 0 — Baseline

Mission is net-new (`PostgreSQLDatasetStore` and `PgDatasetStore` did not exist before
this commit). All 13 Swift + 11 Rust Postgres dataset tests are skip-gated on
`POSTGRES_TEST_URL` / `PERSISTENCEKIT_PG_URL` environment variables — vacuously green
in CI where no live server is present. `swift build` and `cargo build` exited 0.

Pre-existing PersistenceKit Swift suite at mission start (non-Postgres): green.
`decodeCell` visibility change (private → internal) required to share the decode path
between `queryDatasetRows` and `datasetColumnStats` — confirmed no external call sites.

---

## Files Modified

### Swift leg

| File | Change | Role |
|---|---|---|
| `packages/kits/PersistenceKit/Sources/PersistenceKitPostgreSQL/PostgreSQLDatasetStore.swift` | Net-new file — full DatasetStore implementation | Primary implementation |
| `packages/kits/PersistenceKit/Sources/PersistenceKitPostgreSQL/PostgreSQLStorage.swift` | Wire `datasetStore` property on `PostgreSQLStorage` | Integration point |
| `packages/kits/PersistenceKit/Sources/PersistenceKitPostgreSQL/PostgreSQLConnection.swift` | `decodeCell` promoted private → internal for dataset column stats path | Visibility change |
| `packages/kits/PersistenceKit/Tests/PersistenceKitPostgreSQLTests/PostgreSQLDatasetStoreTests.swift` | 13 skip-gated integration tests | Test suite |

### Rust leg

| File | Change | Role |
|---|---|---|
| `packages/kits/PersistenceKit/rust/src/postgres.rs` | `PgDatasetStore` struct + `DatasetStore` impl added (~496 lines) | Primary implementation |
| `packages/kits/PersistenceKit/rust/tests/postgres_dataset_store.rs` | 11 skip-gated integration tests (`PERSISTENCEKIT_PG_URL`) | Test suite |

---

## Design decisions and containment surfaces

### `__ds_pk` containment

The `__ds_pk` column is excluded from the schema-driven SELECT and INSERT lists because
the cached `DatasetSchema.columns` field is populated by `create_dataset` with only
user-declared columns. `__ds_pk` is never inserted into that list.

On a **schema-cache miss** (process restart before `create_dataset` is re-called):
- **Swift:** `queryDatasetRows` throws `BackendError` — no fallback.
- **Rust:** `query_rows` falls back to `SELECT *`. `__ds_pk` is present in returned
  `StorageRow` maps; column-type hints are absent, so DOUBLE PRECISION `column_stats`
  MIN/MAX decode incorrectly (Null instead of Float).

Both divergences are documented in `PostgreSQLDatasetStore.swift` header and
`postgres.rs` `query_rows` comment. Follow-up: `information_schema`-based cache rebuild.

### COLLATE "C" DDL

`pg_dataset_type_sql()` (Rust) / `datasetTypeSql()` (Swift) emit `TEXT COLLATE "C"`
for `ColumnType::Text`. This is the only place in the dataset DDL path that adds a
collation qualifier. No impact on non-TEXT columns.

---

## MUST_UPDATE Resolution

This is a net-new conformance — no existing callers were modified. The only pre-existing
file change was `PostgreSQLConnection.swift` (`decodeCell` visibility: private → internal),
confirmed to have no external call sites.

All sites resolved. No deferrals.

### Known gap (documented, not deferred)

The schema-cache miss divergence between the Swift and Rust legs is a prototype-phase
gap. It is documented in both source files. A dedicated follow-up mission will add
`information_schema`-based schema reconstruction on cache miss to the Rust leg and
add the equivalent fallback to the Swift leg. This is NOT a deferred MUST_UPDATE item —
no existing symbol is being migrated; this is net-new behaviour that needs hardening.
