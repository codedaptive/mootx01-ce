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
  `EncryptionMode.swift`, `StorageIntrospection.swift`,
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
  `caching_row_store.rs`, `cache_invalidator.rs`, `introspection.rs`,
  `inmemory.rs`, `sqlite.rs`, `postgres.rs`.
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
**Rust:** `pub struct EstateConfiguration { estate_id, backend, encryption_config, cache_config }`
(as of PAR-5-PK the Rust version carries both encryption config and cache config,
mirroring the Swift struct field-for-field),
`pub enum BackendConfiguration { Sqlite{…}, Postgresql{…}, InMemory }`.
`EstateConfiguration::new(estate_id, backend)` defaults both fields to plaintext /
disabled, so call sites that use the constructor are unchanged.

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
  `EstateEncryptionConfig` (mode + key identifier + `package`/`pub(crate)`-scoped
  AES-GCM-256 key; `.plaintext` default) — `EncryptionMode.swift` (Swift),
  `encryption.rs` (Rust). Consumers select a mode through
  `EstateConfiguration.encryptionConfig` rather than naming these types.
  Both ports ship behind the swappable `AeadProvider` seam: Swift's
  `CryptoKitAeadProvider` and Rust's `AesGcmAeadProvider` are the defaults;
  a FedRAMP/FIPS replacement drops in by conforming to the protocol/trait.
  See `DECISION_RUST_AEAD_CRATE_2026-06-05.md`.
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

## § 7 — Swift/Rust Concordance

The following types ship in both ports with equivalent semantics. The Rust
names follow Rust conventions (snake_case fields, `snake_case()` methods);
the Swift names follow Swift conventions (camelCase, dot-syntax initializers).

### Full public-surface concordance

One row per public concept. Every top-level public declaration in
`Sources/**` (Swift) and `rust/src/**` (Rust, top-level `pub` only) is
accounted for here, read-anchored to `file:line` in each port. The
conformance binding is the actual parity test that proves Swift==Rust:
the shared backend conformance suite is Swift
`Tests/PersistenceKitConformance/ConformanceRunner.swift` applied to each
backend (`PersistenceKitConformanceTests`, plus per-backend InMemory/SQLite/
PostgreSQL conformance test targets) and Rust
`rust/tests/conformance/mod.rs::run_all` driven from
`rust/tests/inmemory_conformance.rs`, `sqlite_conformance.rs`,
`postgres_conformance.rs`; both expose concept-named fixtures
(`schemaFixtures`/`schema_fixtures`, `rowFixtures`/`row_fixtures`,
`predicateFixtures`/`predicate_fixtures`, `vectorFixtures`/`vector_fixtures`,
`auditFixtures`/`audit_fixtures`, `blobFixtures`/`blob_fixtures`,
`transactionFixtures`/`transaction_fixtures`,
`generatedColumnFixtures`/`generated_column_fixtures`,
`appendOnlyFixtures`/`append_only_fixtures`). Closed value-model and
predicate types additionally carry Swift unit suites in
`Tests/PersistenceKitTests/*` mirrored by Rust `#[cfg(test)]` modules.

