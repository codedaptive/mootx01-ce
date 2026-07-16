// ChangeOriginInMemoryTests.swift
//
// Verifies that the origin field round-trips correctly through the InMemory
// backend observer. The sync-tagged write paths (insertSync / upsertSync /
// deleteSync) must emit TableChange with origin: .syncApply; all ordinary
// write paths must emit origin: .local. This is the PersistenceKit half of
// the echo-suppression contract (I-10, CVK-ICLOUD P1-M1).

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

struct ChangeOriginInMemoryTests {

    func makeStorage() async throws -> InMemoryStorage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "OriginTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("name")],
                    primaryKey: ["id"]
                )
            ]
        ))
        return storage
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

    @Test func insert_emitsLocalOrigin() async throws {
        let storage = try await makeStorage()
        let stream = storage.observer.observe(table: "items", events: [.insert])
        try await Task.sleep(nanoseconds: 50_000_000) // let subscription register
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["id": .uuid(UUID()), "name": .text("alpha")]
        )
        let change = await nextChange(from: stream)
        #expect(change != nil, "observer should have fired")
        #expect(change?.origin == .local, "ordinary insert must emit .local origin")
    }

    @Test func upsert_emitsLocalOrigin() async throws {
        let storage = try await makeStorage()
        let stream = storage.observer.observe(table: "items", events: [.insert, .update])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await storage.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(UUID()), "name": .text("beta")],
            conflictColumns: ["id"]
        )
        let change = await nextChange(from: stream)
        #expect(change?.origin == .local, "ordinary upsert must emit .local origin")
    }

    @Test func delete_emitsLocalOrigin() async throws {
        let storage = try await makeStorage()
        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["id": .uuid(rowID), "name": .text("gamma")]
        )
        let stream = storage.observer.observe(table: "items", events: [.delete])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await storage.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        let change = await nextChange(from: stream)
        #expect(change?.origin == .local, "ordinary delete must emit .local origin")
    }

    // MARK: - Sync-tagged write paths emit .syncApply

    @Test func insertSync_emitsSyncApplyOrigin() async throws {
        let storage = try await makeStorage()
        let stream = storage.observer.observe(table: "items", events: [.insert])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await storage.rowStore.insertSync(
            table: "items",
            values: ["id": .uuid(UUID()), "name": .text("delta")]
        )
        let change = await nextChange(from: stream)
        #expect(change != nil, "sync insert observer should have fired")
        #expect(change?.origin == .syncApply, "insertSync must emit .syncApply origin")
    }

    @Test func upsertSync_emitsSyncApplyOrigin() async throws {
        let storage = try await makeStorage()
        let stream = storage.observer.observe(table: "items", events: [.insert, .update])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await storage.rowStore.upsertSync(
            table: "items",
            values: ["id": .uuid(UUID()), "name": .text("epsilon")],
            conflictColumns: ["id"]
        )
        let change = await nextChange(from: stream)
        #expect(change?.origin == .syncApply, "upsertSync must emit .syncApply origin")
    }

    @Test func deleteSync_emitsSyncApplyOrigin() async throws {
        let storage = try await makeStorage()
        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["id": .uuid(rowID), "name": .text("zeta")]
        )
        let stream = storage.observer.observe(table: "items", events: [.delete])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await storage.rowStore.deleteSync(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        let change = await nextChange(from: stream)
        #expect(change?.origin == .syncApply, "deleteSync must emit .syncApply origin")
    }

    // MARK: - CachingRowStore preserves origin through the chain

    @Test func cachingRowStore_insertSync_preservesSyncApplyOrigin() async throws {
        let backing = try await makeStorage()
        let caching = CachingRowStore(backing: backing.rowStore, config: .disabled)
        let stream = backing.observer.observe(table: "items", events: [.insert])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await caching.insertSync(
            table: "items",
            values: ["id": .uuid(UUID()), "name": .text("eta")]
        )
        let change = await nextChange(from: stream)
        #expect(change?.origin == .syncApply,
            "CachingRowStore.insertSync must propagate .syncApply origin through to the backing observer")
    }

    @Test func cachingRowStore_deleteSync_preservesSyncApplyOrigin() async throws {
        let backing = try await makeStorage()
        let caching = CachingRowStore(backing: backing.rowStore, config: .disabled)
        let rowID = UUID()
        _ = try await caching.insertSync(
            table: "items",
            values: ["id": .uuid(rowID), "name": .text("theta")]
        )
        let stream = backing.observer.observe(table: "items", events: [.delete])
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await caching.deleteSync(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        let change = await nextChange(from: stream)
        #expect(change?.origin == .syncApply,
            "CachingRowStore.deleteSync must propagate .syncApply origin through to the backing observer")
    }
}
