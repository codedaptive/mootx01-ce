// HashingRowStoreTests.swift
//
// Tests for the hash-on-write decorator (NT-P2).
// Verifies:
//   (a) insert to hashable table emits dirty-chain event
//   (b) upsert to hashable table emits dirty-chain event
//   (c) insert to non-hashable table does not fire the hook
//   (d) no-parent-chain path skips emission but stores the hash
//   (e) read operations pass through unchanged
//   (f) hashable field defaults to false
//   (g) default observeDirtyChain returns a finished AsyncStream
//   (h) DirtyChainEvent can be constructed, dispatched, and received by an observer

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

/// Accumulator for dirty-chain events in tests. Actor isolation
/// satisfies Swift 6 strict concurrency without NSLock-in-async.
private actor EventCollector {
    var events: [DirtyChainEvent] = []

    func append(_ event: DirtyChainEvent) {
        events.append(event)
    }

    var count: Int { events.count }
    var isEmpty: Bool { events.isEmpty }

    func get(_ index: Int) -> DirtyChainEvent {
        events[index]
    }
}

struct HashingRowStoreTests {

    // MARK: - Helpers

    /// Creates a deterministic ContentHash for testing.
    private static func testHash(
        _ table: String,
        _ rowKey: RowKey,
        _ values: [String: TypedValue]
    ) -> ContentHash {
        var bytes = [UInt8](repeating: 0, count: 32)
        let uuidBytes = withUnsafeBytes(of: rowKey.uuid) { Array($0) }
        for i in 0..<32 {
            bytes[i] = uuidBytes[i % 16]
        }
        return ContentHash(bytes: bytes)
    }

    private static let parentId = UUID()
    private static let grandparentId = UUID()

    private static func testParentChain(
        _ table: String,
        _ rowKey: RowKey
    ) -> (parentNodeId: UUID, grandparentNodeId: UUID)? {
        (parentNodeId: parentId, grandparentNodeId: grandparentId)
    }

    private static func noParentChain(
        _ table: String,
        _ rowKey: RowKey
    ) -> (parentNodeId: UUID, grandparentNodeId: UUID)? {
        nil
    }

    private func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    private func makeSink(_ collector: EventCollector) -> HashingRowStore.ObserverRegistryRef {
        { event in
            await collector.append(event)
        }
    }

    // MARK: - Part 2: DirtyChainEvent construction and observer delivery

    @Test func dirtyChainEventConstruction() {
        let rowId = UUID()
        let parentId = UUID()
        let grandparentId = UUID()
        let hash = ContentHash(bytes: [UInt8](repeating: 0xAB, count: 32))

        let event = DirtyChainEvent(
            changedRowId: rowId,
            parentNodeId: parentId,
            grandparentNodeId: grandparentId,
            contentHash: hash,
            table: "drawers"
        )

        #expect(event.changedRowId == rowId)
        #expect(event.parentNodeId == parentId)
        #expect(event.grandparentNodeId == grandparentId)
        #expect(event.contentHash == hash)
        #expect(event.table == "drawers")
    }