Shape-rule shorthand: "async/sync seam" = Swift `async throws`, Rust
synchronous `StorageResult<T>` — the sanctioned no-async-runtime parity
seam declared in § 1 (cf. NeuronKit policy-store seam); "name idiom" = a
Swift↔Rust spelling difference only (e.g. `SQLiteStorage`/`SqliteStorage`,
`StorageError`/`StorageResult` throws-vs-Result).

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Top-level storage protocol | `Storage` (`Storage.swift:7`) | `Storage` (`storage.rs:87`) | public protocol / pub trait | async/sync seam; Rust `transaction` non-generic (object-safety, see § 2) | `ConformanceRunner.runAll` / `conformance/mod.rs::run_all` | Confirmed |
| Transaction handle | `StorageTransaction` (`Transaction.swift:15`) | `StorageTransaction` (`storage.rs:74`) | public protocol / pub trait | async/sync seam | `transactionFixtures` / `transaction_fixtures` | Confirmed |
| Isolation level | `IsolationLevel` (`Transaction.swift:9`) | `IsolationLevel` (`storage.rs:64`) | public enum / pub enum | identical (3 cases) | `transactionFixtures` / `transaction_fixtures` | Confirmed |
| Row I/O sub-store | `RowStore` (`RowStore.swift:31`) | `RowStore` (`row_store.rs:8`) | public protocol / pub trait | async/sync seam | `rowFixtures` / `row_fixtures` | Confirmed |
| Row primary key alias | `RowKey` (`RowStore.swift:7`) | `RowKey` (`types.rs:25`) | public typealias / pub type | identical (`UUID`/`uuid::Uuid`) | `rowFixtures` / `row_fixtures` | Confirmed |
| Row value | `StorageRow` (`RowStore.swift:9`) | `StorageRow` (`types.rs:136`) | public struct / pub struct | identical (`[String:TypedValue]`/`HashMap`) | `rowFixtures` / `row_fixtures` | Confirmed |
| Row handle | `RowHandle` (`RowStore.swift:21`) | `RowHandle` (`types.rs:159`) | public struct / pub struct | identical (table, key) | `rowFixtures` / `row_fixtures` | Confirmed |
| Blob I/O sub-store | `BlobStore` (`BlobStore.swift:10`) | `BlobStore` (`blob_store.rs:7`) | public protocol / pub trait | async/sync seam | `blobFixtures` / `blob_fixtures` | Confirmed |
| Blob key alias | `BlobKey` (`BlobStore.swift:8`) | `BlobKey` (`blob_store.rs:5`) | public typealias / pub type | identical (`String`) | `blobFixtures` / `blob_fixtures` | Confirmed |
| Vector index sub-store | `VectorIndex` (`VectorIndex.swift:39`) | `VectorIndex` (`vector_index.rs:36`) | public protocol / pub trait | async/sync seam | `vectorFixtures` / `vector_fixtures` | Confirmed |
| Distance metric | `DistanceMetric` (`VectorIndex.swift:9`) | `DistanceMetric` (`vector_index.rs:9`) | public enum / pub enum | identical (cosine, l2, dot) | `vectorFixtures` / `vector_fixtures` | Confirmed |
| Index build params | `IndexParameters` (`VectorIndex.swift:15`) | `IndexParameters` (`vector_index.rs:16`) | public enum / pub enum | name idiom (`hnsw(m:efConstruction:)`/`Hnsw{m,ef_construction}`) | `vectorFixtures` / `vector_fixtures` | Confirmed |
| Search params | `SearchParameters` (`VectorIndex.swift:21`) | `SearchParameters` (`vector_index.rs:23`) | public enum / pub enum | name idiom (`efSearch`/`ef_search`) | `vectorFixtures` / `vector_fixtures` | Confirmed |
| k-NN result | `VectorSearchResult` (`VectorIndex.swift:27`) | `VectorSearchResult` (`vector_index.rs:30`) | public struct / pub struct | identical (key, distance, metadata) | `vectorFixtures` / `vector_fixtures` | Confirmed |
| Audit log sub-store | `AuditLog` (`AuditLog.swift:24`) | `AuditLog` (`audit_log.rs:48`) | public protocol / pub trait | async/sync seam | `auditFixtures` / `audit_fixtures` | Confirmed |
| Audit event | `AuditEvent` (SubstrateTypes, re-used via `import SubstrateTypes`) | `AuditEvent` (`audit_log.rs:31`) | public (SubstrateLib) / pub struct (crate-local mirror) | Swift re-uses SubstrateLib type; Rust mirrors it crate-locally (same fields) | `auditFixtures` / `audit_fixtures` | Confirmed |
| Change observer | `StorageObserver` (`StorageObserver.swift:57`) | `StorageObserver` (`observer.rs:51`) | public protocol / pub trait | identical (AsyncStream vs callback model) | `InMemoryObserverTests` / `observer` unit tests | Confirmed |
| Observer event kind | `StorageEvent` (`StorageObserver.swift:29`) | `StorageEvent` (`observer.rs:36`) | public enum / pub enum | identical (insert, update, delete) | `InMemoryObserverTests` / `observer` unit tests | Confirmed |
| Table change record | `TableChange` (`StorageObserver.swift:35`) | `TableChange` (`observer.rs:43`) | public struct / pub struct | identical fields (table, event, rowKey, values, hlc) | `InMemoryObserverTests` / `observer` unit tests | Confirmed |
| No-op observer | `NoOpObserver` (`NoOpObserver.swift:10`) | `NoOpObserver` (`observer.rs:64`) | public final class / pub struct | identical (empty-stream default) | `NoOpObserverTests` / `observer` unit tests | Confirmed |
| Closed value model | `TypedValue` (`TypedValue.swift:26`) | `TypedValue` (`types.rs:29`) | public enum / pub enum | identical (13 cases, case-for-case) | `TypedValueTests` / `types` unit tests | Confirmed |
| Column reference | `Column` (`Column.swift:9`) | `Column` (`types.rs:104`) | public struct / pub struct | identical (table, name; Comparable) | `ColumnTests` / `types` unit tests | Confirmed |
| Column type tag | `ColumnType` (`Column.swift:24`) | `ColumnType` (`types.rs:120`) | public enum / pub enum | identical (11 cases) | `ColumnTests` / `types` unit tests | Confirmed |
| Predicate algebra | `StoragePredicate` (`Predicate.swift:11`) | `StoragePredicate` (`predicate.rs:11`) | public indirect enum / pub enum | name idiom (`bitmaskAll`/`BitmaskAll`); Swift `indirect` | `predicateFixtures` / `predicate_fixtures` | Confirmed |
| Order direction | `OrderDirection` (`Predicate.swift:69`) | `OrderDirection` (`predicate.rs:98`) | public enum / pub enum | identical (ascending, descending) | `predicateFixtures` / `predicate_fixtures` | Confirmed |
| Order clause | `OrderClause` (`Predicate.swift:74`) | `OrderClause` (`predicate.rs:104`) | public struct / pub struct | identical (column, direction) | `predicateFixtures` / `predicate_fixtures` | Confirmed |
| Schema declaration | `SchemaDeclaration` (`Schema.swift:9`) | `SchemaDeclaration` (`schema.rs:8`) | public struct / pub struct | identical (kitID, version, tables, indices, migrations) | `SchemaDeclarationTests` + `schemaFixtures` / `schema` unit + `schema_fixtures` | Confirmed |
| Table declaration | `TableDeclaration` (`Schema.swift:31`) | `TableDeclaration` (`schema.rs:39`) | public struct / pub struct | identical (incl. `appendOnly`/`append_only`) | `schemaFixtures` / `schema_fixtures` | Confirmed |
| Column declaration | `ColumnDeclaration` (`Schema.swift:66`) | `ColumnDeclaration` (`schema.rs:91`) | public struct / pub struct | identical (name, type, nullable, defaultValue) | `schemaFixtures` / `schema_fixtures` | Confirmed |
| Index declaration | `IndexDeclaration` (`Schema.swift:85`) | `IndexDeclaration` (`schema.rs:155`) | public struct / pub struct | identical (name, table, columns, unique) | `schemaFixtures` / `schema_fixtures` | Confirmed |
| Migration | `Migration` (`Schema.swift:99`) | `Migration` (`schema.rs:179`) | public struct / pub struct | identical (fromVersion, toVersion, operations) | `schemaFixtures` / `schema_fixtures` | Confirmed |
| Schema operation | `SchemaOperation` (`Schema.swift:111`) | `SchemaOperation` (`schema.rs:186`) | public enum / pub enum | name idiom (`.custom(sqlite:postgresql:)`/`Custom{sqlite,postgresql}`) | `schemaFixtures` / `schema_fixtures` | Confirmed |
| Generated column | `GeneratedColumn` (`GeneratedColumn.swift:44`) | `GeneratedColumn` (`generated_column.rs:23`) | public struct / pub struct | identical (name, type, expression) | `GeneratedExpressionTests` + `generatedColumnFixtures` / `generated_column` unit + `generated_column_fixtures` | Confirmed |
| Generated expression | `GeneratedExpression` (`GeneratedColumn.swift:64`) | `GeneratedExpression` (`generated_column.rs:51`) | public indirect enum / pub enum | name idiom; Swift `indirect` | `GeneratedExpressionTests` / `generated_column` unit tests | Confirmed |
| Estate configuration | `EstateConfiguration` (`EstateConfiguration.swift:8`) | `EstateConfiguration` (`storage.rs:15`) | public struct / pub struct | identical fields (see field-parity table below) | `ConformanceRunner.runAll` / `run_all` (backend selection) | Confirmed |
| Backend selection | `BackendConfiguration` (`EstateConfiguration.swift:33`) | `BackendConfiguration` (`storage.rs:43`) | public enum / pub enum | name idiom (`.sqlite(url:)`/`Sqlite{...}`) | `ConformanceRunner.runAll` / `run_all` | Confirmed |
| Estate cache config | `EstateCacheConfig` (`EstateCacheConfig.swift:23`) | `EstateCacheConfig` (`cache_config.rs:18`) | public struct / pub struct | identical (enabled, byte ceiling, sensitivity ≤2) | `EstateCacheConfigTests` / `cache_config_tests.rs` | Confirmed |
| Caching row-store decorator | `CachingRowStore` (`CachingRowStore.swift:30`) | `CachingRowStore` (`caching_row_store.rs:211`) | public final class / pub struct | async/sync seam | `CachingRowStoreTests` / `caching_row_store_tests.rs` | Confirmed |
| Cache invalidator | `CacheInvalidator` (`CacheInvalidator.swift:34`) | `CacheInvalidator` (`cache_invalidator.rs:27`) | public final class / pub struct | async/sync seam | `CacheWiringTests` / `cache_wiring_tests.rs` | Confirmed |
| InMemory backend | `InMemoryStorage` (`InMemoryStorage.swift:25`) | `InMemoryStorage` (`inmemory.rs:70`) | public final class / pub struct | async/sync seam; identical entry point | `InMemoryConformanceTests` / `inmemory_conformance.rs` | Confirmed |
| SQLite backend | `SQLiteStorage` (`SQLiteStorage.swift:23`) | `SqliteStorage` (`sqlite.rs:383`) | public final class / pub struct | name idiom (`SQLiteStorage`/`SqliteStorage`); Swift raw SQLite, Rust rusqlite bundled + sqlite-vec | `SQLiteConformanceTests` / `sqlite_conformance.rs` | Confirmed |
| PostgreSQL backend | `PostgreSQLStorage` (`PostgreSQLStorage.swift:24`) | `PostgresStorage` (`postgres.rs:714`) | public final class / pub struct | name idiom (`PostgreSQLStorage`/`PostgresStorage`); both pgvector, schema-per-estate | `PostgreSQLConformanceTests` / `postgres_conformance.rs` | Confirmed |
| Error model | `StorageError` (`StorageError.swift:5`) | `StorageError` (`error.rs:6`) | public enum / pub enum | identical (12 cases, case-for-case) | `StorageErrorTests` / `error` unit tests | Confirmed |
| Result alias | (Swift uses `async throws`; no alias) | `StorageResult` (`error.rs:100`) | — / pub type | async/sync seam — Swift surfaces errors via `throws`, Rust via `Result<T, StorageError>` alias | `StorageErrorTests` / `error` unit tests | Confirmed |
| Replication façade | `StorageReplicator` (`StorageReplicator.swift:62`) | (free fns `replicate`/`flush`/`hydrate`, `replication.rs:124`) | public enum (namespace) / pub fns | name idiom — Swift caseless-enum namespace of statics; Rust free functions in `replication` module | `ReplicationConformanceTests` / `replication.rs` `#[cfg(test)]` | Confirmed |
| Replication mode | `ReplicationMode` (`ReplicationTypes.swift:24`) | `ReplicationMode` (`replication.rs:65`) | public enum / pub enum | identical (`.full`/`.incremental`) | `ReplicationConformanceTests` / `replication.rs` tests | Confirmed |
| Replication cursor | `ReplicationCursor` (`ReplicationTypes.swift:50`) | `ReplicationCursor` (`replication.rs:78`) | public struct / pub struct | identical (hlcWatermark, rowsWritten, auditEventsWritten) | `ReplicationConformanceTests` / `replication.rs` tests | Confirmed |
| Replication error | `ReplicationError` (`ReplicationTypes.swift:72`) | `ReplicationError` (`replication.rs:91`) | public enum / pub enum | identical (schemaMismatch, notImplemented, storageFailure) | `ReplicationConformanceTests` / `replication.rs` tests | Confirmed |

