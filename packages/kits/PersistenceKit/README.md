# PersistenceKit

PersistenceKit is the storage abstraction layer for the GeniusLocus substrate. Second foundation kit in the eleven-kit family per `docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md`. Design settled in `docs/decisions/DECISION_STORAGEKIT_DESIGN_2026-05-19.md`.

PersistenceKit answers: where do the durable bits live on this device? ConvergenceKit answers the orthogonal question of how bits converge across boundaries.

## Status (2026-05-19)

| Target | Status |
|---|---|
| PersistenceKit (core protocols + types) | Complete |
| PersistenceKitInMemory | Complete; production-ready for tests, full observer support |
| PersistenceKitSQLite | Complete; sqlite-vec vendored, observer for insert/upsert per-row, coarse for update/delete |
| PersistenceKitPostgreSQL | Complete; PostgresNIO + pgvector; observer is NoOpObserver in v1.0 |
| CSQLiteVec (vendored sqlite-vec C amalgamation) | Complete |
| ConformanceRunner + ~200 fixtures | Pending |
| Port SQLiteDurabilityTail + WorkingSetMmap | Pending |

Tests: 31 pass on Apple Silicon macOS 14+ (8 InMemory base + 3 observer + 1 conformance, 9 SQLite + 1 conformance, 5 core, 2 PostgreSQL gated on `POSTGRES_TEST_URL` + 1 conformance gated, 1 conformance smoke).

## Architecture

Five Swift package targets:

- **PersistenceKit** — protocols and types. Consumed by every kit that touches a database.
- **PersistenceKitInMemory** — in-memory backend, actor-based for Swift 6 strict concurrency. Linear-scan k-NN. No persistence.
- **PersistenceKitSQLite** — SQLite backend with vendored sqlite-vec. Default for Apple ecosystem deployment.
- **PersistenceKitPostgreSQL** — PostgreSQL backend with pgvector. Server-side and not-Apple deployment. Requires `vapor/postgres-nio`.
- **CSQLiteVec** — vendored sqlite-vec C amalgamation (asg017/sqlite-vec, MIT). SwiftPM C target.

Dependencies: SubstrateLib (sibling package at `../SubstrateLib`), PostgresNIO 1.21.0+.

## What PersistenceKit holds

**Protocols.** RowStore, BlobStore, VectorIndex, AuditLog, StorageObserver, Storage, StorageTransaction.

**Types.** TypedValue (closed enum of column values), Column, ColumnType, StoragePredicate (closed enum), Schema declaration types (SchemaDeclaration, TableDeclaration, ColumnDeclaration, IndexDeclaration, Migration, SchemaOperation), EstateConfiguration, IsolationLevel, StorageError, DistanceMetric, IndexParameters, SearchParameters, VectorSearchResult, StorageRow, RowHandle, RowKey, BlobKey, OrderClause.

The closed-enum predicate algebra is PersistenceKit's load-bearing design. BitmapEvaluator (in LocusKit, mission 5) compiles the Filter algebra from spec §7.9 into StoragePredicate trees; each backend compiles those trees into backend-native query language. The three bitmap operators (bitmaskAll, bitmaskAny, bitmaskNone) plus bitwiseEq cover spec §7.9 without leaking SQL into the kit layer.

## What PersistenceKit does not hold

PersistenceKit does not own the CRDT structure of the audit log. GeniusLocusKit owns CRDT enforcement (G-Set CRDT under HLC ordering per paper §6). PersistenceKit provides append-only persistence and HLC-ordered iteration; the CRDT property is mechanical from there. The compound key (eventID, hlc) makes `append` idempotent at the storage layer.

PersistenceKit does not handle sync. ConvergenceKit (mission 3) is separate.

## Encryption at rest

PersistenceKit supports at-rest encryption of estate content, selected per
estate via `EstateConfiguration.encryptionConfig`. Encryption is
**per-record**, not whole-file: a key registry table maps a key identifier
to a wrapped key, and an encrypted row's content column is stored as
ciphertext under that identifier (`drawers.keyID`). A machine reads only
the records whose key it holds; a record under an absent key is unreadable,
not missing. This is a deliberate choice against whole-file encryption
(e.g. SQLCipher), so sharing scales with what is shared, not with database
size.

| Mode | At rest | What encrypts |
|---|---|---|
| 1. Plaintext, fence encryption | Plaintext locally; encrypted only at the share fence | Nothing on disk is encrypted; the fence layer encrypts on send |
| 2. Row encryption | Ciphertext per row under a per-row or per-estate key | Content column stored as ciphertext; key identifier stored per row |
| 3. Full database encryption | Whole estate under a per-install key (hardware-wrapped) | Every content column encrypted under one estate key; key wrapped by Secure Enclave / TPM |

Mode 1 is the default and a pure no-op — existing plaintext estates are
unchanged. Modes 2 and 3 encrypt the content column under AES-GCM-256
(`RowCrypto` in PersistenceKitSQLite); the SQLite backend applies crypto at the
`insertRow`/`queryRows` seam. Mode 4 (database plus threshold, M-of-N key
split) is FedRAMP-tier and not built.

The authoritative mechanism specification is
`docs/decisions/DECISION_FEDERATION_SHARING_MODEL_2026-05-21.md` Appendix A
(A.1 mechanism, A.2 the four modes, A.3 mode-3 query-forwarding federation).
The data key is generated for the user — full entropy, never a passphrase —
and wrapped by device hardware where available, on the model of a disk
encryptor or crypto wallet.

## Eight settled design decisions

Per DECISION_STORAGEKIT_DESIGN_2026-05-19.md:

1. **Schema DSL**: typed Swift structs, no result builder. Diff-friendly, FFI-clean.
2. **Predicate tree**: closed enum, three operator families. No extension points.
3. **Transactions**: read-committed default, explicit transaction block, no nesting, no savepoints in v1.0.
4. **Migrations**: forward-only, transaction-per-migration, fail-fast.
5. **VectorIndex parameters**: typed enum with three index types (flat, ivf, hnsw).
6. **Connection pool**: kit-owned, per-estate, fixed size.
7. **Audit log coordination**: append-only and HLC-ordered iteration in PersistenceKit; CRDT in GeniusLocusKit.
8. **Conformance suite**: deterministic-seed round-trip; all backends produce identical observable results.

## Building and testing

```
cd PersistenceKit
swift build
swift test
```

Requires Swift 6.0+ and SubstrateLib at `../SubstrateLib`. PostgreSQL tests skip cleanly when `POSTGRES_TEST_URL` is unset.

To run PostgreSQL tests, start a postgres instance with pgvector and export the connection string:

```
docker run -d --name pg-storagekit-test -e POSTGRES_PASSWORD=test -p 5432:5432 pgvector/pgvector:pg16
export POSTGRES_TEST_URL='postgres://postgres:test@localhost:5432/postgres'
swift test
```

## For coding agents

When implementing a downstream kit that consumes PersistenceKit, read `docs/INTERFACE_DOCTRINE.md` in this directory first. It is the contract every consumer must follow.

## Public API stability

Once shipped, public API follows semantic versioning. Adding a case to TypedValue, ColumnType, StoragePredicate, IndexParameters, or SearchParameters is a breaking change requiring a major version bump and a decision record in `docs/decisions/`. Backend additions are additive.

## Next missions

PersistenceKit is the substrate's storage foundation. Downstream kits consume PersistenceKit through the protocols documented here and in INTERFACE_DOCTRINE.md.
