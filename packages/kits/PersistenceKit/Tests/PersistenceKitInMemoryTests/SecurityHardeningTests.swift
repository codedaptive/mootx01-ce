// SecurityHardeningTests.swift
//
// Regression tests for SECFIX-WS2-PK planned security hardening (InMemory backend).
//
// F2 — InMemory transaction notification isolation: row and blob change events
//      must not be delivered to observers when the enclosing transaction is rolled
//      back. Prior to the fix, notifications were dispatched immediately inside
//      the transaction block, exposing phantom state to sync engines.
//
// F4 — InMemory blob hub isolation: same isolation guarantee for blob events.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

// MARK: - Shared helpers

private func makeStorage() -> InMemoryStorage {
    InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
}

private func openSchema(_ storage: InMemoryStorage) async throws {
    try await storage.open(schema: SchemaDeclaration(
        kitID: "SecFixInMemoryTestKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "items",
                columns: [.uuid("id"), .text("label"), .bitmap("flags")],
                primaryKey: ["id"]
            )
        ]
    ))
}

@Suite("SecurityHardeningTests — F2/F4 InMemory notification isolation")
struct F2InMemoryNotificationIsolationTests {

    // MARK: Row change isolation

    /// A row inserted inside a rolled-back transaction must not fire a row
    /// change notification. The observer must receive zero events.
    ///
    /// Registers the stream BEFORE the transaction, performs a rollback inside
    /// the transaction, then asserts no event arrived within a 100ms window.
    @Test func rolledBackRowInsertDoesNotFireObserver() async throws {
        let storage = makeStorage()
        try await openSchema(storage)

        // Subscribe before the transaction so the stream is live.
        let stream = storage.observer.observe(table: "items", events: [.insert])

        // Collect up to 1 event with a short timeout.
        let collectTask = Task<TableChange?, Never> {
            for await change in stream { return change }
            return nil
        }
        // Small pause to let the subscription register before the write.
        try await Task.sleep(nanoseconds: 50_000_000)

        struct ForcedRollback: Error {}
        do {
            try await storage.transaction { txn in
                _ = try await txn.rowStore.insert(
                    table: "items",
                    values: ["id": .uuid(UUID()), "label": .text("ghost"), "flags": .bitmap(0)]
                )
                throw ForcedRollback()
            }
        } catch is ForcedRollback {}

        // Wait 100ms; no event should arrive.
        let timeout = Task<TableChange?, Never> {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return nil
        }
        let winner = await withTaskGroup(of: TableChange?.self) { group in
            group.addTask { await collectTask.value }
            group.addTask { await timeout.value }
            let first = await group.next() ?? nil
            group.cancelAll()
            collectTask.cancel()
            return first
        }

        #expect(
            winner == nil,
            "Row observer received an event for a rolled-back transaction"
        )

        // The row must not be readable either.
        let rows = try await storage.rowStore.query(table: "items")
        #expect(rows.isEmpty, "Rolled-back row must not be readable from storage")
    }

    /// A row inserted in a committed transaction MUST fire the observer.
    /// Confirms the buffering mechanism only suppresses rolled-back events.
    @Test func committedRowInsertFiresObserver() async throws {
        let storage = makeStorage()
        try await openSchema(storage)

        let stream = storage.observer.observe(table: "items", events: [.insert])
        let collectTask = Task<TableChange?, Never> {
            for await change in stream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let id = UUID()
        try await storage.transaction { txn in
            _ = try await txn.rowStore.insert(
                table: "items",
                values: ["id": .uuid(id), "label": .text("real"), "flags": .bitmap(0)]
            )
        }

        // 500ms budget for the committed event to arrive.
        let timeoutTask = Task<TableChange?, Never> {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return nil
        }
        let change = await withTaskGroup(of: TableChange?.self) { group in
            group.addTask { await collectTask.value }
            group.addTask { await timeoutTask.value }
            let first = await group.next() ?? nil
            group.cancelAll()
            collectTask.cancel()
            timeoutTask.cancel()
            return first
        }

        #expect(change != nil, "Committed insert must fire row observer")
        #expect(change?.event == .insert)
    }

    // MARK: Blob change isolation (F4 — InMemory blob hub)

    /// A blob written inside a rolled-back transaction must not be delivered
    /// to blob observers and must not be readable from storage.
    @Test func rolledBackBlobWriteDoesNotFireObserver() async throws {
        let storage = makeStorage()
        try await openSchema(storage)

        let blobStream = storage.observer.observeBlobs()
        let collectTask = Task<BlobChange?, Never> {
            for await change in blobStream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let blobKey = "secfix/f4/\(UUID().uuidString)"

        struct ForcedRollback: Error {}
        do {
            try await storage.transaction { txn in
                try await txn.blobStore.put(key: blobKey, bytes: Data([0xDE, 0xAD]))
                throw ForcedRollback()
            }
        } catch is ForcedRollback {}

        let timeoutTask = Task<BlobChange?, Never> {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return nil
        }
        let change = await withTaskGroup(of: BlobChange?.self) { group in
            group.addTask { await collectTask.value }
            group.addTask { await timeoutTask.value }
            let first = await group.next() ?? nil
            group.cancelAll()
            collectTask.cancel()
            timeoutTask.cancel()
            return first
        }

        #expect(
            change == nil,
            "Blob observer received an event for a rolled-back transaction"
        )

        let stored = try await storage.blobStore.get(key: blobKey)
        #expect(stored == nil, "Rolled-back blob must not be readable from storage")
    }

    /// A blob written in a committed transaction MUST fire the blob observer.
    @Test func committedBlobWriteFiresObserver() async throws {
        let storage = makeStorage()
        try await openSchema(storage)

        let blobStream = storage.observer.observeBlobs()
        let collectTask = Task<BlobChange?, Never> {
            for await change in blobStream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let blobKey = "secfix/f4/committed/\(UUID().uuidString)"
        try await storage.transaction { txn in
            try await txn.blobStore.put(key: blobKey, bytes: Data([0xAB, 0xCD]))
        }

        let timeoutTask = Task<BlobChange?, Never> {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return nil
        }
        let change = await withTaskGroup(of: BlobChange?.self) { group in
            group.addTask { await collectTask.value }
            group.addTask { await timeoutTask.value }
            let first = await group.next() ?? nil
            group.cancelAll()
            collectTask.cancel()
            timeoutTask.cancel()
            return first
        }

        #expect(change != nil, "Committed blob put must fire blob observer")
        #expect(change?.key == blobKey)
        #expect(change?.event == .put)
    }
}
