// SQLiteObserverTests.swift
//
// Verifies that the SQLite backend emits TableChange notifications
// carrying the actual row key for update and delete operations.
// Prior to the fix, both emitted rowKey: nil, causing FederationSyncEngine
// to silently skip updates and deletes on SQLite-backed estates.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite

struct SQLiteObserverTests {

    func makeStorage() throws -> SQLiteStorage {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-observer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("test.sqlite")
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
    }

    func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "ObserverTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("row_id"), .text("label"), .bitmap("flags")],
                    primaryKey: ["row_id"]
                )
            ]
        )
    }

    /// Await the first change on `stream` within `duration`, returning nil on timeout.
    private func firstChange(
        from stream: AsyncStream<TableChange>,
        within duration: Duration
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

    // MARK: - Update carries the row key

    @Test func updateNotificationCarriesRowKey() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["row_id": .uuid(rowID), "label": .text("original"), "flags": .bitmap(0)]
        )

        let stream = storage.observer.observe(table: "items", events: [.update])
        // Single consumer: the collected Task is the only reader of the stream.
        let collected = Task<TableChange?, Never> {
            for await change in stream { return change }
            return nil
        }
        // Allow the subscription to register before triggering the mutation.
        try await Task.sleep(nanoseconds: 50_000_000)

        let updated = try await storage.rowStore.update(
            table: "items",
            values: ["label": .text("updated")],
            where: .eq(Column(table: "items", name: "row_id"), .uuid(rowID))
        )
        #expect(updated == 1)

        // Await the collected value with a timeout via a race task.
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

        #expect(change != nil, "update must fire a notification")
        #expect(change?.event == .update)
        #expect(change?.rowKey == rowID, "update notification must carry the actual row key")

        await storage.close()
    }

    // MARK: - Delete carries the row key

    @Test func deleteNotificationCarriesRowKey() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["row_id": .uuid(rowID), "label": .text("to-delete"), "flags": .bitmap(0)]
        )

        let stream = storage.observer.observe(table: "items", events: [.delete])
        let collected = Task<TableChange?, Never> {
            for await change in stream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let deleted = try await storage.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "row_id"), .uuid(rowID))
        )
        #expect(deleted == 1)

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

        #expect(change != nil, "delete must fire a notification")
        #expect(change?.event == .delete)
        #expect(change?.rowKey == rowID, "delete notification must carry the actual row key")

        await storage.close()
    }

    // MARK: - Bulk update emits per-row notifications

    @Test func bulkUpdateEmitsPerRowNotifications() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        for (id, label) in [(id1, "a"), (id2, "b"), (id3, "c")] {
            _ = try await storage.rowStore.insert(
                table: "items",
                values: ["row_id": .uuid(id), "label": .text(label), "flags": .bitmap(0)]
            )
        }

        let stream = storage.observer.observe(table: "items", events: [.update])
        // Collect up to 3 notifications with a bounded wait.
        let collected = Task<[TableChange], Never> {
            var out: [TableChange] = []
            for await change in stream {
                out.append(change)
                if out.count >= 3 { break }
            }
            return out
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Update all three rows with a single call.
        let count = try await storage.rowStore.update(
            table: "items",
            values: ["flags": .bitmap(1)],
            where: .bitmaskNone(Column(table: "items", name: "flags"), mask: 0x01)
        )
        #expect(count == 3)

        // Give the async notifications time to arrive.
        try await Task.sleep(nanoseconds: 200_000_000)
        collected.cancel()
        let changes = await collected.value

        #expect(changes.count == 3, "bulk update should produce one notification per affected row")
        let keys = Set(changes.compactMap { $0.rowKey })
        #expect(keys == Set([id1, id2, id3]), "each notification must carry the correct row key")

        await storage.close()
    }

    // MARK: - Nil key is not emitted

    @Test func noNilKeyNotificationsForUpdate() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["row_id": .uuid(rowID), "label": .text("x"), "flags": .bitmap(0)]
        )

        let stream = storage.observer.observe(table: "items", events: [.update])
        let collected = Task<[TableChange], Never> {
            var out: [TableChange] = []
            for await change in stream {
                out.append(change)
                if out.count >= 1 { break }
            }
            return out
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = try await storage.rowStore.update(
            table: "items",
            values: ["label": .text("y")],
            where: .eq(Column(table: "items", name: "row_id"), .uuid(rowID))
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        collected.cancel()

        let changes = await collected.value
        for change in changes {
            #expect(change.rowKey != nil, "no update notification should have a nil rowKey")
        }

        await storage.close()
    }

    @Test func noNilKeyNotificationsForDelete() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["row_id": .uuid(rowID), "label": .text("y"), "flags": .bitmap(0)]
        )

        let stream = storage.observer.observe(table: "items", events: [.delete])
        let collected = Task<[TableChange], Never> {
            var out: [TableChange] = []
            for await change in stream {
                out.append(change)
                if out.count >= 1 { break }
            }
            return out
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = try await storage.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "row_id"), .uuid(rowID))
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        collected.cancel()

        let changes = await collected.value
        for change in changes {
            #expect(change.rowKey != nil, "no delete notification should have a nil rowKey")
        }

        await storage.close()
    }
}