    @Test func dirtyChainObserverReceivesEvents() async throws {
        let storage = makeStorage()
        let schema = SchemaDeclaration(
            kitID: "HashTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("name"), .blob("content_hash", nullable: true)],
                    primaryKey: ["id"],
                    hashable: true
                )
            ]
        )
        try await storage.open(schema: schema)

        let collector = EventCollector()

        let config = HashOnWriteConfig(
            hashableTables: ["items"],
            hashProvider: Self.testHash,
            parentChainProvider: Self.testParentChain
        )

        let hashingStore = HashingRowStore(
            backing: storage.rowStore,
            config: config,
            dirtyChainSink: makeSink(collector)
        )

        let id = UUID()
        _ = try await hashingStore.insert(
            table: "items",
            values: ["id": .uuid(id), "name": .text("test")]
        )

        let count = await collector.count
        #expect(count == 1)
        let event = await collector.get(0)
        #expect(event.changedRowId == id)
        #expect(event.parentNodeId == Self.parentId)
        #expect(event.grandparentNodeId == Self.grandparentId)
        #expect(event.table == "items")

        // Verify content_hash was persisted on the row.
        let rows = try await hashingStore.query(table: "items")
        #expect(rows.count == 1)
        let storedHash = rows[0]["content_hash"]
        let expectedHash = Self.testHash("items", id, ["id": .uuid(id), "name": .text("test")])
        #expect(storedHash == .blob(Data(expectedHash.bytes)))
    }

    // MARK: - Part 1: Hash-on-write hook behavior

    @Test func insertToHashableTableEmitsDirtyChain() async throws {
        let storage = makeStorage()
        let schema = SchemaDeclaration(
            kitID: "HashTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "hashable_items",
                    columns: [.uuid("id"), .text("content"), .blob("content_hash", nullable: true)],
                    primaryKey: ["id"],
                    hashable: true
                ),
                TableDeclaration(
                    name: "plain_items",
                    columns: [.uuid("id"), .text("content")],
                    primaryKey: ["id"]
                )
            ]
        )
        try await storage.open(schema: schema)

        let collector = EventCollector()

        let config = HashOnWriteConfig(
            hashableTables: ["hashable_items"],
            hashProvider: Self.testHash,
            parentChainProvider: Self.testParentChain
        )

        let hashingStore = HashingRowStore(
            backing: storage.rowStore,
            config: config,
            dirtyChainSink: makeSink(collector)
        )

        // Insert to hashable table — should emit.
        let id1 = UUID()
        _ = try await hashingStore.insert(
            table: "hashable_items",
            values: ["id": .uuid(id1), "content": .text("hello")]
        )

        var count = await collector.count
        #expect(count == 1)
        let event = await collector.get(0)
        #expect(event.changedRowId == id1)
        #expect(event.table == "hashable_items")

        // Verify content_hash was persisted on the row.
        let rows = try await hashingStore.query(table: "hashable_items")
        #expect(rows.count == 1)
        if case .blob(let data) = rows[0]["content_hash"] {
            #expect(data.count == 32, "ContentHash should be 32 bytes")
        } else {
            Issue.record("content_hash column missing or wrong type after insert")
        }

        // Insert to non-hashable table — should NOT emit.
        let id2 = UUID()
        _ = try await hashingStore.insert(
            table: "plain_items",
            values: ["id": .uuid(id2), "content": .text("world")]
        )

        count = await collector.count
        #expect(count == 1, "Non-hashable table should not fire the hook")
    }

    @Test func upsertToHashableTableEmitsDirtyChain() async throws {
        let storage = makeStorage()
        let schema = SchemaDeclaration(
            kitID: "HashTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("name"), .blob("content_hash", nullable: true)],
                    primaryKey: ["id"],
                    hashable: true
                )
            ]
        )
        try await storage.open(schema: schema)

        let collector = EventCollector()

        let config = HashOnWriteConfig(
            hashableTables: ["items"],
            hashProvider: Self.testHash,
            parentChainProvider: Self.testParentChain
        )

        let hashingStore = HashingRowStore(
            backing: storage.rowStore,
            config: config,
            dirtyChainSink: makeSink(collector)
        )

        let id = UUID()
        _ = try await hashingStore.upsert(
            table: "items",
            values: ["id": .uuid(id), "name": .text("original")],
            conflictColumns: ["id"]
        )

        var count = await collector.count
        #expect(count == 1)
        let event = await collector.get(0)
        #expect(event.changedRowId == id)

        // Upsert again (update path).
        _ = try await hashingStore.upsert(
            table: "items",
            values: ["id": .uuid(id), "name": .text("updated")],
            conflictColumns: ["id"]
        )

        count = await collector.count
        #expect(count == 2)
        let event2 = await collector.get(1)
        #expect(event2.changedRowId == id)
    }

    @Test func noParentChainSkipsEmissionButStoresHash() async throws {
        let storage = makeStorage()
        let schema = SchemaDeclaration(
            kitID: "HashTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("name"), .blob("content_hash", nullable: true)],
                    primaryKey: ["id"],
                    hashable: true
                )
            ]
        )
        try await storage.open(schema: schema)

        let collector = EventCollector()

        let config = HashOnWriteConfig(
            hashableTables: ["items"],
            hashProvider: Self.testHash,
            parentChainProvider: Self.noParentChain
        )

        let hashingStore = HashingRowStore(
            backing: storage.rowStore,
            config: config,
            dirtyChainSink: makeSink(collector)
        )

        let id = UUID()
        _ = try await hashingStore.insert(
            table: "items",
            values: ["id": .uuid(id), "name": .text("orphan")]
        )

        let isEmpty = await collector.isEmpty
        #expect(isEmpty, "No parent chain should skip dirty-chain emission")

        // Hash should still be stored on the row even without parent chain.
        let rows = try await hashingStore.query(table: "items")
        #expect(rows.count == 1)
        if case .blob(let data) = rows[0]["content_hash"] {
            #expect(data.count == 32, "ContentHash should be 32 bytes even without parent chain")
        } else {
            Issue.record("content_hash column missing — hash should be stored regardless of parent chain")
        }
    }

    @Test func readOperationsPassThrough() async throws {
        let storage = makeStorage()
        let schema = SchemaDeclaration(
            kitID: "HashTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("name"), .blob("content_hash", nullable: true)],
                    primaryKey: ["id"],
                    hashable: true
                )
            ]
        )
        try await storage.open(schema: schema)

        let config = HashOnWriteConfig(
            hashableTables: ["items"],
            hashProvider: Self.testHash,
            parentChainProvider: Self.testParentChain
        )

        let hashingStore = HashingRowStore(
            backing: storage.rowStore,
            config: config
        )

        let id = UUID()
        _ = try await hashingStore.insert(
            table: "items",
            values: ["id": .uuid(id), "name": .text("hello")]
        )

        let rows = try await hashingStore.query(table: "items")
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("hello"))

        let count = try await hashingStore.count(table: "items", where: nil)
        #expect(count == 1)
    }

    @Test func hashableFieldDefaultsFalse() {
        let table = TableDeclaration(
            name: "test",
            columns: [.uuid("id")],
            primaryKey: ["id"]
        )
        #expect(table.hashable == false)

        let hashableTable = TableDeclaration(
            name: "test",
            columns: [.uuid("id")],
            primaryKey: ["id"],
            hashable: true
        )
        #expect(hashableTable.hashable == true)
    }

    @Test func defaultObserveDirtyChainReturnsFinishedStream() async {
        let observer = NoOpObserver()
        let stream = observer.observeDirtyChain()
        var count = 0
        for await _ in stream {
            count += 1
        }
        #expect(count == 0, "Default dirty-chain stream should be immediately finished")
    }
}