No PersistenceKit public type is an Apple-platform binding: all three
backends (InMemory, SQLite, PostgreSQL) and the crypto seam ship in both
ports (Rust uses rusqlite + sqlite-vec, the `postgres` crate + pgvector,
and the `aes-gcm` crate — the recorded C-1 exception, see
`DECISION_RUST_AEAD_CRATE_2026-06-05.md`). There are therefore no
Exempt rows and no new ignore-list proposals for this package.

### Encryption types (PAR-4-PK / PAR-5-PK)

| Swift | Rust | Notes |
|---|---|---|
| `EncryptionMode` | `EncryptionMode` | Three cases: `plaintext`/`Plaintext`, `rowEncryption`/`RowEncryption`, `fullDatabase`/`FullDatabase` |
| `EstateEncryptionConfig` | `EstateEncryptionConfig` | `mode`, `keyIdentifier`/`key_identifier`, key is `package`/`pub(crate)` scoped. Constructors: `.plaintext` static / `plaintext()`, `init(_ mode:)` / `row_encryption()`, `full_database()` |
| `AeadProvider` (protocol) | `AeadProvider` (trait) | Two methods: `encrypt(_:key:)` / `encrypt(plaintext, key)`, `decrypt(_:key:)` / `decrypt(ciphertext, key)`. Conformers must generate a fresh random nonce per encrypt. Wire layout `[12-byte nonce][16-byte tag][ciphertext]` is identical in both ports |
| `CryptoKitAeadProvider` | `AesGcmAeadProvider` | Default provider behind the seam. Swift uses CryptoKit AES.GCM; Rust uses the `aes-gcm` crate (C-1 exception). Both implement standard AES-GCM-256; cross-decryptable |
| `RowCrypto` | `RowCrypto` | Thin wrapper calling through `AeadProvider`. Swift: `RowCrypto.encrypt(_:key:provider:)`. Rust: `RowCrypto::encrypt(plaintext, key, provider)`. Provider defaults to the CryptoKit/aes-gcm default |

