// SQLiteIntrospectionTests.swift
//
// Verifies the StorageIntrospection conformance of SQLiteStorage.
// Tests focus on the fields the SQLite backend can supply:
// logicalSizeBytes, pageSize, pageCount, freelistPageCount, walFrameCount.
// The lockContention field is tested structurally (its presence, not
// a live-lock scenario — inducing a cross-process lock from a test is
// unsafe and outside the test scope).

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite

@Suite("SQLiteIntrospectionTests")
struct SQLiteIntrospectionTests {

    // Minimal schema used across tests.
    private static let schema = SchemaDeclaration(
        kitID: "introspect-test",
        version: 1,
        tables: [
            TableDeclaration(
                name: "items",
                columns: [
                    ColumnDeclaration(name: "id", type: .uuid, nullable: false),
                    ColumnDeclaration(name: "label", type: .text, nullable: false)
                ],
                primaryKey: ["id"]
            )
        ]
    )

    // Open a fresh in-temp-dir SQLiteStorage for each test.
    private func makeStorage() throws -> SQLiteStorage {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-introspect-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("test.db")
        let cfg = EstateConfiguration(estateID: UUID(), backend: .sqlite(url: url))
        return try SQLiteStorage(configuration: cfg)
    }

    @Test("SQLiteStorage conforms to StorageIntrospection")
    func conformsToStorageIntrospection() throws {
        // Bind as `Any` so the conformance check is a genuine runtime test;
        // casting the concrete type directly is statically always-true.
        let storage: Any = try makeStorage()
        #expect(storage is any StorageIntrospection, "SQLiteStorage must conform to StorageIntrospection")
    }

    @Test("stats returns non-negative logicalSizeBytes after open")
    func statsSizeIsNonNegativeAfterOpen() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: Self.schema)
        defer { Task { await storage.close() } }

        let stats = try await storage.stats(now: Date())
        #expect(stats.logicalSizeBytes >= 0, "logicalSizeBytes must be non-negative")
    }

    @Test("pageSize is a positive power of two")
    func pageSizeIsPositivePowerOfTwo() async throws {
        // SQLite page sizes are always a power of two in the range [512, 65536].
        let storage = try makeStorage()
        try await storage.open(schema: Self.schema)
        defer { Task { await storage.close() } }

        let stats = try await storage.stats(now: Date())
        let ps = try #require(stats.pageSize, "SQLite backend must supply pageSize")
        #expect(ps > 0, "pageSize must be positive")
        // Power-of-two check: ps & (ps - 1) == 0.
        #expect(ps & (ps - 1) == 0, "pageSize must be a power of two")
    }

    @Test("pageCount is positive after open")
    func pageCountIsPositiveAfterOpen() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: Self.schema)
        defer { Task { await storage.close() } }

        let stats = try await storage.stats(now: Date())
        let pc = try #require(stats.pageCount, "SQLite backend must supply pageCount")
        #expect(pc > 0, "pageCount must be positive after open")
    }

    @Test("logicalSizeBytes equals pageCount times pageSize")
    func logicalSizeMatchesPageCountTimesPageSize() async throws {
        // The SQLite backend computes logicalSizeBytes = page_count * page_size.
        let storage = try makeStorage()
        try await storage.open(schema: Self.schema)
        defer { Task { await storage.close() } }

        let stats = try await storage.stats(now: Date())
        let ps = try #require(stats.pageSize)
        let pc = try #require(stats.pageCount)
        #expect(stats.logicalSizeBytes == Int64(pc) * Int64(ps),
                "logicalSizeBytes must equal pageCount * pageSize")
    }

    @Test("freelistPageCount is non-negative")
    func freelistPageCountIsNonNegative() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: Self.schema)
        defer { Task { await storage.close() } }

        let stats = try await storage.stats(now: Date())
        let fl = try #require(stats.freelistPageCount, "SQLite backend must supply freelistPageCount")
        #expect(fl >= 0, "freelistPageCount must be non-negative")
    }

    @Test("walFrameCount is non-negative after open in WAL mode")
    func walFrameCountIsNonNegative() async throws {
        // SQLiteStorage opens in WAL mode (PRAGMA journal_mode = WAL),
        // so wal_checkpoint(PASSIVE) must succeed and return a non-negative frame count.
        let storage = try makeStorage()
        try await storage.open(schema: Self.schema)
        defer { Task { await storage.close() } }

        let stats = try await storage.stats(now: Date())
        // walFrameCount may be 0 immediately after a fresh open (no commits yet
        // to flush to WAL), but it must not be nil.
        let wfc = try #require(stats.walFrameCount, "SQLite backend must supply walFrameCount in WAL mode")
        #expect(wfc >= 0, "walFrameCount must be non-negative")
    }

    @Test("capturedAt matches the now parameter")
    func capturedAtMatchesNowParameter() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: Self.schema)
        defer { Task { await storage.close() } }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stats = try await storage.stats(now: now)
        #expect(stats.capturedAt == now, "capturedAt must equal the injected now parameter")
    }

    @Test("PostgreSQL-specific fields are nil for SQLite backend")
    func postgresSpecificFieldsAreNil() async throws {
        // The SQLite backend cannot supply PostgreSQL-specific stats.
        let storage = try makeStorage()
        try await storage.open(schema: Self.schema)
        defer { Task { await storage.close() } }

        let stats = try await storage.stats(now: Date())
        #expect(stats.cacheHitRatio == nil, "cacheHitRatio must be nil for SQLite")
        #expect(stats.transactionCommitCount == nil, "transactionCommitCount must be nil for SQLite")
        #expect(stats.transactionRollbackCount == nil, "transactionRollbackCount must be nil for SQLite")
        #expect(stats.deadlockCount == nil, "deadlockCount must be nil for SQLite")
    }

    @Test("InMemory-specific fields are nil for SQLite backend")
    func inMemorySpecificFieldsAreNil() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: Self.schema)
        defer { Task { await storage.close() } }

        let stats = try await storage.stats(now: Date())
        #expect(stats.rowCount == nil, "rowCount must be nil for SQLite")
        #expect(stats.blobCount == nil, "blobCount must be nil for SQLite")
    }

    @Test("logicalSizeBytes grows after inserting rows")
    func sizeGrowsAfterInserts() async throws {
        // Insert a batch of rows, then confirm the logical size is at least as
        // large as it was before. (SQLite may not flush every insert to a new page
        // immediately, but the schema page count only grows.)
        let storage = try makeStorage()
        try await storage.open(schema: Self.schema)
        defer { Task { await storage.close() } }

        let before = try await storage.stats(now: Date())

        // Insert enough rows to force at least one new page allocation.
        for _ in 0..<100 {
            _ = try await storage.rowStore.insert(
                table: "items",
                values: ["id": .uuid(UUID()), "label": .text(String(repeating: "x", count: 200))]
            )
        }

        let after = try await storage.stats(now: Date())
        // Size must not have decreased.
        #expect(after.logicalSizeBytes >= before.logicalSizeBytes,
                "logicalSizeBytes must not decrease after inserts")
    }
}
