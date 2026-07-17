// InMemoryChangedColumnsTests.swift
//
// Verifies that InMemoryStorage stamps changedColumns on TableChange
// notifications with the correct column-level precision (CVK-WB4).
//
// Contracts verified:
//  - insert: changedColumns == Set(stored.keys)
//  - update (diff): changedColumns == columns whose value actually changed
//  - upsert-as-insert: changedColumns == Set(stored.keys)
//  - upsert-as-update (diff): changedColumns == columns whose value changed
//  - delete: changedColumns == nil

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

struct InMemoryChangedColumnsTests {

    // MARK: - Helpers

    func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "ChangedColumnsTestKit",
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

    private func firstChange(
        from stream: AsyncStream<TableChange>,
        within duration: Duration = .milliseconds(500)
    ) async -> TableChange? {
        await withTaskGroup(of: TableChange?.self) { group in
            group.addTask {
                for await change in stream { return change }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    // MARK: - Insert: all stored columns stamped

    @Test func insertStampsAllColumns() async throws {
        let storage = makeStorage()
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

        let received = await withTaskGroup(of: TableChange?.self) { group in
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
        let cols = try #require(received?.changedColumns)
        // All three written columns must be stamped.
        #expect(cols == ["row_id", "title", "flags"])
    }

    // MARK: - Update: only actually-changed columns stamped

    @Test func updateStampsOnlyChangedColumns() async throws {
        let storage = makeStorage()
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

        // Update only title; flags is written but same value.
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
        // title changed; flags had the same stored value.
        #expect(cols.contains("title"), "title changed — must be in changedColumns")
        #expect(!cols.contains("flags"), "flags unchanged — must NOT be in changedColumns")
        #expect(!cols.contains("row_id"), "row_id not in SET clause")
    }

    // MARK: - Upsert-as-insert: all written columns stamped

    @Test func upsertInsertPathStampsAllColumns() async throws {
        let storage = makeStorage()
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
        let storage = makeStorage()
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

        // Pre-existing row: upsert fires the update path. title changes, flags stays 0.
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
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["row_id": .uuid(rowID), "title": .text("To delete"), "flags": .bitmap(0)]
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
