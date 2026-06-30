// SecurityHardeningTests.swift
//
// Regression tests for SECFIX-WS2-PK planned security hardening (SQLite backend).
//
// F1 — SQL identifier injection guard: caller-supplied column names must be
//      rejected when they contain characters outside [A-Za-z_][A-Za-z0-9_]*.
//      A name like `id" FROM items; DROP TABLE items; --` can escape the
//      double-quote delimiter used in dynamically-constructed SELECT lists.
//
// F3 — SQLite blob observer isolation: blob change notifications must not be
//      delivered to observers when the enclosing SQLite transaction is rolled back.
//      Prior to the fix, `putBlob`/`deleteBlob` emitted `BlobChange` immediately
//      after the SQLite step — before COMMIT — so a ROLLBACK left observers
//      holding phantom-payload notifications.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite

// MARK: - Shared helpers

private func makeSQLiteStorage() throws -> SQLiteStorage {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("secfix-sqlite-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: dir.appendingPathComponent("test.sqlite"), busyTimeout: 5.0)
    ))
}

private func simpleSchema() -> SchemaDeclaration {
    SchemaDeclaration(
        kitID: "SecFixSQLiteTestKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "items",
                columns: [.uuid("id"), .text("label"), .bitmap("flags")],
                primaryKey: ["id"]
            )
        ]
    )
}

/// Convenience: projected query through `any RowStore` existential.
/// Uses the full-form overload that accepts the `columns:` projection list.
private func queryProjected(
    _ rowStore: any RowStore,
    table: String,
    columns: [String]
) async throws -> [StorageRow] {
    try await rowStore.query(
        table: table,
        where: nil,
        orderBy: [],
        limit: nil,
        offset: nil,
        columns: columns
    )
}

// MARK: - F1: SQL Identifier Injection Guard

@Suite("SecurityHardeningTests — F1 identifier guard")
struct F1IdentifierGuardTests {

    /// A column name containing a double-quote character must be rejected before
    /// it is embedded in a dynamically-constructed SELECT list. The name
    /// `id" FROM items; DROP TABLE items; --` escapes the double-quote delimiter
    /// and alters the query.
    @Test func rejectsDoubleQuoteInColumnName() async throws {
        let storage = try makeSQLiteStorage()
        try await storage.open(schema: simpleSchema())
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["id": .uuid(UUID()), "label": .text("ok"), "flags": .bitmap(0)]
        )
        let badName = #"id" FROM items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: badName)) {
            _ = try await queryProjected(storage.rowStore, table: "items", columns: [badName])
        }
    }

    /// Semicolons are a statement-separator injection vector and must be rejected.
    @Test func rejectsSemicolonInColumnName() async throws {
        let storage = try makeSQLiteStorage()
        try await storage.open(schema: simpleSchema())
        let badName = "id; DROP TABLE items; --"
        await #expect(throws: StorageError.invalidIdentifier(name: badName)) {
            _ = try await queryProjected(storage.rowStore, table: "items", columns: [badName])
        }
    }

    /// Spaces are not in the safe-identifier charset and must be rejected.
    @Test func rejectsSpaceInColumnName() async throws {
        let storage = try makeSQLiteStorage()
        try await storage.open(schema: simpleSchema())
        await #expect(throws: StorageError.invalidIdentifier(name: "my column")) {
            _ = try await queryProjected(storage.rowStore, table: "items", columns: ["my column"])
        }
    }

    /// An empty string is not a valid identifier and must be rejected.
    @Test func rejectsEmptyColumnName() async throws {
        let storage = try makeSQLiteStorage()
        try await storage.open(schema: simpleSchema())
        await #expect(throws: StorageError.invalidIdentifier(name: "")) {
            _ = try await queryProjected(storage.rowStore, table: "items", columns: [""])
        }
    }

    /// A digit-leading name is not a valid SQL identifier (reserved for literals).
    @Test func rejectsDigitLeadingColumnName() async throws {
        let storage = try makeSQLiteStorage()
        try await storage.open(schema: simpleSchema())
        await #expect(throws: StorageError.invalidIdentifier(name: "1id")) {
            _ = try await queryProjected(storage.rowStore, table: "items", columns: ["1id"])
        }
    }

    /// Valid column names within [A-Za-z_][A-Za-z0-9_]* must be accepted.
    @Test func acceptsValidColumnNames() async throws {
        let storage = try makeSQLiteStorage()
        try await storage.open(schema: simpleSchema())
        let id = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["id": .uuid(id), "label": .text("hello"), "flags": .bitmap(0)]
        )
        // All three schema columns are valid identifiers — must not throw.
        let rows = try await queryProjected(storage.rowStore, table: "items", columns: ["id", "label", "flags"])
        #expect(rows.count == 1)
        #expect(rows[0]["id"] == .uuid(id))
        #expect(rows[0]["label"] == .text("hello"))
    }

    /// Underscore-leading and underscore-containing names are valid identifiers.
    @Test func acceptsUnderscoreIdentifiers() async throws {
        let schema = SchemaDeclaration(
            kitID: "SecFixUnderscoreKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "things",
                    columns: [.uuid("row_id"), .text("_label")],
                    primaryKey: ["row_id"]
                )
            ]
        )
        let storage = try makeSQLiteStorage()
        try await storage.open(schema: schema)
        let id = UUID()
        _ = try await storage.rowStore.insert(
            table: "things",
            values: ["row_id": .uuid(id), "_label": .text("x")]
        )
        let rows = try await queryProjected(storage.rowStore, table: "things", columns: ["row_id", "_label"])
        #expect(rows.count == 1)
    }
}

