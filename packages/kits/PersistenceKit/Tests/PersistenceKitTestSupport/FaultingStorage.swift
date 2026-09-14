// FaultingStorage.swift
//
// Test-support: a forwarding Storage decorator that faults one table's
// query path on demand.
//
// ## Purpose
//
// Several GLK verbs perform a "fail-closed pre-read" before their main
// operation: they query a specific table (e.g. "drawers" in `expunge`,
// "kg_facts" in `retireKGFact`) and surface any thrown read error as a
// `VerbError.underlyingEstateFailure`. Nothing currently tests that
// thrown-error branch because the InMemoryStorage backend never throws.
//
// `FaultCell`, `FaultingRowStore`, and `FaultingStorage` together provide
// a minimal seam: arm the cell for a target table, call the verb, and the
// query for that table throws the injected error. Disarm to restore normal
// behaviour and verify the row survived.
//
// ## Usage
//
//     let storage = InMemoryStorage(configuration: config)
//     _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
//     let cell = FaultCell(table: "drawers")
//     let faulting = FaultingStorage(wrapping: storage, cell: cell)
//     let handle = try await kit.open(storage: faulting, owner: owner)
//     // ... seed a row ...
//     cell.arm(.backendUnavailable(reason: "INJECTED_FAULT"))
//     // call verb — expect VerbError.underlyingEstateFailure
//     cell.disarm()
//     // verify row survived
//
// ## Forwarding contract
//
// Every Storage and RowStore method except `rowStore.query` (for the armed
// table) is forwarded unchanged to the wrapped backend. The decorator is
// transparent until armed.
//
// ## Transaction limit
//
// `transaction(_:_:)` forwards to the inner storage unchanged: the block
// receives the inner transaction's row store, so queries inside a transaction
// are unfaulted. The current tests are unaffected because both pre-reads run
// before the transaction opens.

import Foundation
import PersistenceKit

// MARK: - FaultCell

/// Thread-safe shared state controlling a single table-level query fault.
///
/// `FaultCell` is intentionally a class so it can be shared by reference
/// between a `FaultingStorage` and the test that arms/disarms it.
/// `@unchecked Sendable` is correct: all mutable state is protected by the
/// embedded `NSLock`.
public final class FaultCell: @unchecked Sendable {

    private let lock = NSLock()
    private let target: String
    private var armed: StorageError?

    /// Create a disarmed cell targeting `table`.
    ///
    /// - Parameter table: The table whose `query` calls will throw when
    ///   the cell is armed. Non-matching tables always forward normally.
    public init(table: String) {
        self.target = table
    }

    /// Arm the cell: the next (and all subsequent) `query` calls for the
    /// target table will throw `error` instead of querying the backend.
    public func arm(_ error: StorageError) {
        lock.lock()
        defer { lock.unlock() }
        armed = error
    }

    /// Disarm the cell: subsequent `query` calls forward normally.
    public func disarm() {
        lock.lock()
        defer { lock.unlock() }
        armed = nil
    }

    /// If the cell is armed and `table` matches the target, returns the
    /// stored error. Otherwise returns `nil` (forward normally).
    public func tryFire(table: String) -> StorageError? {
        lock.lock()
        defer { lock.unlock() }
        guard table == target else { return nil }
        return armed
    }
}

// MARK: - FaultingRowStore

/// A forwarding `RowStore` that injects a fault into `query` for the
/// target table while armed.
///
/// All other calls — `insert`, `upsert`, `update`, `delete`, `count` —
/// are forwarded unchanged to the wrapped row store.
private final class FaultingRowStore: RowStore, @unchecked Sendable {

    private let inner: any RowStore
    private let cell: FaultCell

    init(wrapping inner: any RowStore, cell: FaultCell) {
        self.inner = inner
        self.cell = cell
    }

    // MARK: Required RowStore methods

    func insert(
        table: String,
        values: [String: TypedValue]
    ) async throws -> RowHandle {
        try await inner.insert(table: table, values: values)
    }

    func upsert(
        table: String,
        values: [String: TypedValue],
        conflictColumns: [String]
    ) async throws -> RowHandle {
        try await inner.upsert(table: table, values: values, conflictColumns: conflictColumns)
    }

    @discardableResult
    func update(
        table: String,
        values: [String: TypedValue],
        where predicate: StoragePredicate
    ) async throws -> Int {
        try await inner.update(table: table, values: values, where: predicate)
    }

