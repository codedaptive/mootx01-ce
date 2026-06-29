// SQLiteBasicTests.swift

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite
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
}