// MARK: - F3: SQLite Blob Observer Isolation

@Suite("SecurityHardeningTests — F3 blob observer isolation")
struct F3BlobObserverIsolationTests {

    /// A blob written during a transaction that is subsequently rolled back
    /// must not be delivered to blob observers. Delivering the event would
    /// allow a sync engine to replicate payload that no longer exists in storage.
    @Test func rolledBackBlobWriteDoesNotFireObserver() async throws {
        let storage = try makeSQLiteStorage()
        try await storage.open(schema: simpleSchema())

        let blobStream = storage.observer.observeBlobs()
        let collectTask = Task<BlobChange?, Never> {
            for await change in blobStream { return change }
            return nil
        }
        // Pause to let the subscription register.
        try await Task.sleep(nanoseconds: 50_000_000)

        let blobKey = "secfix/f3/\(UUID().uuidString)"

        // Run a transaction that puts a blob then throws — forcing rollback.
        struct ForcedRollback: Error {}
        do {
            try await storage.transaction { txn in
                try await txn.blobStore.put(key: blobKey, bytes: Data([0x01, 0x02, 0x03]))
                throw ForcedRollback()
            }
        } catch is ForcedRollback {}

        // 100ms window: no event should arrive for a rolled-back transaction.
        let timeoutTask = Task<BlobChange?, Never> {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return nil
        }
        let winner = await withTaskGroup(of: BlobChange?.self) { group in
            group.addTask { await collectTask.value }
            group.addTask { await timeoutTask.value }
            let first = await group.next() ?? nil
            group.cancelAll()
            collectTask.cancel()
            timeoutTask.cancel()
            return first
        }

        #expect(
            winner == nil,
            "Blob observer received an event for a rolled-back SQLite transaction"
        )

