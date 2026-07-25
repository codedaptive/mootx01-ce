---
title: PersistenceKit Specification
version: 1.10.0
status: active
date: 2026-07-20
description: "Behavioral specification for PersistenceKit: invariants, conformance requirements, and the contract it guarantees."
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/PERSISTENCEKIT_INTERFACE.md
  - docs/reference/SUBSTRATELIB_SPEC.md
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#41-persistencekit-contract
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#42-vector-ownership-correction
purpose: |
  PersistenceKit is the storage-abstraction layer of the substrate.
  It defines one `Storage` protocol — surfacing a RowStore, BlobStore,
  AuditLog, and StorageObserver — and ships three conforming backends
  behind it: SQLite, PostgreSQL, and InMemory (tests). PersistenceKit
  owns no vector-search engine: dense-embedding k-NN lives solely in
  VectorKit (the vector-ownership contract). What every backend guarantees instead is the
  vector-storage ACCOMMODATION contract — it accommodates vector
  workloads' storage needs (vector-payload round-trip, bulk hydration at
  scale, count, delete) through the general RowStore / BlobStore surfaces.
  Consumers declare their schema as typed Swift structs and reach storage
  only through the protocol; no consumer names a backend's internal types.
  The companion INTERFACE document carries the signatures.
---

# PersistenceKit Specification

## § 1 — What this package is

PersistenceKit is the substrate's storage seam. Every kit that needs to
persist rows, blobs, or audit events talks to one protocol —
`Storage` — and never to a database driver. `Storage` surfaces five
sub-stores: a `RowStore` (typed row I/O), a `BlobStore` (opaque byte
I/O), an `AuditLog` (append-only HLC-ordered event persistence), a
`StorageObserver` (change notification), and a `DatasetStore` (typed
tabular I/O for user-defined dataset tables, MX-TAB-1). Three backends
conform: SQLite (file-backed, WAL), PostgreSQL (pooled), and InMemory
(the test and conformance reference). `StorageIntrospection` is a
separate optional-capability protocol, not a `Storage` requirement.
The DatasetStore is available on SQLite and InMemory backends;
PostgreSQL is deferred to MX-TAB-2.

PersistenceKit owns no vector-search engine. An earlier wording, "Storage
surfaces a VectorIndex", was a wording defect; the intent was a
storage-CAPABILITY guarantee, not a per-backend k-NN engine (the vector-ownership contract).
Dense-embedding k-NN lives solely in VectorKit. What every backend
guarantees instead is the **vector-storage accommodation contract**:
it MUST support vector workloads' storage needs — vector-payload
round-trip, bulk hydration at scale, count, and delete — through the
general `RowStore` / `BlobStore` surfaces. The accommodation guarantee
is machine-enforced by the cross-backend conformance harness's vector
fixtures (§ 7) and is permanent.

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
runner, connection pool, audit coordination, conformance fixtures, and —
as corrected by the vector-ownership contract — the vector-storage accommodation contract in
place of the originally-misworded vector engine) are settled in
`the PersistenceKit contract` and `the vector-ownership contract`; this spec is the
durable contract those decisions produced.

## § 2 — Scope

This specification defines:

- The `Storage` protocol and its five sub-store contracts.
- The typed value model (`TypedValue`, `ColumnType`, `Column`).
- Schema declaration and forward-only migration semantics.
- The closed predicate algebra (`StoragePredicate`) and ordering
  (`OrderClause`).
- Generated (computed) columns and their structured expression algebra.
- The transaction model: isolation levels, atomicity, no nesting.
- The vector-storage accommodation contract: every backend round-trips,
  bulk-hydrates, counts, and deletes vector-payload rows through the
  general RowStore/BlobStore surfaces (the vector-ownership contract). PersistenceKit owns no
  k-NN engine.
- Append-only audit persistence and HLC-ordered iteration.
- Change-notification (observer) delivery semantics.
- At-rest encryption modes (1–3) as an estate-configuration concern.
- The automated read-through cache layer: per-backend row caching with
  a tunable sensitivity gate, LRU eviction under a RAM byte ceiling,
  and StorageObserver-driven invalidation.
- The cross-backend conformance obligation (all three backends, one
  fixture suite, identical observable results).
- The dataset store contract (MX-TAB-1): table naming convention
  (`ds_<uuid-no-hyphens>`), column identifier validation, BINARY
  collation discipline, PK pre-sort, f64-only float statistics, and
  per-operation behaviors (`createDataset`, `appendRows`, `queryRows`,
  `columnStats`, `dropDataset`). Available on SQLite and InMemory;
  PostgreSQL deferred (MX-TAB-2).

This specification does NOT define:

