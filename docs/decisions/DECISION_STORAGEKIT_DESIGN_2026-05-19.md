---
status: proposed
question: How should PersistenceKit be designed across its eight open design questions?
authors: MOOTx01 maintainers
date: 2026-05-19
relates_to:
  - docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md (§4.2)
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
supersedes: none
context:
  - PersistenceKit is the storage abstraction layer consumed by LocusKit, VectorKit, CorpusKit, and GeniusLocusKit.
  - Eight design questions need answers before code; this record recommends one answer per question.
---

# Decision: PersistenceKit Design

## 1. Summary

PersistenceKit is the storage abstraction layer. Eight design questions need answers before code. This document recommends one answer per question. Each recommendation is concrete enough to implement; each has a stated reason and a stated cost.

Backends at v1.0: SQLite (sqlite-vec, WAL), PostgreSQL (pgvector, libpq), InMemory (tests). Consumers: LocusKit, VectorKit, CorpusKit, GeniusLocusKit.

## 2. Scope

PersistenceKit owns: connection management, schema declaration and emission, migration, transactions, typed row I/O, blob I/O, vector index I/O, append-only audit persistence, bitmap predicate compilation.

PersistenceKit does not own: CRDT structure (GeniusLocusKit), sync (ConvergenceKit), encryption at rest (backend-specific), schema content (each consumer kit declares its own).

## 3. Q1: Schema declaration DSL

**Decision: typed Swift struct declarations, no DSL or result builder.**

```swift
public struct SchemaDeclaration: Sendable {
    public let kitID: String          // "LocusKit"
    public let version: Int            // monotonic, current target
    public let tables: [TableDeclaration]
    public let indices: [IndexDeclaration]
    public let migrations: [Migration] // applied in order to reach `version`
}

public struct TableDeclaration: Sendable {
    public let name: String            // "drawers"
    public let columns: [ColumnDeclaration]
    public let primaryKey: [String]    // column names
    public let uniqueConstraints: [[String]]
}

public struct ColumnDeclaration: Sendable {
    public let name: String
    public let type: ColumnType        // enum: .uuid, .bitmap, .text, .timestamp, .float, .int, .blob, .json
    public let nullable: Bool
    public let defaultValue: TypedValue?
}

public struct Migration: Sendable {
    public let fromVersion: Int
    public let toVersion: Int
    public let operations: [SchemaOperation]  // .addColumn, .dropColumn, .renameColumn, .addIndex, .dropIndex, .custom(SQL per-backend)
}
```

Reason: a result builder reads better but adds Swift-version risk and makes it harder for non-Swift kits to declare schemas through FFI. Plain structs are diff-friendly, serializable, and trivial to test. Migrations as ordered operation lists let the backend translate to backend-native DDL.

Cost: more verbose than a builder. Mitigated by helper constructors (`Column.bitmap("adjective")`, `Column.text("verbatim", nullable: false)`).

Escape hatch: `.custom(per-backend SQL string)` operation for cases where the operation list doesn't cover what's needed (e.g. SQLite-only `PRAGMA` calls during migration).

## 4. Q2: Predicate tree

**Decision: closed enum, no extension points, three operator families.**

```swift
public indirect enum StoragePredicate: Sendable {
    // Logical
    case and([StoragePredicate])
    case or([StoragePredicate])
    case not(StoragePredicate)
    case isTrue                        // identity
    case isFalse                       // empty result
    
    // Comparison
    case eq(Column, TypedValue)
    case neq(Column, TypedValue)
    case lt(Column, TypedValue)
    case lte(Column, TypedValue)
    case gt(Column, TypedValue)
    case gte(Column, TypedValue)
    case isNull(Column)
    case isNotNull(Column)
    case `in`(Column, [TypedValue])
    case like(Column, String)
    
    // Bitmap (Int64 columns only)
    case bitmaskAll(Column, mask: Int64)      // (col & mask) == mask
    case bitmaskAny(Column, mask: Int64)      // (col & mask) != 0
    case bitmaskNone(Column, mask: Int64)     // (col & mask) == 0
    case bitwiseEq(Column, expected: Int64, mask: Int64)  // (col & mask) == expected
}

public struct Column: Sendable {
    public let table: String
    public let name: String
}
```

