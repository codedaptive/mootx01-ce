---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: PersistenceKit
kind: Kit
relates_to:
  - PERSISTENCEKIT_INTERFACE_v0.8.md  (the API surface this spec contracts)
  - SUBSTRATELIB_SPEC_v0.8.md  (AuditEvent, HLC, Fingerprint256 — the value model persisted here)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md  (where storage sits in the substrate)
  - DECISION_STORAGEKIT_DESIGN_2026-05-19.md  (the eight design decisions Q1–Q8)
purpose: |
  PersistenceKit is the storage-abstraction layer of the substrate.
  It defines one `Storage` protocol — surfacing a RowStore, BlobStore,
  VectorIndex, AuditLog, and StorageObserver — and ships three
  conforming backends behind it: SQLite (with the vendored sqlite-vec
  extension), PostgreSQL (pgvector), and InMemory (tests). Consumers
  declare their schema as typed Swift structs and reach storage only
  through the protocol; no consumer names a backend's internal types.
  The companion INTERFACE document carries the signatures.
---

# PersistenceKit Specification

## § 1 — What this package is

PersistenceKit is the substrate's storage seam. Every kit that needs to
persist rows, blobs, vectors, or audit events talks to one protocol —
`Storage` — and never to a database driver. `Storage` surfaces five
sub-stores: a `RowStore` (typed row I/O), a `BlobStore` (opaque byte
I/O), a `VectorIndex` (k-NN search), an `AuditLog` (append-only
HLC-ordered event persistence), and a `StorageObserver` (change
notification). Three backends conform: SQLite (file-backed, WAL, with
the vendored sqlite-vec C amalgamation for vectors), PostgreSQL
(pooled, pgvector), and InMemory (the test and conformance reference).

Consumers declare their schema once as plain typed Swift structs
(`SchemaDeclaration` → `TableDeclaration` → `ColumnDeclaration`),
express queries through a closed `StoragePredicate` enum, and wrap every
value crossing the boundary in `TypedValue`. The backend compiles these
declarations and predicates to backend-native DDL and SQL. No SQL string
escapes into the kit layer except through the explicit
`SchemaOperation.custom` migration escape hatch.

This package is a **Kit**: it manages connections, files, pools,
transactions, and migration state — durable, lifecycle-bearing state, in
contrast to a stateless Lib. The eight design questions behind this kit
(schema declaration, predicate tree, transaction model, migration
runner, vector parameters, connection pool, audit coordination,
conformance fixtures) are settled in `DECISION_STORAGEKIT_DESIGN_2026-05-19.md`;
this spec is the durable contract those decisions produced.

## § 2 — Scope

This specification defines:

- The `Storage` protocol and its five sub-store contracts.
- The typed value model (`TypedValue`, `ColumnType`, `Column`).
- Schema declaration and forward-only migration semantics.
- The closed predicate algebra (`StoragePredicate`) and ordering
  (`OrderClause`).
- Generated (computed) columns and their structured expression algebra.
- The transaction model: isolation levels, atomicity, no nesting.
- Vector index add/update/delete/knn semantics and the typed parameter
  enums.
- Append-only audit persistence and HLC-ordered iteration.
- Change-notification (observer) delivery semantics.
- At-rest encryption modes (1–3) as an estate-configuration concern.
- The automated read-through cache layer: per-backend row caching with
  a tunable sensitivity gate, LRU eviction under a RAM byte ceiling,
  and StorageObserver-driven invalidation.
- The cross-backend conformance obligation (all three backends, one
  fixture suite, identical observable results).

This specification does NOT define:

- API signatures — those live in `PERSISTENCEKIT_INTERFACE_v0.8.md`.
- The audit-event value model, HLC, or fingerprints — those are
  SubstrateLib's (`SUBSTRATELIB_SPEC_v0.8.md`).
- CRDT structure and audit-event generation (eventID, HLC assignment,
  projection) — GeniusLocusKit owns those.
- Sync / replication — ConvergenceKit owns those.
- Each consumer's schema content — every consumer kit declares its own
  tables.

## § 3 — Position in the kit family

```
SubstrateLib                 (AuditEvent, HLC, Fingerprint256)
   ▲
PersistenceKit               ← the Storage protocol + value model
   ├── PersistenceKitSQLite      (SQLite + sqlite-vec, WAL)
   ├── PersistenceKitPostgreSQL  (PostgreSQL + pgvector, pooled)
   └── PersistenceKitInMemory    (tests, conformance reference)
   ▲
   ├── LocusKit          (one estate's rows, blobs, audit)
   ├── VectorKit         (embeddings → VectorIndex)
   ├── CorpusKit         (RAG bundles → rows + vectors)
   ├── QueueKit          (durable work queue → rows + observer)
   ├── ConvergenceKit    (outbound replication → observer, TableChange)
   └── GeniusLocusKit    (estate composition, opens backends)
```