### AeadProvider seam design

The seam lives in `PersistenceKitSQLite` (Swift) and `encryption.rs` (Rust),
internal to the backend layer. No consumer names `AeadProvider` directly;
`SQLiteBackend` / the Rust SQLite backend call `RowCrypto` which delegates
to the provider. The default provider is wired at backend construction time
and can be replaced by injecting an alternate conformer.

Key invariants shared by both ports:
- **Fresh nonce per encrypt.** Never reuse a nonce under a given key.
- **No key logging.** Keys extracted to raw bytes for the provider interface;
  the local binding is not stored or logged.
- **Authentication on decrypt.** Tampered input throws, never returns corrupt plaintext.
- **Wire layout.** `[12-byte nonce][16-byte GCM tag][ciphertext]` in both ports,
  enabling cross-decryptability between Swift and Rust.

### EstateConfiguration field parity (as of PAR-5-PK)

| Field | Swift | Rust |
|---|---|---|
| Estate identifier | `estateID: UUID` | `estate_id: uuid::Uuid` |
| Backend selection | `backend: BackendConfiguration` | `backend: BackendConfiguration` |
| Encryption config | `encryptionConfig: EstateEncryptionConfig` | `encryption_config: EstateEncryptionConfig` |
| Cache config | `cacheConfig: EstateCacheConfig` | `cache_config: EstateCacheConfig` |

