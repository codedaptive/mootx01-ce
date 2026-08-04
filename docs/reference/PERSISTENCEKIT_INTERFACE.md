---
title: PersistenceKit Interface
status: active
authors: MOOTx01 maintainers
date: 2026-08-03
version: 1.14.0
spec_type: kit
description: Public API surface for PersistenceKit in both the Swift and Rust ports.
package: PersistenceKit
languages: [swift, rust]
relates_to:
  - PERSISTENCEKIT_SPEC.md  (the contract this interface implements)
purpose: |
  Public API surface of PersistenceKit in both ports, in two tiers
  within § 2. Tier 1 is the CONSUMED CONTRACT — the Storage protocol
  and its five sub-store protocols (RowStore, BlobStore, AuditLog,
  StorageObserver, DatasetStore), the value model, schema declaration,
  predicate algebra, and the three backend entry points — documented in
  full with bilingual signatures. Tier 2 (§ 2's closing subsection) is
  the remaining public surface present in the package but not directly
  named by any consumer: a table of contents (name + role + source
  file). The companion SPEC carries the behavioral contracts
  (invariants I-1…I-27, conformance C-1…C-11).
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
  (No `VectorIndex.swift`: PersistenceKit owns no vector engine — the vector-ownership contract.)
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
  (No `vector_index.rs`: removed with the vector engine — the vector-ownership contract.)
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
sub-stores (rowStore, blobStore, auditLog, observer, datasetStore) and
the transaction/migration lifecycle (SPEC § 4, I-1).
`StorageIntrospection` is a separate optional-capability protocol, not
a Storage requirement.

**Swift:**

```swift
public protocol Storage: Sendable {
    var configuration: EstateConfiguration { get }
    var rowStore: any RowStore { get }
    var blobStore: any BlobStore { get }
    var auditLog: any AuditLog { get }
    var observer: any StorageObserver { get }
    /// Dataset store for user-defined tabular data (MX-TAB-1).
    /// Default implementation throws `StorageError.featureGated("datasetStore")`.
    /// SQLiteStorage and InMemoryStorage override with a concrete implementation.
    /// PostgreSQLStorage and third-party conformers inherit the default (SPEC B-18).
    var datasetStore: any DatasetStore { get throws }

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
    // Default datasetStore throws featureGated("datasetStore").
    var datasetStore: any DatasetStore { get throws }
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
    /// Dataset store for user-defined tabular data (MX-TAB-1).
    /// Default returns `Err(StorageError::FeatureGated { feature: "datasetStore" })`.
    /// SqliteStorage and InMemoryStorage override; PostgresStorage and others inherit the default.
    fn dataset_store(&self) -> StorageResult<Arc<dyn DatasetStore>>;
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
    /// Column-projecting query: returns only the named columns in each row.
    /// `nil` columns = full read. Default ignores projection and delegates
    /// to `query(…)`. Override on hot-path backends to avoid reading the
    /// content blob (the "no-blob recall path").
    func query(table: String, where predicate: StoragePredicate?,
               orderBy: [OrderClause], limit: Int?, offset: Int?,
               columns: [String]?) async throws -> [StorageRow]
    /// Best-effort corpus scan: skips rows with `StorageError.corruptStoredValue`
    /// rather than aborting. Returns `(cleanRows, skippedCount)`. Other errors
    /// are re-thrown. Default wraps `query(columns:)` and promotes a top-level
    /// `corruptStoredValue` to `([], 1)`. SQLiteStorage overrides for per-row skipping.
    func querySkipCorrupt(table: String, where predicate: StoragePredicate?,
                          orderBy: [OrderClause], limit: Int?, offset: Int?,
                          columns: [String]?) async throws -> (rows: [StorageRow], skipped: Int)
    // Explicit transaction boundary (GLK_BATCH1). Default is a no-op.
    // SQLiteRowStore overrides with BEGIN IMMEDIATE / COMMIT / ROLLBACK.
    // CachingRowStore delegates explicitly to its backing store.
    func beginTransaction() async throws
    func commitTransaction() async throws
    func rollbackTransaction() async throws
    // Sync-tagged write paths (SPEC B-19, CVK-ICLOUD P1-M1). Emit
    // TableChange with origin: .syncApply so ConvergenceKit's outbound
    // observer can discard inbound-sync writes (echo suppression, I-10).
    // Default implementations delegate to the ordinary write paths
    // (correct for non-sync conformers — origin tag is not needed there).
    func insertSync(table: String, values: [String: TypedValue]) async throws -> RowHandle
    func upsertSync(table: String, values: [String: TypedValue], conflictColumns: [String]) async throws -> RowHandle
    @discardableResult func deleteSync(table: String, where: StoragePredicate) async throws -> Int
}
public extension RowStore {
    func query(table: String, where predicate: StoragePredicate?) async throws -> [StorageRow] // orderBy [], no paging
    // As-of temporal variants (currently gated — returns
    // StorageError.featureGated("asOfQuery") for any non-present coordinate):
    func query(table: String, where predicate: StoragePredicate?,
               orderBy: [OrderClause], limit: Int?, offset: Int?,
               asOf: AsOfCoordinate?) async throws -> [StorageRow]
    func query(table: String, where predicate: StoragePredicate?,
               orderBy: [OrderClause], limit: Int?, offset: Int?,
               columns: [String]?, asOf: AsOfCoordinate?) async throws -> [StorageRow]
    func querySkipCorrupt(table: String, where predicate: StoragePredicate?,
                          orderBy: [OrderClause], limit: Int?, offset: Int?,
                          columns: [String]?, asOf: AsOfCoordinate?) async throws -> (rows: [StorageRow], skipped: Int)
}
```
**Rust:** `pub type RowKey = uuid::Uuid;` `pub trait RowStore: Send + Sync`
with `insert`, `upsert`, `update`, `delete`, `query`, `count`, plus
`query_projected(table, columns, predicate, order_by, limit, offset)` (column-projecting),
`query_skip_corrupt(table, predicate, order_by, limit, offset)` (corrupt-skip),
`query_projected_skip_corrupt(table, columns, predicate, order_by, limit, offset)` (projected + corrupt-skip),
as-of temporal variants `query_as_of`, `query_projected_as_of`, `query_skip_corrupt_as_of`
(all gated — return `StorageError::FeatureGated` for `AsOf` coordinate),
explicit transaction boundary `begin_transaction() / commit_transaction() / rollback_transaction()`
(no-op defaults; `SqliteRowStore` overrides with `BEGIN IMMEDIATE / COMMIT / ROLLBACK`),
and sync-tagged write paths `insert_sync`, `upsert_sync`, `delete_sync` with default
implementations that delegate to `insert` / `upsert` / `delete` (Rust federation uses
`pulling: Arc<AtomicBool>` for echo suppression; the defaults are correct for all backends).
All non-temporal methods return `StorageResult<…>`.
`StorageRow { values: HashMap<String, TypedValue> }`, `RowHandle { table, key }`.

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
type. Dense-embedding k-NN lives solely in VectorKit (the vector-ownership contract). Storage does
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

/// Origin of a TableChange — identifies whether the write was local or
/// an inbound sync application. Used by ConvergenceKit's outbound observer
/// to suppress the echo loop (I-10, SPEC B-19, CVK-ICLOUD P1-M1).
public enum ChangeOrigin: Sendable, Hashable {
    case local      // ordinary write — default
    case syncApply  // write from applyInbound — must not re-enter outbound queue
}

public struct TableChange: Sendable {
    public let table: String
    public let event: StorageEvent
    public let rowKey: RowKey?
    public let values: [String: TypedValue]?
    public let hlc: HLC?
    /// Origin of this change. Defaults to .local; set to .syncApply by the
    /// insertSync / upsertSync / deleteSync paths (SPEC B-19).
    public let origin: ChangeOrigin
    /// Columns that actually changed in this write (SPEC B-20, CVK-WB4).
    /// nil = unknown / all (delete, PostgreSQL backend, third-party conformers).
    /// Present on InMemory and SQLite backends for insert, update, and upsert.
    public let changedColumns: Set<String>?
    public init(table: String, event: StorageEvent, rowKey: RowKey? = nil,
                values: [String: TypedValue]? = nil, hlc: HLC? = nil,
                origin: ChangeOrigin = .local, changedColumns: Set<String>? = nil)
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
`pub enum ChangeOrigin { Local (default), SyncApply }`,
`pub struct TableChange { table, event, row_key, values, hlc, origin: ChangeOrigin, changed_columns: Option<HashSet<String>> }`,
`pub trait StorageObserver`, `pub struct NoOpObserver`.

#### `DatasetStore` / `DatasetSchema` / `DatasetIndexDeclaration` / `ColumnStats`

Typed row I/O for user-defined dataset tables (MX-TAB-1, SPEC § 5 B-18).
Accessed through `Storage.datasetStore`; reuses `StoragePredicate`, `OrderClause`,
and `TypedValue` — no new query language. Each dataset owns one backend table
(`ds_<uuid-no-hyphens>`). Column names are user-supplied and validated against
`[A-Za-z_][A-Za-z0-9_]*` before any DDL or DML — rejection throws
`StorageError.invalidIdentifier` with no sanitize-and-continue path (SPEC I-21).

**Swift:**

```swift
/// Column declarations and optional primary-key for a dataset table.
public struct DatasetSchema: Sendable {
    public let columns: [ColumnDeclaration]
    public let primaryKeyColumn: String?   // nil = backend synthetic key
    public init(columns: [ColumnDeclaration], primaryKeyColumn: String? = nil)
}

/// Single-column secondary index declaration for a dataset table.
public struct DatasetIndexDeclaration: Sendable {
    public let column: String    // user-supplied; validated before DDL
    public let unique: Bool
    public init(column: String, unique: Bool = false)
}

/// Per-column aggregate statistics computed in SQL by the backend.
/// min/max are `.null` when no non-null values exist.
/// Float values for REAL columns always use TypedValue.float(Double) — never
/// f32 — to guarantee identical JSON text across Swift and Rust legs.
public struct ColumnStats: Sendable, Equatable {
    public let count: Int64          // COUNT("col")
    public let distinctCount: Int64  // COUNT(DISTINCT "col")
    public let nullCount: Int64      // COUNT(*) - COUNT("col")
    public let min: TypedValue
    public let max: TypedValue
    public init(count: Int64, distinctCount: Int64, nullCount: Int64,
                min: TypedValue, max: TypedValue)
}

public protocol DatasetStore: Sendable {
    /// Create the backing table. Idempotent (CREATE TABLE IF NOT EXISTS).
    func createDataset(id: UUID, schema: DatasetSchema,
                       indexes: [DatasetIndexDeclaration]) async throws
    /// Bulk-insert rows. Pre-sorts by primaryKeyColumn when declared.
    func appendRows(id: UUID, rows: [[String: TypedValue]]) async throws
    /// Column-projecting predicate query. columns nil = all columns.
    func queryRows(id: UUID, predicate: StoragePredicate?,
                   orderBy: [OrderClause], limit: Int?, offset: Int?,
                   columns: [String]?) async throws -> [StorageRow]
    /// Per-column aggregate statistics (COUNT, COUNT DISTINCT, MIN, MAX, NULL count).
    func columnStats(id: UUID, column: String) async throws -> ColumnStats
    /// Drop backing table. DROP TABLE IF EXISTS semantics — no-op if absent.
    func dropDataset(id: UUID) async throws
}

/// Validate a user-supplied dataset column name as a SQL identifier.
/// Accepts [A-Za-z_][A-Za-z0-9_]* only. Throws StorageError.invalidIdentifier otherwise.
public func validateDatasetColumnIdentifier(_ name: String) throws

/// Derive backing table name: `ds_` + UUID hex with hyphens stripped.
public func datasetTableName(_ id: UUID) -> String

/// Derive index name: `dsi_<uuid-no-hyphens>_<column>`.
public func datasetIndexName(_ id: UUID, column: String) -> String
```

**Rust:** `pub struct DatasetSchema { columns: Vec<ColumnDeclaration>, primary_key_column: Option<String> }`,
`pub struct DatasetIndexDeclaration { column: String, unique: bool }`,
`pub struct ColumnStats { count: i64, distinct_count: i64, null_count: i64, min: TypedValue, max: TypedValue }`,
`pub trait DatasetStore: Send + Sync` with `create_dataset`, `append_rows`, `query_rows`, `column_stats`,
`drop_dataset` — all returning `StorageResult<…>`. Free functions `validate_dataset_column_identifier`,
`dataset_table_name`, `dataset_index_name` in `dataset_store.rs`.
`pub struct InMemoryDatasetStore` provides the test-double `DatasetStore` implementation.

**Backends:** SQLite and InMemory override `Storage.datasetStore` / `dataset_store()` with a
concrete implementation. PostgreSQL (MX-TAB-2) and other conformers inherit the default
`featureGated("datasetStore")` error.

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
**Rust:** `pub struct EstateConfiguration { estate_id, backend, encryption_config, cache_config, novel_token_tagger, residency_hint }`.
The Rust version carries all six fields, mirroring the Swift struct field-for-field.
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
> removed with the vector engine — the vector-ownership contract.)

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
// dense-embedding k-NN is VectorKit's, not PersistenceKit's (the vector-ownership contract).
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
    case corruptStoredValue(table: String, column: String, storedText: String)
    case invalidConfiguration(reason: String)
    case featureGated(feature: String)
    /// A caller-supplied SQL identifier (column or table name) contains
    /// characters outside `[A-Za-z_][A-Za-z0-9_]*`. Thrown by insert,
    /// upsert, update, and queryProjected before any SQL is constructed
    /// (SPEC I-21 — CAND-047, landed 2026-06-28).
    case invalidIdentifier(name: String)
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
    CorruptStoredValue { table: String, column: String, stored_text: String },
    InvalidConfiguration { reason: String },
    FeatureGated { feature: String },
    /// A caller-supplied SQL identifier (column or table name) contains
    /// characters outside `[A-Za-z_][A-Za-z0-9_]*`. Thrown by insert,
    /// upsert, update, and query_projected before any SQL is constructed
    /// (SPEC I-21 — CAND-047, landed 2026-06-28).
    InvalidIdentifier { name: String },
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
| `RowStore` (protocol) | `RowStore` (trait) | Typed row I/O. Core: `insert`, `upsert`, `update`, `delete`, `query`, `count`. Column-projecting: `query(columns:)` / `query_projected`. Corrupt-skip: `querySkipCorrupt(columns:)` / `query_skip_corrupt`, `query_projected_skip_corrupt`. Explicit transaction boundary: `beginTransaction/commitTransaction/rollbackTransaction` / `begin_transaction/commit_transaction/rollback_transaction` (no-op defaults; SQLiteRowStore overrides). As-of temporal (gated — `featureGated("asOfQuery")` for any `AsOf` coordinate): `query(asOf:)` / `query_as_of`, `query(columns:asOf:)` / `query_projected_as_of`, `querySkipCorrupt(columns:asOf:)` / `query_skip_corrupt_as_of`. Swift `async throws` / Rust synchronous `StorageResult`. |
| `RowKey` (typealias `UUID`) | `RowKey` (type alias `uuid::Uuid`) | Primary key type. |
| `StorageRow` | `StorageRow` | `values: [String: TypedValue]` / `HashMap<String, TypedValue>`. |
| `RowHandle` | `RowHandle` | `table: String`, `key: RowKey`. |
| `BlobStore` (protocol) | `BlobStore` (trait) | Opaque byte I/O. `put`, `get`, `delete`, `exists`, `size`. |
| `BlobKey` (typealias `String`) | `BlobKey` (type alias `String`) | Blob key type. |
| `AuditLog` (protocol) | `AuditLog` (trait) | Append-only HLC-ordered audit. `append`, `appendBatch`/`append_batch`, `iterate`, `eventsForRow`/`events_for_row`, `count`. |
| `StorageObserver` (protocol) | `StorageObserver` (trait) | Change notification. `observe(table:events:)` / `observe(table, events)`. Swift returns `AsyncStream<TableChange>`; Rust returns `mpsc::Receiver<TableChange>` — sanctioned seam. |
| `StorageEvent` | `StorageEvent` | Three cases: `insert`/`Insert`, `update`/`Update`, `delete`/`Delete`. |
| `TableChange` | `TableChange` | Row change notification: `table`, `event`, `rowKey`/`row_key`, `values`, `hlc`, `origin`, `changedColumns`/`changed_columns` (SPEC B-19, B-20). |
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
| `ColumnDeclaration` | `ColumnDeclaration` | Column manifest: `name`, `type`/`col_type`, `nullable`, `defaultValue`/`default_value`, `role: ColumnRole?`/`role: Option<ColumnRole>`. |
| `ColumnRole` | `ColumnRole` | Semantic role for temporal filtering (the node-integrity contract §15). Two cases: `createdHlc`/`CreatedHlc`, `tombstonedHlc`/`TombstonedHlc`. |
| `IndexDeclaration` | `IndexDeclaration` | Index manifest: `name`, `table`, `columns`, `unique`. |
| `Migration` | `Migration` | Schema migration step: `fromVersion`/`from_version` (Int/i32), `toVersion`/`to_version` (Int/i32), `operations` ([SchemaOperation]/Vec<SchemaOperation>). |
| `SchemaOperation` | `SchemaOperation` | Closed migration-operation enum: `createTable`/`CreateTable`, `dropTable`/`DropTable`, `addColumn`/`AddColumn`, `dropColumn`/`DropColumn`, `renameColumn`/`RenameColumn`, `addIndex`/`AddIndex`, `dropIndex`/`DropIndex`, `custom(sqlite:postgresql:)`/`Custom{sqlite,postgresql}` (per-backend SQL escape hatch). |
| `GeneratedColumn` | `GeneratedColumn` | Computed column: `name`, `type`/`col_type`, `expression`. |
| `GeneratedExpression` | `GeneratedExpression` | Integer expression algebra. Swift: `public indirect enum` (recursive). Rust: `pub enum`. Same cases: `column`/`Column`, `literal`/`Literal`, `bitAnd`/`BitAnd`, `bitOr`/`BitOr`, `bitXor`/`BitXor`, `shiftRight`/`ShiftRight`, `shiftLeft`/`ShiftLeft`, `equal`/`Equal`, `notEqual`/`NotEqual`. Audit regex limitation as for `StoragePredicate`. |
| `EstateConfiguration` | `EstateConfiguration` | See EstateConfiguration field parity table below. |
| `BackendConfiguration` | `BackendConfiguration` | Three cases: `sqlite(url:busyTimeout:)`/`Sqlite{…}`, `postgresql(…)`/`Postgresql{…}`, `inMemory`/`InMemory`. |
| `NovelTokenTaggerChoice` | `NovelTokenTaggerChoice` | See NovelTokenTaggerChoice parity table below. |
| `ResidencyHint` | `ResidencyHint` | the storage-residency rule: `.diskBacked`/`DiskBacked` (default), `.ramResident`/`RamResident`. Kits read this to choose index caching strategy. |
| `StorageError` | `StorageError` | Closed error enum. Swift: `throws`; Rust: `StorageResult<T>`. Fifteen cases, case-for-case identical. |
| `InMemoryStorage` | `InMemoryStorage` | In-memory `Storage` conformer/implementor. |
| `SQLiteStorage` | `SqliteStorage` | SQLite backend (name idiom: `SQLite`/`Sqlite`). |
| `PostgreSQLStorage` | `PostgresStorage` | PostgreSQL backend (name idiom: `PostgreSQL`/`Postgres`). |
| `StorageStats` | `StorageStats` | Introspection snapshot. See § 9. |
| `StorageIntrospection` (protocol) | `StorageIntrospection` (trait) | Optional introspection capability. See § 9. |

### Dataset store (MX-TAB-1, swift+rust)

| Swift | Rust | Notes |
|---|---|---|
| `DatasetStore` (protocol) | `DatasetStore` (trait) | Typed row I/O for user-defined dataset tables. Reached via `Storage.datasetStore` / `Storage::dataset_store()`. Methods: `createDataset`/`create_dataset`, `appendRows`/`append_rows`, `queryRows`/`query_rows`, `columnStats`/`column_stats`, `dropDataset`/`drop_dataset`. Swift `async throws` / Rust `StorageResult`. Default on `Storage` throws/returns `featureGated("datasetStore")`. |
| `DatasetSchema` | `DatasetSchema` | `columns: [ColumnDeclaration]` / `Vec<ColumnDeclaration>`, `primaryKeyColumn: String?` / `primary_key_column: Option<String>`. |
| `DatasetIndexDeclaration` | `DatasetIndexDeclaration` | `column: String`, `unique: bool`/`Bool`. |
| `ColumnStats` | `ColumnStats` | Aggregate stats: `count`/`distinct_count`/`null_count` (Int64/i64), `min`/`max` (TypedValue). Float values for REAL columns use TypedValue.float(Double) / TypedValue::Float(f64) — f64 only, enforcing the cross-leg wire rule. |
| `validateDatasetColumnIdentifier(_:)` (free func) | `validate_dataset_column_identifier` (free fn) | Validates `[A-Za-z_][A-Za-z0-9_]*`; throws/returns `StorageError.invalidIdentifier` otherwise. Shared seam for all backends. |
| `datasetTableName(_:)` (free func) | `dataset_table_name` (free fn) | Derives backing table name: `ds_` + UUID hex with hyphens stripped. Generated internally — never user-supplied. |
| `datasetIndexName(_:column:)` (free func) | `dataset_index_name` (free fn) | Derives index name: `dsi_<uuid-no-hyphens>_<column>`. |
| — | `InMemoryDatasetStore` | Rust-only public struct providing the in-memory `DatasetStore` implementation. Swift's InMemory implementation is internal to `InMemoryStorage`. |

### Replication module (swift+rust, incremental)

| Swift | Rust | Notes |
|---|---|---|
| `ReplicationCursor` | `ReplicationCursor` | Watermark after flush/hydrate: `hlcWatermark`/`hlc_watermark` (HLC?/Option<HLC>), `rowsWritten`/`rows_written` (Int/usize), `auditEventsWritten`/`audit_events_written` (Int/usize), `blobsWritten`/`blobs_written` (Int/usize). |
| `ReplicationError` | `ReplicationError` | Closed error enum: `schemaMismatch`/`SchemaMismatch`, `storageFailure`/`StorageFailure`. |
| `DirtySet` | `DirtySet` | Observer-fed dirty accumulator. Swift: `public actor DirtySet` (actor serializes access). Rust: `pub struct DirtySet` with `Mutex`-guarded sets (owned-state struct, no async runtime). Observable behaviour is identical: accumulate on change notification, drain before each sync run. **Tracks dirt at three resolutions**, because the durable backends do not always emit primary-key values: rows it can name; tables it cannot name but can re-scan (a `TableChange` with absent or PK-incomplete `values` marks its whole table); and tables that declare no primary key, which can be neither named nor reconciled. A value-less change is NEVER discarded. Inspection: `count()` (named rows only), `pendingRescanTables()` / `pending_rescan_tables`, `pendingUnresolvableTables()` / `pending_unresolvable_tables`. |
| `DirtyDrain` | `DirtyDrain` | One atomic drain of all three resolutions — `keys`, `rescanTables`/`rescan_tables`, `unresolvableTables`/`unresolvable_tables`, plus `isEmpty`/`is_empty`. Returned by `DirtySet.drain()` and accepted by `DirtySet.restore(_:)`; draining or restoring a subset is not expressible, so table-granularity dirt cannot be lost on a retry. Swift: internal `struct DirtyDrain: Sendable`. Rust: `pub struct DirtyDrain`. |
| `IncrementalReplicationSession` | `IncrementalReplicationSession` | Session-oriented incremental replication: wires `StorageObserver` subscriptions to dirty-set accumulators and runs sync passes. Swift: `public final class IncrementalReplicationSession: Sendable`. Rust: `pub struct IncrementalReplicationSession`. `sync` returns `IncrementalSyncOutcome`, not a bare `ReplicationCursor`. A table marked for re-scan is read in full: every source row is upserted and every destination row whose primary key is absent from the source is deleted — the row-level form of the blob reconciliation in the full-snapshot path (§3d, SECFIX-WS2-PK F5). The early return fires only when nothing at all was observed, never for changes that could not be keyed. |
| `IncrementalSyncOutcome` | `IncrementalSyncOutcome` | Result of one incremental cycle: `cursor` (the `ReplicationCursor` to persist), `rescannedTables`/`rescanned_tables` (tables read in full this cycle), `unresolvedTables`/`unresolved_tables` (tables carrying a change resolvable at no granularity), and `isComplete`/`is_complete()`. A non-empty unresolved list means the cycle was INCOMPLETE: no audit events were copied and `cursor.hlcWatermark` carries the INCOMING watermark unchanged, so the next cycle re-reads the same range. Resolvable row work still propagates. **`unresolvable` and `unresolved` are not synonyms and the difference is deliberate:** `DirtySet.pendingUnresolvableTables` / `pending_unresolvable_tables` names a property of the TABLE — it declares no primary key, so it can *never* be reconciled — while `unresolvedTables` / `unresolved_tables` here names a property of the CYCLE: what this run failed to resolve. Declared in the session's own source file on both ports, not alongside `ReplicationCursor`: the cursor is the durable watermark, cycle resolution is a per-run report. Swift: `public struct IncrementalSyncOutcome: Sendable, Equatable`. Rust: `pub struct IncrementalSyncOutcome`. |
| `BlobDirtySet` (Swift) | `BlobDirtyAccumulator` (Rust) | Blob-change dirty accumulator. The name differs by port convention; the contract is identical: accumulate `BlobChange` notifications, drain to get the (key, bytes) set to sync. |
| `EstateCacheConfig` | `EstateCacheConfig` | Cache layer config: `enabled`, byte ceiling, sensitivity threshold (clamped ≤ 2). |
| `CachingRowStore` | `CachingRowStore` | Decorating `RowStore` with InMemory hot tier and LRU eviction (SPEC I-11/I-12). Present and as-of reads key separately (SPEC B-16). Accepts an optional `ParentChainProvider` callback for Merkle-aggregate chain invalidation (SPEC B-17). Swift: `init(backing:config:parentChainProvider:)` with `parentChainProvider` defaulting to `nil`. Rust: `new(backing, config)` (no callback) or `with_parent_chain(backing, config, provider)`. |
| `ParentChainProvider` | `ParentChainProvider` | Public typealias / type alias for the parent-chain callback passed to `CachingRowStore` at construction. Swift: `public typealias ParentChainProvider = @Sendable (String, RowKey) -> [RowHandle]`. Rust: `pub type ParentChainProvider = Box<dyn Fn(&str, RowKey) -> Vec<RowHandle> + Send + Sync>`. Must return synchronously; must not re-enter the same `CachingRowStore` (SPEC B-17). |
| `CacheInvalidator` | `CacheInvalidator` | Subscribes to `StorageObserver` and invalidates cache entries on `TableChange` (SPEC B-14). |

### Hash-on-write decorator (NT-P2)

| Swift | Rust | Notes |
|---|---|---|
| `HashingRowStore` | `HashingRowStore` | `RowStore` decorator that intercepts writes to hashable tables, computes a `ContentHash` via an injected callback, and emits `DirtyChainEvent` notifications. Swift: `public final class HashingRowStore: RowStore, @unchecked Sendable`. Rust: `pub struct HashingRowStore`. PersistenceKit does not import substrate-lib; the hash function is supplied by the consuming kit (e.g. LocusKit passes `MerkleHash::leaf`). NT-P2. |
| `HashOnWriteConfig` | `HashOnWriteConfig` | Configuration for the `HashingRowStore` decorator. Swift: `public struct HashOnWriteConfig: Sendable`. Rust: `pub struct HashOnWriteConfig`. Three fields: `hashableTables`/`hashable_tables` (set of table names to intercept), `hashProvider`/`hash_provider` (`ContentHashProvider` callback), `parentChainProvider`/`parent_chain_provider` (`HashParentChainProvider` callback). NT-P2. |
| `ContentHashProvider` | `ContentHashProvider` | Callback type that computes a `ContentHash` for a row. Swift: `public typealias ContentHashProvider = @Sendable (_ table: String, _ rowKey: RowKey, _ values: [String: TypedValue]) -> ContentHash`. Rust: `pub type ContentHashProvider = Box<dyn Fn(&str, RowKey, &BTreeMap<String, TypedValue>) -> ContentHash + Send + Sync>`. Caller (e.g. LocusKit) supplies `MerkleHash::leaf` or an accelerated kernel variant. NT-P2. |
| `HashParentChainProvider` | `HashParentChainProvider` | Callback type that returns the Merkle containment parent chain for a row. Swift: `public typealias HashParentChainProvider = @Sendable (...) -> (parentNodeId: UUID, grandparentNodeId: UUID)?`. Rust: `pub type HashParentChainProvider = Box<dyn Fn(&str, RowKey) -> Option<(uuid::Uuid, uuid::Uuid)> + Send + Sync>`. Returns `nil`/`None` for rows without a parent chain (root nodes, non-Merkle tables). NT-P2. |
| `DirtyChainEvent` | `DirtyChainEvent` | Three-identifier dirty-chain event emitted by `HashingRowStore` on every write to a hashable table. Swift: `public struct DirtyChainEvent: Sendable`. Rust: `pub struct DirtyChainEvent`. Five fields: `changedRowId`/`changed_row_id`, `parentNodeId`/`parent_node_id`, `grandparentNodeId`/`grandparent_node_id` (UUID/Uuid), `contentHash`/`content_hash` (ContentHash), `table` (String). Consumed by `CachingRowStore` (Merkle invalidation, NT-P4) and Merkle rollup (NT-L3). NT-P2. |

### Snapshot registry (Swift and Rust)

Snapshot and attestation primitives. Both legs ship in `Sources/PersistenceKit/SnapshotRegistry.swift` (Swift) and `rust/src/snapshot_registry.rs` (Rust). The registry records WHEN (an HLC); attestation rows record WHAT the Merkle roots were at that HLC. PersistenceKit owns these primitives; they are not LocusKit types.

| Swift | Rust | Notes |
|---|---|---|
| `SnapshotId` (`struct SnapshotId: Sendable, Hashable, CustomStringConvertible`) | `pub struct SnapshotId { pub raw_value: String }` | Opaque string identifier for a snapshot, keyed by `rawValue: String` (Swift) / `raw_value: String` (Rust). String-typed for cross-backend portability (SQLite TEXT PK, PostgreSQL TEXT PK, InMemory dict key). Swift: `public init(_ rawValue: String)` + `static func mint() -> SnapshotId`. Rust: `pub fn new(raw_value)` + `pub fn mint() -> Self`. |
| `SnapshotRecord` (`struct SnapshotRecord: Sendable, Equatable`) | `pub struct SnapshotRecord` | Snapshot registry row. Fields: `snapshotId`/`snapshot_id` (`SnapshotId`), `hlc` (`HLC`), `label` (`String?`/`Option<String>`), `createdAt`/`created_at` (`Date`/`i64` wall-clock seconds since Unix epoch). |
| `SnapshotAttestation` (`struct SnapshotAttestation: Sendable, Equatable`) | `pub struct SnapshotAttestation` | Attestation row. Fields: `snapshotId`/`snapshot_id` (`SnapshotId`), `subjectKind`/`subject_kind` (`String`), `subjectId`/`subject_id` (`String`), `merkleRoot`/`merkle_root` (`String`), `keyVersion`/`key_version` (`Int64?`/`Option<i64>`) — HMAC key version when this attestation is commitment-bearing (§17); `nil`/`None` for non-commitment attestations. |
| `SnapshotTables` (`enum SnapshotTables`) | Constants `SNAPSHOT_REGISTRY_TABLE`, `SNAPSHOT_ATTESTATIONS_TABLE` (`&str`) | Swift: caseless-enum namespace with `static let registry = "snapshot_registry"` and `static let attestations = "snapshot_attestations"`. Rust: two `pub const &str` values in `snapshot_registry.rs`. Same string values on both legs. |
| `SnapshotSchema` (`enum SnapshotSchema`) | `pub fn registry_table_declaration()`, `pub fn attestations_table_declaration()` | Swift: caseless-enum namespace with `static let registryTable: TableDeclaration` and `static let attestationsTable: TableDeclaration`. Rust: two `pub fn` returning `TableDeclaration`. Both produce identical schema: `snapshot_registry(snapshot_id TEXT PK, hlc HLC, label TEXT?, created_at TIMESTAMP)` and `snapshot_attestations(snapshot_id TEXT, subject_kind TEXT, subject_id TEXT, merkle_root TEXT, key_version INT?, PK(snapshot_id, subject_kind, subject_id))`. |
| `SnapshotRegistryOps` (`enum SnapshotRegistryOps`) | Free functions in `snapshot_registry.rs` | Swift: caseless-enum namespace with four `public static` funcs: `createSnapshot(rowStore:hlc:label:createdAt:attestations:) async throws -> SnapshotRecord`, `listSnapshots(rowStore:) async throws -> [SnapshotRecord]`, `deleteSnapshot(rowStore:snapshotId:) async throws -> Bool`, `attestations(rowStore:snapshotId:) async throws -> [SnapshotAttestation]`. Rust: equivalent `pub fn create_snapshot(…) -> StorageResult<SnapshotRecord>`, `pub fn list_snapshots(…) -> StorageResult<Vec<SnapshotRecord>>`, `pub fn delete_snapshot(…) -> StorageResult<bool>`, `pub fn snapshot_attestations(…) -> StorageResult<Vec<SnapshotAttestation>>`. Semantics identical on both legs. |

#### GC pin (Swift and Rust)

| Swift | Rust | Notes |
|---|---|---|
| `GCPin` (`enum GCPin`) | Free functions in `rust/src/gc_pin.rs` | Swift: caseless-enum namespace with `static func minimumRetainableHlc(rowStore:) async throws -> HLC?` and `static func isPinned(rowStore:rowHlc:) async throws -> Bool`. Rust: `pub fn minimum_retainable_hlc(row_store: &dyn RowStore) -> StorageResult<Option<HLC>>` and `pub fn is_pinned(row_store: &dyn RowStore, row_hlc: HLC) -> StorageResult<bool>` — free functions in `persistence_kit::gc_pin`, not a type. The caseless-enum namespace type has no Rust counterpart; the operations are present on both legs with identical GC-pin semantics. |

### Rust-only types (no Swift public counterpart)

| Rust type | Source file | Reason for Rust-only |
|---|---|---|
| `DirtyKey` | `rust/src/incremental_replication.rs` | The Swift port has an internal (non-`public`) `struct DirtyKey` inside `IncrementalReplicationSession.swift`. The Rust port exposes it as `pub struct DirtyKey` because Rust's ownership model requires callers to construct and pass dirty keys explicitly. This is an implementation-visibility difference, not a parity gap in observable behaviour. |
| `PostgresTlsMode` | `rust/src/postgres_tls.rs` | TLS mode knob for PostgreSQL connections (SECFIX-WS2-PK F3). `pub enum PostgresTlsMode`: three variants — `Disable` (plaintext, loopback/Unix-socket only), `Prefer` (attempt TLS; fall back if server does not support), `Require` (TLS mandatory; fail if server does not offer). Parsed from `ARIA_MCP_POSTGRES_TLS` env var via `PostgresTlsMode::from_env()`; unknown values default to `Prefer` (safe default). Swift uses NIOSSL transport wired directly in `PostgreSQLPool.swift`; there is no named Swift enum. |
| `SslModeRank` | `rust/src/postgres_tls.rs` | Security ranking for libpq `sslmode` values (SECFIX-WS2-PK F3). `pub enum SslModeRank`: six variants ordered weakest-to-strongest — `Disable`, `Allow`, `Prefer`, `Require`, `VerifyCa`, `VerifyFull`. Implements `PartialOrd`/`Ord` so the no-downgrade rule `max(env_rank, dsn_rank)` reduces to an `Ord` comparison. `pub fn from_str(s: &str) -> Option<Self>` parses libpq sslmode strings; `pub fn as_str(self) -> &'static str` serialises back. No Swift counterpart; the Swift pool does not expose a separate rank type. |
| `effective_sslmode` (free fn) | `rust/src/postgres_tls.rs` | No-downgrade sslmode computation (SECFIX-WS2-PK F3). Signature: `pub fn effective_sslmode(conn_str: &str, env_mode: PostgresTlsMode) -> (String, bool)`. Returns `(effective_conn_str, use_tls)`. Applies `max(env_mode_rank, dsn_sslmode_rank)`: the env var may raise security above the DSN's explicit setting, but must never lower it. Unrecognised DSN sslmode values are preserved verbatim and a TLS connector is mandated. Called by `Pool::open_connection` in `postgres.rs` before constructing the transport. No Swift counterpart. |

### Swift-only types (no Rust public counterpart)

| Swift type | Source file | Reason for Swift-only |
|---|---|---|
| `StorageReplicator` | `Sources/PersistenceKitReplication/StorageReplicator.swift` | Caseless-enum namespace for the full-snapshot replication entry points (`replicate(from:to:schema:)`, `flush(from:into:schema:)`, `hydrate(into:from:schema:)`). Rust exposes identical operations as free functions (`replicate`, `flush`, `hydrate`) in `replication.rs`; there is no named namespace type. The audit regex does not match free functions by default; this is a shape-idiom difference, not a parity gap. |
| `ErasureLedgerEntry` | `Sources/PersistenceKit/ErasureLedger.swift:15` | Ledger row for expunge provenance (the node-integrity contract §13). Swift: `public struct ErasureLedgerEntry: Sendable, Equatable`. Records that a row id was erased — stores the fact of erasure, never the content. Rust parity pending; NT-P3/L4. |
| `ErasureOverlay` | `Sources/PersistenceKit/ErasureOverlay.swift:50` | Read-path decorator (caseless enum namespace) that hides expunged content. Swift: `public enum ErasureOverlay`. Two-phase fail-closed: any row id in the erasure ledger returns payload nulled regardless of which temporal version was selected (the node-integrity contract §14). Rust parity pending; NT-P3. |
| `ErasureOverlayConfig` | `Sources/PersistenceKit/ErasureOverlay.swift:22` | Configuration for the `ErasureOverlay` decorator. Swift: `public struct ErasureOverlayConfig: Sendable`. Rust parity pending; NT-P3. |
| `GCPin` | `Sources/PersistenceKit/GCPin.swift:17` | Snapshot-aware garbage collection pin (caseless enum namespace). Swift: `public enum GCPin`. Rust ships equivalent free functions (`minimum_retainable_hlc`, `is_pinned`) in `rust/src/gc_pin.rs`; there is no Rust type named `GCPin`. See "GC pin" cross-leg table in the Snapshot registry subsection above. |

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
| Write (insert / upsert / update) | `encryptedForWrite` → encrypt protected columns → stamp `keyID` | `encrypted_for_write` → encrypt protected columns → stamp `keyID` | Every write verb seals. Only for `mode != .plaintext` and tables declaring protected columns |
| Read (query / query_projected) | `decryptedForRead` → decrypt protected columns | `decrypted_for_read` → decrypt protected columns | Only when `keyID` matches estate key identifier |
| Write-boundary guard (all verbs) | `assertContentKeyIDInvariant` | `assert_content_key_id_invariant` | Runs beneath the seam on insert, upsert and update. Rejects non-empty TEXT in a protected column on an encrypting estate regardless of `keyID` — ciphertext is a blob, so text means the seam did not run. Blob, null/absent and empty text (erasure scrub) are accepted |

Interception is by **(table, column) pair**, never by column name alone. The
protected columns are `"content"`, `"distilled"` and `"subject"` on the
`drawers` table; `"keyID"` is the key-identifier column the seam stamps on
every row it seals. A table absent from the map passes through untouched in
both directions and never receives a `keyID` stamp.

A table joins the map only when it BOTH carries content or content-derived
text AND declares a `keyID` column — the seam stamps `keyID` on write, so a
mapped table without that column would produce a write naming a column that
does not exist. `drawers` is currently the only table in the schema declaring
`keyID`, which makes the map maximal rather than merely current. Two shapes
are deliberately outside it: `kg_facts.subject` (the subject term of an S-P-O
triple, indexed for equality, on a table with no `keyID`) and dataset tables
`ds_<uuid>` (caller-supplied column names, no `keyID` — a boundary, not
protection: such a column is written in the clear on an encrypting estate).

That pair is not an inventory of every content-bearing column in the estate.
`corpus_documents.text` and `.dense_text` hold document body text on the same
physical database through the same seam and are content-derived, but the table
declares no `keyID`, so they are at rest in the clear. That is an open gap
awaiting a schema change rather than a deliberate exemption, and it is tracked
as its own mission; Mode 2 is not an end-to-end at-rest content guarantee until
it closes. Plaintext mode is a no-op on every path. Cross-port compatibility applies to Mode 2
(RowEncryption) only: a Mode 2 content value encrypted by the Swift backend
is decryptable by the Rust backend because both use AES-GCM-256 with the same
`[nonce][tag][ciphertext]` envelope layout and the same key bytes from
`EstateEncryptionConfig.key`. Mode 3 (FullDatabase) uses SQLCipher on every platform (CommonCrypto
backend on Apple, OpenSSL FIPS on Rust). Apple Data Protection and
FileVault are additive defense-in-depth layers, not the encryption
mechanism. The ports never share a physical file, so Mode 3 parity is
behavioral (same rows retrieved), not on-disk byte-identical.

### EstateConfiguration field parity

| Field | Swift | Rust |
|---|---|---|
| Estate identifier | `estateID: UUID` | `estate_id: uuid::Uuid` |
| Backend selection | `backend: BackendConfiguration` | `backend: BackendConfiguration` |
| Encryption config | `encryptionConfig: EstateEncryptionConfig` | `encryption_config: EstateEncryptionConfig` |
| Cache config | `cacheConfig: EstateCacheConfig` | `cache_config: EstateCacheConfig` |
| Novel-token tagger | `novelTokenTagger: NovelTokenTaggerChoice` default `.hmm` | `novel_token_tagger: NovelTokenTaggerChoice` default `Hmm` |
| Residency hint | `residencyHint: ResidencyHint` default `.diskBacked` | `residency_hint: ResidencyHint` default `DiskBacked` |

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

## § 11 — Layout signatures and table inventories (SPEC § 10)

### `SchemaDeclaration.layoutSignatureText()` / `layout_signature_text`

Canonical, cross-port byte-identical structural rendering of a schema
declaration (kitID/version deliberately excluded). Companion digest
helper for logs.

**Swift:**

```swift
extension SchemaDeclaration {
    public func layoutSignatureText() -> String
    public func layoutSignatureDigest() -> String   // FNV-1a 64, hex
}
extension TableDeclaration {
    public func layoutSignatureText() -> String
}
```

**Rust:**

```rust
pub fn layout_signature_text(schema: &SchemaDeclaration) -> String;
pub fn layout_signature_digest(schema: &SchemaDeclaration) -> String;
pub fn table_layout_signature_text(table: &TableDeclaration) -> String;
```

### `DatabaseInventory.capture` / `capture_inventory`

Deterministic per-table row counts + order-independent content folds
over canonically encoded rows, with per-table column exclusions for
wall-clock-stamped columns. See SPEC § 10 for the encoding table.

**Swift:**

```swift
public struct TableInventory: Sendable, Equatable {
    public let table: String
    public let rowCount: Int
    public let contentFold: String
}
public enum DatabaseInventory {
    public static func capture(
        storage: any Storage,
        tables: [String],
        excludingColumns: [String: Set<String>] = [:]
    ) async throws -> [TableInventory]
    public static func canonicalRowEncoding(_ row: StorageRow, excluding: Set<String>) -> String
    public static func canonicalValueEncoding(_ value: TypedValue) -> String
}
```

**Rust:**

```rust
pub struct TableInventory { pub table: String, pub row_count: usize, pub content_fold: String }
pub fn capture_inventory(
    storage: &Arc<dyn Storage>,
    tables: &[&str],
    excluding_columns: &BTreeMap<String, BTreeSet<String>>,
) -> StorageResult<Vec<TableInventory>>;
pub fn canonical_row_encoding(row: &StorageRow, excluded: &BTreeSet<String>) -> String;
pub fn canonical_value_encoding(value: &TypedValue) -> String;
```

---

*End of PersistenceKit Interface.*

## § 12 — Storage maintenance surface (SPEC § 11)

Swift (`PersistenceKit` core declares the protocol; backends conform):

```swift
public enum StorageMaintenancePhase: String, Sendable, Codable, CaseIterable {
    case preflight, walCheckpoint, vacuum, introspection
}
public struct StorageMaintenanceProgress: Sendable, Equatable {
    public let phase: StorageMaintenancePhase
    public let completedPhases: Int
    public let totalPhases: Int
}
public struct StorageMaintenanceReport: Sendable, Equatable, Codable {
    public let backend: String          // "sqlite" | "postgresql" | "inmemory"
    public let performed: Bool
    public let note: String?
    public let pageSizeBytes, pageCountBefore, pageCountAfter: Int64
    public let freelistPagesBefore, freelistPagesAfter: Int64
    public let fileSizeBytesBefore, fileSizeBytesAfter: Int64
    public let walBytesBefore, walBytesAfter: Int64
    public let reclaimedBytes: Int64
    public let durationSeconds: Double
}
public enum StorageMaintenanceError: Error, Equatable, Sendable {
    case notQuiescent(reason: String)
    case insufficientDiskCapacity(requiredBytes: Int64, availableBytes: Int64)
    case cancelled(atPhase: StorageMaintenancePhase)
    case backendFailure(reason: String)
}
public protocol StorageMaintenance: Sendable {
    func estimatedReclaimableBytes() async throws -> Int64
    func performMaintenance(
        progress: (@Sendable (StorageMaintenanceProgress) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) async throws -> StorageMaintenanceReport
}
// + zero-argument performMaintenance() convenience.
// Conformers: SQLiteStorage (real), InMemoryStorage and PostgreSQLStorage
// (explicit no-op reports). Probe with `storage as? StorageMaintenance`.
```

Rust (`persistence_kit::maintenance` module; defaulted `Storage` trait
methods because `dyn Storage` cannot be capability-probed):

```rust
pub enum MaintenancePhase { Preflight, WalCheckpoint, Vacuum, Introspection }
pub struct MaintenanceProgress { pub phase: MaintenancePhase,
    pub completed_phases: usize, pub total_phases: usize }
pub struct MaintenanceReport { /* field-for-field twin of the Swift report */ }
pub enum MaintenanceError { NotQuiescent { .. },
    InsufficientDiskCapacity { .. }, Cancelled { .. }, BackendFailure { .. } }

// On the Storage trait (default = explicit "not implemented" no-op):
fn estimated_reclaimable_bytes(&self) -> Result<i64, MaintenanceError>;
fn perform_maintenance(
    &self,
    progress: Option<&(dyn Fn(MaintenanceProgress) + Send + Sync)>,
    should_cancel: Option<&(dyn Fn() -> bool + Send + Sync)>,
) -> Result<MaintenanceReport, MaintenanceError>;
// Overridden by SqliteStorage (real), InMemoryStorage, PostgresStorage.
```

## Changelog

### 1.14.0 -- 2026-08-03
Corrected the intercepted-column contract (MXE-RW). The at-rest wiring
section said "Column names intercepted: `content` and `keyID`" — wording that
predated `distilled`, `subject` and the (table, column) map, and that
described interception by column name alone, which the seam has not done
since the table filter landed. It now names the protected columns per table,
states that interception is by (table, column) pair, and records the
inclusion rule: a table joins the map when it BOTH carries content or
content-derived text AND declares a `keyID` column, since the seam stamps
`keyID` on every row it seals. `kg_facts.subject` and dataset tables
`ds_<uuid>` are named as the two shapes deliberately outside the map, and the
dataset case is stated as a boundary rather than protection. The section also
now records that those two are not an inventory of every content-bearing
column: `corpus_documents.text` / `.dense_text` are content-derived text on a
table with no `keyID` and are at rest in the clear, an open gap tracked
separately, so Mode 2 is not an end-to-end at-rest content guarantee until it
closes. No signature or behavioural change.

### 1.13.0 -- 2026-08-03
At-rest encryption wiring table corrected (MXE-PW): the seam runs on
insert, upsert AND update in both ports and both backends, and the
write-boundary guard rejects non-empty text in a protected column
regardless of keyID. The previous table stated the seam was "not wired to
upsert" and that update callers only touched non-content columns; both
were false.

### 1.12.0 -- 2026-08-03
MXE-IR (Codex finding `74e3b7f7e6288191ba31644e4fa4b43b`): incremental
replication no longer discards observed changes it cannot attribute to a row.
`DirtySet` now tracks dirt at three resolutions and `DirtySet.drain` returns
`DirtyDrain` rather than `[DirtyKey]` / `Vec<DirtyKey>`;
`DirtySet.restore` takes the same type. `IncrementalReplicationSession.sync`
returns the new `IncrementalSyncOutcome` instead of a bare `ReplicationCursor`,
carrying the cycle's re-scanned and unresolved tables alongside it. The audit
watermark advances only for a cycle that resolved every observed change.
`ReplicationCursor` and `ReplicationError` are unchanged. Breaking for callers
of `sync`, `DirtySet.drain`, and `DirtySet.restore` (MINOR under this
document's numbering, which tracks surface additions; the session had no
in-repo production consumers at the time of the change). The
`IncrementalSyncOutcome` row states explicitly that `unresolvable` (a table that
can never be reconciled) and `unresolved` (what one cycle failed to resolve) are
distinct terms, not synonyms.

### 1.11.0 -- 2026-07-20
Shared-content 1.1 P5: added the storage maintenance surface (§ 12) —
`StorageMaintenance` protocol + phase/progress/report/error types (Swift),
`persistence_kit::maintenance` module + defaulted `Storage` trait methods
(Rust). Additive (MINOR).

### 1.10.0 -- 2026-07-20
GLK shared-content 1.1 P0: added § 11 — canonical layout signatures
(`layoutSignatureText` / `layout_signature_text` + digest helpers) and
deterministic table inventories (`DatabaseInventory` / `capture_inventory`).
Cross-port DDL parity fix: Rust `ColumnDeclaration::bitmap` now mints
`DEFAULT 0` (matching Swift) and the Rust SQLite emitter renders declared
column defaults. Additive (MINOR).

### 1.9.0 -- 2026-07-16
CVK-ICLOUD P1-M1: Added `ChangeOrigin` enum (`case local`, `case syncApply`)
and `origin: ChangeOrigin` field to `TableChange` in both ports (default `.local`).
Added sync-tagged write methods to `RowStore`: `insertSync` / `upsertSync` /
`deleteSync` (Swift) and `insert_sync` / `upsert_sync` / `delete_sync` (Rust),
each with default implementations that delegate to the ordinary write paths.
These emit `origin: .syncApply` / `ChangeOrigin::SyncApply` so ConvergenceKit's
outbound observer can discard `applyInbound` writes (echo suppression, SPEC B-19,
I-10). Updated § 2 Tier 1 RowStore block and StorageObserver block; updated Rust
concordance for both.

### 1.7.0 -- 2026-07-16
MX-TAB-1: Added DatasetStore protocol and its associated types — DatasetSchema,
DatasetIndexDeclaration, ColumnStats — plus helper free functions
validateDatasetColumnIdentifier / datasetTableName / datasetIndexName (both ports).
Added Storage.datasetStore (Swift throwing accessor) / Storage::dataset_store (Rust)
to the Storage protocol signature in § 2 Tier 1 and corrected the sub-store count
to five (rowStore, blobStore, auditLog, observer, datasetStore; StorageIntrospection
is a separate optional-capability protocol).
Added complete RowStore expansion in § 2 Tier 1: column-projecting query (query(columns:)
/ query_projected), corrupt-skip scan (querySkipCorrupt / query_skip_corrupt /
query_projected_skip_corrupt), explicit transaction boundary (beginTransaction /
commitTransaction / rollbackTransaction — no-op defaults, SQLiteRowStore overrides),
and the gated as-of temporal variants (query(asOf:) / query_as_of, etc.) — all were
present in source but missing from the doc. Updated § 7 concordance RowStore row to
cover all method groups. Added § 7 "Dataset store (MX-TAB-1)" concordance subsection.

### 1.6.0 -- 2026-06-28
SECFIX-WS2-PK: Added `StorageError.invalidIdentifier(name:)` /
`StorageError::InvalidIdentifier { name }` to the public error enum in both
ports (§ 4). The case was introduced by a prior mission but missing from this
document. Thrown by `insert`, `upsert`, `update`, and `queryProjected` when a
caller-supplied column name falls outside `[A-Za-z_][A-Za-z0-9_]*` (SPEC
I-21 — CAND-047). Also documents SPEC I-22 (CAND-052): SQLite backend refuses
a symlink at the DB path and sets 0600 on newly-created estate files.

### 1.5.0 -- 2026-06-25
Additive (the recall-driven dreaming contract Decision 7, T3): `EstateConfiguration.queueSibling(filename:)`
(Swift `throws`) / `queue_sibling(&self, filename:)` (Rust `StorageResult`).
Derives a sibling-DB config for the per-estate queue — for a `.sqlite` estate, a
`.sqlite` config at the same directory with the leaf replaced by `filename`,
**carrying the estate's `encryptionConfig` verbatim** (the queue DB is encrypted
with the same key); InMemory → InMemory sibling; PostgreSQL → throws/returns
`StorageError.featureGated` (deferred to the the recall-driven dreaming contract Postgres pass). The sibling
estate-id is derived deterministically (XOR-fold of the filename into the parent
UUID — byte-identical across ports), no `UUID()`/random. Lets mootx01 open the
one encrypted per-estate `queue.sqlite`.

