// RowStore.swift
//
// Typed row I/O protocol.

import Foundation
import SubstrateTypes

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

    // MARK: - Transaction boundary (GLK_BATCH1)

    /// Open a write transaction on the backing store.
    ///
    /// Declared as a protocol requirement (not just a protocol-extension
    /// default) so that dynamic dispatch through `any RowStore` existentials
    /// reaches the concrete type's override. SQLiteRowStore overrides with
    /// `BEGIN IMMEDIATE`. CachingRowStore overrides with explicit delegation
    /// to its backing store. All other conformers inherit the no-op default
    /// provided in the protocol extension.
    func beginTransaction() async throws

    /// Commit the current transaction.
    ///
    /// Protocol requirement for the same dynamic-dispatch reason as
    /// `beginTransaction`.
    func commitTransaction() async throws

    /// Roll back the current transaction, discarding all changes since
    /// the last `beginTransaction` call.
    ///
    /// Protocol requirement for the same dynamic-dispatch reason as
    /// `beginTransaction`.
    func rollbackTransaction() async throws
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

    // MARK: - As-of temporal query (ADR-017 §15)

    /// Temporal query: returns rows visible at the given `AsOfCoordinate`.
    ///
    /// - `.present` or `nil`: delegates to the standard `query(...)` — the
    ///   current live state.
    /// - `.asOf(hlc)`: returns rows whose HLC validity range includes the
    ///   given HLC. **Currently gated off** — returns
    ///   `StorageError.featureGated` until NT-L4 (lineage-wide expunge)
    ///   and NT-P3 (erasure overlay) have both merged.
    ///
    /// The filter logic (when ungated): a row with `created_hlc` and optional
    /// `tombstoned_hlc` is visible at HLC T when
    /// `created_hlc <= T AND (tombstoned_hlc IS NULL OR tombstoned_hlc > T)`.
    ///
    /// Default implementation handles the gate. Backends override once the
    /// gate is lifted to push the temporal filter into the engine.
    func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        asOf: AsOfCoordinate?
    ) async throws -> [StorageRow] {
        switch asOf {
        case nil, .present:
            return try await query(
                table: table, where: predicate,
                orderBy: orderBy, limit: limit, offset: offset)
        case .asOf:
            throw StorageError.featureGated(feature: "asOfQuery")
        }
    }

    /// Temporal projected query: as-of variant of the column-projecting
    /// query. Same gating behavior as `query(..., asOf:)`.
    func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?,
        asOf: AsOfCoordinate?
    ) async throws -> [StorageRow] {
        switch asOf {
        case nil, .present:
            return try await query(
                table: table, where: predicate,
                orderBy: orderBy, limit: limit, offset: offset,
                columns: columns)
        case .asOf:
            throw StorageError.featureGated(feature: "asOfQuery")
        }
    }

    /// Temporal skip-corrupt query: as-of variant of `querySkipCorrupt`.
    /// Same gating behavior as `query(..., asOf:)`.
    func querySkipCorrupt(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?,
        asOf: AsOfCoordinate?
    ) async throws -> (rows: [StorageRow], skipped: Int) {
        switch asOf {
        case nil, .present:
            return try await querySkipCorrupt(
                table: table, where: predicate,
                orderBy: orderBy, limit: limit, offset: offset,
                columns: columns)
        case .asOf:
            throw StorageError.featureGated(feature: "asOfQuery")
        }
    }

    // MARK: - Transaction boundary defaults (GLK_BATCH1)

    /// No-op default for `beginTransaction`. Correct for any backend that has
    /// no serializable multi-statement transaction concept (in-memory, hashing).
    func beginTransaction() async throws {}

    /// No-op default for `commitTransaction`.
    func commitTransaction() async throws {}

    /// No-op default for `rollbackTransaction`.
    func rollbackTransaction() async throws {}
}