- Vector (dense-embedding k-NN) search — VectorKit owns it (the vector-ownership contract).
  PersistenceKit backends accommodate vector storage but run no search.
- API signatures — those live in `PERSISTENCEKIT_INTERFACE.md`.
- The audit-event value model, HLC, or fingerprints — those are
  SubstrateLib's (`SUBSTRATELIB_SPEC.md`).
- CRDT structure and audit-event generation (eventID, HLC assignment,
  projection) — GeniusLocusKit owns those.
- Sync / replication — ConvergenceKit owns those.
- Each consumer's schema content — every consumer kit declares its own
  tables. A standalone and a composed operating profile may declare different
  table sets; GLK's attached CorpusKit profile intentionally omits standalone
  document/passage tables.

## § 3 — Position in the kit family

```
SubstrateLib                 (AuditEvent, HLC, Fingerprint256)
   ▲
PersistenceKit               ← the Storage protocol + value model
   ├── PersistenceKitSQLite      (SQLite, WAL)
   ├── PersistenceKitPostgreSQL  (PostgreSQL, pooled)
   └── PersistenceKitInMemory    (tests, conformance reference)
   ▲
   ├── LocusKit          (one estate's rows, blobs, audit)
   ├── VectorKit         (embeddings + in-house k-NN → rows/blobs)
   ├── CorpusKit         (standalone content or attached derived RAG indexes)
   ├── QueueKit          (durable work queue → rows + observer)
   ├── ConvergenceKit    (outbound replication → observer, TableChange)
   └── GeniusLocusKit    (estate composition, opens backends)
```

**Depends on:** SubstrateLib (for `AuditEvent`, `HLC`, `Fingerprint256`,
which the value model and audit log carry). No external Swift package
dependency beyond the PostgreSQL backend's `postgres-nio`. (The SQLite
backend's former `CSQLiteVec` vendored target was removed with the
vector engine per the vector-ownership contract.)

**Consumed by:** LocusKit, VectorKit, CorpusKit, QueueKit,
ConvergenceKit, GeniusLocusKit (which opens the concrete backends), and
the ARIA surfaces transitively.

## § 4 — Invariants

**I-1 (one protocol, swappable backends):** every consumer reaches
storage through `Storage` and its five sub-store protocols. A consumer
that compiles against `Storage` runs unchanged on SQLite, PostgreSQL, or
InMemory. Backends differ in file format and performance, never in
observable result (§ 7, C-1). The `DatasetStore` sub-store defaults to
`featureGated("datasetStore")` on PostgreSQL and third-party conformers
(B-18, I-23).

**I-1a (vector-storage accommodation):** PersistenceKit owns no vector
search. Every backend MUST accommodate vector workloads' storage needs —
vector-payload round-trip (binary 32-byte and float32 384-d payloads),
bulk hydration of vector rows at scale, count, and delete — through the
general RowStore/BlobStore surfaces. Dense-embedding k-NN lives solely
in VectorKit (the vector-ownership contract). The conformance harness's vector fixtures
machine-enforce this guarantee on all three backends (§ 7).

**I-2 (raw SQLite, never Core Data):** the SQLite backend is built on
raw SQLite through the vendored amalgamation. Core Data is never used
(project decision).

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
the value model, predicate algebra, schema declaration, and the four
trait contracts case-for-case. All three backends ship in both ports —
InMemory, SQLite (rusqlite "bundled"), and PostgreSQL (sync `postgres`
crate) — and both ports implement the transaction surface. The
vector-storage accommodation fixtures (I-1a) run in both ports against
all three backends. The one port adaptation: Swift's `transaction<T>` returns a
generic value, while Rust's must stay object-safe (`dyn Storage`), so the
Rust block returns `StorageResult<()>` (Ok commits, Err rolls back) and
surfaces results through its own captured environment. Observable
conformance results match across ports (C-8), not byte-identical DBs.

**I-20 (novel-token tagger choice, fixed at creation):** `EstateConfiguration`
carries a `novelTokenTagger: NovelTokenTaggerChoice` field (`.hmm` default)
that selects which novel-token tagger the estate uses for content classification.
This choice is fixed at estate creation time; change-after-creation and
re-tagging migration are v1.1 features.

`.hmm` selects the deterministic HMM/Viterbi tagger — the cross-platform
baseline, byte-identical Swift↔Rust. `.nlTagger` selects Apple's
`NLTagger` with `.lexicalClass` (Apple platforms only, advanced opt-in).
`NlTagger` is an **invalid** active selection on Rust; `EstateConfiguration::new_with_tagger`
returns `StorageError::InvalidConfiguration` when called with `NlTagger` on Rust.

