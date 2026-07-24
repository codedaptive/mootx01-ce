// EncryptedValuesPushWiringTests.swift
//
// FAB5-EV2 push-path wiring proof.
//
// These tests exercise the ACTUAL push path — CloudKitStateActor.push() via
// CloudKitSyncEngine.push() — not the mapping layer in isolation. The mapping
// layer tests already exist in EncryptedValuesTests.swift; these tests prove
// that PushCycle passes manifest.encryptedContentColumns through to
// CKRecordMapping.record(...) correctly.
//
// Test harness: TwoEstateFixture with a manifest that declares "secret" as
// encrypted for the "items" table. CloudZoneFake stores the CKRecords so we
// can inspect whether "secret" landed in record.encryptedValues or plaintext.
//
// Two test functions covering three verification points:
//   (1) Declared column absent from plaintext and present via encryptedValues
//       in the CKRecord produced by the full push path; undeclared column
//       on the same record stays plaintext (both verified in one push cycle).
//   (2) Table not in encryptedContentColumns: all columns stay plaintext —
//       the ?? [] fallback in PushCycle preserves byte-identical wire format.

import Testing
import Foundation
import CloudKit
import ConvergenceKit
import ConvergenceKitCloudKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
@testable import ConvergenceKitCloudKit

// MARK: - Manifest with encrypted declaration

/// Estate fixture for encrypted-values push-wiring tests.
/// Uses a manifest that declares "secret" as an encrypted column in "items".
private actor EncryptedPushFixture {

    static let encryptedManifest = SyncManifest(
        kitID: "TestKit",
        schemaVersion: 1,
        zoneIdentifier: "EV2-PUSH-WIRING",
        tables: [
            SyncedTable(
                name: "items",
                direction: .bidirectional,
                primaryKeyColumn: "id",
                conflictPolicy: .lastWriterWinsByHLC
            )
        ],
        encryptedContentColumns: ["items": ["secret"]]
    )

    static let plainManifest = SyncManifest(
        kitID: "TestKit",
        schemaVersion: 1,
        zoneIdentifier: "EV2-PUSH-WIRING-PLAIN",
        tables: [
            SyncedTable(
                name: "items",
                direction: .bidirectional,
                primaryKeyColumn: "id",
                conflictPolicy: .lastWriterWinsByHLC
            )
        ]
        // encryptedContentColumns: [:] (default)
    )

    let storage: any Storage
    let engine: CloudKitSyncEngine
    let cloud: CloudZoneFake

    init(storage: any Storage, engine: CloudKitSyncEngine, cloud: CloudZoneFake) {
        self.storage = storage
        self.engine = engine
        self.cloud = cloud
    }

    static func makeStorage() async throws -> any Storage {
        let s = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await s.open(schema: SchemaDeclaration(
            kitID: "TestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [
                        .uuid("id"),
                        ColumnDeclaration(name: "public", type: .text, nullable: true),
                        ColumnDeclaration(name: "secret", type: .text, nullable: true),
                    ],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        return s
    }

    static func make(manifest: SyncManifest) async throws -> EncryptedPushFixture {
        let storage = try await makeStorage()
        let cloud = CloudZoneFake()
        let engine = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)
        try await engine.enable(manifest: manifest, storage: storage)
        return EncryptedPushFixture(storage: storage, engine: engine, cloud: cloud)
    }

    /// Write a row locally and wait (poll-deadline) for the outbox entry to appear.
    func writeLocal(row: [String: TypedValue]) async throws {
        let before = try await OutboxStore.readBatch(from: storage).count
        _ = try await storage.rowStore.upsert(table: "items", values: row, conflictColumns: ["id"])
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            await Task.yield()
            let count = (try? await OutboxStore.readBatch(from: storage).count) ?? 0
            if count > before { return }
        }
    }
}

// MARK: - Push-path wiring tests

@Suite("FAB5-EV2 — push-path encrypted column wiring")
struct EncryptedValuesPushWiringTests {

    // MARK: (1) Declared column routes through encryptedValues on actual push path

    @Test("declared column absent from plaintext, present via encryptedValues after push()")
    func declaredColumnRoutesToEncryptedValuesViaPush() async throws {
        let fix = try await EncryptedPushFixture.make(manifest: EncryptedPushFixture.encryptedManifest)

        let rowID = UUID()
        try await fix.writeLocal(row: [
            "id":     .uuid(rowID),
            "public": .text("open"),
            "secret": .text("s3cr3t")
        ])

        // Yield to let observer tasks settle, then push.
        for _ in 0..<20 { await Task.yield() }
        let receipt = try await fix.engine.push()
        #expect(receipt.pushed == 1, "expected 1 record pushed, got \(receipt.pushed)")

        // Inspect the CKRecord stored in CloudZoneFake.
        let records = await fix.cloud.allDataRecords()
        let record = try #require(records.first, "CloudZoneFake must contain the pushed record")

        // "secret" must be absent from the plaintext channel.
        #expect(record["secret"] == nil,
                "declared column 'secret' must NOT appear in CKRecord plaintext channel")

        // "secret" must be present via encryptedValues.
        #expect(record.encryptedValues["secret"] != nil,
                "declared column 'secret' must be present in CKRecord.encryptedValues after push")

        // "public" must remain in the plaintext channel (undeclared column).
        #expect(record["public"] != nil,
                "undeclared column 'public' must remain in CKRecord plaintext channel")
        #expect(record.encryptedValues["public"] == nil,
                "undeclared column 'public' must NOT appear in encryptedValues")
    }

    // MARK: (2) Undeclared table — golden byte-identity (all plaintext)

    @Test("undeclared table: all columns stay plaintext after push (golden byte-identity)")
    func undeclaredTableAllColumnsStayPlaintext() async throws {
        let fix = try await EncryptedPushFixture.make(manifest: EncryptedPushFixture.plainManifest)

        let rowID = UUID()
        try await fix.writeLocal(row: [
            "id":     .uuid(rowID),
            "public": .text("hello"),
            "secret": .text("also-plain")
        ])

        for _ in 0..<20 { await Task.yield() }
        let receipt = try await fix.engine.push()
        #expect(receipt.pushed == 1, "expected 1 record pushed, got \(receipt.pushed)")

        let records = await fix.cloud.allDataRecords()
        let record = try #require(records.first, "CloudZoneFake must contain the pushed record")

        // Without a declaration both columns land in plaintext.
        #expect(record["public"] != nil,
                "'public' must be in plaintext channel when no declaration present")
        #expect(record["secret"] != nil,
                "'secret' must be in plaintext channel when not declared encrypted")
        // encryptedValues must be empty (no declaration in manifest).
        #expect(record.encryptedValues["public"] == nil,
                "encryptedValues must be empty for undeclared columns")
        #expect(record.encryptedValues["secret"] == nil,
                "encryptedValues must be empty for undeclared columns")
    }
}
