# PersistenceKit Interface Doctrine

For coding agents implementing kits that consume PersistenceKit (LocusKit, VectorKit, CorpusKit, GeniusLocusKit, anything else). This document is the contract.

If you violate the doctrine, the abstraction breaks and the kit graph rots. Read it before writing code.

## 1. Always go through protocols

Consume `any RowStore`, `any BlobStore`, `any VectorIndex`, `any AuditLog`, `any Storage`. Never reference `InMemoryStorage`, `SQLiteStorage`, or `PostgreSQLStorage` from a downstream kit. Backend selection is the application's job, not the kit's.

```swift
// CORRECT
final class LocusKit {
    let storage: any Storage
    init(storage: any Storage) { self.storage = storage }
}

// WRONG
import PersistenceKitSQLite   // never in a downstream kit
final class LocusKit {
    let storage: SQLiteStorage  // never
}
```

## 2. Declare your schema once, in code

Every kit owns one `SchemaDeclaration`. Build it as a `let` constant inside the kit. Pass it to `Storage.open(schema:)` at estate-open time. PersistenceKit emits backend-specific DDL.

```swift
public enum LocusKitSchema {
    public static let declaration = SchemaDeclaration(
        kitID: "LocusKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "drawers",
                columns: [
                    .uuid("row_id"),
                    .bitmap("adjective"),
                    .bitmap("operational"),
                    .bitmap("provenance"),
                    .text("verbatim"),
                    .timestamp("captured_at"),
                    .int("udc_code"),
                    .int("qid_pointer", nullable: true)
                ],
                primaryKey: ["row_id"]
            )
        ],
        indices: [
            IndexDeclaration(name: "idx_drawers_adjective", table: "drawers", columns: ["adjective"]),
            IndexDeclaration(name: "idx_drawers_captured_at", table: "drawers", columns: ["captured_at"])
        ]
    )
}
```

Schemas are append-only across versions. Bump `version` and add a `Migration` when you change anything. Never edit a `TableDeclaration` already in production.

## 3. Never write raw SQL

If you find yourself building a SQL string, stop. The work belongs in `StoragePredicate` or `OrderClause`. The backend compiles. You declare intent.

```swift
// CORRECT
let active = try await storage.rowStore.query(
    table: "drawers",
    where: .and([
        .bitmaskAll(Column(table: "drawers", name: "operational"), mask: 0x01),
        .bitmaskNone(Column(table: "drawers", name: "operational"), mask: 0x80)
    ]),
    orderBy: [OrderClause(column: Column(table: "drawers", name: "captured_at"), direction: .descending)],
    limit: 50,
    offset: nil
)

// WRONG
let active = try connection.prepare("SELECT * FROM drawers WHERE ...")
```

The exception: if you need an operation that StoragePredicate cannot express, propose a new case in the closed enum via a decision record. Do not work around it with raw SQL.

## 4. Use TypedValue exclusively

Cross every kit boundary with TypedValue, not native Swift types. The encoding is the backend's problem.

```swift
// CORRECT
values: [
    "captured_at": .timestamp(Date()),
    "row_id": .uuid(rowID),
    "adjective": .bitmap(0x01)
]

// WRONG
values: [
    "captured_at": Date(),       // not a TypedValue
    "row_id": rowID.uuidString,  // backend type leakage
    "adjective": 1               // ambiguous between .int and .bitmap
]
```

`.bitmap(_)` and `.int(_)` are semantically distinct even though both are Int64. Use `.bitmap` for the three bitmap columns; `.int` for everything else.

## 5. Atomic work uses transactions

Operations that must commit together go inside `storage.transaction { ... }`. The block receives a `StorageTransaction` whose sub-stores share the same connection. Use them; do not call `storage.rowStore` from inside the block (that would acquire a separate connection).

```swift
try await storage.transaction { txn in
    let handle = try await txn.rowStore.insert(table: "drawers", values: ...)
    try await txn.auditLog.append(captureEvent(for: handle))
}
```

If the block throws, the transaction rolls back atomically. If it returns, the transaction commits.

The capture verb crosses rowStore and auditLog; it always uses a transaction. Likewise for mutate, withdraw, expunge.

## 6. Audit events get a fresh eventID per emit

Every `AuditEvent` you construct gets a fresh `UUID()` for `eventID`. Never reuse an eventID; never derive it from row state. The compound key `(eventID, hlc)` makes append idempotent at the storage layer; ConvergenceKit relies on this property.

```swift
// CORRECT
let event = AuditEvent(
    eventID: UUID(),              // fresh
    estateUuid: estateID,
    rowId: handle.key,
    hlc: hlcGenerator.advance(),
    verb: "capture",
    // ...
)
try await txn.auditLog.append(event)
```

HLC comes from SubstrateLib's HLCGenerator. One generator per estate. Generators are monotonic; do not use raw timestamps.

## 7. Never reach inside another kit's tables

Each kit owns its tables. LocusKit owns `drawers`, `tunnels`, `kg_facts`, etc. VectorKit owns `rag_vectors`. CorpusKit owns `chunks`. Do not write SQL or queries that read another kit's tables from your kit. If you need cross-kit data, ask via that kit's API.

The two tables PersistenceKit owns are internal and start with `_storagekit_`: `_storagekit_meta`, `_storagekit_blobs`, `_storagekit_audit`, `_storagekit_vectors`, `_storagekit_vector_meta`. Never touch them from downstream code.

## 8. Test against InMemory in CI; SQLite for parity

Per-kit test suites use `PersistenceKitInMemory` for speed (in-memory, no disk, no extension loading). Add `PersistenceKitSQLite` parity tests for any code path that depends on backend behavior (predicate semantics, ordering, vector distance). PostgreSQL tests are gated on `POSTGRES_TEST_URL`.

