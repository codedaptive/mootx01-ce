// TransactionBoundaryTests.swift
//
// GLK_BATCH1 — tests for the explicit transaction boundary added to RowStore.
// Verifies:
//   - SQLiteRowStore begin/commit round-trip persists all rows
//   - SQLiteRowStore begin/rollback discards all rows
//   - CachingRowStore delegates begin/commit/rollback to backing SQLiteRowStore
//   - InMemoryStorage rowStore inherits no-op default without error
//   - Nested begin throws transactionConflict

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
import PersistenceKitInMemory

@Suite("TransactionBoundaryTests")
struct TransactionBoundaryTests {

    private func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "TxnTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [
                        .uuid("id"),
                        .text("val", nullable: true)
                    ],
                    primaryKey: ["id"]
                )
            ]
        )
    }

    private func freshDBURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("txn-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }

    private func makeSQLiteStorage() async throws -> SQLiteStorage {
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: freshDBURL(), busyTimeout: 5.0)
        ))
        try await storage.open(schema: makeSchema())
        return storage
    }

    private func makeCachingSQLiteStorage() async throws -> SQLiteStorage {
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: freshDBURL(), busyTimeout: 5.0),
            cacheConfig: EstateCacheConfig(
                enabled: true,
                ceilingBytes: 1_024 * 1_024,
                sensitivityThreshold: 2
            )
        ))
        try await storage.open(schema: makeSchema())
        return storage
    }

    private func rowValues(id: UUID, val: String) -> [String: TypedValue] {
        ["id": .uuid(id), "val": .text(val)]
    }

    // MARK: - SQLiteRowStore commit

    @Test("begin/commit persists inserted rows")
    func commitPersistsRows() async throws {
        let storage = try await makeSQLiteStorage()
        let rowStore = storage.rowStore
        let id = UUID()
        try await rowStore.beginTransaction()
        _ = try await rowStore.insert(table: "items", values: rowValues(id: id, val: "hello"))
        try await rowStore.commitTransaction()
        let rows = try await rowStore.query(table: "items", where: nil)
        #expect(rows.count == 1)
        let idCol = rows.first?["id"]
        #expect(idCol == .uuid(id))
    }

    // MARK: - SQLiteRowStore rollback

    @Test("begin/rollback discards inserted rows")
    func rollbackDiscardsRows() async throws {
        let storage = try await makeSQLiteStorage()
        let rowStore = storage.rowStore
        let id = UUID()
        try await rowStore.beginTransaction()
        _ = try await rowStore.insert(table: "items", values: rowValues(id: id, val: "discard"))
        try await rowStore.rollbackTransaction()
        let rows = try await rowStore.query(table: "items", where: nil)
        #expect(rows.isEmpty)
    }

    // MARK: - SQLiteRowStore nested begin throws

    @Test("nested beginTransaction throws StorageError")
    func nestedBeginThrows() async throws {
        let storage = try await makeSQLiteStorage()
        let rowStore = storage.rowStore
        try await rowStore.beginTransaction()
        defer {
            Task { try? await rowStore.rollbackTransaction() }
        }
        var threw = false
        do {
            try await rowStore.beginTransaction()
        } catch {
            threw = true
        }
        #expect(threw, "Expected nested beginTransaction to throw")
    }

    // MARK: - CachingRowStore delegates to backing SQLiteRowStore

    @Test("CachingRowStore begin/commit delegates to backing store")
    func cachingRowStoreCommitDelegates() async throws {
        let storage = try await makeCachingSQLiteStorage()
        #expect(storage.rowStore is CachingRowStore, "Expected CachingRowStore for enabled cache config")
        let rowStore = storage.rowStore
        let id = UUID()
        try await rowStore.beginTransaction()
        _ = try await rowStore.insert(table: "items", values: rowValues(id: id, val: "cached"))
        try await rowStore.commitTransaction()
        let rows = try await rowStore.query(table: "items", where: nil)
        #expect(rows.count == 1)
        #expect(rows.first?["id"] == .uuid(id))
    }

    @Test("CachingRowStore begin/rollback delegates to backing store")
    func cachingRowStoreRollbackDelegates() async throws {
        let storage = try await makeCachingSQLiteStorage()
        let rowStore = storage.rowStore
        let id = UUID()
        try await rowStore.beginTransaction()
        _ = try await rowStore.insert(table: "items", values: rowValues(id: id, val: "discard"))
        try await rowStore.rollbackTransaction()
        let rows = try await rowStore.query(table: "items", where: nil)
        #expect(rows.isEmpty)
    }

    // MARK: - InMemoryStorage rowStore inherits no-op default

    @Test("InMemoryStorage rowStore no-op transaction methods do not throw")
    func inMemoryNoOp() async throws {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await storage.open(schema: makeSchema())
        let rowStore = storage.rowStore
        // These should all succeed silently — the protocol no-op default is
        // correct for an in-memory store that has no persistence layer.
        try await rowStore.beginTransaction()
        _ = try await rowStore.insert(
            table: "items",
            values: rowValues(id: UUID(), val: "mem")
        )
        try await rowStore.commitTransaction()
        try await rowStore.rollbackTransaction()
    }
}