        // The blob itself must not exist in storage after the rollback.
        let stored = try await storage.blobStore.get(key: blobKey)
        #expect(stored == nil, "Rolled-back blob must not be readable from storage")
    }

    /// A blob written in a committed transaction MUST fire the observer.
    /// Confirms the buffering mechanism doesn't accidentally suppress all events.
    @Test func committedBlobWriteFiresObserver() async throws {
        let storage = try makeSQLiteStorage()
        try await storage.open(schema: simpleSchema())

        let blobStream = storage.observer.observeBlobs()
        let collectTask = Task<BlobChange?, Never> {
            for await change in blobStream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let blobKey = "secfix/f3/committed/\(UUID().uuidString)"
        try await storage.transaction { txn in
            try await txn.blobStore.put(key: blobKey, bytes: Data([0xAB, 0xCD]))
        }

        // 500ms budget for the committed event to arrive.
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

        #expect(change != nil, "Committed blob put must fire the blob observer")
        #expect(change?.key == blobKey)
        #expect(change?.event == .put)
    }

    /// A blob deleted during a rolled-back transaction must not fire a delete event,
    /// and the blob must still be readable after the rollback.
    @Test func rolledBackBlobDeleteDoesNotFireObserver() async throws {
        let storage = try makeSQLiteStorage()
        try await storage.open(schema: simpleSchema())

        let blobKey = "secfix/f3/delete/\(UUID().uuidString)"
        // Pre-insert the blob outside any transaction.
        try await storage.blobStore.put(key: blobKey, bytes: Data([0xFF]))

        let blobStream = storage.observer.observeBlobs()
        let collectTask = Task<BlobChange?, Never> {
            for await change in blobStream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Roll back a transaction that deletes the blob.
        struct ForcedRollback: Error {}
        do {
            try await storage.transaction { txn in
                try await txn.blobStore.delete(key: blobKey)
                throw ForcedRollback()
            }
        } catch is ForcedRollback {}

        let timeoutTask = Task<BlobChange?, Never> {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return nil
        }
        let winner = await withTaskGroup(of: BlobChange?.self) { group in
            group.addTask { await collectTask.value }
            group.addTask { await timeoutTask.value }
            let first = await group.next() ?? nil
            group.cancelAll()
            collectTask.cancel()
            timeoutTask.cancel()
            return first
        }

        #expect(
            winner == nil,
            "Blob observer received a delete event for a rolled-back SQLite transaction"
        )

        // Blob must still exist after the rollback.
        let stored = try await storage.blobStore.get(key: blobKey)
        #expect(stored != nil, "Blob must still exist after transaction rollback")
    }
}

// MARK: - F1 Write-Path Extension: insert / upsert / update injection guard (CAND-047)
//
// The F1 guard above covers `queryProjected`. These tests confirm the same
// `validateSQLIdentifier` gate is active on every write path: insertRow,
// upsertRow (value keys AND conflict columns), and updateRows.

@Suite("SecurityHardeningTests — F1 write-path identifier guard (CAND-047)")
struct F1WritePathInjectionTests {

    /// Shared helpers — minimal schema matching the items table above.
    private func storage() async throws -> SQLiteStorage {
        let s = try makeSQLiteStorage()
        try await s.open(schema: simpleSchema())
        return s
    }

    // ── insert ────────────────────────────────────────────────────────────