Reason: closed enum gives exhaustive compile-time backend coverage. BitmapEvaluator compiles Filter algebra → StoragePredicate; backend compiles StoragePredicate → SQL. The three bitmap operators cover spec §7.9 needs without leaking SQL into the kit layer.

Cost: extending the enum requires changing every backend. This is the right cost; arbitrary backend extensions break the bit-identity story.

Mandatory filter ordering (spec §7.9.5): enforced by BitmapEvaluator before producing the StoragePredicate, not by PersistenceKit. PersistenceKit treats the predicate as opaque.

Tombstone exclusion: BitmapEvaluator wraps every user predicate in `.and([userPredicate, .bitmaskNone(stateBitmap, mask: tombstoneMask)])`. PersistenceKit does not know about tombstones.

Implementation note: the type is named `StoragePredicate` to avoid collision with Foundation's `Predicate<each Input>` type introduced in macOS 14.

## 5. Q3: Transaction model

**Decision: read-committed default, explicit `transaction` block, no nested transactions, no savepoints in v1.0.**

```swift
public protocol Storage: Sendable {
    func transaction<T: Sendable>(
        isolation: IsolationLevel = .readCommitted,
        _ block: (StorageTransaction) async throws -> T
    ) async throws -> T
}

public enum IsolationLevel: Sendable {
    case readCommitted        // default; SQLite IMMEDIATE, PostgreSQL READ COMMITTED
    case repeatableRead       // SQLite BEGIN EXCLUSIVE, PostgreSQL REPEATABLE READ
    case serializable         // SQLite (impossible without exclusive lock), PostgreSQL SERIALIZABLE
}

public protocol StorageTransaction: Sendable {
    var rowStore: any RowStore { get }
    var blobStore: any BlobStore { get }
    var vectorIndex: any VectorIndex { get }
    var auditLog: any AuditLog { get }
}
```

Reason: read-committed is the safe default for substrate work. The capture verb spans rowStore + auditLog; transaction block ensures atomicity. Nested transactions add complexity for cases that haven't shown up yet. Savepoints same.

Cost: callers needing nesting use composition (one outer transaction; inner functions get the same `StorageTransaction`). Callers needing partial rollback wait for v1.x.

SQLite isolation mapping: `BEGIN IMMEDIATE` for readCommitted and repeatableRead (sqlite is effectively serializable already with WAL); document that SQLite serializable is the same as repeatableRead because of WAL semantics.

PostgreSQL isolation mapping: standard `SET TRANSACTION ISOLATION LEVEL ...`.

InMemory isolation mapping: full snapshot at transaction start; commit replaces snapshot; rollback discards. All three levels behave identically (always serializable).

## 6. Q4: Migration runner

**Decision: forward-only, transaction-per-migration, fail-fast with detailed error, no automatic rollback across migrations.**

```swift
public extension Storage {
    func migrate(to targetVersion: Int) async throws {
        let current = try await currentSchemaVersion()
        guard current < targetVersion else { return }
        
        let pendingMigrations = declaration.migrations
            .filter { $0.fromVersion >= current && $0.toVersion <= targetVersion }
            .sorted(by: { $0.fromVersion < $1.fromVersion })
        
        for migration in pendingMigrations {
            try await transaction(isolation: .serializable) { txn in
                try await applyMigration(migration, in: txn)
                try await recordSchemaVersion(migration.toVersion, in: txn)
            }
        }
    }
}
```

Reason: each migration runs in its own transaction. If migration N succeeds and N+1 fails, the schema is at version N (committed). Operator inspects, fixes the migration code, retries. No "magic rollback across multiple committed migrations."

Cost: a failed migration mid-run leaves the schema partially upgraded. Document this clearly; operators must check `currentSchemaVersion()` after a failed migrate call.

Destructive-during-development changes: not PersistenceKit's concern. Destructive migration means dropping the file and recreating; that's an operator choice, not a kit feature.

DDL transactionality: PostgreSQL supports transactional DDL; SQLite supports it for most DDL but not all (`PRAGMA` is a notable exception). The kit documents that custom SQL migrations on SQLite may not be fully transactional and recommends keeping them small.

## 7. Q5: VectorIndex parameter shape

**Decision: typed struct with three index types, backend-specific parameters in a typed sub-enum.**