**Depends on:** SubstrateLib (for `AuditEvent`, `HLC`, `Fingerprint256`,
which the value model and audit log carry). The SQLite backend depends
additionally on the vendored `CSQLiteVec` C target; no other external
Swift package dependency.

**Consumed by:** LocusKit, VectorKit, CorpusKit, QueueKit,
ConvergenceKit, GeniusLocusKit (which opens the concrete backends), and
the ARIA surfaces transitively.

## § 4 — Invariants

**I-1 (one protocol, swappable backends):** every consumer reaches
storage through `Storage` and its five sub-store protocols. A consumer
that compiles against `Storage` runs unchanged on SQLite, PostgreSQL, or
InMemory. Backends differ in file format and performance, never in
observable result (§ 7, C-1).

**I-2 (raw SQLite, never Core Data):** the SQLite backend is built on
raw SQLite through the vendored amalgamation, with the sqlite-vec
extension for vectors. Core Data is never used (project decision).

**I-3 (dates are TEXT ISO-8601):** a `TypedValue.timestamp` is stored as
ISO-8601 UTC text, never as a REAL Unix/Julian timestamp. This holds in
every backend that materializes a date column (project decision; spec
constraint).

**I-4 (closed value model):** the set of `TypedValue` cases and
`ColumnType` cases is closed. Adding a case requires updating every
backend in the same change; backends pattern-match exhaustively. There
is no `Any`-typed or string-typed value escape.

**I-5 (closed predicate algebra):** `StoragePredicate` is a closed enum
with three operator families — logical, comparison, bitmap. Backends
compile every case exhaustively to native SQL. There is no
`additionalParameters` or raw-SQL predicate escape; PersistenceKit
treats predicates as opaque except for compilation.