    /// A double-quote in a value-map column name escapes the INSERT column
    /// list delimiter. Must be rejected before the SQL string is built.
    @Test func insertRejectsDoubleQuoteInColumnName() async throws {
        let s = try await storage()
        let badName = #"id" FROM items; DROP TABLE items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: badName)) {
            _ = try await s.rowStore.insert(
                table: "items",
                values: [badName: .text("x")]
            )
        }
    }

    /// Semicolons in a column name allow statement stacking — rejected on insert.
    @Test func insertRejectsSemicolonInColumnName() async throws {
        let s = try await storage()
        let badName = "id;DROP TABLE items"
        await #expect(throws: StorageError.invalidIdentifier(name: badName)) {
            _ = try await s.rowStore.insert(table: "items", values: [badName: .text("x")])
        }
    }

    /// A digit-leading column name is rejected on insert.
    @Test func insertRejectsDigitLeadingColumnName() async throws {
        let s = try await storage()
        await #expect(throws: StorageError.invalidIdentifier(name: "1evil")) {
            _ = try await s.rowStore.insert(table: "items", values: ["1evil": .text("x")])
        }
    }

    /// A column name with a space is rejected on insert.
    @Test func insertRejectsSpaceInColumnName() async throws {
        let s = try await storage()
        await #expect(throws: StorageError.invalidIdentifier(name: "col name")) {
            _ = try await s.rowStore.insert(table: "items", values: ["col name": .text("x")])
        }
    }

    /// A valid insert must still succeed — the guard must not break normal writes.
    @Test func insertAcceptsValidColumnNames() async throws {
        let s = try await storage()
        let id = UUID()
        _ = try await s.rowStore.insert(
            table: "items",
            values: ["id": .uuid(id), "label": .text("safe"), "flags": .bitmap(0)]
        )
        let rows = try await s.rowStore.query(
            table: "items", where: nil, orderBy: [], limit: nil, offset: nil
        )
        #expect(rows.count == 1)
    }

    // ── upsert ────────────────────────────────────────────────────────────

    /// Injected column name in the value map is rejected on upsert.
    @Test func upsertRejectsInjectedValueColumn() async throws {
        let s = try await storage()
        let badName = #"id"); DROP TABLE items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: badName)) {
            _ = try await s.rowStore.upsert(
                table: "items",
                values: [badName: .text("x")],
                conflictColumns: ["id"]
            )
        }
    }

    /// Injected column name in the conflict-column list is rejected on upsert.
    @Test func upsertRejectsInjectedConflictColumn() async throws {
        let s = try await storage()
        let badConflict = #"id"); DROP TABLE items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: badConflict)) {
            _ = try await s.rowStore.upsert(
                table: "items",
                values: ["id": .uuid(UUID()), "label": .text("x"), "flags": .bitmap(0)],
                conflictColumns: [badConflict]
            )
        }
    }

    /// A valid upsert must still succeed.
    @Test func upsertAcceptsValidIdentifiers() async throws {
        let s = try await storage()
        let id = UUID()
        _ = try await s.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(id), "label": .text("hello"), "flags": .bitmap(0)],
            conflictColumns: ["id"]
        )
        let rows = try await s.rowStore.query(
            table: "items", where: nil, orderBy: [], limit: nil, offset: nil
        )
        #expect(rows.count == 1)
    }

    // ── update ────────────────────────────────────────────────────────────

    /// Injected column name in the SET map is rejected on update.
    @Test func updateRejectsInjectedColumnName() async throws {
        let s = try await storage()
        let badName = #"label"; DROP TABLE items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: badName)) {
            _ = try await s.rowStore.update(
                table: "items",
                values: [badName: .text("x")],
                where: .isTrue
            )
        }
    }

    /// A valid update must still succeed.
    @Test func updateAcceptsValidColumnNames() async throws {
        let s = try await storage()
        let id = UUID()
        _ = try await s.rowStore.insert(
            table: "items",
            values: ["id": .uuid(id), "label": .text("before"), "flags": .bitmap(0)]
        )
        let count = try await s.rowStore.update(
            table: "items",
            values: ["label": .text("after")],
            where: .eq(Column(table: "items", name: "id"), .uuid(id))
        )
        #expect(count == 1)
    }
}

// MARK: - SECFIX-WS2-PK F9: Table-name injection guard (SQLite RowStore methods)
//
// Every RowStore method that interpolates a table name into SQL must validate it
// before SQL construction. This extends the column-name guard (F7) to the table
// identifier surface (F9): insert, upsert, update, delete, query, count, and
// queryRowsSkipCorrupt. A table name like `items"; DROP TABLE items; --` can
// escape the double-quote delimiter when interpolated directly into a FROM or
// INTO clause.

@Suite("SecurityHardeningTests — F9 table-name identifier guard (SECFIX-WS2-PK)")
struct F9TableNameInjectionTests {

