// FederationStubTests.swift
import Testing
import Foundation
import SubstrateTypes
import ConvergenceKit
import ConvergenceKitFederation
import PersistenceKit
import PersistenceKitInMemory

@Suite("FederationSyncEngine stub")
struct FederationStubTests {
    @Test("engine starts disabled")
    func stubExists() async {
        let engine = FederationSyncEngine()
        guard case .disabled = await engine.state else {
            Issue.record("expected disabled")
            return
        }
    }

    // MARK: - Push includes update and delete SyncRecords

    /// Regression test: FederationSyncEngine.push() must emit SyncRecords for
    /// insert, update, AND delete — not just insert. Before the SQLite observer
    /// rowKey fix, update and delete changes were silently dropped by the
    /// `guard let rowKey = change.rowKey else { continue }` guard. This test
    /// confirms all three event types produce outbound SyncRecords.
    @Test("push emits SyncRecords for insert, update, and delete")
    func pushEmitsSyncRecordsForAllEventTypes() async throws {
        let storageA = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        let storageB = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        let schema = SchemaDeclaration(
            kitID: "PushTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("note"), .bitmap("flags")],
                    primaryKey: ["id"]
                )
            ]
        )
        try await storageA.open(schema: schema)
        try await storageB.open(schema: schema)

        let engineA = FederationSyncEngine()
        let engineB = FederationSyncEngine()
        let manifest = SyncManifest(
            kitID: "PushTest",
            schemaVersion: 1,
            zoneIdentifier: "test-zone",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id",
                                 conflictPolicy: .lastWriterWinsByHLC)]
        )
        try await engineA.enable(manifest: manifest, storage: storageA)
        try await engineB.enable(manifest: manifest, storage: storageB)
        let relay = FederationRelay()
        let family = HyperplaneFamilySpec(seed: 0xBEEF_CAFE)
        try await engineA.pair(with: engineB, via: relay, family: family)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        let rowID = UUID()

        // INSERT
        _ = try await storageA.rowStore.insert(
            table: "items",
            values: ["id": .uuid(rowID), "note": .text("first"), "flags": .bitmap(0)]
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let insertReceipt = try await engineA.push()
        #expect(insertReceipt.pushed > 0, "insert should produce at least one SyncRecord")
        _ = try await engineB.pull()

        // Verify B received the insert.
        let afterInsert = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(afterInsert.count == 1, "insert must replicate to B")

        // UPDATE
        _ = try await storageA.rowStore.update(
            table: "items",
            values: ["note": .text("updated")],
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let updateReceipt = try await engineA.push()
        #expect(updateReceipt.pushed > 0, "update must produce at least one SyncRecord")
        _ = try await engineB.pull()

        // Verify B received the update.
        let afterUpdate = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(afterUpdate.count == 1, "updated row should still exist on B")
        #expect(afterUpdate[0]["note"] == .text("updated"), "update must replicate to B")

        // DELETE
        _ = try await storageA.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let deleteReceipt = try await engineA.push()
        #expect(deleteReceipt.pushed > 0, "delete must produce at least one SyncRecord")
        _ = try await engineB.pull()

        // Verify B received the delete.
        let afterDelete = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(afterDelete.count == 0, "delete must replicate to B")
    }
}