Federation constraint (v1.1 enforcement): an `nlTagger` estate cannot be
safely federated with an `hmm` estate without full content re-tagging.
This constraint is documented here; enforcement (refusing to sync incompatible
estates) is out of scope for v1.0 and will be added in v1.1.

`NovelTokenTaggerChoice` is defined independently in PersistenceKit (configuration
concern) and LatticeLib (tagger-dispatch concern) as identical two-case enums.
The topology boundary (PersistenceKit upstream of LatticeLib) requires separate
declarations; consumers bridge them with a trivial switch at the GLK/NeuronKit
boundary when calling LatticeLib tagging APIs with the estate's choice.

**I-22 (residency hint, the storage-residency rule):** `EstateConfiguration` carries a
`residencyHint: ResidencyHint` field (`.diskBacked` default) that kits
read to choose their index caching strategy. `.diskBacked`: computed
indexes (BM25, float vector) are loaded from the durable store on
demand and discarded after use; the OS page cache manages RAM residency
via `PRAGMA mmap_size`. `.ramResident`: all indexes are cached in the
process heap between queries for minimum query latency (pre-the storage-residency rule
behavior). The hint is advisory — kits interpret it independently for
their own index structures. PersistenceKit defines the enum and the
field; it does not enforce or interpret the hint itself.

**I-21 (SQL-identifier validation on all write paths, CAND-047):** every
caller-supplied column name that reaches a dynamically-constructed SQL string
MUST be validated against the safe-identifier charset `[A-Za-z_][A-Za-z0-9_]*`
before interpolation. This applies to INSERT column lists, UPDATE SET clauses,
ON CONFLICT column lists, and projected-read column lists. A name outside
this charset is rejected with `StorageError.invalidIdentifier` before any SQL
is built. Double-quoting alone is insufficient protection — a name containing
`"` can escape the delimiter and alter the query. This invariant holds for all
three backends (SQLite, PostgreSQL, InMemory). The validation function is the
single shared seam `validate_sql_identifier` (Rust) / `validateSQLIdentifier`
(Swift); no per-backend fork is permitted (SECFIX-WS2-PK CAND-047,
landed 2026-06-28).

**I-22 (SQLite DB file symlink refusal, CAND-052):** the SQLite backend MUST
refuse to open a database at a path that resolves to a symbolic link (checked
via `lstat`/`symlink_metadata` before `sqlite3_open_v2`/`Connection::open`).
A pre-planted symlink at the DB path can redirect all SQLite writes to an
arbitrary file; the refusal closes this attack surface. New database files
created by the backend MUST be written with owner-only permissions (0600 on
Unix) so that other OS users cannot read the estate. Apple Data Protection
(`.completeUntilFirstUserAuthentication`) is applied to the file post-open as
an orthogonal at-rest encryption layer (SECFIX-WS2-PK CAND-052, landed
2026-06-28).

**I-23 (dataset table naming):** each dataset's backing table is named
`ds_<uuid-no-hyphens>` (all lowercase hex). The `ds_` prefix provides
a letter first character; the 32 hex digits are all alphanumeric. The
result is a valid SQL identifier on every backend without quoting.
Table names are generated internally by `datasetTableName(_:)` /
`dataset_table_name`; they are never user-supplied and never need
identifier validation (MX-TAB-1).

**I-24 (dataset column identifier validation, fail-closed):** every
user-supplied column name (from `moot_file_dataset` and CSV headers)
MUST pass `validateDatasetColumnIdentifier` / `validate_dataset_column_identifier`
against `[A-Za-z_][A-Za-z0-9_]*` before any DDL or DML is constructed.
An invalid name rejects the entire `createDataset` or `appendRows`
operation with `StorageError.invalidIdentifier`; there is no
sanitize-and-continue path. This is the same validation rule as I-21
applied at the dataset surface.

**I-25 (dataset BINARY collation discipline):** TEXT column ordering
(`ORDER BY`) and distinct-count in dataset queries use byte order —
SQLite BINARY collation (the default; dataset DDL never overrides
collation). This locks parity between backends and across Swift/Rust legs
so the conformance harness can verify identical results with non-ASCII
fixture strings. Locale-aware ordering for dataset columns is out of scope
for v1.

**I-26 (dataset PK pre-sort):** when `DatasetSchema.primaryKeyColumn`
is non-nil, `appendRows` pre-sorts the supplied rows ascending by that
column's value before insertion, so SQLite rowid assignment tracks key
order. When the PK column is nil, the backend uses its synthetic key
(SQLite rowid; PostgreSQL `bigint generated always as identity`) and no
pre-sort applies.