    private func storage() async throws -> SQLiteStorage {
        let s = try makeSQLiteStorage()
        try await s.open(schema: simpleSchema())
        return s
    }

    // ── query (read path) ─────────────────────────────────────────────────

    /// A double-quote in the table name must be rejected before SELECT SQL is built.
    @Test func queryRejectsDoubleQuoteInTableName() async throws {
        let s = try await storage()
        let bad = #"items" UNION SELECT * FROM items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.query(
                table: bad, where: nil, orderBy: [], limit: nil, offset: nil
            )
        }
    }

    /// A semicolon in the table name is a statement-stacking vector.
    @Test func queryRejectsSemicolonInTableName() async throws {
        let s = try await storage()
        let bad = "items; DROP TABLE items; --"
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.query(
                table: bad, where: nil, orderBy: [], limit: nil, offset: nil
            )
        }
    }

    /// Space-containing table names are rejected.
    @Test func queryRejectsSpaceInTableName() async throws {
        let s = try await storage()
        await #expect(throws: StorageError.invalidIdentifier(name: "bad table")) {
            _ = try await s.rowStore.query(
                table: "bad table", where: nil, orderBy: [], limit: nil, offset: nil
            )
        }
    }

    /// A valid table name must still produce correct results.
    @Test func queryAcceptsValidTableName() async throws {
        let s = try await storage()
        let id = UUID()
        _ = try await s.rowStore.insert(
            table: "items",
            values: ["id": .uuid(id), "label": .text("hello"), "flags": .bitmap(0)]
        )
        let rows = try await s.rowStore.query(
            table: "items", where: nil, orderBy: [], limit: nil, offset: nil
        )
        #expect(rows.count == 1)
    }

    // ── count ─────────────────────────────────────────────────────────────

    /// A double-quote in the table name must be rejected in countRows.
    @Test func countRejectsDoubleQuoteInTableName() async throws {
        let s = try await storage()
        let bad = #"items" UNION SELECT 1; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.count(table: bad, where: nil)
        }
    }

    // ── delete ────────────────────────────────────────────────────────────

    /// A double-quote in the table name must be rejected in deleteRows.
    @Test func deleteRejectsDoubleQuoteInTableName() async throws {
        let s = try await storage()
        let bad = #"items" WHERE 1=1; DROP TABLE items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.delete(
                table: bad, where: .isTrue
            )
        }
    }

    // ── insert ────────────────────────────────────────────────────────────

    /// A double-quote in the table name must be rejected in insert.
    @Test func insertRejectsDoubleQuoteInTableName() async throws {
        let s = try await storage()
        let bad = #"items"; DROP TABLE items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.insert(
                table: bad,
                values: ["id": .uuid(UUID()), "label": .text("x"), "flags": .bitmap(0)]
            )
        }
    }

    // ── upsert ────────────────────────────────────────────────────────────

    /// A double-quote in the table name must be rejected in upsert.
    @Test func upsertRejectsDoubleQuoteInTableName() async throws {
        let s = try await storage()
        let bad = #"items"; DROP TABLE items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.upsert(
                table: bad,
                values: ["id": .uuid(UUID()), "label": .text("x"), "flags": .bitmap(0)],
                conflictColumns: ["id"]
            )
        }
    }

    // ── update ────────────────────────────────────────────────────────────

    /// A double-quote in the table name must be rejected in update.
    @Test func updateRejectsDoubleQuoteInTableName() async throws {
        let s = try await storage()
        let bad = #"items"; DROP TABLE items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.update(
                table: bad,
                values: ["label": .text("x")],
                where: .isTrue
            )
        }
    }
}

// MARK: - SECFIX-WS2-PK F7: ORDER BY column injection guard (SQLite)
//
// The ORDER BY renderer interpolates column names from caller-supplied
// OrderClause values. A malicious column name like `label"; DROP TABLE items; --`
// can escape the double-quote delimiter. These tests confirm the guard fires
// for query and queryRowsSkipCorrupt.