---

## § 10 — PersistenceKitReplication module (§5 full-snapshot)

**Added:** 2026-06-05, mission `pk-replication`.

A new `PersistenceKitReplication` library target (Swift) and `replication` module
(Rust) expose a generic full-snapshot primitive for copying estates between storage
backends. No existing target gains a dependency on this library; consumers opt in
by adding the dependency explicitly.

### Types

| Type | Swift | Rust | Role |
|---|---|---|---|
| `ReplicationMode` | `enum ReplicationMode: Sendable` | `enum ReplicationMode` | Controls scope: `.full` or `.incremental` (latter throws) |
| `ReplicationCursor` | `struct ReplicationCursor: Sendable, Equatable` | `struct ReplicationCursor` | Watermark returned after flush/hydrate |
| `ReplicationError` | `enum ReplicationError: Error, Sendable, Equatable` | `enum ReplicationError` | Closed error enum (schemaMismatch, notImplemented, storageFailure) |

### Entry points

| Name | Swift signature | Rust signature |
|---|---|---|
| `replicate` | `static func replicate(from:to:schema:mode:) async throws -> ReplicationCursor` | `pub fn replicate(source, destination, schema, mode) -> Result<ReplicationCursor, ReplicationError>` |
| `flush` | `static func flush(from:into:schema:mode:) async throws -> ReplicationCursor` | `pub fn flush(source, destination, schema) -> Result<ReplicationCursor, ReplicationError>` |
| `hydrate` | `static func hydrate(into:from:schema:) async throws -> ReplicationCursor` | `pub fn hydrate(in_memory, durable, schema) -> Result<ReplicationCursor, ReplicationError>` |

### Swift/Rust concordance

