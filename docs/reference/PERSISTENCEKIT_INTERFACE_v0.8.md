---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: PersistenceKit
languages: [swift, rust]
relates_to:
  - PERSISTENCEKIT_SPEC_v0.8.md  (the contract this interface implements)
purpose: |
  Public API surface of PersistenceKit in both ports, in two tiers
  within § 2. Tier 1 is the CONSUMED CONTRACT — the 18 types other
  packages actually import (the Storage protocol, its five sub-store
  protocols, the value model, schema declaration, predicate algebra,
  and the three backend entry points) — documented in full with
  bilingual signatures. Tier 2 (§ 2's closing subsection) is the
  remaining public surface present in the package but not directly
  named by any consumer: a table of contents (name + role + source
  file). The companion SPEC carries the behavioral contracts
  (invariants I-1…I-10, conformance C-1…C-8).
---

# PersistenceKit Interface

## § 1 — Package layout

**Swift:** `packages/kits/PersistenceKit/` — one package, multiple
targets:

- `Sources/PersistenceKit/` — the protocol + value model (no backend).
  `Storage.swift`, `RowStore.swift`, `BlobStore.swift`,
  `VectorIndex.swift`, `AuditLog.swift`, `StorageObserver.swift`,
  `Transaction.swift`, `TypedValue.swift`, `Column.swift`,
  `Predicate.swift`, `Schema.swift`, `GeneratedColumn.swift`,
  `EstateConfiguration.swift`, `EstateCacheConfig.swift`,
  `CachingRowStore.swift`, `CacheInvalidator.swift`,
  `EncryptionMode.swift`,
  `StorageError.swift`, `NoOpObserver.swift`.
- `Sources/PersistenceKitInMemory/` — `InMemoryStorage` (test +
  conformance reference).
- `Sources/PersistenceKitSQLite/` — `SQLiteStorage` (raw SQLite, WAL).
- `Sources/PersistenceKitPostgreSQL/` — `PostgreSQLStorage` (pgvector,
  pooled).
- `Sources/CSQLiteVec/` — vendored sqlite-vec C amalgamation (the
  SQLite backend's only external dependency).
- `Tests/PersistenceKit*Tests/`, `Tests/PersistenceKitConformance*/`,
  `Package.swift`.

**Rust:** `packages/kits/PersistenceKit/rust/` — crate `persistence-kit`.

- `src/storage.rs`, `row_store.rs`, `blob_store.rs`, `vector_index.rs`,
  `audit_log.rs`, `observer.rs`, `types.rs`, `predicate.rs`,
  `schema.rs`, `generated_column.rs`, `error.rs`, `cache_config.rs`,
  `caching_row_store.rs`, `cache_invalidator.rs`, `inmemory.rs`,
  `sqlite.rs`, `postgres.rs`.
- Traits are synchronous (`Result<T, StorageError>`); the Swift side is
  `async` because Swift actors require it, while the in-process Rust
  backends do no real async I/O. All three backends ship in both ports:
  InMemory, SQLite (rusqlite "bundled" + sqlite-vec vectors), and
  PostgreSQL (sync `postgres` crate + pgvector). The Rust transaction
  surface (`Storage::transaction` + `StorageTransaction`) is implemented
  across all three.

Naming differs by port convention (Swift `insert(table:values:)` /
`StoragePredicate.bitmaskAll`; Rust `insert(table, values)` /
`StoragePredicate::BitmaskAll`); the *observable results* match
(SPEC § 7, C-8).

> **Two-tier surface.** PersistenceKit declares 42 public types across
> its targets, of which 21 are consumed by other packages today (measured
> against all package Sources, 2026-06-03). § 2 Tier 1 documents those 21
> in full — the contract the system depends on, including the structural
> sub-store protocols reached through `Storage`. The Tier 2 subsection at
> the end of § 2 is a table of contents for the rest: present in the
> package, not yet named by a consumer, kept so future builders can find
> them.

## § 2 — Public types

### Tier 1 — consumed contract

#### `Storage`

The top-level protocol every backend conforms to; surfaces the five
sub-stores and the transaction/migration lifecycle (SPEC § 4, I-1).

**Swift:**

```swift
public protocol Storage: Sendable {
    var configuration: EstateConfiguration { get }
    var rowStore: any RowStore { get }
    var blobStore: any BlobStore { get }
    var vectorIndex: any VectorIndex { get }
    var auditLog: any AuditLog { get }
    var observer: any StorageObserver { get }

    func open(schema: SchemaDeclaration) async throws
    func close() async
    func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T
    func currentSchemaVersion() async throws -> Int
    func currentSchemaVersion(for kitID: String) async throws -> Int
    func migrate(to schema: SchemaDeclaration) async throws
}

public extension Storage {
    // Default isolation is read-committed.
    func transaction<T: Sendable>(
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T
}
```

**Rust:**

```rust
pub trait Storage: Send + Sync {
    fn configuration(&self) -> &EstateConfiguration;
    fn row_store(&self) -> Arc<dyn RowStore>;
    fn blob_store(&self) -> Arc<dyn BlobStore>;
    fn vector_index(&self) -> Arc<dyn VectorIndex>;
    fn audit_log(&self) -> Arc<dyn AuditLog>;
    fn observer(&self) -> Arc<dyn StorageObserver>;
    fn open(&self, schema: &SchemaDeclaration) -> StorageResult<()>;
    fn close(&self) -> StorageResult<()>;
    fn current_schema_version(&self) -> StorageResult<i32>;
    fn migrate(&self, schema: &SchemaDeclaration) -> StorageResult<()>;
    fn transaction(
        &self,
        isolation: IsolationLevel,
        block: &mut dyn FnMut(&dyn StorageTransaction) -> StorageResult<()>,
    ) -> StorageResult<()>;
}
// Object-safety adaptation: `dyn Storage` is used throughout, so the Rust
// `transaction` cannot be generic over a return type like Swift's. The block
// returns `StorageResult<()>` — Ok commits, Err rolls back — and surfaces any
// result through its own captured environment.
```

#### `StorageTransaction`

The transaction handle: the same four sub-stores bound to one
connection (SPEC § 5, B-1/B-2).

```swift
public protocol StorageTransaction: Sendable {
    var rowStore: any RowStore { get }
    var blobStore: any BlobStore { get }
    var vectorIndex: any VectorIndex { get }
    var auditLog: any AuditLog { get }
}
public enum IsolationLevel: Sendable { case readCommitted, repeatableRead, serializable }
```
**Rust:**

```rust
pub trait StorageTransaction {
    fn row_store(&self) -> Arc<dyn RowStore>;
    fn blob_store(&self) -> Arc<dyn BlobStore>;
    fn vector_index(&self) -> Arc<dyn VectorIndex>;
    fn audit_log(&self) -> Arc<dyn AuditLog>;
}
pub enum IsolationLevel { ReadCommitted, RepeatableRead, Serializable }
```

Each backend's storage type implements `StorageTransaction` by delegating to
its own sub-stores; `transaction` brackets the block with the backend's
native primitives (InMemory snapshot/restore, SQLite `BEGIN IMMEDIATE`,
PostgreSQL `BEGIN ISOLATION LEVEL <level>`).

#### `RowStore`

Typed row I/O (SPEC § 5, B-4/B-5). `RowKey` is `UUID`.

```swift
public typealias RowKey = UUID

public struct StorageRow: Sendable {
    public let values: [String: TypedValue]
    public init(values: [String: TypedValue])
    public subscript(column: String) -> TypedValue? { get }
}
public struct RowHandle: Sendable, Hashable {
    public let table: String
    public let key: RowKey
    public init(table: String, key: RowKey)
}

public protocol RowStore: Sendable {
    func insert(table: String, values: [String: TypedValue]) async throws -> RowHandle
    func upsert(table: String, values: [String: TypedValue], conflictColumns: [String]) async throws -> RowHandle
    func update(table: String, values: [String: TypedValue], where: StoragePredicate) async throws -> Int
    func delete(table: String, where: StoragePredicate) async throws -> Int
    func query(table: String, where predicate: StoragePredicate?, orderBy: [OrderClause],
               limit: Int?, offset: Int?) async throws -> [StorageRow]
    func count(table: String, where predicate: StoragePredicate?) async throws -> Int
}
public extension RowStore {
    func query(table: String, where predicate: StoragePredicate?) async throws -> [StorageRow] // orderBy [], no paging
}
```
**Rust:** `pub type RowKey = uuid::Uuid;` `pub trait RowStore: Send + Sync`
with `insert`, `upsert`, `update`, `delete`, `query`, `count` returning
`StorageResult<…>`; `StorageRow { values: HashMap<String, TypedValue> }`,
`RowHandle { table, key }`.

#### `BlobStore`

Opaque byte I/O keyed by arbitrary string (SPEC § 2). `BlobKey` is
`String`.

```swift
public typealias BlobKey = String
public protocol BlobStore: Sendable {
    func put(key: BlobKey, bytes: Data) async throws
    func get(key: BlobKey) async throws -> Data?
    func delete(key: BlobKey) async throws
    func exists(key: BlobKey) async throws -> Bool
    func size(key: BlobKey) async throws -> Int?
}
```
**Rust:** `pub trait BlobStore: Send + Sync` with `put(key, bytes)`,
`get -> Option<Vec<u8>>`, `delete`, `exists -> bool`, `size -> Option<usize>`.

#### `VectorIndex`

Vector storage and k-NN search (SPEC § 5, B-9; Q5). Typed parameter
enums; no escape hatch.

```swift
public enum DistanceMetric: Sendable { case cosine, l2, dot }
public enum IndexParameters: Sendable { case flat, ivf(lists: Int), hnsw(m: Int, efConstruction: Int) }
public enum SearchParameters: Sendable { case flat, ivf(probes: Int), hnsw(efSearch: Int) }

public struct VectorSearchResult: Sendable {
    public let key: RowKey
    public let distance: Float
    public let metadata: [String: TypedValue]
    public init(key: RowKey, distance: Float, metadata: [String: TypedValue])
}

public protocol VectorIndex: Sendable {
    func add(key: RowKey, vector: [Float], metadata: [String: TypedValue]) async throws
    func update(key: RowKey, vector: [Float], metadata: [String: TypedValue]) async throws
    func delete(key: RowKey) async throws
    func knn(query: [Float], k: Int, metric: DistanceMetric,
             filter: StoragePredicate?, searchParameters: SearchParameters?) async throws -> [VectorSearchResult]
    func reindex(parameters: IndexParameters) async throws
    func count() async throws -> Int
}
```
**Rust:** mirrored — `DistanceMetric { Cosine, L2, Dot }`,
`IndexParameters { Flat, Ivf{lists}, Hnsw{m, ef_construction} }`,
`SearchParameters { Flat, Ivf{probes}, Hnsw{ef_search} }`,
`VectorSearchResult { key, distance, metadata }`, `trait VectorIndex`.

#### `AuditLog`

Append-only, HLC-ordered audit persistence (SPEC § 4 I-6, § 5 B-10).
Carries SubstrateLib's `AuditEvent` and `HLC`.

```swift
public protocol AuditLog: Sendable {
    func append(_ event: AuditEvent) async throws                 // idempotent on (eventID, hlc)
    func appendBatch(_ events: [AuditEvent]) async throws         // idempotent
    func iterate(after: HLC?, rowID: UUID?, limit: Int) async throws -> [AuditEvent]  // HLC order
    func eventsForRow(_ rowID: UUID) async throws -> [AuditEvent]                      // HLC order
    func count() async throws -> Int
}
```
**Rust:** `pub trait AuditLog: Send + Sync` with `append`,
`append_batch`, `iterate(after, row_id, limit)`,
`events_for_row(row_id) -> Vec<AuditEvent>`, `count -> usize`.

#### `StorageObserver`

Change notification (SPEC § 5, B-11). `NoOpObserver` is the
empty-stream default.

```swift
public enum StorageEvent: Sendable, Hashable { case insert, update, delete }

public struct TableChange: Sendable {
    public let table: String
    public let event: StorageEvent
    public let rowKey: RowKey?
    public let values: [String: TypedValue]?
    public let hlc: HLC?
    public init(table: String, event: StorageEvent, rowKey: RowKey? = nil,
                values: [String: TypedValue]? = nil, hlc: HLC? = nil)
}

public protocol StorageObserver: Sendable {
    func observe(table: String, events: Set<StorageEvent>) -> AsyncStream<TableChange>
}

public final class NoOpObserver: StorageObserver, Sendable {
    public init()
    public func observe(table: String, events: Set<StorageEvent>) -> AsyncStream<TableChange>
}
```
**Rust:** `pub enum StorageEvent { Insert, Update, Delete }`,
`pub struct TableChange { table, event, row_key, values, hlc }`,
`pub trait StorageObserver`, `pub struct NoOpObserver`.

#### `TypedValue` / `Column` / `ColumnType`

The closed value model and column reference (SPEC § 4, I-4).

```swift
public enum TypedValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case bitmap(Int64)              // distinct from int; bitmap-specific storage hints
    case float(Double)
    case text(String)
    case blob(Data)
    case uuid(UUID)
    case timestamp(Date)            // stored as ISO-8601 UTC text (SPEC I-3)
    case json(Data)                 // pre-encoded JSON bytes
    case hlc(HLC)                   // packed UInt64 via HLC.packed
    case fingerprint(Fingerprint256)// 32-byte representation
    case array([TypedValue])        // homogeneous
}
public extension TypedValue { var typeDescription: String { get }; var isNull: Bool { get } }

public struct Column: Sendable, Hashable, Comparable {
    public let table: String
    public let name: String
    public init(table: String, name: String)   // Comparable by (table, name)
}
public enum ColumnType: String, Sendable, Hashable, Codable {
    case uuid, bitmap, text, timestamp, float, int, bool, blob, json, hlc, fingerprint
}
```
**Rust:** `pub enum TypedValue { Null, Bool, Int, Bitmap, Float, Text,
Blob, Uuid, Timestamp, Json, Hlc, Fingerprint, Array }` (case-for-case),
`pub struct Column { table, name }`, `pub enum ColumnType { … }`.

#### `StoragePredicate` / `OrderClause` / `OrderDirection`

The closed predicate algebra and ordering (SPEC § 4 I-5, § 5 B-6).

```swift
public indirect enum StoragePredicate: Sendable {
    // Logical
    case and([StoragePredicate]), or([StoragePredicate]), not(StoragePredicate)
    case isTrue, isFalse
    // Comparison
    case eq(Column, TypedValue), neq(Column, TypedValue)
    case lt(Column, TypedValue), lte(Column, TypedValue)
    case gt(Column, TypedValue), gte(Column, TypedValue)
    case isNull(Column), isNotNull(Column)
    case `in`(Column, [TypedValue]), like(Column, String)
    // Bitmap (Int64 columns only)
    case bitmaskAll(Column, mask: Int64)                    // (col & mask) == mask
    case bitmaskAny(Column, mask: Int64)                    // (col & mask) != 0
    case bitmaskNone(Column, mask: Int64)                   // (col & mask) == 0
    case bitwiseEq(Column, expected: Int64, mask: Int64)    // (col & mask) == expected
}
public extension StoragePredicate {
    static func all(_ predicates: [StoragePredicate]) -> StoragePredicate  // folds isTrue/isFalse
    static func any(_ predicates: [StoragePredicate]) -> StoragePredicate
}

public enum OrderDirection: Sendable { case ascending, descending }
public struct OrderClause: Sendable {
    public let column: Column
    public let direction: OrderDirection
    public init(column: Column, direction: OrderDirection = .ascending)
}
```
**Rust:** `pub enum StoragePredicate { And, Or, Not, IsTrue, IsFalse, Eq,
Neq, Lt, Lte, Gt, Gte, IsNull, IsNotNull, In, Like, BitmaskAll,
BitmaskAny, BitmaskNone, BitwiseEq }`, `pub enum OrderDirection`,
`pub struct OrderClause { column, direction }`.

#### Schema declaration: `SchemaDeclaration`, `TableDeclaration`, `ColumnDeclaration`, `IndexDeclaration`

Typed schema structs; no result builder (SPEC § 5; Q1).

```swift
public struct SchemaDeclaration: Sendable {
    public let kitID: String
    public let version: Int
    public let tables: [TableDeclaration]
    public let indices: [IndexDeclaration]
    public let migrations: [Migration]
    public init(kitID: String, version: Int, tables: [TableDeclaration],
                indices: [IndexDeclaration] = [], migrations: [Migration] = [])
}
public struct TableDeclaration: Sendable {
    public let name: String
    public let columns: [ColumnDeclaration]
    public let primaryKey: [String]
    public let uniqueConstraints: [[String]]
    public let generatedColumns: [GeneratedColumn]
    public let appendOnly: Bool                      // rejects UPDATE/DELETE (SPEC B-8)
    public init(name: String, columns: [ColumnDeclaration], primaryKey: [String],
                uniqueConstraints: [[String]] = [], generatedColumns: [GeneratedColumn] = [],
                appendOnly: Bool = false)
}
public struct ColumnDeclaration: Sendable {
    public let name: String
    public let type: ColumnType
    public let nullable: Bool
    public let defaultValue: TypedValue?
    public init(name: String, type: ColumnType, nullable: Bool = false, defaultValue: TypedValue? = nil)
    // Convenience constructors: .uuid(_), .bitmap(_,default:), .text(_), .timestamp(_),
    //   .int(_), .float(_), .bool(_), .blob(_), .json(_), .hlc(_), .fingerprint(_)
}
public struct IndexDeclaration: Sendable {
    public let name: String
    public let table: String
    public let columns: [String]
    public let unique: Bool
    public init(name: String, table: String, columns: [String], unique: Bool = false)
}
```
**Rust:** mirrored structs `SchemaDeclaration`, `TableDeclaration`,
`ColumnDeclaration`, `IndexDeclaration` in `schema.rs`.

#### `GeneratedColumn` / `GeneratedExpression`

Computed columns over a structured integer expression algebra
(SPEC § 5, B-7).

```swift
public struct GeneratedColumn: Sendable, Equatable {
    public let name: String
    public let type: ColumnType                  // typically .int / .bitmap / .bool
    public let expression: GeneratedExpression
    public init(name: String, type: ColumnType, expression: GeneratedExpression)
}
public indirect enum GeneratedExpression: Sendable, Equatable {
    case column(String), literal(Int64)
    case bitAnd(GeneratedExpression, GeneratedExpression)
    case bitOr(GeneratedExpression, GeneratedExpression)
    case bitXor(GeneratedExpression, GeneratedExpression)
    case shiftRight(GeneratedExpression, UInt8)
    case shiftLeft(GeneratedExpression, UInt8)
    case equal(GeneratedExpression, GeneratedExpression)      // 1 / 0
    case notEqual(GeneratedExpression, GeneratedExpression)   // 1 / 0
    public func renderSQL() -> String                          // shared SQLite/PostgreSQL DDL
    public func evaluate(_ row: [String: TypedValue]) -> Int64 // InMemory path
}
```
**Rust:** `pub struct GeneratedColumn { name, type, expression }`,
`pub enum GeneratedExpression { … }` in `generated_column.rs`.

#### `EstateConfiguration` / `BackendConfiguration`

One configuration value per estate selects the backend (SPEC § 4 I-9;
Q6).

```swift
public struct EstateConfiguration: Sendable {
    public let estateID: UUID
    public let backend: BackendConfiguration
    public let encryptionConfig: EstateEncryptionConfig   // defaults .plaintext (SPEC B-12)
    public let cacheConfig: EstateCacheConfig             // defaults .disabled (SPEC I-11)
    public init(estateID: UUID, backend: BackendConfiguration,
                encryptionConfig: EstateEncryptionConfig = .plaintext,
                cacheConfig: EstateCacheConfig = .disabled)
}
public enum BackendConfiguration: Sendable {
    case sqlite(url: URL, busyTimeout: TimeInterval = 5.0)
    case postgresql(connectionString: String, poolSize: Int = 10,
                    connectionTimeout: TimeInterval = 5.0, idleTimeout: TimeInterval = 300.0)
    case inMemory
}
```
**Rust:** `pub struct EstateConfiguration { estate_id, backend, cache_config }` (the
Rust version carries encryption config and cache config at v0.8),
`pub enum BackendConfiguration { Sqlite{…}, Postgresql{…}, InMemory }`.

#### Backend entry points: `InMemoryStorage`, `SQLiteStorage`, `PostgreSQLStorage`

The three `Storage` conformers consumers instantiate (SPEC § 3).

```swift
public final class InMemoryStorage: Storage, Sendable {
    public init(configuration: EstateConfiguration)
}
public final class SQLiteStorage: Storage, Sendable {
    public init(configuration: EstateConfiguration) throws   // raw SQLite + sqlite-vec, WAL
}
public final class PostgreSQLStorage: Storage, Sendable {
    public init(configuration: EstateConfiguration)          // pgvector, pooled; observer = NoOpObserver
}
```
**Rust:** `pub struct InMemoryStorage` with
`new(configuration: EstateConfiguration)` and
`with_estate(estate_id: Uuid)`; `pub struct SqliteStorage` and
`pub struct PostgresStorage`, each with
`new(config: EstateConfiguration) -> StorageResult<Self>` (SQLite =
rusqlite "bundled" + sqlite-vec; Postgres = sync `postgres` crate +
pgvector, schema-per-estate).

### Tier 2 — broader package surface (table of contents)

The following public types are **present in the package but not yet
named by any other package** (measured against all package Sources,
2026-05-27). Recorded as a navigable index; full signatures live in the
cited file. Promote a type into Tier 1 when a consumer adopts it.

- **Schema mutation:** `Migration` (fromVersion / toVersion /
  operations), `SchemaOperation` (`.createTable`, `.dropTable`,
  `.addColumn`, `.dropColumn`, `.renameColumn`, `.addIndex`,
  `.dropIndex`, `.custom(sqlite:postgresql:)` — the per-backend SQL
  escape hatch) — `Schema.swift`. (Migration is exercised through
  `SchemaDeclaration.migrations` / `Storage.migrate`, not named
  directly by consumers yet.)
- **At-rest encryption:** `EncryptionMode` (`.plaintext`,
  `.rowEncryption`, `.fullDatabase` — modes 1–3),
  `EstateEncryptionConfig` (mode + key identifier + `package`-scoped
  AES-GCM-256 key; `.plaintext` default) — `EncryptionMode.swift`.
  Consumers select a mode through `EstateConfiguration.encryptionConfig`
  rather than naming these types.
- **Cache layer:** `EstateCacheConfig` (enabled flag, byte ceiling,
  sensitivity threshold clamped to ≤2; `.disabled` default),
  `CachingRowStore` (decorating `RowStore` with InMemory hot tier, LRU
  eviction, and sensitivity gate per SPEC I-11/I-12), `CacheInvalidator`
  (subscribes to `StorageObserver` and invalidates cache entries on
  `TableChange` per SPEC B-14) — `EstateCacheConfig.swift`,
  `CachingRowStore.swift`, `CacheInvalidator.swift`. Consumers do not
  name these types; enabling caching is done through
  `EstateConfiguration.cacheConfig`. The decorator is wired inside each
  backend when enabled (SPEC I-13).

> Beyond these, the backend targets (`PersistenceKitSQLite`,
> `PersistenceKitPostgreSQL`, `PersistenceKitInMemory`) expose only their
> `*Storage` entry point publicly (all Tier 1, above); their connection,
> schema-emission, predicate-compilation, store, observer, and crypto
> implementation types are `internal`/`package`-scoped and are not part
> of the public surface. `CSQLiteVec` is a C shim target, not Swift
> public API.

## § 3 — Public functions

The principal Tier-1 entry points (types in § 2):

```swift
let storage: any Storage = try SQLiteStorage(configuration: cfg)   // or InMemoryStorage / PostgreSQLStorage
try await storage.open(schema: declaration)
try await storage.migrate(to: declaration)                          // forward-only (SPEC I-7)

let handle = try await storage.rowStore.insert(table: "drawers", values: row)
let rows   = try await storage.rowStore.query(table: "drawers",
                where: .bitmaskAny(stateCol, mask: 0b110),
                orderBy: [OrderClause(column: createdCol, direction: .descending)],
                limit: 50, offset: 0)
let hits   = try await storage.vectorIndex.knn(query: v, k: 10, metric: .cosine,
                filter: nil, searchParameters: nil)                 // backend default params
try await storage.auditLog.append(event)                            // idempotent on (eventID, hlc)
let stream = storage.observer.observe(table: "drawers", events: [.insert, .update])
```

## § 4 — Errors

```swift
public enum StorageError: Error, Sendable, Equatable {
    case backendUnavailable(reason: String)
    case schemaMismatch(expected: Int, actual: Int)
    case migrationFailed(version: Int, reason: String)
    case constraintViolation(detail: String)
    case poolExhausted(timeout: TimeInterval)
    case transactionConflict(detail: String)
    case typeMismatch(column: String, expected: ColumnType, actual: String)
    case rowNotFound(table: String, key: String)
    case duplicateKey(table: String, key: String)
    case invalidQuery(detail: String)
    case appendOnlyViolation(table: String)
    case backendError(underlying: String)
}
```

**Rust:**

```rust
pub enum StorageError {
    BackendUnavailable { reason: String },
    SchemaMismatch { expected: i32, actual: i32 },
    MigrationFailed { version: i32, reason: String },
    ConstraintViolation { detail: String },
    PoolExhausted { timeout_secs: f64 },
    TransactionConflict { detail: String },
    TypeMismatch { column: String, expected: ColumnType, actual: String },
    RowNotFound { table: String, key: String },
    DuplicateKey { table: String, key: String },
    InvalidQuery { detail: String },
    AppendOnlyViolation { table: String },
    BackendError { underlying: String },
}
pub type StorageResult<T> = Result<T, StorageError>;
```

Behavioral meaning of each category: SPEC § 6.

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/PersistenceKit
```

Targets: `PersistenceKitTests` (core value model), `PersistenceKitInMemoryTests`,
`PersistenceKitSQLiteTests`, `PersistenceKitPostgreSQLTests`, and the
shared `PersistenceKitConformanceTests` — the runner that applies one
fixture set to each backend for identical observable results (SPEC § 7,
C-1).

**Rust:**

```
cargo test -p persistence-kit
```

(InMemory backend conformance; `tests/inmemory_tests.rs`.)

## § 6 — Examples

```swift
import PersistenceKit
import PersistenceKitSQLite

let cfg = EstateConfiguration(
    estateID: estate,
    backend: .sqlite(url: dbURL, busyTimeout: 5.0)     // dates persist as ISO-8601 TEXT
)
let storage = try SQLiteStorage(configuration: cfg)

// Declare a tiny append-only audit table with a generated state cluster.
let schema = SchemaDeclaration(
    kitID: "LocusKit",
    version: 1,
    tables: [
        TableDeclaration(
            name: "drawers",
            columns: [.uuid("id"), .bitmap("adjective_bitmap"), .timestamp("created_at")],
            primaryKey: ["id"],
            generatedColumns: [
                GeneratedColumn(name: "state_cluster", type: .int,
                    expression: .bitAnd(.column("adjective_bitmap"), .literal(0xF)))
            ]
        )
    ],
    indices: [IndexDeclaration(name: "ix_state", table: "drawers", columns: ["state_cluster"])]
)
try await storage.open(schema: schema)

// Atomic capture: row + audit event commit together (SPEC B-2).
try await storage.transaction { txn in
    _ = try await txn.rowStore.insert(table: "drawers", values: row)
    try await txn.auditLog.append(event)
}
```

---

*End of PersistenceKit Interface v0.8.*