**I-6 (append-only audit, idempotent on key):** the audit log is
append-only. `append` and `appendBatch` are idempotent on the compound
key `(eventID, hlc)`: re-appending the same event is a no-op. The kit
persists and iterates; it does not enforce CRDT structure or generate
event identities (those are GeniusLocusKit's, per Q7).

**I-7 (forward-only migration, fail-fast):** migration runs forward only,
one transaction per migration, fail-fast. A failure mid-run leaves the
schema at the last successfully committed version; there is no automatic
rollback across committed migrations. Callers inspect
`currentSchemaVersion()` after a failed `migrate`. In multi-kit
deployments (multiple kits sharing one `Storage` instance), use
`currentSchemaVersion(for: kitID)` to query per-kit version; the
no-arg method returns the global maximum across all kits.

**I-8 (no Bool stored property on entities):** PersistenceKit stores
boolean *columns* (`ColumnType.bool`, `TypedValue.bool`) for backends,
but the substrate's entity types carry boolean state in `Int64` bitmap
fields, queried through the bitmap predicate family
(`bitmaskAll`/`bitmaskAny`/`bitmaskNone`/`bitwiseEq`). The bitmap
operators exist precisely so entity booleans never need a dedicated
stored column.

**I-9 (estate-scoped):** one `EstateConfiguration` opens one `Storage`
instance for one estate. A PostgreSQL pool is per-estate, fixed-size,
with an explicit maximum and no auto-resize (Q6).

**I-11 (cache transparency):** when `EstateConfiguration.cacheConfig` is
enabled, each backend's `rowStore` accessor returns a `CachingRowStore`
decorator wrapping the backing `RowStore`. The decorator is fully
transparent: consumers call the same `RowStore` protocol, receive
identical results, and need not know the cache exists. When
`cacheConfig` is disabled (the default, `.disabled`), no decorator is
created, no observer is subscribed, no memory is allocated — behavior
is identical to pre-cache PersistenceKit.

**I-12 (sensitivity gate, fail-closed):** the cache reads the
`provenance` column from each `StorageRow` and decodes sensitivity as
`(provenance >> 4) & 0x7`. Rows at or above the configured
`sensitivityThreshold` are not cached. Rows at Secret level (raw 3)
are never cached regardless of threshold — `EstateCacheConfig` clamps
the threshold to ≤2 at construction. If the `provenance` column is
absent (table does not carry it), the row caches normally. If the
column is present but unparseable, the row does not cache (fail
closed), mirroring the `adjectives.rs` `from_raw` precedent.

**I-13 (cache is PersistenceKit-internal):** the cache lives entirely
inside PersistenceKit. No consumer kit constructs, configures, or
references caching types directly. Consumers receive `any Storage` via
dependency injection (I-1) and get caching automatically if the
underlying backend's `EstateConfiguration` has it enabled.

**I-14 (cross-port parity):** the Rust version (`persistence-kit`) mirrors
the value model, predicate algebra, schema declaration, and the five
trait contracts case-for-case. All three backends ship in both ports —
InMemory, SQLite (rusqlite "bundled" + sqlite-vec), and PostgreSQL (sync
`postgres` crate + pgvector) — and both ports implement the transaction
surface. The one port adaptation: Swift's `transaction<T>` returns a
generic value, while Rust's must stay object-safe (`dyn Storage`), so the
Rust block returns `StorageResult<()>` (Ok commits, Err rolls back) and
surfaces results through its own captured environment. Observable
conformance results match across ports (C-8), not byte-identical DBs.

## § 5 — Behavioral contracts

**B-1 (auto-commit outside a transaction):** the sub-stores reached
through `storage.rowStore` etc. auto-commit each single operation. For
multi-operation atomicity, use `transaction(_:)`, which exposes the same
sub-store protocols bound to one connection.

**B-2 (transaction atomicity):** if the `transaction` block throws, the
transaction rolls back and no write within it is visible. If it returns,
all writes commit together. The four sub-stores inside one transaction
share one connection (Q6).

**B-3 (isolation levels):** `readCommitted` is the default. SQLite maps
`readCommitted` and `repeatableRead` to `BEGIN IMMEDIATE` and is
effectively serializable under WAL; PostgreSQL maps to the standard
levels; InMemory snapshots at transaction start and behaves as
serializable for all three. No nested transactions, no savepoints at
v0.8 (Q3).

**B-4 (query ordering and paging):** `query` returns rows matching the
predicate, ordered by the supplied `[OrderClause]` (ascending default),
with optional `limit` and `offset`. A nil predicate matches every row in
the table.

**B-5 (upsert by conflict columns):** `upsert` inserts, or updates the
existing row when the named `conflictColumns` collide, returning the
`RowHandle` either way. `update` and `delete` return the affected-row
count.

**B-6 (predicate short-circuiting):** `StoragePredicate.all([…])` and
`.any([…])` fold trivial `isTrue`/`isFalse` terms: an `all` containing
`isFalse` collapses to `isFalse`; an empty `all` is `isTrue`; dually for
`any`. The bitmap operators evaluate against `Int64` columns:
`bitmaskAll` is `(col & mask) == mask`, `bitmaskAny` is
`(col & mask) != 0`, `bitmaskNone` is `(col & mask) == 0`, `bitwiseEq`
is `(col & mask) == expected`.

**B-7 (generated columns, one meaning per backend):** a `GeneratedColumn`
carries a structured `GeneratedExpression` (bit-and/or/xor, fixed-count
shifts, equality), not a SQL string. SQLite and PostgreSQL render it to
identical `GENERATED ALWAYS AS (…) STORED` DDL; InMemory evaluates it
against the row at write time. All three realize the same integer
result. Generated columns are always STORED (PostgreSQL has no VIRTUAL
generated columns).

**B-8 (append-only tables):** a `TableDeclaration` with `appendOnly =
true` accepts INSERT and rejects UPDATE/DELETE. SQLite emits aborting
BEFORE-UPDATE/BEFORE-DELETE triggers; PostgreSQL attaches a raising
trigger; InMemory rejects in `RowStore.update`/`delete` with
`StorageError.appendOnlyViolation`.

**B-9 (vector search):** `knn(query:k:metric:filter:searchParameters:)`
returns up to `k` `VectorSearchResult`s ordered by ascending distance
under the chosen `DistanceMetric` (cosine, l2, dot), optionally narrowed
by a `StoragePredicate` filter. A nil `searchParameters` uses the
backend's documented default for the index type (e.g. sqlite-vec HNSW
m=16, efConstruction=200, efSearch=50). `reindex(parameters:)` rebuilds
under the given `IndexParameters` (flat / ivf / hnsw).

**B-10 (audit iteration order):** `iterate(after:rowID:limit:)` returns
events in HLC order, resumable via the `after` cursor and optionally
narrowed to one `rowID`. `eventsForRow(_:)` returns one row's events in
HLC order for projection. The kit orders and persists; it does not fold
or project.