| Behavioural contract | Swift | Rust |
|---|---|---|
| Schema gate | `source.currentSchemaVersion(for: schema.kitID)` vs `destination.currentSchemaVersion(for: schema.kitID)`, both must equal `schema.version` | global `current_schema_version()` compared against `schema.version`; Rust trait has no per-kit version |
| Atomicity | `destination.transaction(isolation: .serializable)` wrapping all row upserts + `auditLog.appendBatch` | `destination.transaction(IsolationLevel::Serializable, &mut \|txn\| { ... })` |
| Generated column filter | `Set(table.generatedColumns.map(\.name))` | `table.generated_columns.iter().map(\|g\| g.name.clone()).collect::<BTreeSet<_>>()` |
| Conflict columns | `table.primaryKey` (NOT `RowHandle.key`) | `table.primary_key` (NOT `RowHandle.key`) |
| Audit copy path | `source.auditLog.iterate(after: nil, rowID: nil, limit: Int.max)` → `txn.auditLog.appendBatch` | `source.audit_log().iterate(None, None, usize::MAX)` → `audit_log.append_batch` |
| Blob copy | Not implemented (no `listKeys()` on `BlobStore`; no GLK kit uses blobStore as of 2026-06-05) | Same |
| HLC watermark | Max `HLC` across all row `.hlc` TypedValues + all `AuditEvent.hlc` | Same |
| `incremental` | Throws `ReplicationError.notImplemented` | Returns `ReplicationError::NotImplemented` |

### ReplicationCursor fields

| Field | Swift | Rust | Meaning |
|---|---|---|---|
| HLC watermark | `hlcWatermark: HLC?` | `hlc_watermark: Option<HLC>` | Max HLC seen; `nil`/`None` if source was empty |
| Row count | `rowsWritten: Int` | `rows_written: usize` | Total rows upserted across all tables |
| Audit count | `auditEventsWritten: Int` | `audit_events_written: usize` | Total audit events copied |

### Source files

| Language | File |
|---|---|
| Swift | `Sources/PersistenceKitReplication/ReplicationTypes.swift` |
| Swift | `Sources/PersistenceKitReplication/StorageReplicator.swift` |
| Swift tests | `Tests/PersistenceKitReplicationTests/ReplicationConformanceTests.swift` |
| Rust | `rust/src/replication.rs` (module `replication`) |
| Package | `Package.swift` (product `PersistenceKitReplication`, target `PersistenceKitReplication`, testTarget `PersistenceKitReplicationTests`) |
| Rust module | `rust/src/lib.rs` (`pub mod replication;`) |

### Known deviations from Swift

- The Rust `Storage` trait has no `currentSchemaVersion(for: kitID)`. The Rust
  replication gate uses the global `current_schema_version()` and compares it
  against `schema.version` directly. This is correct for single-kit-per-storage
  estates (the common case in tests and current GLK usage). Multi-kit estates would
  need a `current_schema_version_for(kit_id)` addition to the Rust trait — tracked
  as a future extension.

- Pre-existing bug F-HLC-01: `SQLiteConnection.bind(.hlc)` uses `SubstrateTypes.HLC.packed`
  layout `(node<<56)|(logical<<40)|phys` but `SQLiteBackend.unpackHLC()` reads a different
  bit layout, so HLC columns do NOT round-trip through SQLite. The replication primitive
  is not affected (it copies TypedValue verbatim). The bug exists in the SQLite backend
  independently of replication and is tracked as F-HLC-01 for a follow-on fix mission.

---

## § 11 — StorageIntrospection surface (PK_INTROSPECT_001)

**Added:** 2026-06-06, mission `PK_INTROSPECT_001`.

### `StorageStats`

Closed value struct returned by `StorageIntrospection.stats(now:)`.
Fields not meaningful for a given backend are nil (SPEC § 8, I-17).

**Swift:**

```swift
public struct StorageStats: Sendable, Equatable {
    public let logicalSizeBytes: Int64
    public let pageSize: Int?
    public let pageCount: Int?
    public let freelistPageCount: Int?
    public let walFrameCount: Int?
    public let cacheHitRatio: Double?
    public let transactionCommitCount: Int64?
    public let transactionRollbackCount: Int64?
    public let deadlockCount: Int64?
    public let lockContention: Bool?
    public let rowCount: Int?
    public let blobCount: Int?
    public let vectorCount: Int?
    public let capturedAt: Date

    public init(
        logicalSizeBytes: Int64,
        pageSize: Int? = nil,
        pageCount: Int? = nil,
        freelistPageCount: Int? = nil,
        walFrameCount: Int? = nil,
        cacheHitRatio: Double? = nil,
        transactionCommitCount: Int64? = nil,
        transactionRollbackCount: Int64? = nil,
        deadlockCount: Int64? = nil,
        lockContention: Bool? = nil,
        rowCount: Int? = nil,
        blobCount: Int? = nil,
        vectorCount: Int? = nil,
        capturedAt: Date
    )
}
```

**Rust:**

