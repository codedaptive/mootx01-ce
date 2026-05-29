# storage-kit (Rust)

Rust port of the Swift `PersistenceKit` package. Mirrors the closed-enum predicate algebra, typed value carriers, schema declaration, and the five abstraction protocols: `Storage`, `RowStore`, `BlobStore`, `VectorIndex`, `AuditLog`, `StorageObserver`.

**Status:** v1.0 InMemory backend shipped (Rust mission 2). SQLite and PostgreSQL backends deferred to a follow-on R-mission. The trait surface is stable; backends slot in additively.

## Trait surface

Synchronous (`Result<T, StorageError>`). The Swift side uses `async` because Swift actors require it; the Rust in-process backends do no real async I/O so synchronous traits are cleaner and avoid pulling in an async-runtime dependency. When a future tokio-postgres backend lands, it can wrap its own runtime; the trait remains synchronous because callers can `tokio::task::spawn_blocking` the whole call.

## What ships at v1.0

- `TypedValue` mirroring Swift's case-for-case (13 variants)
- `Column`, `ColumnType`, `StoragePredicate`, `OrderClause`, `OrderDirection`
- `SchemaDeclaration`, `TableDeclaration`, `ColumnDeclaration`, `IndexDeclaration`, `Migration`, `SchemaOperation`
- `EstateConfiguration`, `BackendConfiguration` (InMemory, Sqlite, Postgresql variants reserved)
- `Storage`, `RowStore`, `BlobStore`, `VectorIndex`, `AuditLog`, `StorageObserver` traits
- `StorageError` (11 variants)
- `InMemoryStorage` backend (this crate's only conforming backend at v1.0)
- `NoOpObserver` for backends without change notification
- 17 integration tests covering insert / query / order / paginate / upsert / update / delete / bitmask predicates / blobs / vector kNN / audit log idempotence / audit ordering / observer fire / observer filter / schema version / LIKE patterns / predicate short-circuit

## What does NOT ship at v1.0

- SQLite backend with predicate compiler (follow-on R-mission)
- PostgreSQL backend with pgvector (follow-on R-mission)
- `StorageTransaction` trait (Swift has it via async closure; Rust v1.0 omits it because the closure-with-trait-objects pattern adds noise. The SQLite backend lands with explicit begin/commit/rollback.)
- `AuditEvent` lattice anchor decode (stored as raw `u64` codes; the lattice algebra lives in LocusKit which has not been ported yet)

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
