# Blast Radius Report — CVK-WB4

**Baseline:** PK Swift 458 tests | CVK Swift 438 tests | PK Rust 340 tests | CVK Rust 85 tests
**Mission:** Add changedColumns to PersistenceKit TableChange (CVK-WB4)
**Symbol being changed:** `TableChange` struct — additive field `changedColumns: Set<String>?` (nil = unknown/all; backward-compat default)

All existing `TableChange(...)` construction sites remain valid; the new parameter is trailing with a `= nil` default so existing call sites compile unchanged. Sites are updated to stamp the field with precision values.

---

## Symbol: `TableChange` (Swift) / `TableChange` (Rust)

**Change class:** Additive field — backward-compatible. Existing construction sites that use positional init or named params without `changedColumns` continue to compile; new field defaults to `nil`.

**Scope:** public (protocol-boundary type in PersistenceKit)

---

### Swift construction sites

| File | Site description | Source | Classification | Justification |
|---|---|---|---|---|
| `PersistenceKit/Sources/PersistenceKit/StorageObserver.swift` | Struct definition + init | grep | MUST_UPDATE | Field definition lives here |
| `PersistenceKit/Sources/PersistenceKitInMemory/InMemoryStorage.swift` | `insertRow` — `notify(TableChange(...))` | grep | MUST_UPDATE | Stamp `Set(stored.keys)` |
| `PersistenceKit/Sources/PersistenceKitInMemory/InMemoryStorage.swift` | `upsertRow` insert path — `notify(TableChange(...))` | grep | MUST_UPDATE | Stamp `Set(stored.keys)` |
| `PersistenceKit/Sources/PersistenceKitInMemory/InMemoryStorage.swift` | `upsertRow` update path — `notify(TableChange(...))` | grep | MUST_UPDATE | Stamp diff(existingRow, merged) |
| `PersistenceKit/Sources/PersistenceKitInMemory/InMemoryStorage.swift` | `updateRows` — `notifications.append(TableChange(...))` | grep | MUST_UPDATE | Stamp diff(oldRow, mergedRow) — old row available in loop |
| `PersistenceKit/Sources/PersistenceKitInMemory/InMemoryStorage.swift` | `deleteRows` — `notifications.append(TableChange(...))` | grep | MUST_UPDATE | Stamp `nil` |
| `PersistenceKit/Sources/PersistenceKitSQLite/SQLiteStorage.swift` | `insertRow` — `notifyObservers(TableChange(...))` | grep | MUST_UPDATE | Stamp `Set(values.keys)` |
| `PersistenceKit/Sources/PersistenceKitSQLite/SQLiteStorage.swift` | `upsertRow` — `notifyObservers(TableChange(...))` | grep | MUST_UPDATE | Pre-SELECT old row; stamp diff if found, else all keys |
| `PersistenceKit/Sources/PersistenceKitSQLite/SQLiteStorage.swift` | `updateRows` (pre-key fetch path) — `notifyObservers(TableChange(...))` | grep | MUST_UPDATE | Extend `fetchMatchingRowKeys` to return full rows; stamp diff |
| `PersistenceKit/Sources/PersistenceKitSQLite/SQLiteStorage.swift` | `updateRows` (values=nil path) — `notifyObservers(TableChange(...))` | grep | MUST_UPDATE | Stamp `Set(values.keys)` (columns passed to SET clause — conservative but correct; exact diff unavailable without schema-round-trip) |
| `PersistenceKit/Sources/PersistenceKitSQLite/SQLiteStorage.swift` | `deleteRows` — `notifyObservers(TableChange(...))` | grep | MUST_UPDATE | Stamp `nil` |
| `PersistenceKit/Tests/PersistenceKitReplicationTests/IncrementalReplicationTests.swift` | Synthetic `TableChange(...)` in 5 tests | grep | MUST_UPDATE | Must compile with new field (default nil covers them; no value needed for replication tests) |
| `ConvergenceKit/Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | `strippedChange = TableChange(...)` in `recordOutbound` | grep | MUST_UPDATE | Pass through `changedColumns: change.changedColumns` |

### Swift consumer sites (observe or carry TableChange, no construction)

| File | Site description | Source | Classification | Justification |
|---|---|---|---|---|
| `ConvergenceKit/Sources/ConvergenceKitCloudKit/Engine/CloudKitStateActor.swift` | `recordOutbound(_ change: TableChange)` | grep | MUST_UPDATE | Storm-kill upgrade + fieldLevelLWW precision stamping |
| `ConvergenceKit/Sources/ConvergenceKitFederation/FederationSyncEngine.swift` | `push()` fieldLevelLWW stamp via `ColumnHLCMap.stampAll` | grep | MUST_UPDATE | Use `changedColumns` when non-nil |
| `PersistenceKit/Sources/PersistenceKitReplication/IncrementalReplicationSession.swift` | `accumulate(_ change: TableChange)` | grep | INTENTIONALLY_LEFT | Uses `change.values` for replication; `changedColumns` not relevant to blob/row dirty tracking |
| `PersistenceKit/Sources/PersistenceKit/NoOpObserver.swift` | `AsyncStream<TableChange>` in protocol default | grep | INTENTIONALLY_LEFT | No-op stub; emits empty stream; no construction |
| `PersistenceKit/Sources/PersistenceKitInMemory/InMemoryObserver.swift` | `notify(_ change: TableChange)` carrier | grep | INTENTIONALLY_LEFT | Routing only; no construction |
| `PersistenceKit/Sources/PersistenceKitSQLite/SQLiteObserver.swift` | `notify(_ change: TableChange)` carrier | grep | INTENTIONALLY_LEFT | Routing only; no construction |
| `QueueKit/Sources/QueueKit/PersistenceKitBackend.swift` | Comment referencing TableChange | grep | INTENTIONALLY_LEFT | Comment only; no construction or access to changedColumns |
| All test files observing TableChange fields | Various tests asserting `origin`, `event`, `values` fields | grep | INTENTIONALLY_LEFT | Adding a field doesn't break observers; tests check specific existing fields |

---

### Rust construction sites

| File | Site description | Source | Classification | Justification |
|---|---|---|---|---|
| `PersistenceKit/rust/src/observer.rs` | `TableChange` struct definition | grep | MUST_UPDATE | Field definition |
| `PersistenceKit/rust/src/inmemory.rs` | `insert`: `TableChange { ... }` (buffered + direct paths) | grep | MUST_UPDATE | Stamp `Some(HashSet::from(stored.keys()))` |
| `PersistenceKit/rust/src/inmemory.rs` | `upsert` insert path: `TableChange { ... }` | grep | MUST_UPDATE | Stamp `Some(HashSet::from(stored.keys()))` |
| `PersistenceKit/rust/src/inmemory.rs` | `upsert` update path: `TableChange { ... }` | grep | MUST_UPDATE | Stamp diff(old, merged) |
| `PersistenceKit/rust/src/inmemory.rs` | `update`: `TableChange { ... }` (buffered + direct) | grep | MUST_UPDATE | Stamp diff(old_row, merged) |
| `PersistenceKit/rust/src/inmemory.rs` | `delete`: `TableChange { ... }` (buffered + direct) | grep | MUST_UPDATE | Stamp `None` |
| `PersistenceKit/rust/src/sqlite.rs` | `insert`: `TableChange { ... }` | grep | MUST_UPDATE | Stamp `Some(HashSet::from(values.keys()))` |
| `PersistenceKit/rust/src/sqlite.rs` | `upsert`: `TableChange { ... }` | grep | MUST_UPDATE | Pre-SELECT; stamp diff or all keys |
| `PersistenceKit/rust/src/sqlite.rs` | `update`: `TableChange { ... }` per matched key | grep | MUST_UPDATE | Pre-SELECT full rows; stamp diff |
| `PersistenceKit/rust/src/sqlite.rs` | `delete`: `TableChange { ... }` per matched key | grep | MUST_UPDATE | Stamp `None` |

---

### Docs (prose references)

| File | Reference | Source | Classification |
|---|---|---|---|
| `docs/reference/PERSISTENCEKIT_SPEC.md` | Add B-20 contract for changedColumns | grep | MUST_UPDATE |
| `docs/reference/PERSISTENCEKIT_INTERFACE.md` | TableChange interface block | grep | MUST_UPDATE |
| `docs/reference/CONVERGENCEKIT_SPEC.md` | B-8 stamp-all WHY comment (precision refinement), B-14 storm-kill precision | grep | MUST_UPDATE |
| `docs/status/CVK_ICLOUD/TRACKED_FOLLOWUPS.md` | Row 4 — mark done | grep | MUST_UPDATE |

---

## Summary
- MUST_UPDATE: 22 sites (Swift + Rust + docs)
- INTENTIONALLY_LEFT: 8 sites (all justified)
- RESCOPE_REQUIRED: 0

The `changedColumns` field is purely additive with a `nil` default. All construction sites that do not explicitly set it remain valid and compile unchanged. Sites are updated to stamp accurate column sets, unlocking precision storm-kill and fieldLevelLWW stamping in ConvergenceKit.

> Post-review note (Adams Wave B): the baseline test counts above were
> taken from a multi-kit context and overstate the single-kit baseline
> (CVK Swift was 221 at the time, not 438). Counts are informational;
> the site classifications are the load-bearing content.