```rust
#[derive(Debug, Clone, PartialEq)]
pub struct StorageStats {
    pub logical_size_bytes: i64,
    pub page_size: Option<i32>,
    pub page_count: Option<i32>,
    pub freelist_page_count: Option<i32>,
    pub wal_frame_count: Option<i32>,
    pub cache_hit_ratio: Option<f64>,
    pub transaction_commit_count: Option<i64>,
    pub transaction_rollback_count: Option<i64>,
    pub deadlock_count: Option<i64>,
    pub lock_contention: Option<bool>,
    pub row_count: Option<usize>,
    pub blob_count: Option<usize>,
    pub vector_count: Option<usize>,
    pub captured_at_secs: i64,   // Unix seconds, caller-injected (I-16)
}
```

### `StorageIntrospection`

Optional-capability protocol separate from `Storage`. Consumers probe
with `as? StorageIntrospection`; existing Storage call sites are
unaffected (SPEC § 8, I-15).

**Swift:**

```swift
/// Optional-capability protocol that backends conform to independently
/// of `Storage`. Probe with `as? StorageIntrospection`.
public protocol StorageIntrospection: Sendable {
    /// Returns a snapshot of backend-specific storage statistics.
    /// - Parameter now: caller-injected timestamp — never call Date() internally (I-16).
    func stats(now: Date) async throws -> StorageStats
}
```

**Rust:**

```rust
/// Optional introspection capability; separate from `Storage`.
/// Probe with `downcast_ref::<ConcreteBackend>()` or `as dyn StorageIntrospection`.
pub trait StorageIntrospection {
    /// Returns a snapshot of backend-specific storage stats.
    /// `now_secs`: caller-injected Unix timestamp in seconds (I-16).
    fn stats(&self, now_secs: i64) -> StorageResult<StorageStats>;
}
```

### Swift/Rust concordance

| Concept | Swift | Rust | Notes |
|---|---|---|---|
| Stats value type | `StorageStats` (`StorageIntrospection.swift`) | `StorageStats` (`introspection.rs`) | `Sendable + Equatable` / `Debug + Clone + PartialEq` |
| Protocol / trait | `StorageIntrospection` (`StorageIntrospection.swift`) | `StorageIntrospection` (`introspection.rs`) | Separate from `Storage`; optional capability |
| Timestamp field | `capturedAt: Date` | `captured_at_secs: i64` | Both are caller-injected (I-16) |
| SQLite conformer | `extension SQLiteStorage: StorageIntrospection` | `impl StorageIntrospection for SqliteStorage` | `SQLiteStorage.swift` / `sqlite.rs` |
| PostgreSQL conformer | `extension PostgreSQLStorage: StorageIntrospection` | `impl StorageIntrospection for PostgresStorage` | `PostgreSQLStorage.swift` / `postgres.rs` |
| InMemory conformer | `extension InMemoryStorage: StorageIntrospection` | `impl StorageIntrospection for InMemoryStorage` | `InMemoryStorage.swift` / `inmemory.rs` |
| WAL frame count source | Filesystem stat of `<path>-wal` | `std::fs::metadata(&wal_path)` | No checkpoint lock (I-18) |
| Rollback counter | `InMemoryStateActor.rollbackStats: Int64` | `rollback_count: Arc<Mutex<i64>>` | Outside snapshotted State (I-19) |

### Source files

| Language | File | Role |
|---|---|---|
| Swift | `Sources/PersistenceKit/StorageIntrospection.swift` | `StorageStats` struct + `StorageIntrospection` protocol |
| Swift | `Sources/PersistenceKitSQLite/SQLiteStorage.swift` | `extension SQLiteStorage: StorageIntrospection` |
| Swift | `Sources/PersistenceKitPostgreSQL/PostgreSQLStorage.swift` | `extension PostgreSQLStorage: StorageIntrospection` |
| Swift | `Sources/PersistenceKitInMemory/InMemoryStorage.swift` | `extension InMemoryStorage: StorageIntrospection` |
| Swift tests | `Tests/PersistenceKitSQLiteTests/SQLiteIntrospectionTests.swift` | 11 tests |
| Swift tests | `Tests/PersistenceKitInMemoryTests/InMemoryIntrospectionTests.swift` | 10 tests |
| Rust | `rust/src/introspection.rs` | `StorageStats` + `StorageIntrospection` trait |
| Rust | `rust/src/sqlite.rs` | `impl StorageIntrospection for SqliteStorage` |
| Rust | `rust/src/postgres.rs` | `impl StorageIntrospection for PostgresStorage` |
| Rust | `rust/src/inmemory.rs` | `impl StorageIntrospection for InMemoryStorage` |
| Rust tests | `rust/tests/inmemory_tests.rs` | 7 introspection tests appended |
| Rust tests | `rust/tests/sqlite_conformance.rs` | 9 introspection tests appended |

