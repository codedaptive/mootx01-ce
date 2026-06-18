// CorruptReadBackTests.swift
//
// Verifies that the SQLite backend throws StorageError.corruptStoredValue
// when a stored TEXT value cannot be parsed to its declared column type.
//
// Strategy: write a valid row via the public RowStore API, then corrupt the
// stored value directly via a raw SQLite UPDATE (bypassing the kit's value
// codec), then attempt a read-back and assert the structured error — never
// a silently wrong value (random UUID, epoch-0 timestamp, etc.).
//
// The type-tolerant decode path (valid value in the wrong column affinity —
// e.g. an INTEGER where TEXT is expected) is distinct from parse failure and
// is NOT tested here; that path is intentionally lenient for cross-backend
// parity reasons and must stay unchanged.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite
import SQLCipher

// MARK: - Helpers

private func makeStorage() throws -> (SQLiteStorage, URL) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corrupt-readback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let dbURL = tmpDir.appendingPathComponent("test.sqlite")
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: dbURL, busyTimeout: 5.0)
    ))
    return (storage, dbURL)
}

/// Execute a raw SQL statement against a SQLite file, bypassing the kit.
/// Used exclusively to corrupt stored values for negative-path testing.
private func rawExec(_ dbURL: URL, _ sql: String) throws {
    var db: OpaquePointer?
    let rc = sqlite3_open(dbURL.path, &db)
    defer { sqlite3_close(db) }
    guard rc == SQLITE_OK, let db else {
        throw StorageError.backendError(underlying: "rawExec open failed: \(rc)")
    }
    var errMsg: UnsafeMutablePointer<CChar>?
    let rc2 = sqlite3_exec(db, sql, nil, nil, &errMsg)
    if rc2 != SQLITE_OK {
        let msg = errMsg.map { String(cString: $0) } ?? "exec failed"
        sqlite3_free(errMsg)
        throw StorageError.backendError(underlying: msg)
    }
}

// MARK: - UUID corruption

@Suite("SQLite fail-loud corrupt UUID read-back")
struct SQLiteCorruptUUIDReadBackTests {

    /// Schema with a declared .uuid column so readColumn resolves it to .uuid.
    private func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "CorruptUUIDTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [
                        .uuid("row_id"),
                        .uuid("ref_id"),  // second uuid column — this is the one we corrupt
                        .text("label")
                    ],
                    primaryKey: ["row_id"]
                )
            ]
        )
    }

    @Test("corrupt UUID column throws corruptStoredValue, not random UUID")
    func corruptUUIDColumnThrows() async throws {
        let (storage, dbURL) = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        let validRefID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: [
                "row_id": .uuid(rowID),
                "ref_id": .uuid(validRefID),
                "label": .text("original")
            ]
        )

        // Verify clean round-trip before corruption.
        let cleanRows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "row_id"), .uuid(rowID))
        )
        #expect(cleanRows.count == 1)
        guard case .uuid(let cleanRef) = cleanRows[0]["ref_id"] else {
            Issue.record("expected .uuid before corruption"); return
        }
        #expect(cleanRef == validRefID)

        // Close storage before raw SQL surgery so WAL is checkpointed.
        await storage.close()

        // Corrupt the ref_id column with a string that is not a valid UUID.
        let corruptSQL = "UPDATE \"items\" SET \"ref_id\" = 'NOT-A-UUID' WHERE \"row_id\" = '\(rowID.uuidString)'"
        try rawExec(dbURL, corruptSQL)

        // Reopen and attempt read-back — must throw, not silently substitute.
        let storage2 = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
        try await storage2.open(schema: makeSchema())

        await #expect(throws: StorageError.corruptStoredValue(
            table: "items",
            column: "ref_id",
            storedText: "NOT-A-UUID"
        )) {
            _ = try await storage2.rowStore.query(
                table: "items",
                where: .eq(Column(table: "items", name: "row_id"), .uuid(rowID))
            )
        }

        await storage2.close()
    }

    @Test("valid UUID string still reads back as .uuid after fix")
    func validUUIDRoundTrip() async throws {
        let (storage, _) = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        let refID = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: [
                "row_id": .uuid(rowID),
                "ref_id": .uuid(refID),
                "label": .text("valid")
            ]
        )
        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "row_id"), .uuid(rowID))
        )
        #expect(rows.count == 1)
        guard case .uuid(let readBack) = rows[0]["ref_id"] else {
            Issue.record("expected .uuid"); return
        }
        #expect(readBack == refID)
        await storage.close()
    }
}

// MARK: - Timestamp corruption

@Suite("SQLite fail-loud corrupt timestamp read-back")
struct SQLiteCorruptTimestampReadBackTests {