**I-27 (dataset f64-only float statistics):** `columnStats` returns
`TypedValue.float(Double)` / `TypedValue::Float(f64)` for the `min`
and `max` fields of REAL columns — never f32. This enforces the
cross-leg wire rule so Swift and Rust produce identical JSON text on the
MCP tool surface regardless of which leg handled the query.

## § 5 — Behavioral contracts

**B-1 (auto-commit outside a transaction):** the sub-stores reached
through `storage.rowStore` etc. auto-commit each single operation. For
multi-operation atomicity, use `transaction(_:)`, which exposes the same
sub-store protocols bound to one connection.

**B-2 (transaction atomicity):** if the `transaction` block throws, the
transaction rolls back and no write within it is visible. If it returns,
all writes commit together. The three sub-stores inside one transaction
(`rowStore`, `blobStore`, `auditLog`) share one connection (Q6).
`observer` and `datasetStore` are not part of `StorageTransaction`.

**B-3 (isolation levels):** `readCommitted` is the default. SQLite maps
`readCommitted` and `repeatableRead` to `BEGIN IMMEDIATE` and is
effectively serializable under WAL; PostgreSQL maps to the standard
levels; InMemory snapshots at transaction start and behaves as
serializable for all three. No nested transactions, no savepoints (Q3).

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

**B-9 (vector-storage accommodation):** PersistenceKit exposes no `knn`
or any vector-search method — dense-embedding k-NN lives solely in
VectorKit (the vector-ownership contract). Instead, every backend MUST accommodate a vector
workload's storage needs through the general `RowStore`/`BlobStore`
surfaces: (1) a vector-payload row (a 32-byte binary payload column and a
384-d float32 payload column, stored as `.blob`) round-trips
byte-for-byte through insert→query; (2) a bulk load of ≥1,000 vector
rows hydrates back fully via `query`; (3) `count` and `delete` operate
over those rows. The cross-backend conformance harness's vector fixtures
(§ 7) assert all three on InMemory, SQLite, and PostgreSQL. This is the
permanent, machine-enforced form of the original (misworded) vector
guarantee.

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

**B-16 (temporal cache key isolation):** present and as-of reads are
keyed separately inside `CachingRowStore`. A `query` for the current
row (`nil` / `AsOfCoordinate.present`) and a `query` for a snapshot
timestamp (`AsOfCoordinate.asOf(hlc)`) produce distinct cache entries.
On a write (insert, upsert, update, delete), only the `present` cache
entry for the affected row is invalidated; historical snapshot entries
are immutable and are never invalidated (GC-pin guarantees snapshot
correctness). `TemporalCacheKey` is an internal implementation detail
and is not part of the public surface.

**B-17 (parent-chain invalidation):** `CachingRowStore` accepts an
optional `ParentChainProvider` callback at construction time. When
provided, any write or external `invalidate()` call also evicts every
cache entry for the Merkle-aggregate parent chain of the affected row,
as returned by the callback. When the callback is absent (the default),
no chain invalidation fires and behaviour is identical to prior versions
(backward-compatible). The callback is invoked with the table name and
`RowKey`; it must return synchronously and must not call back into the
same `CachingRowStore` (to prevent lock re-entry).

**B-12 (encryption is transparent to consumers):** an estate's
`EstateEncryptionConfig` selects mode 1 (plaintext), 2 (per-row content
ciphertext), or 3 (full-database, whole-file encryption). Consumers issue
the same reads and writes regardless of mode.

Mode 2 (RowEncryption) encrypts the `content` column value under an
AES-GCM-256 key and is the federation grant-granularity mechanism
(per-row keys). Mode 3 (FullDatabase) encrypts the ENTIRE database file —
schema included — at the storage layer, using each platform's native
whole-file mechanism — **SQLCipher on every platform** (`PRAGMA key` with the
raw 256-bit cipher key): the OpenSSL FIPS provider on the Rust port
(Windows/Linux), and the **CommonCrypto backend** (Apple CoreCrypto) on the
Apple port (iOS + macOS). Because the whole file is ciphertext, Mode 3 does NOT
also apply the per-row content seam (the seam is a no-op for FullDatabase). An
external process opening a Mode 3 file with a plain SQLite library cannot read
or alter the schema.

> **Implemented (the whole-file encryption contract).** Apple uses SQLCipher on CommonCrypto (Apple
> CoreCrypto, FIPS-validated), vendored from the Community Edition source, with
> the key from `KeychainKeyStore` (Secure-Enclave-wrapped). One whole-file
> mechanism across all platforms. Apple Data Protection (iOS), the macOS
> app-group container, and FileVault are additive defense-in-depth layers.

