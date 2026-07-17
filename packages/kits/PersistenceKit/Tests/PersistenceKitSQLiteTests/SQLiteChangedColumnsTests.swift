// SQLiteChangedColumnsTests.swift
//
// Verifies that SQLiteStorage stamps changedColumns on TableChange
// notifications with the correct column-level precision (CVK-WB4).
//
// Contracts verified:
//  - insert: changedColumns == Set(values.keys)
//  - update (diff via pre-SELECT): changedColumns == columns whose value changed
//  - upsert-as-insert: changedColumns == all written column keys
//  - upsert-as-update (diff via pre-SELECT): changedColumns == columns that changed
//  - delete: changedColumns == nil

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite

struct SQLiteChangedColumnsTests {

    // MARK: - Helpers

    func makeStorage() throws -> SQLiteStorage {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-changed-cols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("test.sqlite")
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
    }

    func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "SQLiteChangedColsKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("row_id"), .text("title"), .bitmap("flags")],
                    primaryKey: ["row_id"]
                )
            ]
        )
    }

    // MARK: - Insert: all written columns stamped

    @Test func insertStampsAllColumns() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        let stream = storage.observer.observe(table: "items", events: [.insert])
        let collected = Task<TableChange?, Never> {
            for await change in stream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["row_id": .uuid(rowID), "title": .text("Hello"), "flags": .bitmap(0)]
        )

        let change = await withTaskGroup(of: TableChange?.self) { group in
            group.addTask { await collected.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                collected.cancel()
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        let cols = try #require(change?.changedColumns)
        #expect(cols == ["row_id", "title", "flags"])
    }

    // MARK: - Update: only actually-changed columns stamped

    @Test func updateStampsOnlyChangedColumns() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["row_id": .uuid(rowID), "title": .text("Original"), "flags": .bitmap(0)]
        )

        let stream = storage.observer.observe(table: "items", events: [.update])
        let collected = Task<TableChange?, Never> {
            for await change in stream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // title changes, flags is passed but carries the same value.
        _ = try await storage.rowStore.update(
            table: "items",
            values: ["title": .text("Updated"), "flags": .bitmap(0)],
            where: .eq(Column(table: "items", name: "row_id"), .uuid(rowID))
        )

        let change = await withTaskGroup(of: TableChange?.self) { group in
            group.addTask { await collected.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                collected.cancel()
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        let cols = try #require(change?.changedColumns)
        #expect(cols.contains("title"), "title changed — must be in changedColumns")
        #expect(!cols.contains("flags"), "flags value unchanged — must NOT be in changedColumns")
        #expect(!cols.contains("row_id"), "row_id is not in the SET clause")
    }

    // MARK: - Upsert-as-insert: all written columns stamped

    @Test func upsertInsertPathStampsAllColumns() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        let stream = storage.observer.observe(table: "items", events: [.insert, .update])
        let collected = Task<TableChange?, Never> {
            for await change in stream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // No pre-existing row — upsert fires the insert path.
        _ = try await storage.rowStore.upsert(
            table: "items",
            values: ["row_id": .uuid(rowID), "title": .text("New"), "flags": .bitmap(1)],
            conflictColumns: ["row_id"]
        )

        let change = await withTaskGroup(of: TableChange?.self) { group in
            group.addTask { await collected.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                collected.cancel()
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        let cols = try #require(change?.changedColumns)
        #expect(cols == ["row_id", "title", "flags"], "insert path: all written columns stamped")
    }

    // MARK: - Upsert-as-update: only changed columns stamped

    @Test func upsertUpdatePathStampsOnlyChangedColumns() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["row_id": .uuid(rowID), "title": .text("Existing"), "flags": .bitmap(0)]
        )

        let stream = storage.observer.observe(table: "items", events: [.insert, .update])
        let collected = Task<TableChange?, Never> {
            for await change in stream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Pre-existing row: upsert fires update path. title changes, flags stays 0.
        _ = try await storage.rowStore.upsert(
            table: "items",
            values: ["row_id": .uuid(rowID), "title": .text("Modified"), "flags": .bitmap(0)],
            conflictColumns: ["row_id"]
        )

        let change = await withTaskGroup(of: TableChange?.self) { group in
            group.addTask { await collected.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                collected.cancel()
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        let cols = try #require(change?.changedColumns)
        #expect(cols.contains("title"), "title changed — must be stamped")
        #expect(!cols.contains("flags"), "flags unchanged — must NOT be stamped")
    }

    // MARK: - Delete: changedColumns is nil

    @Test func deleteEmitsNilChangedColumns() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["row_id": .uuid(rowID), "title": .text("Bye"), "flags": .bitmap(0)]
        )

        let stream = storage.observer.observe(table: "items", events: [.delete])
        let collected = Task<TableChange?, Never> {
            for await change in stream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = try await storage.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "row_id"), .uuid(rowID))
        )

        let change = await withTaskGroup(of: TableChange?.self) { group in
            group.addTask { await collected.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                collected.cancel()
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        let received = try #require(change)
        #expect(received.changedColumns == nil, "delete tombstones carry no column granularity")
    }
}