```swift
public protocol VectorIndex: Sendable {
    func add(key: RowKey, vector: [Float], metadata: [String: TypedValue]) async throws
    func delete(key: RowKey) async throws
    func knn(
        query: [Float],
        k: Int,
        metric: DistanceMetric,
        filter: StoragePredicate?,
        searchParameters: SearchParameters?
    ) async throws -> [(RowKey, Float)]
    func reindex(parameters: IndexParameters) async throws
}

public enum DistanceMetric: Sendable {
    case cosine
    case l2
    case dot
}

public enum IndexParameters: Sendable {
    case flat
    case ivf(lists: Int)
    case hnsw(m: Int, efConstruction: Int)
}

public enum SearchParameters: Sendable {
    case flat
    case ivf(probes: Int)
    case hnsw(efSearch: Int)
}
```

Reason: typed sub-enums keep the protocol closed but cover the three index types both sqlite-vec and pgvector support. Backends translate to native parameters.

Cost: a hypothetical fourth index type (DiskANN, ScaNN) requires extending the enum. That's the right cost; v1.0 ships with three.

Backend defaults when caller passes nil searchParameters: each backend's documented best default for the index type. SQLite + sqlite-vec: hnsw m=16 efConstruction=200 efSearch=50. PostgreSQL + pgvector: hnsw m=16 efConstruction=64 efSearch=40.

No `additionalParameters: [String: Any]` escape hatch. Tuning beyond the typed parameters requires a kit-level decision recorded in `docs/decisions/`, not an ad-hoc dict.

sqlite-vec source: asg017/sqlite-vec (Alex Garcia), MIT licensed, single-file C amalgamation vendored as a SwiftPM C target.

## 8. Q6: PostgreSQL connection pool

**Decision: PersistenceKit owns the pool, configured per-estate via `EstateConfiguration`, fixed-size with explicit max, no auto-resize.**

```swift
public struct EstateConfiguration: Sendable {
    public let estateID: UUID
    public let backend: BackendConfiguration
}

public enum BackendConfiguration: Sendable {
    case sqlite(url: URL, busyTimeout: TimeInterval = 5.0)
    case postgresql(
        connectionString: String,
        poolSize: Int = 10,
        connectionTimeout: TimeInterval = 5.0,
        idleTimeout: TimeInterval = 300.0
    )
    case inMemory
}
```

Reason: PersistenceKit-owned pool means the kit controls connection lifetimes. Per-estate (not per-process) pool means multi-estate deployments scale predictably. Fixed size means failure modes are observable; auto-resize hides pool exhaustion.

Pool exhaustion: `transaction` blocks waiting for a connection up to `connectionTimeout`, then throws `StorageError.poolExhausted`. Caller decides retry policy.

Cost: callers with extreme concurrency tune `poolSize` per estate. Document the typical workloads (one estate Mac+iPhone: 5; one estate server: 20; MSP per-tenant: 10).

Connection sharing across StorageTransaction operations: a single transaction holds one connection from acquire to commit. The four sub-stores within a transaction (rowStore, blobStore, vectorIndex, auditLog) share that connection.

## 9. Q7: Audit log coordination

**Decision: PersistenceKit provides append-only persistence and HLC-ordered iteration; GeniusLocusKit owns CRDT enforcement; SubstrateLib's `GSetAuditLog` type is the wire format.**

```swift
public protocol AuditLog: Sendable {
    // Append; uniqueness enforced by (eventID, hlc) compound key.
    // Duplicate appends (same eventID+hlc) are idempotent no-ops.
    func append(_ event: AuditEvent) async throws
    
    // Bulk append for sync inbound.
    func appendBatch(_ events: [AuditEvent]) async throws
    
    // Iterate in HLC order; resumable via the after cursor.
    func iterate(
        after: HLC?,
        rowID: RowID?,
        limit: Int
    ) async throws -> AsyncStream<AuditEvent>
    
    // Read events for a row, in HLC order, for projection.
    func eventsForRow(_ rowID: RowID) async throws -> [AuditEvent]
}
```

Reason: G-Set CRDT requires set-union semantics. The (eventID, hlc) compound key enforces uniqueness at the row store level. Two replicas appending the same event commit at most one row each side; sync exchanges events; receiver's `append` is idempotent because the compound key collides.

GeniusLocusKit's responsibility: generating eventIDs (UUID), assigning HLC via HLCGenerator, calling `append`. The CRDT property (commutativity, associativity, idempotence under union) is mechanical from there.

