// RowStore.swift
//
// Typed row I/O protocol.

import Foundation

public typealias RowKey = UUID

public struct StorageRow: Sendable {
    public let values: [String: TypedValue]

    public init(values: [String: TypedValue]) {
        self.values = values
    }

    public subscript(column: String) -> TypedValue? {
        values[column]
    }
}

public struct RowHandle: Sendable, Hashable {
    public let table: String
    public let key: RowKey

    public init(table: String, key: RowKey) {
        self.table = table
        self.key = key
    }
}

public protocol RowStore: Sendable {
    func insert(table: String, values: [String: TypedValue]) async throws -> RowHandle
    @discardableResult
    func upsert(table: String, values: [String: TypedValue], conflictColumns: [String]) async throws -> RowHandle
    @discardableResult
    func update(table: String, values: [String: TypedValue], where: StoragePredicate) async throws -> Int
    func delete(table: String, where: StoragePredicate) async throws -> Int
    func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?
    ) async throws -> [StorageRow]
    func count(table: String, where predicate: StoragePredicate?) async throws -> Int

    /// Corpus scan that skips rows with a corrupt stored value rather than
    /// failing the entire scan.
    ///
    /// ## When to use
    ///
    /// Use this method for **best-effort corpus scans** (e.g. `allDrawers`,
    /// `drawersIn(wing:)`) where a single corrupt row must not brick the entire
    /// estate. For **point lookups** (single-row fetches by primary key) use
    /// `query(...)`, which is strict: a corrupt value in a point-lookup row is
    /// an unambiguous data-integrity failure and the caller must know about it.
    ///
    /// ## Contract
    ///
    /// Returns `(cleanRows, skippedCount)`. Rows that decode without error
    /// appear in `cleanRows`. Rows that fail with `StorageError.corruptStoredValue`
    /// are counted in `skippedCount` and logged via OSLog. Any other error
    /// (engine failure, connectivity, locking) is re-thrown — those are systemic
    /// failures, not data problems.
    ///
    /// ## Default implementation
    ///
    /// Calls `query(...)` and promotes a top-level `corruptStoredValue` error to
    /// `([], 1)`. Backends that iterate at the cursor level (SQLiteStorage)
    /// override this to skip individual corrupt rows without aborting the scan.
    func querySkipCorrupt(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> (rows: [StorageRow], skipped: Int)

    /// Column-projecting query: like `query(...)` but reads ONLY the named
    /// `columns` from the row, leaving every unnamed column absent from the
    /// returned `StorageRow`. A `nil` projection is a full read (every column).
    ///
    /// This is the no-blob read path: passing the structured/bitmap columns
    /// without the content column means the content blob is never transferred
    /// out of storage — the dense-first candidate-pool load. The returned rows
    /// carry only the projected keys, so a consumer that decodes an absent
    /// column reads the type's empty/default value.
    ///
    /// The protocol-extension default below ignores `columns` and performs the
    /// existing full `query(...)`. Backends on the recall hot path (SQLite,
    /// InMemory) override it to genuinely project; other backends inherit the
    /// full-read default, which is always correct (a superset of the requested
    /// columns) and simply does not realize the no-blob saving.
    func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> [StorageRow]
}

public extension RowStore {
    func query(table: String, where predicate: StoragePredicate? = nil) async throws -> [StorageRow] {
        try await query(table: table, where: predicate, orderBy: [], limit: nil, offset: nil)
    }

    /// Default projection: ignore `columns` and perform a full read. Correct
    /// for every backend (the full row is a superset of any projection); only
    /// the overriding backends realize the no-blob transfer saving.
    func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> [StorageRow] {
        try await query(
            table: table, where: predicate,
            orderBy: orderBy, limit: limit, offset: offset)
    }

    /// Default skip-corrupt implementation: calls `query(...)` with the given
    /// projection and promotes a top-level `StorageError.corruptStoredValue`
    /// error to `([], 1)`. Backends that iterate at cursor level override this
    /// for correct per-row skip-and-log behaviour.
    func querySkipCorrupt(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> (rows: [StorageRow], skipped: Int) {
        do {
            let rows = try await query(
                table: table, where: predicate,
                orderBy: orderBy, limit: limit, offset: offset, columns: columns)
            return (rows, 0)
        } catch StorageError.corruptStoredValue {
            // Promote: the whole-query abort becomes a skip-and-empty-result.
            // Backends that iterate at cursor level override this for per-row
            // skip-and-log behaviour (SQLiteRowStore overrides this).
            return ([], 1)
        }
    }
}
