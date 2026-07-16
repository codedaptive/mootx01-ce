# Blast Radius Report — CVK-ICLOUD P1-M1
# Echo suppression via PersistenceKit origin tag

**Mission:** CVK-ICLOUD P1-M1
**Date:** 2026-07-16
**Author:** Bilby
**Tier:** Primitive-touching (touches `TableChange` core primitive and `RowStore` protocol)

---

## Problem statement

`applyInbound` writes through `rowStore` (invariant I-3) → `StorageObserver`
fires → `recordOutbound` records the change into `pendingOutbound` → pushed
back to the remote machine. Two live machines ping-pong forever, never
converging.

## Accepted mechanism (Kong Q2 adjudication)

PersistenceKit stamps an `origin` field on `TableChange` at write time. Field
takes `ChangeOrigin.local` (default, every caller-initiated write) or
`ChangeOrigin.syncApply` (writes issued by `applyInbound`). ConvergenceKit's
outbound observer (`recordOutbound`) discards any `TableChange` with
`origin == .syncApply`.

The keyed-window alternative was REJECTED: SQLite observer delivery is
fire-and-forget unordered `Task`s; echoes can arrive after the flag clears.
`TableChange.hlc` is always `nil` in practice on both backends.

---

## MUST_UPDATE — files and sites

### Swift — PersistenceKit

| File | Change | Sites |
|---|---|---|
| `Sources/PersistenceKit/StorageObserver.swift` | Add `ChangeOrigin` enum (`.local`, `.syncApply`, `Sendable`); add `origin: ChangeOrigin` field + default `.local` to `TableChange.init` | 1 enum, 1 field, 1 init param |
| `Sources/PersistenceKit/RowStore.swift` | Add `insertSync`, `upsertSync`, `deleteSync` with default implementations that call `insert`/`upsert`/`delete` (drops origin — safe for non-sync conformers) | 3 new methods |
| `Sources/PersistenceKitInMemory/InMemoryStorage.swift` | Add `origin: ChangeOrigin = .local` to `insertRow`, `upsertRow`, `deleteRows` actor methods; thread to `TableChange(origin:)` | 3 method sigs, 5 construction sites |
| `Sources/PersistenceKitInMemory/InMemoryRowStore.swift` | Add `insertSync`, `upsertSync`, `deleteSync` overrides calling actor with `origin: .syncApply` | 3 new methods |
| `Sources/PersistenceKitSQLite/SQLiteStorage.swift` | Add `origin: ChangeOrigin = .local` to `insertRow`, `upsertRow`, `deleteRows` backend methods; thread to `notifyObservers(TableChange(origin:))` | 3 method sigs, 4 notification sites |
| `Sources/PersistenceKitSQLite/SQLiteStores.swift` | Add `insertSync`, `upsertSync`, `deleteSync` overrides calling backend with `origin: .syncApply` | 3 new methods |
| `Sources/PersistenceKit/CachingRowStore.swift` | Add `insertSync`, `upsertSync`, `deleteSync` overrides delegating to `backing.insertSync/upsertSync/deleteSync` (preserves origin through the chain) | 3 new methods |

### Swift — ConvergenceKit

| File | Change | Sites |
|---|---|---|
| `Sources/ConvergenceKitCloudKit/Engine/CloudKitStateActor.swift` | Add `guard change.origin != .syncApply else { return }` at top of `recordOutbound` | 1 guard |
| `Sources/ConvergenceKitCloudKit/Engine/ApplyInbound.swift` | 4 `rowStore.upsert/insert` calls → `rowStore.upsertSync/insertSync` | 4 call sites |
| `Sources/ConvergenceKitCloudKit/Engine/PullCycle.swift` | 1 `rowStore.delete` call → `rowStore.deleteSync` | 1 call site |
| `Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | 6 `rowStore.upsert/insert/delete` calls in `applyInbound` → sync variants; add origin guard to `FederationStateActor.recordOutbound` | 7 changes |

### Rust — PersistenceKit

| File | Change | Sites |
|---|---|---|
| `rust/src/observer.rs` | Add `ChangeOrigin` enum (`Local`, `SyncApply`) with `Default = Local`; add `origin: ChangeOrigin` field to `TableChange` | 1 enum, 1 field |
| `rust/src/inmemory.rs` | Add `origin: ChangeOrigin::Local` to 8 `TableChange { ... }` construction sites | 8 sites |
| `rust/src/sqlite.rs` | Add `origin: ChangeOrigin::Local` to 4 `TableChange { ... }` construction sites | 4 sites |
| `rust/src/postgres.rs` | Add `origin: ChangeOrigin::Local` to 8 `TableChange { ... }` construction sites | 8 sites |
| `rust/src/row_store.rs` | Add `insert_sync`, `upsert_sync`, `delete_sync` to `RowStore` trait with default implementations | 3 new methods |

### Docs (same commit as code)

| File | Change |
|---|---|
| `docs/reference/PERSISTENCEKIT_SPEC.md` | Add B-19 (change origin) behavioral contract |
| `docs/reference/PERSISTENCEKIT_INTERFACE.md` | Add `ChangeOrigin` to `TableChange` block; add `insertSync`/`upsertSync`/`deleteSync` to RowStore block |
| `docs/reference/CONVERGENCEKIT_SPEC.md` | Add implementation note to I-10 (keep `v1.2-draft` marker — flip deferred to P5-M4) |

---

## INTENTIONALLY_LEFT — compile unchanged with default origin

| File | Reason |
|---|---|
| `PersistenceKit/Tests/PersistenceKitReplicationTests/IncrementalReplicationTests.swift` (5 construction sites) | All existing `TableChange(table:event:rowKey:values:hlc:)` calls get default `origin: .local` — compile unchanged |
| `ConvergenceKit/rust/src/federation.rs` | Echo suppression already implemented via `pulling: Arc<AtomicBool>` flag (sound for synchronous Rust thread delivery; the unordered-Task problem that motivated this mission applies only to Swift's async backend). `ChangeOrigin` field added to `TableChange` for API parity only. No change to suppression logic required. |
| `PersistenceKit/Sources/PersistenceKitReplication/IncrementalReplicationSession.swift` | Receives `TableChange` from observer; does not construct. No change. |
| `QueueKit/Sources/QueueKit/PersistenceKitBackend.swift` | References `TableChange` type signature; does not construct. No change. |
| `PersistenceKit/Sources/PersistenceKit/NoOpObserver.swift` | Returns empty stream; no `TableChange` construction. |
| `ConvergenceKit/Sources/ConvergenceKit/SyncRecord.swift` | Receives `TableChange` from caller; references type only. No change. |

---

## Baseline

- `swift test` in PersistenceKit: exit 0 (445+ tests passing, captured at session start)
- `swift test` in ConvergenceKit: exit 0 (26 tests passing, captured at session start)
- `cargo test` in PersistenceKit/rust: to be captured before first Rust edit

---

## Risk

**Low.** The `ChangeOrigin` enum is additive. The `origin` field has a default
`.local` that makes all existing construction sites compile unchanged. The three
new protocol methods have default implementations that call the existing
non-sync variants, so existing conformers continue to compile and behave
correctly. Only ConvergenceKit's `applyInbound` paths use the sync variants.

The only behavioral change is in `recordOutbound` (both CloudKit and Federation
actors): `.syncApply` changes are silently dropped. No existing test asserts
that `applyInbound` writes show up in `pendingOutbound` — the opposite was
the bug.