**B-11 (observer delivery):** `observe(table:events:)` returns an
`AsyncStream<TableChange>`. Delivery is at-least-once; ordering is
preserved within one observer but not across tables. Writes do not block
on subscribers; a slow subscriber gets backpressure and may drop oldest
under load. `NoOpObserver` returns an immediately-finished stream for
backends or paths that do not observe.

**B-13 (cache read-through):** on a keyed row lookup, `CachingRowStore`
serves from its InMemory hot tier when the row is warm and admissible.
On a miss, it falls through to the backing `RowStore`, populates the
cache (subject to the sensitivity gate), and returns the result. Query
by predicate passes through to the backing store (no query-result
caching). `insert`, `upsert`, `update`, and `delete` pass through to
the backing store and synchronously invalidate the affected cache
entry.

**B-14 (cache invalidation):** `CacheInvalidator` subscribes to
`StorageObserver` for insert/update/delete events on all tables. On a
`TableChange`, it invalidates the affected `RowHandle` in the
`CachingRowStore`. This provides belt-and-suspenders invalidation
alongside the synchronous write-path invalidation in B-13.

**B-15 (LRU eviction):** the cache maintains an estimated byte size
for its entries and evicts least-recently-used entries when the total
exceeds `EstateCacheConfig.ceilingBytes`. Evicted rows remain
readable via the backing store on the next read.

**B-12 (encryption is transparent to consumers):** an estate's
`EstateEncryptionConfig` selects mode 1 (plaintext), 2 (per-row content
ciphertext), or 3 (full-database under a per-install key). Default is
`.plaintext`, so existing call sites are unchanged and carry no crypto
on any path. Modes 2 and 3 encrypt the content column under an
AES-GCM-256 key; consumers issue the same reads and writes regardless of
mode.

## § 6 — Error model (conceptual)

Errors are surfaced as `StorageError` (Swift) / `StorageError` (Rust).

| Category | Trigger | Recovery posture |
|---|---|---|
| `backendUnavailable` | backend cannot be opened/reached | abort; fix configuration |
| `schemaMismatch` | on-disk schema version ≠ expected | migrate, or surface to operator |
| `migrationFailed` | a migration step threw | inspect `currentSchemaVersion(for:)` (or no-arg for global), fix migration, retry forward |
| `constraintViolation` | unique/PK/check constraint hit | surface to caller; caller adjusts data |
| `poolExhausted` | no connection within `connectionTimeout` | retry per caller policy (Q6) |
| `transactionConflict` | serialization/lock conflict | retry the transaction |
| `typeMismatch` | column value type ≠ declared `ColumnType` | abort; caller fix |
| `rowNotFound` | keyed read found no row | surface; not always fatal |
| `duplicateKey` | insert collided on key | surface; caller may upsert |
| `invalidQuery` | malformed predicate/query for backend | abort; programmer error |
| `appendOnlyViolation` | UPDATE/DELETE on append-only table | abort; programmer error (B-8) |
| `backendError` | underlying driver error, wrapped | inspect `underlying`; backend-specific |

Concrete enum shapes (Swift cases, Rust variants) live in INTERFACE § 4.

## § 7 — Conformance requirements

**C-1 (backend equivalence):** all three backends pass one shared
fixture suite (200+ seeded operations across schema, migration, row I/O,
all `StoragePredicate` cases, blob I/O, vector knn over all metrics and
index types, audit ordering, transactions, concurrency, and error
paths) with identical *observable* results — same query results, same
error categories for the same invalid inputs, same projection output.
"Identical" is observable, not byte-identical at the file layer (Q8).

**C-2 (predicate coverage):** every `StoragePredicate` case — logical,
comparison, and all four bitmap operators — compiles and executes on
every backend with the semantics in B-6.

**C-3 (generated-column parity):** every `GeneratedExpression` produces
the same integer result whether rendered to SQLite DDL, PostgreSQL DDL,
or evaluated in-memory (B-7).

**C-4 (migration forward-only):** migrating forward through a sequence
applies each migration in its own transaction and records the version;
an injected mid-sequence failure leaves the schema at the last committed
version (I-7).

**C-5 (audit idempotence):** appending the same `(eventID, hlc)` twice,
directly or via `appendBatch`, yields one stored event; iteration order
is HLC-monotonic (I-6, B-10).

**C-6 (append-only enforcement):** UPDATE or DELETE against an
append-only table fails with `appendOnlyViolation` on every backend;
INSERT succeeds (B-8).

