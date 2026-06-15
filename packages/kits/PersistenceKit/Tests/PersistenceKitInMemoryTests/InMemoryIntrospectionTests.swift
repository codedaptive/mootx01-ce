// InMemoryIntrospectionTests.swift
//
// Verifies the StorageIntrospection conformance of InMemoryStorage.
// Tests focus on the fields the InMemory backend supplies: rowCount,
// blobCount, transactionRollbackCount, and approximate
// logicalSizeBytes. SQLite- and PostgreSQL-specific fields must be nil.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory

@Suite("InMemoryIntrospectionTests")
struct InMemoryIntrospectionTests {

    private static let schema = SchemaDeclaration(
        kitID: "inmem-introspect-test",
        version: 1,
        tables: [
            TableDeclaration(
                name: "nodes",
                columns: [
                    ColumnDeclaration(name: "id", type: .uuid, nullable: false),
                    ColumnDeclaration(name: "payload", type: .text, nullable: false)
                ],
                primaryKey: ["id"]
            )
        ]
    )

    private func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    }

    @Test("InMemoryStorage conforms to StorageIntrospection")
    func conformsToStorageIntrospection() {
        // Bind as `Any` so the conformance check is a genuine runtime test;
        // casting the concrete type directly is statically always-true.
        let storage: Any = makeStorage()
        #expect(storage is any StorageIntrospection, "InMemoryStorage must conform to StorageIntrospection")
    }

    @Test("rowCount is zero before any inserts")
    func rowCountIsZeroOnFreshStorage() async throws {
        let storage = makeStorage()
        try await storage.open(schema: Self.schema)

        let stats = await storage.stats(now: Date())
        #expect(stats.rowCount == 0, "rowCount must be 0 on empty storage")
    }

    @Test("rowCount reflects inserted rows")
    func rowCountReflectsInsertedRows() async throws {
        let storage = makeStorage()
        try await storage.open(schema: Self.schema)

        let n = 5
        for _ in 0..<n {
            _ = try await storage.rowStore.insert(
                table: "nodes",
                values: ["id": .uuid(UUID()), "payload": .text("hello")]
            )
        }

        let stats = await storage.stats(now: Date())
        #expect(stats.rowCount == n, "rowCount must equal the number of inserted rows")
    }

    @Test("blobCount reflects stored blobs")
    func blobCountReflectsStoredBlobs() async throws {
        let storage = makeStorage()
        try await storage.open(schema: Self.schema)

        try await storage.blobStore.put(key: "a", bytes: Data("hello".utf8))
        try await storage.blobStore.put(key: "b", bytes: Data("world".utf8))

        let stats = await storage.stats(now: Date())
        #expect(stats.blobCount == 2, "blobCount must equal the number of stored blobs")
    }

    @Test("transactionRollbackCount increments on user-block error")
    func rollbackCountIncrements() async throws {
        let storage = makeStorage()
        try await storage.open(schema: Self.schema)

        let before = await storage.stats(now: Date())
        #expect(before.transactionRollbackCount == 0 || before.transactionRollbackCount == nil,
                "rollbackCount must start at 0 or nil")

        // Execute a transaction that throws, forcing a rollback.
        struct TestError: Error {}
        do {
            _ = try await storage.transaction { _ in
                throw TestError()
            }
        } catch {}

        let after = await storage.stats(now: Date())
        let afterCount = after.transactionRollbackCount ?? 0
        #expect(afterCount == 1, "rollbackCount must be 1 after one failing transaction")
    }

    @Test("logicalSizeBytes grows after inserting blobs")
    func logicalSizeBytesGrowsWithBlobs() async throws {
        let storage = makeStorage()
        try await storage.open(schema: Self.schema)

        let before = await storage.stats(now: Date())
        let payload = Data(repeating: 0xFF, count: 1024)
        try await storage.blobStore.put(key: "bigblob", bytes: payload)

        let after = await storage.stats(now: Date())
        #expect(after.logicalSizeBytes > before.logicalSizeBytes,
                "logicalSizeBytes must grow after a large blob insert")
    }

    @Test("capturedAt matches the now parameter")
    func capturedAtMatchesNowParameter() async throws {
        let storage = makeStorage()
        try await storage.open(schema: Self.schema)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stats = await storage.stats(now: now)
        #expect(stats.capturedAt == now, "capturedAt must equal the injected now parameter")
    }

    @Test("SQLite-specific fields are nil for InMemory backend")
    func sqliteSpecificFieldsAreNil() async throws {
        let storage = makeStorage()
        try await storage.open(schema: Self.schema)

        let stats = await storage.stats(now: Date())
        #expect(stats.pageSize == nil, "pageSize must be nil for InMemory backend")
        #expect(stats.pageCount == nil, "pageCount must be nil for InMemory backend")
        #expect(stats.freelistPageCount == nil, "freelistPageCount must be nil for InMemory backend")
        #expect(stats.walFrameCount == nil, "walFrameCount must be nil for InMemory backend")
        #expect(stats.lockContention == nil, "lockContention must be nil for InMemory backend")
    }

    @Test("PostgreSQL-specific fields are nil for InMemory backend")
    func postgresSpecificFieldsAreNil() async throws {
        let storage = makeStorage()
        try await storage.open(schema: Self.schema)

        let stats = await storage.stats(now: Date())
        #expect(stats.cacheHitRatio == nil, "cacheHitRatio must be nil for InMemory backend")
        #expect(stats.transactionCommitCount == nil,
                "transactionCommitCount must be nil for InMemory backend")
        #expect(stats.deadlockCount == nil, "deadlockCount must be nil for InMemory backend")
    }
}