Activation: the whole-file key is **per-estate on both ports** — distinct estates
get distinct keys, so a key compromise is scoped to one estate. On the **Rust**
port a resident service writes a `db.key` file inside the estate's own directory
(owner-only `0600`) at startup; `SqliteStorage::new` resolves that sibling key and
opens the estate as FullDatabase. On the **Apple** port the key is a per-estate
Keychain item keyed by the estate file path (`KeychainKeyStore(service:estateURL:)`);
the app and the managed server point at the same file, derive the same account,
and load the same key, then construct the estate with
`EstateEncryptionConfig.fullDatabase(key:)`. Both ports **dispose the key when the
estate is removed** (the Rust `db.key` goes with the estate directory; the Apple
side calls `KeychainKeyStore.deleteKey()`), so a key never outlives the data it
protected. Estates with no key (tests, pre-lockdown installs) remain plaintext, so
existing call sites are unchanged.

The key-storage **mechanism** differs by port — a `0600` `db.key` file on Rust
(Windows/Linux), a Keychain item on Apple — as does FIPS provider (OpenSSL on
Rust, CommonCrypto on Apple) and RAM-swap protection (the Rust resident daemon
calls `mlockall`; the Apple port relies on macOS's encrypted virtual memory, so
no `mlock` is needed). These are approved port divergences; the result — a
per-estate-keyed, whole-file-encrypted estate — is identical. See the whole-file encryption contract.

**B-12b (per-backend at-rest coverage):** the at-rest mechanism is NOT uniform
across backends — whole-file encryption is intrinsically a SQLite (embedded-file)
concept. The Mode 2 content seam is wired in the SQLite and PostgreSQL backends
(both ports); InMemory stores plaintext.

- **SQLite** — Mode 3 (whole-file SQLCipher) protects schema and content; Mode 2
  (per-row AEAD) is also available. The structure-protection guarantee.
- **PostgreSQL** — content is encrypted by the client via **Mode 2** (per-row
  AEAD) before the value reaches Postgres, so the bytes are ciphertext at rest in
  the database regardless of the server. Wired on both ports: the per-row AEAD
  seam lives in PersistenceKit core and `PostgreSQLRowStore` applies it on
  insert (and asserts the content/keyID invariant on upsert/update). Deployment
  TDE / TLS / RBAC are defense-in-depth, not the primary answer; the
  schema/structure is the server's, the data is ours to encrypt.
- **InMemory** — the in-memory store holds content **encrypted** (the same Mode 2
  AEAD seam) so a memory dump, debugger, or swap yields ciphertext, plus RAM
  hardening (no-swap / `mlock`, zero-on-free). (Currently plaintext — to build.)

Mode 2 (per-row AEAD) is the cross-backend content-encryption mechanism that
works on SQLite AND PostgreSQL. Mode 3 (whole-file SQLCipher) is SQLite-only
(both Swift and Rust ports). See the whole-file encryption contract (Backend coverage).

**B-12a (cross-port at-rest format parity — Mode 2 only):** for Mode 2
(RowEncryption), the Rust SQLite backend encrypts the `content` column at
rest using AES-GCM-256, mirroring the Swift
`SQLiteBackend.encryptedForWrite`/`decryptedForRead` seam exactly. The
stored envelope layout is `[12-byte nonce][16-byte GCM tag][ciphertext]`
on both ports. A Mode 2 column value encrypted by the Swift port can be
decrypted by the Rust port, and vice versa. The nonce is
cryptographically random per encryption (via `OsRng` in Rust, via
`AES.GCM.Nonce()` in Swift); nonce reuse is never permitted. The
`assertContentKeyIDInvariant` / `assert_content_key_id_invariant` guard
on both ports ensures upsert and update paths on Mode 2 estates cannot
store plaintext content without a keyID.

Mode 3 (FullDatabase) is deliberately NOT cross-port byte-compatible: both
ports use SQLCipher whole-file encryption but on different crypto backends
(OpenSSL FIPS on Rust, CommonCrypto on Apple) and never share a physical
file. Parity for Mode 3 is behavioral — the rows retrieved are identical
across ports — not on-disk byte identity. See B-12.

**B-18 (dataset store operations):** `DatasetStore` is the sixth sub-store on
`Storage`, accessed through `storage.datasetStore` / `storage.dataset_store()`.
It reuses `StoragePredicate`, `OrderClause`, and `TypedValue` — no new
query language. All identifier validation, collation, PK pre-sort, and
float-statistics rules are governed by I-23 through I-27.

- `createDataset(id:schema:indexes:)` / `create_dataset`: creates the backing
  table with `CREATE TABLE IF NOT EXISTS` semantics. Idempotent: a second call
  with the same `id` is a no-op. Column names in `schema.columns` and index
  column names are validated (I-24) before any DDL; an invalid name throws
  `StorageError.invalidIdentifier` and aborts the operation.