    private func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "CorruptTimestampTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "events",
                    columns: [
                        .uuid("row_id"),
                        .timestamp("captured_at")
                    ],
                    primaryKey: ["row_id"]
                )
            ]
        )
    }

    @Test("corrupt timestamp column throws corruptStoredValue, not epoch-0")
    func corruptTimestampColumnThrows() async throws {
        let (storage, dbURL) = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        let validDate = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await storage.rowStore.insert(
            table: "events",
            values: [
                "row_id": .uuid(rowID),
                "captured_at": .timestamp(validDate)
            ]
        )

        await storage.close()

        // Corrupt the timestamp with a string that is not ISO-8601.
        let corruptSQL = "UPDATE \"events\" SET \"captured_at\" = 'definitely-not-a-date' WHERE \"row_id\" = '\(rowID.uuidString)'"
        try rawExec(dbURL, corruptSQL)

        let storage2 = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
        try await storage2.open(schema: makeSchema())

        await #expect(throws: StorageError.corruptStoredValue(
            table: "events",
            column: "captured_at",
            storedText: "definitely-not-a-date"
        )) {
            _ = try await storage2.rowStore.query(
                table: "events",
                where: .eq(Column(table: "events", name: "row_id"), .uuid(rowID))
            )
        }

        await storage2.close()
    }

    @Test("valid ISO-8601 timestamp still reads back correctly after fix")
    func validTimestampRoundTrip() async throws {
        let (storage, _) = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await storage.rowStore.insert(
            table: "events",
            values: [
                "row_id": .uuid(rowID),
                "captured_at": .timestamp(originalDate)
            ]
        )
        let rows = try await storage.rowStore.query(
            table: "events",
            where: .eq(Column(table: "events", name: "row_id"), .uuid(rowID))
        )
        #expect(rows.count == 1)
        guard case .timestamp(let readBack) = rows[0]["captured_at"] else {
            Issue.record("expected .timestamp"); return
        }
        // ISO-8601 round-trip loses sub-second precision; compare to the second.
        #expect(abs(readBack.timeIntervalSince1970 - originalDate.timeIntervalSince1970) < 1.0)
        await storage.close()
    }
}

// MARK: - Audit row UUID corruption

@Suite("SQLite fail-loud corrupt audit UUID read-back")
struct SQLiteCorruptAuditUUIDTests {

    @Test("corrupt event_id in audit table throws corruptStoredValue")
    func corruptAuditEventIDThrows() async throws {
        let (storage, dbURL) = try makeStorage()
        try await storage.open(schema: SchemaDeclaration(
            kitID: "CorruptAuditTest", version: 1, tables: []
        ))

        let hlc = HLC(physicalTime: 1000, logicalCount: 1, nodeID: 1)
        let event = AuditEvent(
            estateUuid: UUID(),
            rowId: UUID(),
            hlc: hlc,
            verb: "store",
            beforeBitmaps: nil,
            afterBitmaps: (1, 2, 3),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: LatticeAnchor(udcCode: 0),
            actor: "test"
        )
        try await storage.auditLog.append(event)

        await storage.close()

        // Corrupt the event_id column with a non-UUID string.
        let corruptSQL = "UPDATE \"_storagekit_audit\" SET \"event_id\" = 'NOT-A-UUID'"
        try rawExec(dbURL, corruptSQL)

        let storage2 = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
        try await storage2.open(schema: SchemaDeclaration(
            kitID: "CorruptAuditTest", version: 1, tables: []
        ))

        // The corrupt event_id must surface as an error, not a random UUID.
        await #expect(throws: StorageError.corruptStoredValue(
            table: "_storagekit_audit",
            column: "event_id",
            storedText: "NOT-A-UUID"
        )) {
            _ = try await storage2.auditLog.iterate(after: nil, rowID: nil, limit: 100)
        }

        await storage2.close()
    }

    @Test("valid audit event round-trips correctly after fix")
    func validAuditEventRoundTrip() async throws {
        let (storage, _) = try makeStorage()
        try await storage.open(schema: SchemaDeclaration(
            kitID: "AuditRoundTrip", version: 1, tables: []
        ))

        let estateID = UUID()
        let rowID = UUID()
        let hlc = HLC(physicalTime: 1_700_000_000, logicalCount: 42, nodeID: 3)
        let event = AuditEvent(
            estateUuid: estateID,
            rowId: rowID,
            hlc: hlc,
            verb: "store",
            beforeBitmaps: nil,
            afterBitmaps: (10, 20, 30),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: LatticeAnchor(udcCode: 99),
            actor: "round-trip-actor"
        )
        try await storage.auditLog.append(event)

        let events = try await storage.auditLog.iterate(after: nil, rowID: nil, limit: 10)
        #expect(events.count == 1)
        #expect(events[0].estateUuid == estateID)
        #expect(events[0].rowId == rowID)
        #expect(events[0].verb == "store")
        #expect(events[0].actor == "round-trip-actor")

        await storage.close()
    }
}
