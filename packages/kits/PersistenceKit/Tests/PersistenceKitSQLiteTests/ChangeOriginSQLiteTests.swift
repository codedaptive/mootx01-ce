// ChangeOriginSQLiteTests.swift
//
// Verifies that the origin field round-trips correctly through the SQLite
// backend observer. SQLite observer delivery is fire-and-forget Task-based
// (unordered), so these tests use a bounded wait. This is the SQLite half
// of the echo-suppression contract (I-10, CVK-ICLOUD P1-M1).

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite

struct ChangeOriginSQLiteTests {

    func makeStorage() throws -> SQLiteStorage {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-origin-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("test.sqlite")
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
    }

    func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "OriginSQLiteTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "things",
                    columns: [.uuid("row_id"), .text("label")],
                    primaryKey: ["row_id"]
                )
            ]
        )
    }

    private func nextChange(
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

    // MARK: - Ordinary write paths emit .local

    @Test func sqliteInsert_emitsLocalOrigin() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())
        let stream = storage.observer.observe(table: "things", events: [.insert])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await storage.rowStore.insert(
            table: "things",
            values: ["row_id": .uuid(UUID()), "label": .text("alpha")]
        )
        let change = await nextChange(from: stream)
        #expect(change != nil, "SQLite observer should fire on insert")
        #expect(change?.origin == .local, "ordinary SQLite insert must emit .local origin")
    }

    @Test func sqliteUpsert_emitsLocalOrigin() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())
        let stream = storage.observer.observe(table: "things", events: [.insert, .update])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await storage.rowStore.upsert(
            table: "things",
            values: ["row_id": .uuid(UUID()), "label": .text("beta")],
            conflictColumns: ["row_id"]
        )
        let change = await nextChange(from: stream)
        #expect(change?.origin == .local, "ordinary SQLite upsert must emit .local origin")
    }

    // MARK: - Sync-tagged write paths emit .syncApply

    @Test func sqliteInsertSync_emitsSyncApplyOrigin() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())
        let stream = storage.observer.observe(table: "things", events: [.insert])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await storage.rowStore.insertSync(
            table: "things",
            values: ["row_id": .uuid(UUID()), "label": .text("gamma")]
        )
        let change = await nextChange(from: stream)
        #expect(change != nil, "SQLite observer should fire on insertSync")
        #expect(change?.origin == .syncApply,
            "SQLite insertSync must emit .syncApply origin so recordOutbound discards it")
    }

    @Test func sqliteUpsertSync_emitsSyncApplyOrigin() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())
        let stream = storage.observer.observe(table: "things", events: [.insert, .update])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await storage.rowStore.upsertSync(
            table: "things",
            values: ["row_id": .uuid(UUID()), "label": .text("delta")],
            conflictColumns: ["row_id"]
        )
        let change = await nextChange(from: stream)
        #expect(change?.origin == .syncApply,
            "SQLite upsertSync must emit .syncApply origin so recordOutbound discards it")
    }

    @Test func sqliteDeleteSync_emitsSyncApplyOrigin() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())
        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "things",
            values: ["row_id": .uuid(rowID), "label": .text("epsilon")]
        )
        let stream = storage.observer.observe(table: "things", events: [.delete])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await storage.rowStore.deleteSync(
            table: "things",
            where: .eq(Column(table: "things", name: "row_id"), .uuid(rowID))
        )
        let change = await nextChange(from: stream)
        #expect(change?.origin == .syncApply,
            "SQLite deleteSync must emit .syncApply origin so recordOutbound discards it")
    }
}