### 1.4.0 -- 2026-06-21
NT-DOC-1: Added 12 concordance rows for the node-integrity contract node-tree migration types. New
`### Hash-on-write decorator (NT-P2)` subsection documents `HashingRowStore`,
`HashOnWriteConfig`, `ContentHashProvider`, `HashParentChainProvider`, and
`DirtyChainEvent` (Swift+Rust, 5 rows). Expanded `### Swift-only types` section
with `ErasureLedgerEntry`, `ErasureOverlay`, `ErasureOverlayConfig`, `GCPin`,
`SnapshotId`, `SnapshotRecord`, and `SnapshotAttestation` (7 rows; latter two
include layering note documenting that Rust counterparts currently reside in
`LocusKit/merkle_rollup.rs`, parity debt NT-P1/L4).

### 1.3.0 -- 2026-06-20
NT-P4: Added `ParentChainProvider` to the § 7 concordance table (new public
typealias/type alias). Updated the `CachingRowStore` row to document temporal key
isolation (SPEC B-16), the `ParentChainProvider` callback contract (SPEC B-17),
and the Swift vs Rust constructor shape difference (`init` default-nil param vs
`new`/`with_parent_chain` two-constructor pattern).

### 1.2.0 -- 2026-06-20
NT-P1: Added `ColumnRole` enum (`createdHlc`/`CreatedHlc`,
`tombstonedHlc`/`TombstonedHlc`) and `role: ColumnRole?` field on
`ColumnDeclaration`. Added three as-of temporal query default methods to
`RowStore` (`query(..., asOf:)` / `query_as_of`, projected and skip-corrupt
variants). Added three error cases to `StorageError`: `corruptStoredValue`,
`invalidConfiguration`, `featureGated` (the latter gates the as-of query
surface per the node-integrity contract §17). Updated § 7 parity table: `StorageError` fifteen
cases; `ColumnDeclaration` includes `role`; new `ColumnRole` row; `RowStore`
notes as-of default methods.

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
