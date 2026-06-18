---
title: PersistenceKit Interface
status: active
authors: MOOTx01 maintainers
date: 2026-06-18
version: 1.1.1
spec_type: kit
description: Public API surface for PersistenceKit in both the Swift and Rust ports.
package: PersistenceKit
languages: [swift, rust]
relates_to:
  - PERSISTENCEKIT_SPEC.md  (the contract this interface implements)
purpose: |
  Public API surface of PersistenceKit in both ports, in two tiers
  within § 2. Tier 1 is the CONSUMED CONTRACT — the 21 types other
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
  `AuditLog.swift`, `StorageObserver.swift`,
  `Transaction.swift`, `TypedValue.swift`, `Column.swift`,
  `Predicate.swift`, `Schema.swift`, `GeneratedColumn.swift`,
  `EstateConfiguration.swift`, `EstateCacheConfig.swift`,
  `CachingRowStore.swift`, `CacheInvalidator.swift`,
  `EncryptionMode.swift`, `StorageIntrospection.swift`,
  `StorageError.swift`, `NoOpObserver.swift`.
  (No `VectorIndex.swift`: PersistenceKit owns no vector engine — ADR-008.)
- `Sources/PersistenceKitInMemory/` — `InMemoryStorage` (test +
  conformance reference).
- `Sources/PersistenceKitSQLite/` — `SQLiteStorage` (raw SQLite, WAL).
- `Sources/PersistenceKitPostgreSQL/` — `PostgreSQLStorage` (pooled).
- `Tests/PersistenceKit*Tests/`, `Tests/PersistenceKitConformance*/`,
  `Package.swift`.

**Rust:** `packages/kits/PersistenceKit/rust/` — crate `persistence-kit`.

- `src/storage.rs`, `row_store.rs`, `blob_store.rs`,
  `audit_log.rs`, `observer.rs`, `types.rs`, `predicate.rs`,
  `schema.rs`, `generated_column.rs`, `error.rs`, `cache_config.rs`,
  `caching_row_store.rs`, `cache_invalidator.rs`, `introspection.rs`,
  `inmemory.rs`, `sqlite.rs`, `postgres.rs`.
  (No `vector_index.rs`: removed with the vector engine — ADR-008.)
- Traits are synchronous (`Result<T, StorageError>`); the Swift side is
  `async` because Swift actors require it, while the in-process Rust
  backends do no real async I/O. All three backends ship in both ports:
  InMemory, SQLite (rusqlite "bundled"), and PostgreSQL (sync `postgres`
  crate). The Rust transaction surface (`Storage::transaction` +
  `StorageTransaction`) is implemented across all three.

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

The transaction handle: the same three sub-stores bound to one
connection (SPEC § 5, B-1/B-2).

```swift
public protocol StorageTransaction: Sendable {
    var rowStore: any RowStore { get }
    var blobStore: any BlobStore { get }
    var auditLog: any AuditLog { get }
}
public enum IsolationLevel: Sendable { case readCommitted, repeatableRead, serializable }
```
**Rust:**

```rust
pub trait StorageTransaction {
    fn row_store(&self) -> Arc<dyn RowStore>;
    fn blob_store(&self) -> Arc<dyn BlobStore>;
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

#### Vector-storage accommodation (no `VectorIndex` protocol)

PersistenceKit exposes **no** `VectorIndex` protocol, `knn` method, or
`DistanceMetric`/`IndexParameters`/`SearchParameters`/`VectorSearchResult`
type. Dense-embedding k-NN lives solely in VectorKit (ADR-008). Storage does
not surface a VectorIndex (SPEC § 1, B-9).

Instead, every backend accommodates a vector workload's STORAGE needs
through the general `RowStore`/`BlobStore` surfaces. A consumer (e.g.
VectorKit) stores embeddings as ordinary rows: an opaque binary payload
(`.blob`, 32 bytes for a packed Engram/fingerprint) and/or a float32
payload (`.blob`, dim×4 bytes for a dense embedding), keyed by `.uuid`.
The accommodation contract — vector-payload round-trip, ≥1k bulk
hydration, count, delete — is asserted by `vectorFixtures` /
`vector_fixtures` on all three backends (SPEC I-1a, B-9; § "Conformance").

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

One configuration value per estate selects the backend and the novel-token
tagger choice (SPEC § 4 I-9, I-20; Q6).

```swift
/// Estate-creation-time selection of the novel-token tagger (SPEC I-20).
/// Fixed at creation; change-after-creation is v1.1.
public enum NovelTokenTaggerChoice: Sendable, Hashable, Codable {
    case hmm        // Deterministic HMM/Viterbi — default and cross-port baseline.
    case nlTagger   // Apple NLTagger — Apple-only advanced opt-in.
                    // NOT federatable with hmm estates (federation enforcement v1.1).
    static let `default`: NovelTokenTaggerChoice  // .hmm
}