- `appendRows(id:rows:)` / `append_rows`: bulk-inserts rows via
  `beginTransaction / commitTransaction` (GLK_BATCH1) so all rows land in one
  atomic write. Pre-sorts by `primaryKeyColumn` when declared (I-26). Column
  names in each row dict are validated (I-24).
- `queryRows(id:predicate:orderBy:limit:offset:columns:)` / `query_rows`:
  column-projecting predicate query. `columns nil` returns all columns.
  TEXT ordering uses BINARY collation (I-25).
- `columnStats(id:column:)` / `column_stats`: per-column aggregate statistics
  computed in SQL: `COUNT`, `COUNT(DISTINCT …)`, `MIN`, `MAX`, NULL count.
  Float `min`/`max` values for REAL columns use `TypedValue.float(Double)` /
  `TypedValue::Float(f64)` — never f32 (I-27).
- `dropDataset(id:)` / `drop_dataset`: drops the backing table with
  `DROP TABLE IF EXISTS` semantics. A no-op if the table does not exist.
  The caller is responsible for the estate handle tombstone (LocusKit, MX-TAB-4).

The default `Storage.datasetStore` / `Storage::dataset_store()` throws
`StorageError.featureGated("datasetStore")`. `SQLiteStorage` and
`InMemoryStorage` override this with a concrete implementation.
`PostgreSQLStorage` and third-party conformers inherit the default (MX-TAB-2).

**B-19 (change origin tag):** Every `TableChange` emitted by a backend carries
an `origin: ChangeOrigin` field (`ChangeOrigin` / `change_origin::ChangeOrigin`
in Rust) that identifies whether the triggering write was a local user-initiated
write (`.local` / `Local`) or a write performed during inbound sync application
(`.syncApply` / `SyncApply`).

- All ordinary write paths (`insert`, `upsert`, `update`, `delete` on every
  backend) emit `origin: .local` / `ChangeOrigin::Local`.
