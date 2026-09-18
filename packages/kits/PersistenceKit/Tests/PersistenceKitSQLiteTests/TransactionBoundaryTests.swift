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

    // MARK: - V2 nesting probe (batch inserts inside open transaction)

    /// V2 nesting probe for commit 6751fc618 (VAULT-FIX-01 V2).
    ///
    /// Background: the Rust PersistenceKit SQLite backend had three call sites
    /// (transaction(), begin_transaction(), append_rows()) that all issued
    /// BEGIN IMMEDIATE on one connection. Only transaction() held the serialising
    /// lock; begin_transaction() and append_rows() had no such guard. When
    /// vault_import drove capture_batch inside an outer transaction() bracket,
    /// the inner begin_transaction() hit the same connection with a second
    /// BEGIN IMMEDIATE, producing "cannot start a transaction within a
    /// transaction". The Rust fix added a per-connection tx_depth counter with
    /// SAVEPOINTs so nested callers transparently use SAVEPOINT tx_N instead.
    ///
    /// Swift exposure (from V2 commit message): "verified-unaffected.
    /// SQLiteBackend throws transactionConflict loudly when inTransaction == true;
    /// it does not produce the silent SQLite nesting error." That was an argument;
    /// this test is the evidence.
    ///
    /// Why Swift is unaffected: SQLiteBackend's insertRow(), appendAuditBatch(),
    /// and all other individual write operations are synchronous actor calls that
    /// issue direct SQL (INSERT, etc.) without opening their own BEGIN IMMEDIATE.
    /// Only beginTransactionDirect() and runTransaction() issue BEGIN IMMEDIATE.
    /// Calling insertRow() inside an open beginTransactionDirect() bracket
    /// therefore runs correctly as part of that transaction, not as a nested one.
    ///
    /// This test pins the actual observed behaviour: five insertRow calls inside
    /// one open beginTransactionDirect() succeed and commit atomically. No
    /// nested-BEGIN conflict occurs, and no SAVEPOINT logic is needed in Swift.
    ///
    /// VERDICT: VERIFIED-UNAFFECTED — Swift batch inserts inside a
    /// beginTransactionDirect-opened transaction work correctly. The Rust
    /// SAVEPOINT fix does not have a Swift equivalent because the Swift insert
    /// path is direct SQL, not a re-entrant BEGIN IMMEDIATE site.
    @Test("V2 nesting probe: batch inserts inside beginTransactionDirect succeed (VAULT-FIX-01 V2)")
    func batchInsertsInsideBeginTransactionSucceed() async throws {
        let storage = try await makeSQLiteStorage()
        let rowStore = storage.rowStore

        // Open an explicit transaction — mirrors the outer bracket that
        // triggered the Rust crash (vault_import drove capture_batch inside a
        // transaction() block, and the inner begin_transaction() site issued
        // a second BEGIN IMMEDIATE on the same connection).
        try await rowStore.beginTransaction()
        defer {
            // Safety rollback if the test body throws before commit.
            Task { try? await rowStore.rollbackTransaction() }
        }

        // Batch: insert five rows while the transaction is open. Each call is a
        // synchronous actor dispatch to insertRow — no BEGIN IMMEDIATE is issued
        // by insertRow, so no nested-transaction conflict occurs. This is the
        // Swift analogue of the Rust append_rows() path that the V2 SAVEPOINT
        // fix covers via SAVEPOINT tx_N.
        let ids = (0..<5).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            _ = try await rowStore.insert(
                table: "items",
                values: rowValues(id: id, val: "v2-probe-\(i)"))
        }

        // Commit all five rows as one atomic unit.
        try await rowStore.commitTransaction()

        // Verify all five rows are retrievable — proof the batch committed and
        // no silent data loss occurred (a nested-BEGIN error would either throw
        // or silently drop the transaction depending on the backend).
        let rows = try await rowStore.query(table: "items", where: nil)
        #expect(rows.count == 5, "All 5 batch rows must persist; got \(rows.count). A nested-BEGIN conflict would prevent commit.")
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