    @discardableResult
    func delete(table: String, where predicate: StoragePredicate) async throws -> Int {
        try await inner.delete(table: table, where: predicate)
    }

    func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?
    ) async throws -> [StorageRow] {
        // Fire fault for the armed table; forward everything else.
        if let err = cell.tryFire(table: table) { throw err }
        return try await inner.query(
            table: table,
            where: predicate,
            orderBy: orderBy,
            limit: limit,
            offset: offset
        )
    }

    func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> [StorageRow] {
        // Fire fault before any projection; forward otherwise.
        if let err = cell.tryFire(table: table) { throw err }
        return try await inner.query(
            table: table,
            where: predicate,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
            columns: columns
        )
    }

    func querySkipCorrupt(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> (rows: [StorageRow], skipped: Int) {
        // Fire fault before any query; forward otherwise.
        if let err = cell.tryFire(table: table) { throw err }
        return try await inner.querySkipCorrupt(
            table: table,
            where: predicate,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
            columns: columns
        )
    }

    func count(table: String, where predicate: StoragePredicate?) async throws -> Int {
        try await inner.count(table: table, where: predicate)
    }

    // Sync-tagged write paths: forward to inner (faults are query-side only).

    func insertSync(table: String, values: [String: TypedValue]) async throws -> RowHandle {
        try await inner.insertSync(table: table, values: values)
    }

    func upsertSync(
        table: String,
        values: [String: TypedValue],
        conflictColumns: [String]
    ) async throws -> RowHandle {
        try await inner.upsertSync(table: table, values: values, conflictColumns: conflictColumns)
    }

    @discardableResult
    func deleteSync(table: String, where predicate: StoragePredicate) async throws -> Int {
        try await inner.deleteSync(table: table, where: predicate)
    }

    // Transaction boundary: forward (faults are read-path only).
    func beginTransaction() async throws { try await inner.beginTransaction() }
    func commitTransaction() async throws { try await inner.commitTransaction() }
    func rollbackTransaction() async throws { try await inner.rollbackTransaction() }
}

// MARK: - FaultingStorage

/// A forwarding `Storage` decorator that injects a query fault on demand.
///
/// Every method is forwarded to the wrapped backend. The sole exception is
/// `rowStore`, which returns a `FaultingRowStore` that intercepts `query`
/// calls for the armed table.
public final class FaultingStorage: Storage, @unchecked Sendable {

    private let inner: any Storage
    private let cell: FaultCell

    /// Wrap `inner` with a fault cell targeting a single table.
    ///
    /// - Parameters:
    ///   - inner: The real storage backend. Must already have been opened
    ///     (or will be opened through this wrapper via `open(schema:)`).
    ///   - cell: The `FaultCell` the caller uses to arm/disarm the fault.
    ///     `FaultingStorage` holds a reference; arm/disarm through the
    ///     same `FaultCell` instance the test holds.
    public init(wrapping inner: any Storage, cell: FaultCell) {
        self.inner = inner
        self.cell = cell
    }

    // MARK: Storage requirements — forwarded to `inner`

    public var configuration: EstateConfiguration { inner.configuration }

    /// Returns a `FaultingRowStore` that intercepts queries for the armed
    /// table. All writes and queries for other tables pass through unchanged.
    public var rowStore: any RowStore {
        FaultingRowStore(wrapping: inner.rowStore, cell: cell)
    }

    public var blobStore: any BlobStore { inner.blobStore }
    public var auditLog: any AuditLog { inner.auditLog }
    public var observer: any StorageObserver { inner.observer }

    public func open(schema: SchemaDeclaration) async throws {
        try await inner.open(schema: schema)
    }

    public func close() async {
        await inner.close()
    }

    public func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        try await inner.transaction(isolation: isolation, block)
    }

    public func currentSchemaVersion() async throws -> Int {
        try await inner.currentSchemaVersion()
    }

    public func currentSchemaVersion(for kitID: String) async throws -> Int {
        try await inner.currentSchemaVersion(for: kitID)
    }

    public func renameSchemaKit(
        from oldKitID: String,
        to newKitID: String
    ) async throws -> SchemaKitRenameOutcome {
        try await inner.renameSchemaKit(from: oldKitID, to: newKitID)
    }

    public func migrate(to schema: SchemaDeclaration) async throws {
        try await inner.migrate(to: schema)
    }
}