- Three sync-tagged write methods — `insertSync`, `upsertSync`, `deleteSync`
  (Swift) / `insert_sync`, `upsert_sync`, `delete_sync` (Rust) — emit
  `origin: .syncApply` / `ChangeOrigin::SyncApply`. All three are protocol
  requirements with default implementations that delegate to the ordinary write
  paths (safe for non-sync conformers; the origin override is in the backend
  implementations that ConvergenceKit's `applyInbound` calls).
- `CachingRowStore` delegates `insertSync` / `upsertSync` / `deleteSync` to its
  backing store and applies identical cache-invalidation logic, preserving the
  origin tag through the caching layer.
- The `origin` field enables ConvergenceKit's outbound observer to discard
  `applyInbound` writes and prevent the multi-device echo loop (I-10,
  CVK-ICLOUD P1-M1). Observers uninterested in origin may ignore the field.

**B-20 (changedColumns stamping — CVK-WB4):** Every `TableChange` emitted by
the InMemory and SQLite backends carries a `changedColumns: Set<String>?`
(`changed_columns: Option<HashSet<String>>` in Rust) field that identifies
which columns actually changed in the write. The contract per operation:

- **insert:** `changedColumns` = `Some(Set(values.keys))` — all written columns.
  No pre-existing row exists; every column in the insert dict is "changed" from
  the nothing that was there before.
- **update:** `changedColumns` = `Some(columns where newValue != oldValue)` —
  only the columns whose value actually changed relative to the stored row before
  the UPDATE. A value present in the SET clause but equal to the stored value is
  NOT included. The backend performs a pre-read (O(1) in InMemory — old row
  already in memory; O(1) in SQLite — `SELECT` by primary key before `UPDATE`)
  to compute the diff.
- **upsert (insert path):** `changedColumns` = `Some(Set(values.keys))` — same
  as insert; no pre-existing row. The pre-read (`SELECT` by conflict columns)
  confirms the row is absent.
- **upsert (update path):** `changedColumns` = `Some(columns where newValue !=
  oldValue)` — diff against the pre-existing row, same as update.
- **delete:** `changedColumns` = `nil` / `None` — delete tombstones carry no
  column-level granularity; the row is gone.

The PostgreSQL backend always emits `changed_columns: None` (conservative /
backward-compatible); pre-read diff is not implemented there.

Consumers that do not use `changedColumns` may ignore the field: the field is
additive and does not change existing `TableChange` semantics. ConvergenceKit
uses `changedColumns` for two behaviors (CVK-WB4): (1) mixed-column storm-kill
precision — when `changedColumns` is present and every changed column is in the
excluded-columns set, the outbound change is dropped even if non-changed sync
columns survive the projection strip; (2) fieldLevelLWW stamp precision — only
the columns in `changedColumns` receive a new column-level HLC stamp in the
outbound `SyncRecord`, preventing false HLC advancement on unchanged columns.

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
| `corruptStoredValue` | stored text cannot be parsed to declared column type | log and skip (corpus scans) or abort (point lookups) |
| `invalidConfiguration` | configuration invalid for current platform/runtime | abort; fix configuration |
| `featureGated` | feature surface exists but is gated off pending prerequisites | caller checks feature availability; wait for gate lift |

Concrete enum shapes (Swift cases, Rust variants) live in INTERFACE § 4.

## § 7 — Conformance requirements

**C-1 (backend equivalence):** all three backends pass one shared
fixture suite (200+ seeded operations across schema, migration, row I/O,
all `StoragePredicate` cases, blob I/O, the vector-storage accommodation
fixtures (vector-payload round-trip, ≥1k bulk hydration, count, delete —
I-1a/B-9), audit ordering, transactions, concurrency, and error
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
columns, append-only enforcement, transaction commit/rollback, and the
vector-storage accommodation fixtures (vector-payload round-trip, bulk
hydration, count, delete). The Rust port proves this with a
backend-agnostic conformance suite driven by a `Factory` over each
backend; PostgreSQL runs against a live database when `PERSISTENCEKIT_PG_URL`
is set (I-9).

**C-11 (introspection field isolation):** SQLite-specific fields
(`pageSize`, `pageCount`, `freelistPageCount`, `walFrameCount`) are nil
on PostgreSQL and InMemory backends. PostgreSQL-specific fields
(`cacheHitRatio`, `transactionCommitCount`, `transactionRollbackCount`,
`deadlockCount`, `lockContention`) are nil on SQLite and InMemory
backends. InMemory-specific fields (`rowCount`, `blobCount`) are nil on
SQLite and PostgreSQL backends. No backend populates a field it does not
own.

## § 8 — StorageIntrospection — DB-layer stats surface

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
`transactionRollbackCount` = lifetime count of transactions that returned
`Err` / threw (tracked outside `State` per I-19).

## § 9 — Self-Report Telemetry

Invariants that govern the telemetry surface wired
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
`the package-dependency rule`.

## Changelog

### 1.10.0 -- 2026-07-20
Cross-port parity fix (GLK shared-content 1.1 P4): the Rust SQLite
backend now EXECUTES declared `SchemaDeclaration.migrations` operations
(createTable/dropTable/addColumn/dropColumn/renameColumn/addIndex/
dropIndex/custom) with the same forward-only, per-step version-recording
semantics as the Swift backend — previously it silently ignored them, so
declared retirements (e.g. the shared-content dropTable migration) never
ran on Rust SQLite estates. Version recording is now upgrade-only
(matching Swift); dropped tables leave the accumulated schema view.

### 1.9.0 -- 2026-07-20

Clarified that consumer kits may declare standalone and composed schema
profiles; GLK's attached CorpusKit profile omits standalone content/passage
tables. PersistenceKit behavior is unchanged.

### 1.8.0 -- 2026-07-16
CVK-ICLOUD P1-M1: Added behavioral contract B-19 (change origin tag). Every
`TableChange` now carries `origin: ChangeOrigin` (.local / .syncApply). Three
sync-tagged write methods (`insertSync` / `upsertSync` / `deleteSync`, with Rust
equivalents) emit `.syncApply`, enabling ConvergenceKit's outbound observer to
discard `applyInbound` writes and prevent the multi-device echo loop (I-10).

### 1.7.0 -- 2026-07-16
MX-TAB-1: Updated § 1 to name five sub-stores (was four, omitting DatasetStore;
StorageIntrospection is correctly a separate optional-capability protocol, not
a Storage sub-store). Added DatasetStore to § 2 scope bullet. Added
invariants I-23 (dataset table naming), I-24 (column identifier validation,
fail-closed), I-25 (BINARY collation discipline), I-26 (PK pre-sort), I-27
(f64-only float statistics). Added behavioral contract B-18 (DatasetStore
operations: createDataset idempotence, appendRows GLK_BATCH1 + pre-sort,
queryRows BINARY collation, columnStats f64 rule, dropDataset IF EXISTS, and
the featureGated default for PostgreSQL and third-party conformers).

### 1.6.0 -- 2026-06-28
SECFIX-WS2-PK: Added I-21 (SQL-identifier validation on all write paths,
CAND-047) and I-22 (SQLite DB file symlink refusal + 0600 creation mode,
CAND-052). I-21 extends the existing projected-read identifier gate to INSERT,
upsert ON CONFLICT, and UPDATE SET column lists across all backends — one
shared validator, no forked copies. I-22 hardens the SQLite open path to
refuse a pre-planted symlink at the DB path and sets owner-only permissions
(0600) on newly-created estate files.

### 1.5.0 -- 2026-06-20
NT-P4: Added B-16 (temporal cache key isolation) and B-17 (parent-chain
invalidation). B-16 specifies that present and as-of reads key separately inside
`CachingRowStore` and that snapshot entries are never evicted on writes. B-17
specifies the optional `ParentChainProvider` callback contract: invoked on
write-path and external `invalidate()` calls, must be synchronous, must not
re-enter the cache. Both behaviours are backward-compatible: the callback defaults
to absent, and `TemporalCacheKey` is internal.

### 1.4.0 -- 2026-06-20
NT-P1: Added `corruptStoredValue`, `invalidConfiguration`, and `featureGated`
to the § 6 error table. The `featureGated` case gates the as-of temporal query
surface (the node-integrity contract §17) until NT-L4 (lineage-wide expunge) and NT-P3 (erasure
overlay) merge. `ColumnRole` metadata enables temporal validity column
identification at schema declaration time; the as-of filter uses it to push
`created_hlc <= T AND (tombstoned_hlc IS NULL OR tombstoned_hlc > T)` into the
engine without knowing kit-specific column names.

### 1.3.3 -- 2026-06-18
B-12 Activation: the Mode 3 whole-file key is per-estate on **both** ports (was
described as per-install). Rust keeps a `db.key` inside each estate's directory;
Apple keys a Keychain item by the estate file path
(`KeychainKeyStore(service:estateURL:)`). Both ports dispose the key on
estate-remove (Apple via `KeychainKeyStore.deleteKey()`), so a key never outlives
its data. Recorded the approved port divergences: FIPS provider (OpenSSL vs
CommonCrypto), key storage (file vs Keychain), and RAM-swap protection (Rust
`mlockall` vs Apple's encrypted virtual memory — no `mlock` needed on Apple).

### 1.3.2 -- 2026-06-18
B-12b: PostgreSQL Mode 2 content encryption is wired on both ports. The per-row
AEAD seam (`encryptedForWrite` / `decryptedForRead` /
`assertContentKeyIDInvariant`, with `RowCrypto` and the AEAD provider) now lives
in PersistenceKit core, shared byte-compatibly by the SQLite and PostgreSQL
backends; `PostgreSQLRowStore` applies it. Corrected the B-12a Mode 3 cross-port
note: both ports use SQLCipher (OpenSSL FIPS on Rust, CommonCrypto on Apple), not
"SQLCipher vs Apple Data Protection". InMemory at-rest remains plaintext.

### 1.3.1 -- 2026-06-18
B-12: Apple SQLCipher is implemented (was queued). Mode 3 is now SQLCipher on
every platform — OpenSSL FIPS on Rust, CommonCrypto (CoreCrypto) on Apple,
vendored from the Community amalgamation; the Apple per-install key lives in the
Keychain (`KeychainKeyStore`) and is supplied via
`EstateEncryptionConfig.fullDatabase(key:)`.

### 1.3.0 -- 2026-06-18
B-12b records two decisions for the non-SQLite backends: PostgreSQL content is
encrypted client-side (Mode 2 AEAD); InMemory data is held encrypted in RAM with
hardening (no-swap/mlock, zero-on-free). Both unwired today — to build.

### 1.2.0 -- 2026-06-18
Added B-12b (per-backend at-rest coverage): the at-rest mechanism is not uniform
across backends. SQLite uses Mode 3 whole-file SQLCipher (schema + content);
PostgreSQL has no whole-file analogue and relies on Mode 2 client-side AEAD
(currently unwired) plus deployment TDE/TLS/RBAC; InMemory at-rest is N/A. Mode 2
is the cross-backend content mechanism; Mode 3 is SQLite-only.

### 1.1.1 -- 2026-06-17
Added a forward-pointer in B-12 to the whole-file encryption contract: the Apple port moves to SQLCipher on
the CommonCrypto backend (FIPS-validated, Secure-Enclave-wrapped Keychain key),
with Data Protection / app-group container / FileVault as additive layers
(implementation queued).

### 1.1.0 -- 2026-06-17
Planned encryption lockdown. Redefined Mode 3 (FullDatabase) from per-row
crypto to whole-file encryption using each platform's native mechanism
(SQLCipher `PRAGMA key` on Rust; Apple Data Protection on iOS); the per-row
content seam is now a no-op for Mode 3 (B-12). Scoped B-12a cross-port at-rest
byte-parity to Mode 2 only; Mode 3 parity is behavioral, not byte-identical
(the ports never share a file). Documented the shared per-install `db.key`
sibling-file activation written by the resident services at startup.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