**C-7 (date storage):** a round-tripped `TypedValue.timestamp` is stored
as ISO-8601 text and reads back equal (I-3).

**C-9 (cache transparency):** a backend with caching enabled produces
identical observable results to the same backend with caching disabled
for the same operation sequence. The cache is a performance
optimization only; it must never change semantics.

**C-10 (cache sensitivity gate):** rows with `(provenance >> 4) & 0x7`
at or above the configured threshold are verified absent from the
cache after admission attempts. Secret-level rows (raw 3) are never
present in the cache regardless of threshold setting. Rows without a
`provenance` column are verified present in the cache after admission.

**C-8 (cross-port parity):** every backend — InMemory, SQLite, and
PostgreSQL — produces identical observable results in the Swift and Rust
ports for the same fixture sequence: value round-trip, predicate
evaluation, schema declaration, blob I/O, audit ordering, generated
columns, append-only enforcement, transaction commit/rollback, and (where
a backend ships a VectorIndex) k-NN ordering. The Rust port proves this
with a backend-agnostic conformance suite driven by a `Factory` over each
backend; PostgreSQL runs against a live database when `PERSISTENCEKIT_PG_URL`
is set (I-10).

**C-11 (introspection field isolation):** SQLite-specific fields
(`pageSize`, `pageCount`, `freelistPageCount`, `walFrameCount`) are nil
on PostgreSQL and InMemory backends. PostgreSQL-specific fields
(`cacheHitRatio`, `transactionCommitCount`, `transactionRollbackCount`,
`deadlockCount`, `lockContention`) are nil on SQLite and InMemory
backends. InMemory-specific fields (`rowCount`, `blobCount`,
`vectorCount`) are nil on SQLite and PostgreSQL backends. No backend
populates a field it does not own.

## § 8 — StorageIntrospection — DB-layer stats surface

**Added:** 2026-06-06, mission `PK_INTROSPECT_001`.

`StorageIntrospection` is an optional-capability protocol, separate from
`Storage`, that each backend conforms to. Consumers discover it with
`as? StorageIntrospection`; existing `Storage`-only callers are
unaffected. Its single method `stats(now:)` returns a closed value struct
`StorageStats` with backend-specific subsets of fields populated; fields
not relevant to the queried backend are nil.

### Invariants

**I-15 (additive only, no impact on Storage):** `StorageIntrospection` is
declared as a separate protocol. `Storage` does not require it and is
not modified. Every existing `Storage` call site compiles unchanged.

**I-16 (deterministic timestamps):** `stats(now:)` accepts a `now: Date`
parameter (Swift) / `now_secs: i64` (Rust). Neither port calls
`Date()` / `SystemTime::now()` internally. Callers inject the timestamp.

**I-17 (optional-or-zero field discipline):** every field in `StorageStats`
that is not meaningful for a given backend is nil. Fields that are
present are always non-negative numeric values; there are no sentinel
values like -1. The single exception is `logicalSizeBytes`, which is
always populated and is always ≥ 0.

**I-18 (WAL frame count via filesystem, not checkpoint):** the SQLite
backend reads WAL frame count from the WAL file's size on the
filesystem (`pageSize + 24` bytes per frame after a 32-byte WAL header)
rather than calling `PRAGMA wal_checkpoint`, which would acquire a lock.
If the WAL file does not exist (WAL mode not yet entered), the value is
0.

**I-19 (rollback counter survives rollback):** the InMemory backend
tracks rollback count outside its snapshotted `State` struct. The
counter increments even when the transaction's snapshot is restored;
restoring the snapshot does not reset the counter.

### `StorageStats` fields

| Field | Swift | Rust | Populated by |
|---|---|---|---|
| Logical DB size (bytes) | `logicalSizeBytes: Int64` | `logical_size_bytes: i64` | All backends |
| Page size (bytes) | `pageSize: Int?` | `page_size: Option<i32>` | SQLite only |
| Page count | `pageCount: Int?` | `page_count: Option<i32>` | SQLite only |
| Freelist page count | `freelistPageCount: Int?` | `freelist_page_count: Option<i32>` | SQLite only |
| WAL frame count | `walFrameCount: Int?` | `wal_frame_count: Option<i32>` | SQLite only |
| Cache-hit ratio | `cacheHitRatio: Double?` | `cache_hit_ratio: Option<f64>` | PostgreSQL only |
| Transaction commit count | `transactionCommitCount: Int64?` | `transaction_commit_count: Option<i64>` | PostgreSQL only |
| Transaction rollback count | `transactionRollbackCount: Int64?` | `transaction_rollback_count: Option<i64>` | PostgreSQL/InMemory |
| Deadlock count | `deadlockCount: Int64?` | `deadlock_count: Option<i64>` | PostgreSQL only |
| Lock contention | `lockContention: Bool?` | `lock_contention: Option<bool>` | SQLite, PostgreSQL |
| Row count | `rowCount: Int?` | `row_count: Option<usize>` | InMemory only |
| Blob count | `blobCount: Int?` | `blob_count: Option<usize>` | InMemory only |
| Vector count | `vectorCount: Int?` | `vector_count: Option<usize>` | InMemory only |
| Captured at | `capturedAt: Date` | `captured_at_secs: i64` | All backends |