Projection: GeniusLocusKit calls `eventsForRow`, folds via `AuditLogFold` from SubstrateLib. PersistenceKit does not project; it stores and iterates.

Implementation note: this decision requires adding `eventID: UUID` to SubstrateLib's `AuditEvent` struct. That addition was made on 2026-05-19 as part of the PersistenceKit build; the existing initializer signature gains `eventID: UUID = UUID()` as a leading parameter, defaulted so existing call sites remain valid.

Cost: GeniusLocusKit must use SubstrateLib's HLC consistently. Document and test.

The "concurrent captures on the same device" case: two concurrent captures get different eventIDs (UUIDs are independent), different HLCs (HLCGenerator is monotonic), both append cleanly, projection orders them by HLC. No coordination needed.

Cross-device: handled by ConvergenceKit, which exchanges events via `appendBatch`. Same idempotence story.

## 10. Q8: Conformance fixture suite

**Decision: deterministic-seed round-trip suite, 200+ operations, all three backends produce identical results.**

The suite shape:

```
Tests/PersistenceKitConformanceTests/
├── ConformanceFixtures.swift          // 200+ operations, seeded
├── ConformanceRunner.swift            // runs fixtures against any backend
├── SQLiteConformanceTests.swift       // applies runner to PersistenceKit-SQLite
├── PostgreSQLConformanceTests.swift   // applies runner to PersistenceKit-PostgreSQL
└── InMemoryConformanceTests.swift     // applies runner to PersistenceKit-InMemory
```

Fixture categories:
- Schema declaration + emission (10 fixtures)
- Migration forward through 5 versions (5)
- Row insert/upsert/delete/query/count, all column types (40)
- Bitmap predicate compilation and execution (50, covers all `StoragePredicate` cases)
- Blob put/get/delete/stream (20)
- Vector add/delete/knn with all three metrics and three index types (30)
- Audit append, appendBatch, iterate, eventsForRow with HLC ordering (25)
- Transaction commit, rollback, isolation level behavior (15)
- Concurrency: parallel transactions, expected serialization (10)
- Error paths: pool exhaustion, schema mismatch, constraint violation (15)

Acceptance: all three backends pass all fixtures with identical observable results. "Identical" means same query results, same error types for the same invalid inputs, same projection output. NOT bit-identical at the storage layer (file format differs; that's expected).

Cost: real engineering. The runner pattern (one fixture set, multiple backend bindings) keeps the cost linear in fixtures plus backends rather than multiplicative.

## 11. Construction shape

With these eight settled, PersistenceKit construction is:

1. Core protocols + types (RowStore, BlobStore, VectorIndex, AuditLog, Storage, StoragePredicate, TypedValue, ColumnType, etc.)
2. PersistenceKit-InMemory backend (simplest; validates the protocol surface)
3. ConformanceRunner + initial 50 fixtures
4. PersistenceKit-SQLite backend (with sqlite-vec, including the SQLiteDurabilityTail and WorkingSetMmap components)
5. Remaining 150 fixtures
6. PersistenceKit-PostgreSQL backend (with pgvector, libpq client)
7. Performance baseline measurement on each backend
8. README + public API documentation

Estimated scope: larger than SubstrateLib's promotion (which was mostly packaging); this is real construction.

## 12. Open items not pre-decided

These surface during construction and get decision records as they resolve:

- PostgreSQL libpq client library choice (Vapor's PostgresNIO vs swift-postgres-client vs raw libpq via C interop). Lean toward PostgresNIO for ergonomics and Vapor ecosystem compatibility.
- sqlite-vec linking strategy (vendored .c file via SwiftPM C target vs system library). Decided: vendored .c amalgamation from asg017/sqlite-vec for portability.
- Test harness for PostgreSQL CI (Docker container, embedded postgres, or external requirement). Probably ephemeral container in CI; document for contributors.
- Specific connection pool implementation (custom actor-based pool vs PostgresNIO's built-in). Probably PostgresNIO's, if we use that library.
- Migration rollback story for failed schema upgrades. Currently "forward-only, fail-fast"; v1.1 may add explicit down-migrations if usage demands.

## 13. Recommendation

Build PersistenceKit directly, following the same pattern as SubstrateLib.

Estimated wall-clock: longer than SubstrateLib. Real new construction across three backends. The eight decisions above remove the design ambiguity; the work after that is mechanical.
