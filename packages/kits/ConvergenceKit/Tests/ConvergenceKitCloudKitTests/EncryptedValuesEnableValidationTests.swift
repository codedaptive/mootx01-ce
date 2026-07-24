// EncryptedValuesEnableValidationTests.swift
//
// FAB5-EV2 enable-time validation proof.
//
// Verifies that CloudKitStateActor.enable(manifest:storage:) calls
// manifest.validateEncryptedColumns() before zone setup, so an invalid
// declaration fails enable with a descriptive SyncError before any push
// can occur. A valid declaration (or the empty default) succeeds.

import Testing
import Foundation
import ConvergenceKit
import ConvergenceKitCloudKit
import PersistenceKit
import PersistenceKitInMemory
@testable import ConvergenceKitCloudKit

// MARK: - Helpers

private func makeStorage() async throws -> any Storage {
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
                    ColumnDeclaration(name: "content", type: .text, nullable: true),
                ],
                primaryKey: ["id"]
            )
        ],
        indices: [],
        migrations: []
    ))
    return s
}

private func makeEngine(manifest: SyncManifest, storage: any Storage) async -> CloudKitSyncEngine {
    let cloud = CloudZoneFake()
    let engine = CloudKitSyncEngine(containerIdentifier: nil)
    await engine.stateActor.setTestDatabase(cloud)
    return engine
}

// MARK: - Enable-time validation tests

@Suite("FAB5-EV2 — enable-time encrypted column validation")
struct EncryptedValuesEnableValidationTests {

    // MARK: (1) Invalid declaration: _ck_* table is rejected before zone setup

    @Test("enable() throws on _ck_* table in encryptedContentColumns")
    func enableRejectsCkPrefixTable() async throws {
        let storage = try await makeStorage()
        let manifest = SyncManifest(
            kitID: "TestKit",
            schemaVersion: 1,
            zoneIdentifier: "EV2-ENABLE-VALIDATION",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id")],
            encryptedContentColumns: ["_ck_device_slot": ["device_uuid"]]
        )
        let engine = await makeEngine(manifest: manifest, storage: storage)
        await #expect(throws: SyncError.self) {
            try await engine.enable(manifest: manifest, storage: storage)
        }
    }

    // MARK: (2) Invalid declaration: _sync* column is rejected before zone setup

    @Test("enable() throws on _sync* column in encryptedContentColumns")
    func enableRejectsSyncPrefixColumn() async throws {
        let storage = try await makeStorage()
        let manifest = SyncManifest(
            kitID: "TestKit",
            schemaVersion: 1,
            zoneIdentifier: "EV2-ENABLE-VALIDATION",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id")],
            encryptedContentColumns: ["items": ["_syncHLC"]]
        )
        let engine = await makeEngine(manifest: manifest, storage: storage)
        await #expect(throws: SyncError.self) {
            try await engine.enable(manifest: manifest, storage: storage)
        }
    }

    // MARK: (3) Valid declaration succeeds

    @Test("enable() succeeds with valid encryptedContentColumns declaration")
    func enableSucceedsWithValidDeclaration() async throws {
        let storage = try await makeStorage()
        let manifest = SyncManifest(
            kitID: "TestKit",
            schemaVersion: 1,
            zoneIdentifier: "EV2-ENABLE-VALIDATION-OK",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id")],
            encryptedContentColumns: ["items": ["content"]]
        )
        let engine = await makeEngine(manifest: manifest, storage: storage)
        await #expect(throws: Never.self) {
            try await engine.enable(manifest: manifest, storage: storage)
        }
        try await engine.disable()
    }

    // MARK: (4) Empty declaration succeeds (default / no-op path)

    @Test("enable() succeeds with empty encryptedContentColumns (default)")
    func enableSucceedsWithEmptyDeclaration() async throws {
        let storage = try await makeStorage()
        let manifest = SyncManifest(
            kitID: "TestKit",
            schemaVersion: 1,
            zoneIdentifier: "EV2-ENABLE-VALIDATION-EMPTY",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id")]
            // encryptedContentColumns: [:] (default)
        )
        let engine = await makeEngine(manifest: manifest, storage: storage)
        await #expect(throws: Never.self) {
            try await engine.enable(manifest: manifest, storage: storage)
        }
        try await engine.disable()
    }
}
