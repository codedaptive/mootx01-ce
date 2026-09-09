import Foundation
import Testing
import PersistenceKit
import PersistenceKitPostgreSQL
import SubstrateTypes
@testable import PersistenceKitPostgreSQL

@Suite("PostgreSQL inventory snapshot", .serialized)
struct PostgreSQLInventorySnapshotTests {
    private let validFingerprintHex = "0100000000000000020000000000000003000000000000000400000000000000"
    private let alternateFingerprintHex = "0500000000000000060000000000000007000000000000000800000000000000"
    private let zeroFingerprintHex = String(repeating: "00", count: 32)

    private func connectionString() -> String? {
        ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"]
    }

    private var schema: SchemaDeclaration {
        SchemaDeclaration(
            kitID: "PostgreSQLInventorySnapshotTests",
            version: 1,
            tables: [
                TableDeclaration(name: "drawers", columns: [
                    .uuid("id"), .text("payload"), .uuid("nullable_uuid", nullable: true),
                    .json("metadata"), .fingerprint("fingerprint")
                ], primaryKey: ["id"]),
                TableDeclaration(name: "nodes", columns: [.uuid("id"), .text("name")], primaryKey: ["id"]),
            ]
        )
    }

    /// This narrow fixture seam uses only static, test-owned SQL literals.
    /// Production JSON binding remains outside this snapshot test's scope.
    private func executeFixtureSQL(_ sql: String, storage: PostgreSQLStorage) async throws {
        let connection = try await storage.pool.acquire()
        let logger = await storage.backend.logger
        do {
            try await connection.executeSimple(sql, logger: logger)
            await storage.pool.release(connection)
        } catch {
            await storage.pool.release(connection)
            throw error
        }
    }

    private func resetFixture(_ storage: PostgreSQLStorage) async throws {
        try await executeFixtureSQL("TRUNCATE TABLE \"nodes\", \"drawers\"", storage: storage)
    }

    private func insertDrawer(
        _ storage: PostgreSQLStorage,
        id: UUID,
        payloadSQL: String,
        metadataJSON: String,
        fingerprintHex: String
    ) async throws {
        try await executeFixtureSQL("""
            INSERT INTO "drawers" ("id", "payload", "nullable_uuid", "metadata", "fingerprint")
            VALUES ('\(id.uuidString.lowercased())'::uuid, \(payloadSQL), NULL, '\(metadataJSON)'::jsonb, decode('\(fingerprintHex)', 'hex'))
            """, storage: storage)
    }

    private func insertNode(_ storage: PostgreSQLStorage, id: UUID) async throws {
        try await executeFixtureSQL("""
            INSERT INTO "nodes" ("id", "name")
            VALUES ('\(id.uuidString.lowercased())'::uuid, 'node')
            """, storage: storage)
    }

    private func resetAndClose(_ storage: PostgreSQLStorage) async {
        try? await resetFixture(storage)
        await storage.close()
    }