```swift
func makeStorage() -> any Storage {
    InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
}
```

When the conformance fixture suite lands (mission 2 final piece), your kit will run a small set of conformance fixtures against every backend.

## 9. Migrations are forward-only

When you change your schema, bump `version` and append a `Migration` with the operations to reach the new version. Never edit an existing migration. Never remove a migration.

```swift
public static let declaration = SchemaDeclaration(
    kitID: "LocusKit",
    version: 2,                                   // bumped from 1
    tables: [...],                                 // current target shape
    migrations: [
        Migration(fromVersion: 1, toVersion: 2, operations: [
            .addColumn(table: "drawers", column: .text("dialect", nullable: true))
        ])
    ]
)
```

A failed migration leaves the schema at the last successfully-applied version. Operators check `currentSchemaVersion()` (global max) or `currentSchemaVersion(for: kitID)` (per-kit) after failure. In multi-kit deployments, use the kitID-scoped variant to avoid misdiagnosing failure in one kit as failure in another.

## 10. Bitmap predicate semantics

Three operators cover spec §7.9:

- `.bitmaskAll(col, mask: M)` → `(col & M) == M`. "all bits in M are set"
- `.bitmaskAny(col, mask: M)` → `(col & M) != 0`. "at least one bit in M is set"
- `.bitmaskNone(col, mask: M)` → `(col & M) == 0`. "no bits in M are set"

Plus `.bitwiseEq(col, expected: E, mask: M)` → `(col & M) == E` for stateful bit-pattern matches.

Compose with `.and([...])` and `.or([...])`. The mandatory filter ordering from spec §7.9.5 (tombstone exclusion, default state filters, then user predicates) is enforced by the kit constructing the predicate, not by PersistenceKit. Wrap user-supplied predicates:

```swift
let final: StoragePredicate = .all([
    // 1. tombstone exclusion (always first)
    .bitmaskNone(opCol, mask: TOMBSTONE_BIT),
    // 2. default state filter (active rows)
    .bitmaskAll(opCol, mask: ACTIVE_BIT),
    // 3. user predicate
    userPredicate
])
```

## 11. Vector index conventions

Vector dimensionality is fixed at first `add`. All subsequent vectors must match. To change dimensionality, drop and recreate.

Distance metrics: `.cosine`, `.l2`, `.dot`. SQLite vec0 returns L2 by default regardless of metric requested; the abstraction tolerates this for v1.0 since callers normalize on the way in. PostgreSQL pgvector honors the metric per query.

Vector metadata is per-vector key/value, encoded as JSON internally. Filter predicates on metadata work but currently run in-memory after the k-NN result returns (JSONB column-level predicate compilation is a v1.x improvement). Use metadata filters sparingly when k is large.

## 12. EstateConfiguration is opaque

The kit consuming Storage never inspects `configuration.backend`. The estate handle is opaque; the protocols are the contract. If your kit needs to know "am I on SQLite or PostgreSQL?", you have a layering bug.

If your kit needs a behavior that differs by backend (e.g. concurrency tuning), that's a missing protocol method. Propose it via decision record.

## 13. Sendable everywhere

Every type that crosses an actor boundary or escapes into an `async` context must be Sendable. PersistenceKit's public types all are. Your downstream types must be too. Use `@unchecked Sendable` with a documented rationale (locking, immutable-after-init, etc.) only when needed.

## 14. StorageObserver

`Storage.observer` exposes change notifications. Subscribe to a table by event set; you receive an `AsyncStream<TableChange>` that fires on commits. Multiple subscribers on the same table coexist.

```swift
let stream = storage.observer.observe(table: "jobs", events: [.insert])
for await change in stream {
    // wake up; do the work
    guard let key = change.rowKey else { continue }
    handleNewJob(key)
}
```

Use cases at v1.0:

- QueueKit's `watch()` for filesystem-backed and PersistenceKit-backed queues
- GeniusLocusKit Brain layer standing signals waking on audit log appends
- ConvergenceKit replicating row-level changes outbound (when sync is enabled on the PersistenceKit instance)

Backend semantics:

- **InMemory**: notifications are reliably delivered to all matching subscribers
- **SQLite**: per-row notifications for `insert` and per-row notifications for `upsert`; `update` and `delete` fire coarse "something changed" notifications (rowKey may be nil) because bulk operations don't compose into per-row events without query rewriting
- **PostgreSQL**: NoOpObserver in v1.0; LISTEN/NOTIFY integration is v1.x

Delivery is at-least-once. Subscribers must tolerate seeing a change after the row has already been deleted (race).

Writes do not block on subscribers. AsyncStream uses `bufferingOldest(1024)`; slow subscribers may miss events under load.

## 15. Error handling

PersistenceKit throws `StorageError` for backend-attributable failures. Your kit can map these to kit-specific errors but should preserve the underlying cause:

```swift
do {
    try await storage.rowStore.insert(table: "drawers", values: ...)
} catch let error as StorageError {
    throw LocusKitError.captureFailed(underlying: error)
}
```

Do not swallow StorageError. The error type carries diagnostic information operators need.

## 16. When in doubt, file a decision record

If you find yourself wanting to:

- Add a case to TypedValue, ColumnType, StoragePredicate, or any closed enum in PersistenceKit
- Add a new protocol method to RowStore, BlobStore, VectorIndex, AuditLog, or Storage
- Change the audit log compound key
- Add a backend-specific escape hatch
- Treat one backend differently from another in downstream code

Stop. Write a decision record in `docs/decisions/` proposing the change. The closed-enum design depends on every change being deliberate.