@Suite("SecurityHardeningTests — F7 ORDER BY column identifier guard (SECFIX-WS2-PK)")
struct F7OrderByInjectionTests {

    private func storage() async throws -> SQLiteStorage {
        let s = try makeSQLiteStorage()
        try await s.open(schema: simpleSchema())
        return s
    }

    /// A double-quote in an ORDER BY column name must be rejected by query.
    @Test func queryRejectsDoubleQuoteInOrderByColumn() async throws {
        let s = try await storage()
        let bad = #"label"; DROP TABLE items; --"#
        let badClause = OrderClause(column: Column(table: "items", name: bad), direction: .ascending)
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.query(
                table: "items", where: nil, orderBy: [badClause], limit: nil, offset: nil
            )
        }
    }

    /// A semicolon in an ORDER BY column name must be rejected by query.
    @Test func queryRejectsSemicolonInOrderByColumn() async throws {
        let s = try await storage()
        let bad = "label; DROP TABLE items; --"
        let badClause = OrderClause(column: Column(table: "items", name: bad), direction: .ascending)
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.query(
                table: "items", where: nil, orderBy: [badClause], limit: nil, offset: nil
            )
        }
    }

    /// A valid ORDER BY column name must produce correct results.
    @Test func queryAcceptsValidOrderByColumn() async throws {
        let s = try await storage()
        let id1 = UUID()
        let id2 = UUID()
        _ = try await s.rowStore.insert(
            table: "items",
            values: ["id": .uuid(id1), "label": .text("b"), "flags": .bitmap(0)]
        )
        _ = try await s.rowStore.insert(
            table: "items",
            values: ["id": .uuid(id2), "label": .text("a"), "flags": .bitmap(0)]
        )
        let rows = try await s.rowStore.query(
            table: "items",
            where: nil,
            orderBy: [OrderClause(column: Column(table: "items", name: "label"), direction: .ascending)],
            limit: nil,
            offset: nil
        )
        #expect(rows.count == 2)
        #expect(rows[0]["label"] == .text("a"))
        #expect(rows[1]["label"] == .text("b"))
    }
}

// MARK: - SECFIX-WS2-PK F10: queryRowsSkipCorrupt column projection + table guard
//
// queryRowsSkipCorrupt shares the same SQL projection surface as queryRows but
// was previously missing both the table-name guard (F9) and the projection
// column guard (F10). These tests confirm both gaps are closed.

@Suite("SecurityHardeningTests — F10 queryRowsSkipCorrupt identifier guards (SECFIX-WS2-PK)")
struct F10SkipCorruptProjectionTests {

    private func storage() async throws -> SQLiteStorage {
        let s = try makeSQLiteStorage()
        try await s.open(schema: simpleSchema())
        return s
    }

    /// A double-quote in a projected column name must be rejected by
    /// queryRowsSkipCorrupt, just as it is by queryRows (F1).
    @Test func skipCorruptRejectsDoubleQuoteInProjectionColumn() async throws {
        let s = try await storage()
        _ = try await s.rowStore.insert(
            table: "items",
            values: ["id": .uuid(UUID()), "label": .text("ok"), "flags": .bitmap(0)]
        )
        let bad = #"id" FROM items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.querySkipCorrupt(
                table: "items", where: nil, orderBy: [], limit: nil, offset: nil, columns: [bad]
            )
        }
    }

    /// A semicolon in a projected column name must be rejected.
    @Test func skipCorruptRejectsSemicolonInProjectionColumn() async throws {
        let s = try await storage()
        let bad = "id; DROP TABLE items; --"
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.querySkipCorrupt(
                table: "items", where: nil, orderBy: [], limit: nil, offset: nil, columns: [bad]
            )
        }
    }

    /// A double-quote in the table name must be rejected by queryRowsSkipCorrupt.
    @Test func skipCorruptRejectsDoubleQuoteInTableName() async throws {
        let s = try await storage()
        let bad = #"items" UNION SELECT * FROM items; --"#
        await #expect(throws: StorageError.invalidIdentifier(name: bad)) {
            _ = try await s.rowStore.querySkipCorrupt(
                table: bad, where: nil, orderBy: [], limit: nil, offset: nil, columns: nil
            )
        }
    }

    /// Valid table and column names must still produce correct results.
    @Test func skipCorruptAcceptsValidIdentifiers() async throws {
        let s = try await storage()
        let id = UUID()
        _ = try await s.rowStore.insert(
            table: "items",
            values: ["id": .uuid(id), "label": .text("ok"), "flags": .bitmap(0)]
        )
        // Project two valid columns; the third (flags) is intentionally omitted.
        let result = try await s.rowStore.querySkipCorrupt(
            table: "items", where: nil, orderBy: [], limit: nil, offset: nil, columns: ["id", "label"]
        )
        #expect(result.rows.count == 1)
        #expect(result.skipped == 0)
        #expect(result.rows[0]["id"] == .uuid(id))
    }
}