public struct EstateConfiguration: Sendable {
    public let estateID: UUID
    public let backend: BackendConfiguration
    public let encryptionConfig: EstateEncryptionConfig   // defaults .plaintext (SPEC B-12)
    public let cacheConfig: EstateCacheConfig             // defaults .disabled (SPEC I-11)
    public let novelTokenTagger: NovelTokenTaggerChoice   // defaults .hmm (SPEC I-20)
    public init(estateID: UUID, backend: BackendConfiguration,
                encryptionConfig: EstateEncryptionConfig = .plaintext,
                cacheConfig: EstateCacheConfig = .disabled,
                novelTokenTagger: NovelTokenTaggerChoice = .hmm)
}
public enum BackendConfiguration: Sendable {
    case sqlite(url: URL, busyTimeout: TimeInterval = 5.0)
    case postgresql(connectionString: String, poolSize: Int = 10,
                    connectionTimeout: TimeInterval = 5.0, idleTimeout: TimeInterval = 300.0)
    case inMemory
}
```
**Rust:** `pub struct EstateConfiguration { estate_id, backend, encryption_config, cache_config, novel_token_tagger }`.
The Rust version carries all five fields, mirroring the Swift struct field-for-field.
`EstateConfiguration::new(estate_id, backend)` defaults all optional fields to plaintext /
disabled / Hmm, so existing call sites are unchanged.
`EstateConfiguration::new_with_tagger(estate_id, backend, choice)` accepts an explicit
`NovelTokenTaggerChoice`; returns `StorageError::InvalidConfiguration` when `NlTagger`
is requested on Rust (no NaturalLanguage framework — fail-closed, SPEC I-20).
`pub enum BackendConfiguration { Sqlite{…}, Postgresql{…}, InMemory }`.
`pub enum NovelTokenTaggerChoice { Hmm, NlTagger }` — `NlTagger` exists for schema parity
with the Swift port; active construction via `new_with_tagger` is rejected on Rust.

#### Backend entry points: `InMemoryStorage`, `SQLiteStorage`, `PostgreSQLStorage`

The three `Storage` conformers consumers instantiate (SPEC § 3).

```swift
public final class InMemoryStorage: Storage, Sendable {
    public init(configuration: EstateConfiguration)
}
public final class SQLiteStorage: Storage, Sendable {
    public init(configuration: EstateConfiguration) throws   // raw SQLite, WAL
}
public final class PostgreSQLStorage: Storage, Sendable {
    public init(configuration: EstateConfiguration)          // pooled; observer = NoOpObserver
}
```
**Rust:** `pub struct InMemoryStorage` with
`new(configuration: EstateConfiguration)` and
`with_estate(estate_id: Uuid)`; `pub struct SqliteStorage` and
`pub struct PostgresStorage`, each with
`new(config: EstateConfiguration) -> StorageResult<Self>` (SQLite =
rusqlite "bundled"; Postgres = sync `postgres` crate, schema-per-estate).

### Tier 2 — broader package surface (table of contents)

The following public types are **present in the package but not yet
named by any other package** (measured against all package Sources,
2026-06-03). Recorded as a navigable index; full signatures live in the
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
  The Rust port's use of the `aes-gcm` crate behind this seam is the
  recorded C-1 exception.
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
> of the public surface. (The former `CSQLiteVec` C shim target was
> removed with the vector engine — ADR-008.)

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
// Vector embeddings persist as ordinary rows (a .blob payload column);
// dense-embedding k-NN is VectorKit's, not PersistenceKit's (ADR-008).
_ = try await storage.rowStore.insert(table: "vectors", values: vectorRow)
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

Every public type documented in § 2 ships in both ports with equivalent
semantics, proven by the shared backend conformance suite: one fixture set
(schema, row, predicate, vector, audit, blob, transaction, generated-column,
and append-only fixtures) is applied to all three backends in each port and
must yield identical observable results. Closed value-model and predicate
types additionally carry mirrored unit suites in each port.

Two shape rules recur across the surface. "async/sync seam" means the Swift
side is `async throws` while the Rust side is synchronous `StorageResult<T>` —
the sanctioned no-async-runtime parity seam declared in § 1. "name idiom"
means a Swift↔Rust spelling difference only (e.g. `SQLiteStorage` ↔
`SqliteStorage`, errors surfaced via `throws` ↔ a `StorageResult` alias).
A handful of types differ by more than spelling: the Rust `transaction` is
non-generic for object-safety (see § 2); the replication module's
dirty-tracking helpers are Swift `actor`s on one side and owned-state structs
(`Mutex<HashSet<…>>`) on the other; and the blob dirty-key accumulator is named
`BlobDirtySet` (Swift) and `BlobDirtyAccumulator` (Rust). In every case the
observable behaviour is identical.

No PersistenceKit public type is an Apple-platform binding: all three
backends (InMemory, SQLite, PostgreSQL) and the crypto seam ship in both
ports (Rust uses rusqlite, the `postgres` crate, and the `aes-gcm`
crate — the recorded C-1 exception). There are therefore no
Exempt rows for this package.

Two types appear as `rust-only` in the concordance audit because the Swift
declarations use `public indirect enum` and the audit regex only matches
`public enum`: `StoragePredicate` and `GeneratedExpression` are both public
in Swift and Rust; the `indirect` keyword is a recursive-enum qualifier, not
a visibility modifier. The rows below document these as the swift+rust types
they are.

One type — `StorageReplicator` — is Swift-only: the Rust port exposes the
same replication operations as free functions (`replicate`, `flush`, `hydrate`)
in `replication.rs`, not as a named namespace type. The `DirtyKey` type is
Rust-only: the Swift implementation uses an internal (non-`public`) `DirtyKey`
struct inside `IncrementalReplicationSession.swift`.

### Core protocol and value types

| Swift | Rust | Notes |
|---|---|---|
| `Storage` (protocol) | `Storage` (trait) | Top-level backend protocol/trait. Swift: `async throws` methods. Rust: synchronous `StorageResult<T>` — sanctioned async/sync seam (§ 1). |
| `StorageTransaction` (protocol) | `StorageTransaction` (trait) | Transaction handle carrying `rowStore`, `blobStore`, `auditLog`. Rust `transaction` is non-generic (object-safety; block returns `StorageResult<()>`). |
| `IsolationLevel` | `IsolationLevel` | Three cases: `readCommitted`/`ReadCommitted`, `repeatableRead`/`RepeatableRead`, `serializable`/`Serializable`. |
| `RowStore` (protocol) | `RowStore` (trait) | Typed row I/O. `insert`, `upsert`, `update`, `delete`, `query`, `count`. Swift `async throws` / Rust `StorageResult`. |
| `RowKey` (typealias `UUID`) | `RowKey` (type alias `uuid::Uuid`) | Primary key type. |
| `StorageRow` | `StorageRow` | `values: [String: TypedValue]` / `HashMap<String, TypedValue>`. |
| `RowHandle` | `RowHandle` | `table: String`, `key: RowKey`. |
| `BlobStore` (protocol) | `BlobStore` (trait) | Opaque byte I/O. `put`, `get`, `delete`, `exists`, `size`. |
| `BlobKey` (typealias `String`) | `BlobKey` (type alias `String`) | Blob key type. |
| `AuditLog` (protocol) | `AuditLog` (trait) | Append-only HLC-ordered audit. `append`, `appendBatch`/`append_batch`, `iterate`, `eventsForRow`/`events_for_row`, `count`. |
| `StorageObserver` (protocol) | `StorageObserver` (trait) | Change notification. `observe(table:events:)` / `observe(table, events)`. Swift returns `AsyncStream<TableChange>`; Rust returns `mpsc::Receiver<TableChange>` — sanctioned seam. |
| `StorageEvent` | `StorageEvent` | Three cases: `insert`/`Insert`, `update`/`Update`, `delete`/`Delete`. |
| `TableChange` | `TableChange` | Row change notification: `table`, `event`, `rowKey`/`row_key`, `values`, `hlc`. |
| `BlobEvent` | `BlobEvent` | Two cases: `put`/`Put`, `delete`/`Delete`. |
| `BlobChange` | `BlobChange` | Blob change notification: `key`, `event`, `bytes`. `bytes` is `Data?`/`Option<Vec<u8>>`; carries payload on `put`, nil/None on `delete`. |
| `NoOpObserver` | `NoOpObserver` | Empty-stream default `StorageObserver` conformer. |
| `TypedValue` | `TypedValue` | Closed value enum: `null`/`Null`, `bool`/`Bool`, `int`/`Int`, `bitmap`/`Bitmap`, `float`/`Float`, `text`/`Text`, `blob`/`Blob`, `uuid`/`Uuid`, `timestamp`/`Timestamp`, `json`/`Json`, `hlc`/`Hlc`, `fingerprint`/`Fingerprint`, `array`/`Array`. Case-for-case identical. |
| `Column` | `Column` | `table: String`, `name: String`. |
| `ColumnType` | `ColumnType` | Eleven cases: `uuid`, `bitmap`, `text`, `timestamp`, `float`, `int`, `bool`, `blob`, `json`, `hlc`, `fingerprint`. |
| `StoragePredicate` | `StoragePredicate` | Closed predicate algebra. Swift: `public indirect enum` (recursive). Rust: `pub enum`. Same cases: `and`/`And`, `or`/`Or`, `not`/`Not`, `isTrue`/`IsTrue`, `isFalse`/`IsFalse`, comparisons, bitmap predicates. The audit regex misses Swift `indirect` — this is a known regex limitation, not a parity gap. |
| `OrderDirection` | `OrderDirection` | Two cases: `ascending`/`Ascending`, `descending`/`Descending`. |
| `OrderClause` | `OrderClause` | `column: Column`, `direction: OrderDirection`. |
| `SchemaDeclaration` | `SchemaDeclaration` | Schema manifest: `kitID`/`kit_id`, `version`, `tables`, `indices`, `migrations`. |
| `TableDeclaration` | `TableDeclaration` | Table manifest: `name`, `columns`, `primaryKey`/`primary_key`, `uniqueConstraints`/`unique_constraints`, `generatedColumns`/`generated_columns`, `appendOnly`/`append_only`. |
| `ColumnDeclaration` | `ColumnDeclaration` | Column manifest: `name`, `type`/`col_type`, `nullable`, `defaultValue`/`default_value`. |
| `IndexDeclaration` | `IndexDeclaration` | Index manifest: `name`, `table`, `columns`, `unique`. |
| `Migration` | `Migration` | Schema migration step: `fromVersion`/`from_version` (Int/i32), `toVersion`/`to_version` (Int/i32), `operations` ([SchemaOperation]/Vec<SchemaOperation>). |
| `SchemaOperation` | `SchemaOperation` | Closed migration-operation enum: `createTable`/`CreateTable`, `dropTable`/`DropTable`, `addColumn`/`AddColumn`, `dropColumn`/`DropColumn`, `renameColumn`/`RenameColumn`, `addIndex`/`AddIndex`, `dropIndex`/`DropIndex`, `custom(sqlite:postgresql:)`/`Custom{sqlite,postgresql}` (per-backend SQL escape hatch). |
| `GeneratedColumn` | `GeneratedColumn` | Computed column: `name`, `type`/`col_type`, `expression`. |
| `GeneratedExpression` | `GeneratedExpression` | Integer expression algebra. Swift: `public indirect enum` (recursive). Rust: `pub enum`. Same cases: `column`/`Column`, `literal`/`Literal`, `bitAnd`/`BitAnd`, `bitOr`/`BitOr`, `bitXor`/`BitXor`, `shiftRight`/`ShiftRight`, `shiftLeft`/`ShiftLeft`, `equal`/`Equal`, `notEqual`/`NotEqual`. Audit regex limitation as for `StoragePredicate`. |
| `EstateConfiguration` | `EstateConfiguration` | See EstateConfiguration field parity table below. |
| `BackendConfiguration` | `BackendConfiguration` | Three cases: `sqlite(url:busyTimeout:)`/`Sqlite{…}`, `postgresql(…)`/`Postgresql{…}`, `inMemory`/`InMemory`. |
| `NovelTokenTaggerChoice` | `NovelTokenTaggerChoice` | See NovelTokenTaggerChoice parity table below. |
| `StorageError` | `StorageError` | Closed error enum. Swift: `throws`; Rust: `StorageResult<T>`. Twelve cases, case-for-case identical. |
| `InMemoryStorage` | `InMemoryStorage` | In-memory `Storage` conformer/implementor. |
| `SQLiteStorage` | `SqliteStorage` | SQLite backend (name idiom: `SQLite`/`Sqlite`). |
| `PostgreSQLStorage` | `PostgresStorage` | PostgreSQL backend (name idiom: `PostgreSQL`/`Postgres`). |
| `StorageStats` | `StorageStats` | Introspection snapshot. See § 9. |
| `StorageIntrospection` (protocol) | `StorageIntrospection` (trait) | Optional introspection capability. See § 9. |

### Replication module (swift+rust, incremental)

| Swift | Rust | Notes |
|---|---|---|
| `ReplicationCursor` | `ReplicationCursor` | Watermark after flush/hydrate: `hlcWatermark`/`hlc_watermark` (HLC?/Option<HLC>), `rowsWritten`/`rows_written` (Int/usize), `auditEventsWritten`/`audit_events_written` (Int/usize), `blobsWritten`/`blobs_written` (Int/usize). |
| `ReplicationError` | `ReplicationError` | Closed error enum: `schemaMismatch`/`SchemaMismatch`, `storageFailure`/`StorageFailure`. |
| `DirtySet` | `DirtySet` | Observer-fed dirty-row accumulator. Swift: `public actor DirtySet` (actor serializes access). Rust: `pub struct DirtySet` with `Mutex<BTreeSet<DirtyKey>>` (owned-state struct, no async runtime). Observable behaviour is identical: accumulate on change notification, drain before each sync run. |
| `IncrementalReplicationSession` | `IncrementalReplicationSession` | Session-oriented incremental replication: wires `StorageObserver` subscriptions to dirty-set accumulators and runs sync passes. Swift: `public final class IncrementalReplicationSession: Sendable`. Rust: `pub struct IncrementalReplicationSession`. |
| `BlobDirtySet` (Swift) | `BlobDirtyAccumulator` (Rust) | Blob-change dirty accumulator. The name differs by port convention; the contract is identical: accumulate `BlobChange` notifications, drain to get the (key, bytes) set to sync. |
| `EstateCacheConfig` | `EstateCacheConfig` | Cache layer config: `enabled`, byte ceiling, sensitivity threshold (clamped ≤ 2). |
| `CachingRowStore` | `CachingRowStore` | Decorating `RowStore` with InMemory hot tier and LRU eviction (SPEC I-11/I-12). |
| `CacheInvalidator` | `CacheInvalidator` | Subscribes to `StorageObserver` and invalidates cache entries on `TableChange` (SPEC B-14). |

### Rust-only types (no Swift public counterpart)

| Rust type | Source file | Reason for Rust-only |
|---|---|---|
| `DirtyKey` | `rust/src/incremental_replication.rs` | The Swift port has an internal (non-`public`) `struct DirtyKey` inside `IncrementalReplicationSession.swift`. The Rust port exposes it as `pub struct DirtyKey` because Rust's ownership model requires callers to construct and pass dirty keys explicitly. This is an implementation-visibility difference, not a parity gap in observable behaviour. |

### Swift-only types (no Rust public counterpart)

| Swift type | Source file | Reason for Swift-only |
|---|---|---|
| `StorageReplicator` | `Sources/PersistenceKitReplication/StorageReplicator.swift` | Caseless-enum namespace for the full-snapshot replication entry points (`replicate(from:to:schema:)`, `flush(from:into:schema:)`, `hydrate(into:from:schema:)`). Rust exposes identical operations as free functions (`replicate`, `flush`, `hydrate`) in `replication.rs`; there is no named namespace type. The audit regex does not match free functions by default; this is a shape-idiom difference, not a parity gap. |

### Encryption types

| Swift | Rust | Notes |
|---|---|---|
| `EncryptionMode` | `EncryptionMode` | Three cases: `plaintext`/`Plaintext`, `rowEncryption`/`RowEncryption`, `fullDatabase`/`FullDatabase`. Mode 3 (`fullDatabase`) is whole-file encryption — **SQLCipher on every platform** (CommonCrypto on Apple, OpenSSL FIPS on Rust), not per-row; the content seam is a no-op for it |
| `EstateEncryptionConfig` | `EstateEncryptionConfig` | `mode`, `keyIdentifier`/`key_identifier`, key is `package`/`pub(crate)` scoped. Constructors: `.plaintext` static / `plaintext()`, `init(_ mode:)` / `row_encryption()`, `full_database()`, and **`.fullDatabase(key:)` (Swift) / `full_database_with_key(key)` (Rust)** for the stable per-install key. Key source: **`KeychainKeyStore` (Swift)** loads/creates the per-install key in the Keychain; Rust uses `ensure_install_key(estates_dir)` / `INSTALL_KEY_FILE` (`db.key`) |
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
- **Fresh nonce per encrypt.** Never reuse a nonce under a given key (OsRng
  in Rust, `AES.GCM.Nonce()` in Swift — both use the OS CSPRNG).
- **No key logging.** Keys extracted to raw bytes for the provider interface;
  the local binding is not stored or logged.
- **Authentication on decrypt.** Tampered input throws, never returns corrupt plaintext.
- **Wire layout.** `[12-byte nonce][16-byte GCM tag][ciphertext]` in both ports,
  enabling cross-decryptability between Swift and Rust.

### At-rest encryption wiring in the SQLite backend (both ports)

Both the Swift `SQLiteBackend` and the Rust `SqliteRowStore` wire the
encryption seam at the storage layer:

| Path | Swift | Rust | Notes |
|---|---|---|---|
| Write (insert) | `encryptedForWrite` → encrypt `content` → stamp `keyID` | `encrypted_for_write` → encrypt `content` → stamp `keyID` | Only for `mode != .plaintext` and rows with a `content` column |
| Read (query / query_projected) | `decryptedForRead` → decrypt `content` | `decrypted_for_read` → decrypt `content` | Only when `keyID` matches estate key identifier |
| Upsert guard | `assertContentKeyIDInvariant` | `assert_content_key_id_invariant` | Rejects plaintext `content` on encrypting estate; encryption seam is not wired to upsert |
| Update guard | `assertContentKeyIDInvariant` | `assert_content_key_id_invariant` | Same guard; all current callers update non-content columns |

Column names intercepted: `"content"` and `"keyID"`. Plaintext mode is a
no-op on every path. Cross-port compatibility applies to Mode 2
(RowEncryption) only: a Mode 2 content value encrypted by the Swift backend
is decryptable by the Rust backend because both use AES-GCM-256 with the same
`[nonce][tag][ciphertext]` envelope layout and the same key bytes from
`EstateEncryptionConfig.key`. Mode 3 (FullDatabase) uses each platform's
native whole-file mechanism and is not cross-port byte-compatible; the ports
never share a file, so Mode 3 parity is behavioral, not byte-identical.

### EstateConfiguration field parity

| Field | Swift | Rust |
|---|---|---|
| Estate identifier | `estateID: UUID` | `estate_id: uuid::Uuid` |
| Backend selection | `backend: BackendConfiguration` | `backend: BackendConfiguration` |
| Encryption config | `encryptionConfig: EstateEncryptionConfig` | `encryption_config: EstateEncryptionConfig` |
| Cache config | `cacheConfig: EstateCacheConfig` | `cache_config: EstateCacheConfig` |
| Novel-token tagger | `novelTokenTagger: NovelTokenTaggerChoice` default `.hmm` | `novel_token_tagger: NovelTokenTaggerChoice` default `Hmm` |

### `NovelTokenTaggerChoice` parity (SPEC I-20)

| Concept | Swift | Rust | Notes |
|---|---|---|---|
| HMM tagger | `case hmm` | `Hmm` | Deterministic, cross-port, always valid |
| NLTagger | `case nlTagger` | `NlTagger` | Apple-only in Swift; schema-parity only in Rust; `new_with_tagger(NlTagger)` returns `StorageError::InvalidConfiguration` on Rust |
| Default | `.hmm` / `NovelTokenTaggerChoice.default` | `Default::default()` → `Hmm` | |
| Rust validation | Swift: both cases valid | Rust: `new_with_tagger(NlTagger)` returns `StorageError::InvalidConfiguration` | Fail-closed per SPEC I-20 |

---

## § 8 — PersistenceKitReplication module (full-snapshot)

The `PersistenceKitReplication` library target (Swift) and `replication` module
(Rust) expose a generic full-snapshot primitive for copying estates between storage
backends. No existing target gains a dependency on this library; consumers opt in
by adding the dependency explicitly.

### Types

| Type | Swift | Rust | Role |
|---|---|---|---|
| `ReplicationCursor` | `struct ReplicationCursor: Sendable, Equatable` | `struct ReplicationCursor` | Watermark returned after flush/hydrate |
| `ReplicationError` | `enum ReplicationError: Error, Sendable, Equatable` | `enum ReplicationError` | Closed error enum (schemaMismatch, storageFailure) |

### Entry points

| Name | Swift signature | Rust signature |
|---|---|---|
| `replicate` | `static func replicate(from:to:schema:) async throws -> ReplicationCursor` | `pub fn replicate(source, destination, schema) -> Result<ReplicationCursor, ReplicationError>` |
| `flush` | `static func flush(from:into:schema:) async throws -> ReplicationCursor` | `pub fn flush(source, destination, schema) -> Result<ReplicationCursor, ReplicationError>` |
| `hydrate` | `static func hydrate(into:from:schema:) async throws -> ReplicationCursor` | `pub fn hydrate(in_memory, durable, schema) -> Result<ReplicationCursor, ReplicationError>` |

### Swift/Rust concordance

| Behavioural contract | Swift | Rust |
|---|---|---|
| Schema gate | `source.currentSchemaVersion(for: schema.kitID)` vs `destination.currentSchemaVersion(for: schema.kitID)`, both must equal `schema.version` | global `current_schema_version()` compared against `schema.version`; Rust trait has no per-kit version |
| Atomicity | `destination.transaction(isolation: .serializable)` wrapping all row upserts + `auditLog.appendBatch` | `destination.transaction(IsolationLevel::Serializable, &mut \|txn\| { ... })` |
| Generated column filter | `Set(table.generatedColumns.map(\.name))` | `table.generated_columns.iter().map(\|g\| g.name.clone()).collect::<BTreeSet<_>>()` |
| Conflict columns | `table.primaryKey` (NOT `RowHandle.key`) | `table.primary_key` (NOT `RowHandle.key`) |
| Audit copy path | `source.auditLog.iterate(after: nil, rowID: nil, limit: Int.max)` → `txn.auditLog.appendBatch` | `source.audit_log().iterate(None, None, usize::MAX)` → `audit_log.append_batch` |
| Blob copy | `source.blobStore.listKeys()` → sort → `source.blobStore.get(key:)` each, then `txn.blobStore.put(key:bytes:)` inside the serializable transaction. Fail-loud on TOCTOU gap (key present in listKeys but absent in get). Idempotent: repeated flush with unchanged blobs is a no-op. | Same |
| HLC watermark | Max `HLC` across all row `.hlc` TypedValues + all `AuditEvent.hlc` | Same |

### ReplicationCursor fields

| Field | Swift | Rust | Meaning |
|---|---|---|---|
| HLC watermark | `hlcWatermark: HLC?` | `hlc_watermark: Option<HLC>` | Max HLC seen; `nil`/`None` if source was empty |
| Row count | `rowsWritten: Int` | `rows_written: usize` | Total rows upserted across all tables |
| Audit count | `auditEventsWritten: Int` | `audit_events_written: usize` | Total audit events copied |
| Blob count | `blobsWritten: Int` | `blobs_written: usize` | Total blobs written; 0 for an empty source or sourceless blob store |

### Source files

| Language | File |
|---|---|
| Swift | `Sources/PersistenceKitReplication/ReplicationTypes.swift` |
| Swift | `Sources/PersistenceKitReplication/StorageReplicator.swift` |
| Swift tests | `Tests/PersistenceKitReplicationTests/ReplicationConformanceTests.swift` |
| Rust | `rust/src/replication.rs` (module `replication`) |
| Package | `Package.swift` (product `PersistenceKitReplication`, target `PersistenceKitReplication`, testTarget `PersistenceKitReplicationTests`) |
| Rust module | `rust/src/lib.rs` (`pub mod replication;`) |

### Port differences

- The Rust `Storage` trait has no `currentSchemaVersion(for: kitID)`. The Rust
  replication gate uses the global `current_schema_version()` and compares it
  against `schema.version` directly. This is correct for single-kit-per-storage
  estates (the common case). Multi-kit estates require a
  `current_schema_version_for(kit_id)` addition to the Rust trait — a planned
  extension.

---

## § 9 — StorageIntrospection surface

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

## § 10 — Self-Report Telemetry Surface

Wires the existing `StorageIntrospection` / `StorageStats` surface to emit
DB-layer health metrics via IntellectusLib. Off by default.

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

The telemetry surface depends on IntellectusLib, the lightweight metrics-emission
library that carries the `report` sink and `StatSample` types. PersistenceKit
depends on it in both ports (Swift target and test targets; Rust crate via path
dependency). IntellectusLib has zero in-repo dependencies, so the
`PersistenceKit → IntellectusLib` edge introduces no layering cycle.

### Test sources

| Language | File | Tests |
|---|---|---|
| Swift | `Tests/PersistenceKitInMemoryTests/PersistenceKitTelemetryTests.swift` | 4 suites, 14 tests (InMemory backend) |
| Swift | `Tests/PersistenceKitSQLiteTests/PersistenceKitSQLiteTelemetryTests.swift` | 4 suites, 4 tests (SQLite backend) |
| Swift | `Tests/PersistenceKitInMemoryTests/GlobalTestLock.swift` | Actor mutex — Intellectus singleton isolation |
| Swift | `Tests/PersistenceKitSQLiteTests/GlobalTestLock.swift` | Actor mutex — Intellectus singleton isolation |
| Rust | `rust/tests/telemetry_tests.rs` | 10 tests (InMemory backend) |

---

*End of PersistenceKit Interface.*

## Changelog

### 1.1.1 -- 2026-06-18
Mode 3 is SQLCipher on every platform (CommonCrypto on Apple, implemented).
Added the Swift key API: `EstateEncryptionConfig.fullDatabase(key:)` and
`KeychainKeyStore` (the Apple per-install key source).

### 1.1.0 -- 2026-06-17
Planned encryption lockdown. Documented Mode 3 (`fullDatabase`) as whole-file
encryption (SQLCipher on Rust, Apple Data Protection on iOS), not per-row.
Added the Rust key-source surface: `EstateEncryptionConfig.full_database_with_key`,
`ensure_install_key`, `INSTALL_KEY_FILE`. Scoped the cross-port at-rest
byte-compatibility note to Mode 2; Mode 3 parity is behavioral.

### 1.0.1 -- 2026-06-15
Completed Swift/Rust concordance table in § 7: added core protocol and value type rows (Storage, StorageTransaction, IsolationLevel, RowStore, RowKey, StorageRow, RowHandle, BlobStore, BlobKey, AuditLog, StorageObserver, StorageEvent, TableChange, BlobEvent, BlobChange, NoOpObserver, TypedValue, Column, ColumnType, StoragePredicate, OrderDirection, OrderClause, SchemaDeclaration, TableDeclaration, ColumnDeclaration, IndexDeclaration, Migration, SchemaOperation, GeneratedColumn, GeneratedExpression, EstateConfiguration, BackendConfiguration, NovelTokenTaggerChoice, StorageError, InMemoryStorage, SQLiteStorage, PostgreSQLStorage, StorageStats, StorageIntrospection); added replication module rows (ReplicationCursor, ReplicationError, DirtySet, IncrementalReplicationSession, BlobDirtySet/BlobDirtyAccumulator, EstateCacheConfig, CachingRowStore, CacheInvalidator); documented DirtyKey as Rust-only and StorageReplicator as Swift-only with justification.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