    @Test func conditionalBackendCapturePinsOneConnectionForBothStrictTables() async throws {
        guard let connectionString = connectionString() else { return }
        let storage = PostgreSQLStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .postgresql(connectionString: connectionString, poolSize: 1)
        ))
        do {
            try await storage.open(schema: schema)
            try await resetFixture(storage)
            try await insertDrawer(
                storage, id: UUID(), payloadSQL: "'drawer'", metadataJSON: "{\"kind\":\"drawer\"}",
                fingerprintHex: validFingerprintHex
            )
            try await insertNode(storage, id: UUID())

            let snapshot = try await storage.captureInventorySnapshot()
            #expect(snapshot.drawers.count == 1)
            #expect(snapshot.nodes.count == 1)
            #expect(snapshot.drawers[0]["nullable_uuid"] == .null)
            guard case .json(let metadata)? = snapshot.drawers[0]["metadata"] else {
                Issue.record("JSONB column was not preserved as TypedValue.json")
                await resetAndClose(storage)
                return
            }
            let metadataObject = try JSONSerialization.jsonObject(with: metadata) as? [String: String]
            #expect(metadataObject?["kind"] == "drawer")
            #expect(snapshot.drawers[0]["fingerprint"] == .fingerprint(
                Fingerprint256(block0: 1, block1: 2, block2: 3, block3: 4)
            ))

            try await insertDrawer(
                storage, id: UUID(), payloadSQL: "'second drawer'", metadataJSON: "{\"kind\":\"second\"}",
                fingerprintHex: zeroFingerprintHex
            )
            do {
                _ = try await storage.captureInventorySnapshot(
                    limits: InventorySnapshotLimits(maxRowsPerTable: 1, maxSerializedBytes: 1_024)
                )
                Issue.record("expected drawer row bound to fail")
            } catch let error as InventorySnapshotError {
                #expect(error == .rowLimitExceeded(table: "drawers", limit: 1))
            } catch {
                Issue.record("unexpected row-limit error: \(error)")
            }

            do {
                _ = try await storage.captureInventorySnapshot(
                    limits: InventorySnapshotLimits(maxRowsPerTable: 3, maxSerializedBytes: 1)
                )
                Issue.record("expected serialized byte bound to fail")
            } catch let error as InventorySnapshotError {
                #expect(error == .byteLimitExceeded(limit: 1))
            } catch {
                Issue.record("unexpected byte-limit error: \(error)")
            }

            let rowsBeforeOversizedPreflight = await storage.backend.inventorySnapshotFullRowMaterializations
            try await insertDrawer(
                storage, id: UUID(), payloadSQL: "repeat('x', 1048576)", metadataJSON: "{\"kind\":\"large\"}",
                fingerprintHex: alternateFingerprintHex
            )
            await #expect(throws: InventorySnapshotError.byteLimitExceeded(limit: 1_024)) {
                try await storage.captureInventorySnapshot(
                    limits: InventorySnapshotLimits(maxRowsPerTable: 3, maxSerializedBytes: 1_024)
                )
            }
            #expect(await storage.backend.inventorySnapshotFullRowMaterializations == rowsBeforeOversizedPreflight)

            try await insertDrawer(
                storage, id: UUID(), payloadSQL: "'bad fingerprint'", metadataJSON: "{\"kind\":\"bad\"}",
                fingerprintHex: "01"
            )
            do {
                _ = try await storage.captureInventorySnapshot()
                Issue.record("expected malformed stored fingerprint to fail strict snapshot decoding")
            } catch let error as StorageError {
                guard case .typeMismatch(let column, expected: .fingerprint, actual: _) = error else {
                    Issue.record("unexpected strict-decoding error: \(error)")
                    await resetAndClose(storage)
                    return
                }
                #expect(column == "fingerprint")
            }
            await resetAndClose(storage)
        } catch {
            await resetAndClose(storage)
            throw error
        }
    }

    @Test func conditionalBackendSnapshotRejectsANativeDeclaredTypeMismatch() async throws {
        guard let connectionString = connectionString() else { return }
        let storage = PostgreSQLStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .postgresql(connectionString: connectionString, poolSize: 1)
        ))
        do {
            try await storage.open(schema: schema)
            try await resetFixture(storage)
            try await insertDrawer(
                storage, id: UUID(), payloadSQL: "'drawer'", metadataJSON: "{\"kind\":\"drawer\"}",
                fingerprintHex: validFingerprintHex
            )
            try await insertNode(storage, id: UUID())
            try await executeFixtureSQL(
                "ALTER TABLE \"drawers\" ALTER COLUMN \"id\" TYPE BIGINT USING 7",
                storage: storage
            )

            do {
                _ = try await storage.captureInventorySnapshot()
                Issue.record("expected native UUID type mismatch to fail strict snapshot decoding")
            } catch let error as StorageError {
                guard case .typeMismatch(let column, expected: .uuid, actual: _) = error else {
                    Issue.record("unexpected strict-decoding error: \(error)")
                    await resetAndClose(storage)
                    return
                }
                #expect(column == "id")
            }
            await resetAndClose(storage)
        } catch {
            await resetAndClose(storage)
            throw error
        }
    }

    @Test func conditionalBackendRejectsCanonicalFramingGapBeforeMaterializingTheBody() async throws {
        guard let connectionString = connectionString() else { return }
        let storage = PostgreSQLStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .postgresql(connectionString: connectionString, poolSize: 1)
        ))
        do {
            try await storage.open(schema: schema)
            try await resetFixture(storage)
            try await insertDrawer(
                storage, id: UUID(), payloadSQL: "repeat('x', 50)", metadataJSON: "{\"kind\":\"gap\"}",
                fingerprintHex: validFingerprintHex
            )

            // Legacy field lengths remain below 190, while canonical text,
            // JSON, and fingerprint framing crosses it. The new bound must
            // reject before PostgreSQL yields the complete row body.
            let rowsBeforePreflight = await storage.backend.inventorySnapshotFullRowMaterializations
            await #expect(throws: InventorySnapshotError.byteLimitExceeded(limit: 190)) {
                try await storage.captureInventorySnapshot(
                    limits: InventorySnapshotLimits(maxRowsPerTable: 2, maxSerializedBytes: 190)
                )
            }
            #expect(await storage.backend.inventorySnapshotFullRowMaterializations == rowsBeforePreflight)
            await resetAndClose(storage)
        } catch {
            await resetAndClose(storage)
            throw error
        }
    }

    @Test func conditionalBackendRejectsOversizedMalformedFingerprintBeforeMaterializingBody() async throws {
        guard let connectionString = connectionString() else { return }
        let storage = PostgreSQLStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .postgresql(connectionString: connectionString, poolSize: 1)
        ))
        do {
            try await storage.open(schema: schema)
            try await resetFixture(storage)
            try await executeFixtureSQL(
                """
                INSERT INTO "drawers" ("id", "payload", "nullable_uuid", "metadata", "fingerprint")
                VALUES ('\(UUID().uuidString.lowercased())'::uuid, 'drawer', NULL, '{}'::jsonb,
                        decode(repeat('00', 1048576), 'hex'))
                """,
                storage: storage
            )

            let rowsBeforePreflight = await storage.backend.inventorySnapshotFullRowMaterializations
            await #expect(throws: InventorySnapshotError.byteLimitExceeded(limit: 1_024)) {
                try await storage.captureInventorySnapshot(
                    limits: InventorySnapshotLimits(maxRowsPerTable: 1, maxSerializedBytes: 1_024)
                )
            }
            #expect(await storage.backend.inventorySnapshotFullRowMaterializations == rowsBeforePreflight)
            await resetAndClose(storage)
        } catch {
            await resetAndClose(storage)
            throw error
        }
    }
}