// MARK: - CAND-052: Estate DB file symlink refusal
//
// A symlink pre-planted at the database path must be refused before
// sqlite3_open_v2 is called. Allowing a symlink would redirect SQLite
// writes to an arbitrary file controlled by an attacker. Apple Data
// Protection (already applied in SQLiteConnection.init) covers the DB
// file at rest; this guard addresses the symlink-redirection attack
// surface, which is orthogonal to at-rest encryption.

@Suite("SecurityHardeningTests — CAND-052 DB file symlink refusal")
struct CAND052SymlinkRefusalTests {

    /// Build a temp directory and return a unique DB URL within it.
    private func tempDBURL(tag: String = UUID().uuidString) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cand052-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("estate.sqlite")
        return (dir, dbURL)
    }

    /// A symlink pre-planted at the estate DB path must be refused with a
    /// `backendError` before `sqlite3_open_v2` is called. Allowing the open
    /// would write to the symlink's target rather than the intended location.
    @Test func refusesSymlinkAtDBPath() async throws {
        let (dir, dbURL) = try tempDBURL(tag: "symlink")
        // Plant a symlink at the DB path pointing at an innocuous file.
        let decoy = dir.appendingPathComponent("decoy.txt")
        FileManager.default.createFile(atPath: decoy.path, contents: Data("decoy".utf8))
        try FileManager.default.createSymbolicLink(at: dbURL, withDestinationURL: decoy)

        let config = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        )
        // Opening must fail with a backend error naming the symlink threat.
        var threw = false
        do {
            _ = try SQLiteStorage(configuration: config)
        } catch StorageError.backendError(let underlying) where underlying.contains("symbolic link") {
            threw = true
        }
        #expect(threw, "SQLiteStorage.init must throw backendError for a symlink at the DB path")
    }

    /// Opening an already-existing regular (non-symlink) database file must
    /// succeed. This regression confirms the symlink guard does not block the
    /// normal open-existing-DB path.
    @Test func opensExistingRegularFile() async throws {
        let (_, dbURL) = try tempDBURL(tag: "existing")
        let config1 = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        )
        // First open creates the file.
        let s1 = try SQLiteStorage(configuration: config1)
        try await s1.open(schema: simpleSchema())
        // Second open of the same file must succeed.
        let config2 = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        )
        let s2 = try SQLiteStorage(configuration: config2)
        try await s2.open(schema: simpleSchema())
        // A basic round-trip confirms the estate is usable after reopen.
        let id = UUID()
        _ = try await s2.rowStore.insert(
            table: "items",
            values: ["id": .uuid(id), "label": .text("ok"), "flags": .bitmap(0)]
        )
        let rows = try await s2.rowStore.query(
            table: "items", where: nil, orderBy: [], limit: nil, offset: nil
        )
        #expect(rows.count == 1)
    }
}