### Per-backend sourcing

**SQLite:** `PRAGMA page_size`, `PRAGMA page_count`, `PRAGMA freelist_count`.
WAL frame count: filesystem stat of `<db-path>-wal`; formula
`(fileSize - 32) / (pageSize + 24)` when `fileSize > 32`, else 0.
Lock contention: probe `PRAGMA schema_version`; if the connection gets
`SQLITE_LOCKED`, `lockContention = true`.
`logicalSizeBytes = pageCount * pageSize`.

**PostgreSQL:** `pg_database_size(current_database())` for `logicalSizeBytes`.
`pg_stat_database WHERE datname = current_database()` for `blks_hit/(blks_hit+blks_read)` (cacheHitRatio),
`xact_commit`, `xact_rollback`, `deadlocks`.
`pg_locks WHERE NOT granted` count > 0 for `lockContention`.

**InMemory:** `logicalSizeBytes` = sum of all stored blob payload byte counts.
`rowCount` = total rows across all tables.
`blobCount` = count of stored blob keys.
`vectorCount` = count of stored vector entries.
`transactionRollbackCount` = lifetime count of transactions that returned
`Err` / threw (tracked outside `State` per I-19).

## § 9 — Self-Report Telemetry (cp-persistencekit-report)

Added 2026-06-06. Invariants that govern the telemetry surface wired
to `StorageIntrospection` / `StorageStats`.

**T-1 (off by default):** `Intellectus.isEnabled` / `Intellectus::is_enabled()`
is `false` at process start. No metrics are emitted unless the operator
explicitly enables monitoring. The telemetry path must never fire in test
harnesses or production estates unless opted in.

**T-2 (zero cost when disabled):** when monitoring is disabled, every call
to `reportStorageStats` / `report_storage_stats` costs exactly one
`AtomicBool` load + branch (~1 ns). No lock, no heap allocation,
`stats(now:)` / `stats(now_secs)` is not called.

**T-3 (caller-supplied timestamp):** the `now: Date` / `now_secs: i64`
parameter is always injected by the caller. Neither Swift nor Rust
implementations call `Date()` / `SystemTime::now()` internally.
This is an instance of the global determinism rule: no engine calls a
wall clock.

**T-4 (results unchanged):** `reportStorageStats` does not modify any
field of `StorageStats`, does not alter backend state, and does not change
the value returned by a subsequent `stats(now:)` call with the same
timestamp. The telemetry call is observationally equivalent to a no-op
from the storage layer's perspective.

**T-5 (telemetry errors are silent):** if `stats(now:)` throws (Swift) or
returns `Err` (Rust), the error is logged at warning level (Swift OSLog) or
silently dropped (Rust) and no metrics are emitted. Telemetry must never
propagate an error to the caller or degrade the caller's execution path.

**T-6 (nil / None fields skipped):** only non-nil (Swift) / non-None (Rust)
`StorageStats` fields produce emitted metrics. Backends that do not support
a field (e.g., InMemory does not support WAL fields) do not emit those
metrics. This prevents misleading zero values and keeps the metric stream
backend-specific without a dispatch table.

**T-7 (metric namespace):** all metrics use the `persistence.db.*` prefix.
Tag contract: every metric carries `"kit": "PersistenceKit"` and
`"estate": <estateID>`. Full metric list in INTERFACE § 12.

**T-8 (layering):** IntellectusLib is the telemetry floor. Its Rust crate
(`intellectus-lib`) and Swift package (`IntellectusLib`) carry zero
intra-repo dependencies. `PersistenceKit → IntellectusLib` is
downstream→upstream; the dep direction does not invert the kit topology.
Authority for the Package.swift / Cargo.toml addition:
`DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28`.
