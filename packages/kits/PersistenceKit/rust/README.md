# storage-kit (Rust)

Rust port of the Swift `PersistenceKit` package. Mirrors the closed-enum predicate algebra, typed value carriers, schema declaration, and the five abstraction protocols: `Storage`, `RowStore`, `BlobStore`, `VectorIndex`, `AuditLog`, `StorageObserver`.

**Status:** All three backends shipped: `InMemoryStorage`, `SqliteStorage`, and `PostgresStorage`. The SQLite backend runs the full conformance suite (10 integration tests covering schema, rows, predicates, blobs, vectors, audit, generated columns, transactions, append-only, and introspection). The PostgreSQL backend compiles and runs the same conformance suite when `PERSISTENCEKIT_PG_URL` points to a scratch database; it is skipped by default without a live server.

## Trait surface

Synchronous (`Result<T, StorageError>`). The Swift side uses `async` because Swift actors require it; the Rust in-process backends do no real async I/O so synchronous traits are cleaner and avoid pulling in an async-runtime dependency. When a future tokio-postgres backend lands, it can wrap its own runtime; the trait remains synchronous because callers can `tokio::task::spawn_blocking` the whole call.

## What ships at v1.0

- `TypedValue` mirroring Swift's case-for-case (13 variants)
- `Column`, `ColumnType`, `StoragePredicate`, `OrderClause`, `OrderDirection`
- `SchemaDeclaration`, `TableDeclaration`, `ColumnDeclaration`, `IndexDeclaration`, `Migration`, `SchemaOperation`
- `EstateConfiguration`, `BackendConfiguration` (InMemory, Sqlite, Postgresql variants reserved)
- `Storage`, `RowStore`, `BlobStore`, `VectorIndex`, `AuditLog`, `StorageObserver` traits
- `StorageError` (11 variants)
- `InMemoryStorage` backend — full conforming backend for tests and ephemeral estates
- `SqliteStorage` backend — file-backed, full predicate compiler, BlobStore, VectorIndex (sqlite-vec), AuditLog, StorageObserver, StorageTransaction, StorageIntrospection
- `PostgresStorage` backend — full predicate compiler, BlobStore, VectorIndex (pgvector-compatible), AuditLog, StorageObserver, StorageTransaction, StorageIntrospection; lazy-connect (no network I/O on `new()`)
- `NoOpObserver` for backends without change notification
- `CachingRowStore` — LRU row cache wrapper over any `RowStore`
- 17 InMemory integration tests covering insert / query / order / paginate / upsert / update / delete / bitmask predicates / blobs / vector kNN / audit log idempotence / audit ordering / observer fire / observer filter / schema version / LIKE patterns / predicate short-circuit
- SQLite conformance suite (10 tests): full `run_all` fixture battery + 9 `StorageIntrospection` tests
- PostgreSQL conformance suite: same fixture battery, gated on `PERSISTENCEKIT_PG_URL` environment variable

## What does NOT ship at v1.0

- `AuditEvent` lattice anchor decode to a meaningful lattice coordinate (the raw `u64` codes are stored and read back correctly; semantic interpretation requires LatticeLib, which was not ported at the time these backends landed)

## Building

```
cd PersistenceKit/rust
cargo build
cargo test
```

Requires Rust 1.75+ and a sibling `substrate-kit` crate at `../../SubstrateLib/rust`.

## See also

- Swift counterpart: `PersistenceKit/Sources/PersistenceKit/`
- Design record: `docs/decisions/DECISION_STORAGEKIT_DESIGN_2026-05-19.md`
- Kit graph ADR: `docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md`