---

## § 12 — Self-Report Telemetry Surface (cp-persistencekit-report)

Added in mission `cp-persistencekit-report` (2026-06-06). Wires the
existing `StorageIntrospection` / `StorageStats` surface to emit DB-layer
health metrics via IntellectusLib. Off by default.

### Swift

**Source file:** `Sources/PersistenceKit/PersistenceKitTelemetry.swift`

```swift
/// Capture a StorageStats snapshot from `storage` and emit all non-nil
/// fields as StatSample.metric samples via Intellectus.report.
///
/// When Intellectus.isEnabled is false (the default), returns immediately
/// after a single AtomicBool load + branch without calling stats(now:).
///
/// Parameters:
/// - storage: Any StorageIntrospection conformer.
/// - estateID: Carried as the "estate" tag on every emitted metric.
/// - now: Caller-supplied Date (determinism rule — never call Date() inside engine).
public func reportStorageStats(
    _ storage: any StorageIntrospection,
    estateID: String,
    now: Date
) async
```

### Rust

**Source file:** `rust/src/telemetry.rs`

```rust
/// Capture a StorageStats snapshot from `storage` and emit all non-None
/// fields as StatSample::Metric samples via the report! macro.
///
/// When Intellectus::is_enabled() is false (the default), returns
/// immediately after a single AtomicBool load + branch.
pub fn report_storage_stats(
    storage: &dyn StorageIntrospection,
    estate_id: &str,
    now_secs: i64,
)
```

### Metric namespace

All metrics are emitted in the `persistence.db.*` namespace.

| Metric name | Backend | Description |
|---|---|---|
| `persistence.db.size_bytes` | All | Logical DB size in bytes |
| `persistence.db.page_size` | SQLite | Page size in bytes |
| `persistence.db.page_count` | SQLite | Total allocated pages |
| `persistence.db.freelist_pages` | SQLite | Unused (freelist) pages |
| `persistence.db.wal_frames` | SQLite | WAL frame count since last checkpoint |
| `persistence.db.cache_hit_ratio` | PostgreSQL | Buffer-cache hit ratio (0.0–1.0) |
| `persistence.db.tx_commits` | PostgreSQL | Committed transactions |
| `persistence.db.tx_rollbacks` | PostgreSQL, InMemory | Rolled-back transactions |
| `persistence.db.deadlocks` | PostgreSQL | Deadlock count |
| `persistence.db.lock_contention` | SQLite, PostgreSQL | Lock contention flag (1.0/0.0) |
| `persistence.db.row_count` | InMemory | Total row count across all tables |
| `persistence.db.blob_count` | InMemory | Blob store entry count |
| `persistence.db.vector_count` | InMemory | Vector store entry count |

Fields that are `nil` / `None` for a given backend are not emitted.

### Common tags

Every emitted metric carries:

```
"kit":    "PersistenceKit"
"estate": <estateID>
```

### Invariants

See SPEC § 9 (T-1 through T-8) for the full invariant set.

### IntellectusLib dependency

- **Package.swift:** `PersistenceKit` target and both test targets depend on `IntellectusLib`.
  Authority: `DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28`.
- **Cargo.toml:** `intellectus-lib = { path = "../../../libs/IntellectusLib/rust" }`.
  Layering: IntellectusLib has zero repo deps; `PersistenceKit → IntellectusLib` is
  downstream→upstream, no cycle.

### Test sources

| Language | File | Tests |
|---|---|---|
| Swift | `Tests/PersistenceKitInMemoryTests/PersistenceKitTelemetryTests.swift` | 4 suites, 14 tests (InMemory backend) |
| Swift | `Tests/PersistenceKitSQLiteTests/PersistenceKitSQLiteTelemetryTests.swift` | 4 suites, 4 tests (SQLite backend) |
| Swift | `Tests/PersistenceKitInMemoryTests/GlobalTestLock.swift` | Actor mutex — Intellectus singleton isolation |
| Swift | `Tests/PersistenceKitSQLiteTests/GlobalTestLock.swift` | Actor mutex — Intellectus singleton isolation |
| Rust | `rust/tests/telemetry_tests.rs` | 10 tests (InMemory backend) |

---

*End of PersistenceKit Interface v0.8.*
