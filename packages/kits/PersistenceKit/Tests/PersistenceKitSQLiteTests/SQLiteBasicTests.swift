// SQLiteBasicTests.swift

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite
import SQLCipher
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

struct SQLiteBasicTests {

    func makeStorage() throws -> SQLiteStorage {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storagekit-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("test.sqlite")
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
    }

    func makeSchema(version: Int = 1) -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "TestKit",
            version: version,
            tables: [
                TableDeclaration(
                    name: "drawers",
                    columns: [
                        .uuid("row_id"),
                        .bitmap("adjective"),
                        .bitmap("operational"),
                        .bitmap("provenance"),
                        .text("verbatim"),
                        .timestamp("captured_at")
                    ],
                    primaryKey: ["row_id"]
                )
            ]
        )
    }

    private func rawExec(_ dbURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open(dbURL.path, &db)
        defer { sqlite3_close(db) }
        guard rc == SQLITE_OK, let db else {
            throw StorageError.backendError(underlying: "raw ledger exec open failed: \(rc)")
        }
        var errMsg: UnsafeMutablePointer<CChar>?
        let exec = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if exec != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "raw ledger exec failed"
            sqlite3_free(errMsg)
            throw StorageError.backendError(underlying: message)
        }
    }

    private func rawMigrationTimestamp(_ dbURL: URL) throws -> (storageClass: String, value: String) {
        var db: OpaquePointer?
        let rc = sqlite3_open(dbURL.path, &db)
        defer { sqlite3_close(db) }
        guard rc == SQLITE_OK, let db else {
            throw StorageError.backendError(underlying: "raw ledger read open failed: \(rc)")
        }
        var statement: OpaquePointer?
        let sql = "SELECT typeof(\"applied_at\"), \"applied_at\" FROM \"_storagekit_migrations\" WHERE \"kit_id\" = 'TestKit'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StorageError.backendError(underlying: "raw ledger read prepare failed")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let storageClass = sqlite3_column_text(statement, 0),
              let value = sqlite3_column_text(statement, 1)
        else {
            throw StorageError.backendError(underlying: "raw ledger row missing")
        }
        return (String(cString: storageClass), String(cString: value))
    }

    @Test func openAndSchemaVersion() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema(version: 1))
        let v = try await storage.currentSchemaVersion()
        #expect(v == 1)
        await storage.close()
    }

    @Test func insertAndQuery() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: [
                "row_id": .uuid(rowID),
                "adjective": .bitmap(0x01),
                "operational": .bitmap(0x02),
                "provenance": .bitmap(0x04),
                "verbatim": .text("hello sqlite"),
                "captured_at": .timestamp(Date(timeIntervalSince1970: 1000))
            ]
        )
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "row_id"), .uuid(rowID))
        )
        #expect(rows.count == 1)
        if case .text(let s) = rows[0]["verbatim"] {
            #expect(s == "hello sqlite")
        } else {
            Issue.record("expected text verbatim")
        }
        await storage.close()
    }

    @Test func bitmaskPredicate() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        for bits: Int64 in [0x01, 0x03, 0x07, 0x0F] {
            _ = try await storage.rowStore.insert(
                table: "drawers",
                values: [
                    "row_id": .uuid(UUID()),
                    "adjective": .bitmap(bits),
                    "operational": .bitmap(0),
                    "provenance": .bitmap(0),
                    "verbatim": .text("row_\(bits)"),
                    "captured_at": .timestamp(Date())
                ]
            )
        }

        let allBit0 = try await storage.rowStore.count(
            table: "drawers",
            where: .bitmaskAll(Column(table: "drawers", name: "adjective"), mask: 0x01)
        )
        #expect(allBit0 == 4)

        let all0x07 = try await storage.rowStore.count(
            table: "drawers",
            where: .bitmaskAll(Column(table: "drawers", name: "adjective"), mask: 0x07)
        )
        #expect(all0x07 == 2)

        let none0xF0 = try await storage.rowStore.count(
            table: "drawers",
            where: .bitmaskNone(Column(table: "drawers", name: "adjective"), mask: 0xF0)
        )
        #expect(none0xF0 == 4)
        await storage.close()
    }

    @Test func auditAppendIdempotent() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let event = AuditEvent(
            eventID: UUID(),
            estateUuid: UUID(),
            rowId: UUID(),
            hlc: HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1),
            verb: "capture",
            beforeBitmaps: nil,
            afterBitmaps: (1, 2, 4),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: LatticeAnchor(udcCode: 0),
            actor: "test"
        )

        try await storage.auditLog.append(event)
        try await storage.auditLog.append(event)
        try await storage.auditLog.append(event)

        let count = try await storage.auditLog.count()
        #expect(count == 1)
        await storage.close()
    }

    @Test func transactionCommit() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        try await storage.transaction { txn in
            _ = try await txn.rowStore.insert(
                table: "drawers",
                values: [
                    "row_id": .uuid(UUID()),
                    "adjective": .bitmap(0),
                    "operational": .bitmap(0),
                    "provenance": .bitmap(0),
                    "verbatim": .text("committed"),
                    "captured_at": .timestamp(Date())
                ]
            )
        }
        let count = try await storage.rowStore.count(table: "drawers", where: nil)
        #expect(count == 1)
        await storage.close()
    }

    @Test func transactionRollback() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        struct TestError: Error {}
        await #expect(throws: TestError.self) {
            try await storage.transaction { txn in
                _ = try await txn.rowStore.insert(
                    table: "drawers",
                    values: [
                        "row_id": .uuid(UUID()),
                        "adjective": .bitmap(0),
                        "operational": .bitmap(0),
                        "provenance": .bitmap(0),
                        "verbatim": .text("should rollback"),
                        "captured_at": .timestamp(Date())
                    ]
                )
                throw TestError()
            }
        }
        let count = try await storage.rowStore.count(table: "drawers", where: nil)
        #expect(count == 0, "rollback should leave no rows")
        await storage.close()
    }

    @Test func blobRoundtrip() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await storage.blobStore.put(key: "test/blob", bytes: payload)
        let retrieved = try await storage.blobStore.get(key: "test/blob")
        #expect(retrieved == payload)
        let exists = try await storage.blobStore.exists(key: "test/blob")
        #expect(exists)
        let size = try await storage.blobStore.size(key: "test/blob")
        #expect(size == 4)
        await storage.close()
    }

    @Test func schemaMigration() async throws {
        let storage = try makeStorage()
        // Open at version 1
        try await storage.open(schema: makeSchema(version: 1))
        let v1 = try await storage.currentSchemaVersion()
        #expect(v1 == 1)

        // Open at version 2 with an added column
        let v2 = SchemaDeclaration(
            kitID: "TestKit",
            version: 2,
            tables: [
                TableDeclaration(
                    name: "drawers",
                    columns: [
                        .uuid("row_id"),
                        .bitmap("adjective"),
                        .bitmap("operational"),
                        .bitmap("provenance"),
                        .text("verbatim"),
                        .timestamp("captured_at"),
                        .text("notes", nullable: true)
                    ],
                    primaryKey: ["row_id"]
                )
            ],
            migrations: [
                Migration(
                    fromVersion: 1,
                    toVersion: 2,
                    operations: [
                        .addColumn(table: "drawers", column: .text("notes", nullable: true))
                    ]
                )
            ]
        )
        try await storage.migrate(to: v2)
        let v2Version = try await storage.currentSchemaVersion()
        #expect(v2Version == 2)
        await storage.close()
    }

    @Test func migrationLedgerWritesCanonicalTextAndNormalizesLegacyTimestamps() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let dbURL = tempDirectory.appendingPathComponent("estate.sqlite")
        let configuration = EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: dbURL, busyTimeout: 5.0))
        let schema = makeSchema()

        let writer = try SQLiteStorage(configuration: configuration)
        try await writer.open(schema: schema)
        await writer.close()
        let written = try rawMigrationTimestamp(dbURL)
        #expect(written.storageClass == "text"
            && written.value.contains("T")
            && written.value.hasSuffix("Z")
            && written.value != "1970-01-01T00:00:00.000Z")

        try rawExec(dbURL, """
            DROP TABLE "_storagekit_migrations";
            CREATE TABLE "_storagekit_migrations" (
                "kit_id" TEXT NOT NULL,
                "version" INTEGER NOT NULL,
                "applied_at" INTEGER NOT NULL,
                PRIMARY KEY ("kit_id")
            );
            INSERT INTO "_storagekit_migrations" ("kit_id", "version", "applied_at")
            VALUES ('TestKit', 1, 1700000123456);
            """)
        let integerLegacy = try SQLiteStorage(configuration: configuration)
        #expect(try await integerLegacy.currentSchemaVersion(for: "TestKit") == 1)
        try await integerLegacy.open(schema: schema)
        await integerLegacy.close()
        let normalizedInteger = try rawMigrationTimestamp(dbURL)
        #expect(normalizedInteger.storageClass == "text"
            && normalizedInteger.value == "2023-11-14T22:15:23.456Z",
            "normalized integer timestamp: \(normalizedInteger.value)")

        try rawExec(dbURL, """
            UPDATE "_storagekit_migrations"
            SET "applied_at" = '1970-01-01T00:00:00.000Z'
            WHERE "kit_id" = 'TestKit'
            """)
        let sentinelLegacy = try SQLiteStorage(configuration: configuration)
        try await sentinelLegacy.open(schema: schema)
        await sentinelLegacy.close()
        let normalizedSentinel = try rawMigrationTimestamp(dbURL)
        #expect(normalizedSentinel.storageClass == "text"
            && normalizedSentinel.value != "1970-01-01T00:00:00.000Z")

        try rawExec(dbURL, """
            UPDATE "_storagekit_migrations"
            SET "applied_at" = '2024-02-03T04:05:06.789Z'
            WHERE "kit_id" = 'TestKit'
            """)
        let canonical = try SQLiteStorage(configuration: configuration)
        try await canonical.open(schema: schema)
        await canonical.close()
        #expect(try rawMigrationTimestamp(dbURL).value == "2024-02-03T04:05:06.789Z")
    }

    @Test func schemasFromMultipleKitsRetainTypedValues() async throws {
        let storage = try makeStorage()
        let applicationSchema = SchemaDeclaration(
            kitID: "ApplicationKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "application_rows",
                    columns: [
                        .uuid("id"),
                        .timestamp("created_at"),
                        .bitmap("flags"),
                    ],
                    primaryKey: ["id"]
                )
            ]
        )
        let sideSchema = SchemaDeclaration(
            kitID: "SideKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "_side_rows",
                    columns: [
                        .uuid("id"),
                        .timestamp("created_at"),
                        .bitmap("flags"),
                    ],
                    primaryKey: ["id"]
                )
            ]
        )

        try await storage.open(schema: applicationSchema)
        try await storage.migrate(to: sideSchema)

        let applicationID = UUID()
        let sideID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await storage.rowStore.insert(
            table: "application_rows",
            values: [
                "id": .uuid(applicationID),
                "created_at": .timestamp(createdAt),
                "flags": .bitmap(0x05),
            ]
        )
        _ = try await storage.rowStore.insert(
            table: "_side_rows",
            values: [
                "id": .uuid(sideID),
                "created_at": .timestamp(createdAt),
                "flags": .bitmap(0x0A),
            ]
        )

        let applicationRows = try await storage.rowStore.query(
            table: "application_rows", where: nil
        )
        #expect(applicationRows.count == 1)
        #expect(applicationRows[0]["id"] == .uuid(applicationID))
        #expect(applicationRows[0]["created_at"] == .timestamp(createdAt))
        #expect(applicationRows[0]["flags"] == .bitmap(0x05))

        let transactionalSideRows = try await storage.transaction { transaction in
            try await transaction.rowStore.query(table: "_side_rows", where: nil)
        }
        #expect(transactionalSideRows.count == 1)
        #expect(transactionalSideRows[0]["id"] == .uuid(sideID))
        #expect(transactionalSideRows[0]["created_at"] == .timestamp(createdAt))
        #expect(transactionalSideRows[0]["flags"] == .bitmap(0x0A))
        await storage.close()
    }

    @Test func sameKitMigrationRefreshesTypedTableDeclaration() async throws {
        let storage = try makeStorage()
        let v1 = SchemaDeclaration(
            kitID: "TypedMigrationKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "typed_rows",
                    columns: [.uuid("id")],
                    primaryKey: ["id"]
                )
            ]
        )
        let payloadColumn = ColumnDeclaration.uuid("payload_id", nullable: true)
        let v2 = SchemaDeclaration(
            kitID: "TypedMigrationKit",
            version: 2,
            tables: [
                TableDeclaration(
                    name: "typed_rows",
                    columns: [.uuid("id"), payloadColumn],
                    primaryKey: ["id"]
                )
            ],
            migrations: [
                Migration(
                    fromVersion: 1,
                    toVersion: 2,
                    operations: [.addColumn(table: "typed_rows", column: payloadColumn)]
                )
            ]
        )

        try await storage.open(schema: v1)
        try await storage.migrate(to: v2)
        let rowID = UUID()
        let payloadID = UUID()
        _ = try await storage.rowStore.insert(
            table: "typed_rows",
            values: ["id": .uuid(rowID), "payload_id": .uuid(payloadID)]
        )
        let rows = try await storage.rowStore.query(table: "typed_rows", where: nil)
        #expect(rows.count == 1)
        #expect(rows[0]["payload_id"] == .uuid(payloadID))
        await storage.close()
    }

    @Test func conflictingCrossKitTableDeclarationsFail() async throws {
        let storage = try makeStorage()
        let ownerSchema = SchemaDeclaration(
            kitID: "OwnerKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "shared_rows",
                    columns: [.uuid("id")],
                    primaryKey: ["id"]
                )
            ]
        )
        let conflictingSchema = SchemaDeclaration(
            kitID: "ConflictingKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "shared_rows",
                    columns: [.text("id")],
                    primaryKey: ["id"]
                )
            ]
        )
        try await storage.open(schema: ownerSchema)

        do {
            try await storage.migrate(to: conflictingSchema)
            Issue.record("expected conflicting cross-kit declaration to fail")
        } catch let StorageError.constraintViolation(detail) {
            #expect(detail.contains("shared_rows"))
            #expect(detail.contains("OwnerKit"))
            #expect(detail.contains("ConflictingKit"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        await storage.close()
    }

    /// Opening a FRESH database directly at a schema whose latest table already
    /// declares the added column must not fail. The open path creates every
    /// table at the latest schema first, then replays migrations from version 0
    /// — so the v1→v2 addColumn targets a column that already exists. The
    /// emitter must treat addColumn idempotently (ADD COLUMN IF NOT EXISTS
    /// semantics), mirroring CREATE TABLE IF NOT EXISTS. Regression for the
    /// "duplicate column name" failure on fresh DBs.
    @Test func freshOpenWithAddColumnMigrationIsIdempotent() async throws {
        let storage = try makeStorage()
        let schemaV2 = SchemaDeclaration(
            kitID: "TestKit",
            version: 2,
            tables: [
                TableDeclaration(
                    name: "drawers",
                    columns: [
                        .uuid("row_id"),
                        .bitmap("adjective"),
                        .bitmap("operational"),
                        .bitmap("provenance"),
                        .text("verbatim"),
                        .timestamp("captured_at"),
                        // Latest schema already carries the column the migration adds.
                        .text("notes", nullable: true)
                    ],
                    primaryKey: ["row_id"]
                )
            ],
            migrations: [
                Migration(
                    fromVersion: 1,
                    toVersion: 2,
                    operations: [
                        .addColumn(table: "drawers", column: .text("notes", nullable: true))
                    ]
                )
            ]
        )
        // Direct open on a brand-new file — the addColumn migration replays
        // against a table that already has `notes`. Must succeed, not throw.
        try await storage.open(schema: schemaV2)
        let version = try await storage.currentSchemaVersion()
        #expect(version == 2)
        await storage.close()
    }
    /// Two CONCURRENT transactions must both succeed: the second waits for the
    /// first instead of throwing transactionConflict. Regression for the live
    /// daemon failure "reindex: background backfill failed: transactionConflict
    /// (nested transactions not supported)" — background workers (reindex
    /// rollup, dream cycle, captures) legitimately overlap on one estate, and
    /// runTransaction used to reject the overlap outright. True nesting (a
    /// block reentering its own backend) still fails via the bounded wait.
    @Test func concurrentTransactionsBothCommit() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        // Each transaction holds the backend across an await (Task.sleep) so
        // the two genuinely interleave at a suspension point — the exact shape
        // that used to throw.
        @Sendable func slowInsert(_ tag: String) async throws {
            try await storage.transaction { txn in
                _ = try await txn.rowStore.insert(
                    table: "drawers",
                    values: [
                        "row_id": .uuid(UUID()),
                        "adjective": .bitmap(0),
                        "operational": .bitmap(0),
                        "provenance": .bitmap(0),
                        "verbatim": .text(tag),
                        "captured_at": .timestamp(Date())
                    ]
                )
                try await Task.sleep(nanoseconds: 100_000_000)  // hold the txn open 100 ms
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await slowInsert("first") }
            group.addTask { try await slowInsert("second") }
            try await group.waitForAll()
        }

        let count = try await storage.rowStore.count(table: "drawers", where: nil)
        #expect(count == 2, "both concurrent transactions must commit")
        await storage.close()
    }

}
