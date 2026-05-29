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
`currentSchemaVersion()` after a failed `migrate`.

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

**I-10 (cross-port parity):** the Rust port (`persistence-kit`) mirrors
the value model, predicate algebra, schema declaration, and the five
trait contracts case-for-case. The InMemory backend ships in both ports
at v0.8; SQLite/PostgreSQL backends are Swift-side at v0.8, with the
Rust SQLite backend as a declared follow-on (the trait surface is
already defined).

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
| `migrationFailed` | a migration step threw | inspect `currentSchemaVersion()`, fix migration, retry forward |
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

**C-8 (cross-port parity):** the Swift and Rust InMemory backends agree
on value round-trip, predicate evaluation, schema declaration, and audit
ordering for every shared fixture (I-10).

## § 8 — Out of scope

- `AuditEvent`, `HLC`, `Fingerprint256` value definitions →
  `SUBSTRATELIB_SPEC_v0.8.md`.
- Audit-event generation, HLC assignment, CRDT projection →
  GeniusLocusKit (`GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md`).
- Sync / replication, outbound change forwarding → ConvergenceKit
  (`CONVERGENCEKIT_SPEC_v0.8.md`).
- Embedding generation and ANN ranking math → `VECTORKIT_SPEC_v0.8.md`
  (PersistenceKit stores and searches vectors; it does not embed).
- Schema content (which tables/columns each kit needs) → each consumer
  kit's own spec.
- The share-fence encryption and federation model → the federation
  decision record; PersistenceKit owns only at-rest modes 1–3 (B-12).

## § 9 — Open questions

- PostgreSQL libpq client choice (PostgresNIO vs raw libpq) and the CI
  test-harness shape are tracked in
  `DECISION_STORAGEKIT_DESIGN_2026-05-19.md` § 12, not yet recorded as
  separate ADRs.
- Down-migrations (explicit reverse) remain deferred; v0.8 is
  forward-only (I-7). A v1.x decision adds them if usage demands.
- Encryption mode 4 (database + threshold) is deliberately absent from
  the build; adding it is a reviewed act, not a silent enum extension.
- The Rust SQLite/PostgreSQL backends are declared in the trait surface
  but ship after v0.8; the InMemory backend is the cross-port reference
  until then (I-10).

---

*End of PersistenceKit Specification v0.8.*
