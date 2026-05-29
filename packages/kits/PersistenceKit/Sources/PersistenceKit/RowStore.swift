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
    func upsert(table: String, values: [String: TypedValue], conflictColumns: [String]) async throws -> RowHandle
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
}

public extension RowStore {
    func query(table: String, where predicate: StoragePredicate? = nil) async throws -> [StorageRow] {
        try await query(table: table, where: predicate, orderBy: [], limit: nil, offset: nil)
    }
}
