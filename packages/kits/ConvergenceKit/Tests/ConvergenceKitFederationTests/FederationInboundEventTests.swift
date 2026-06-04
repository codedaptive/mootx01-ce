// FederationInboundEventTests.swift
//
// Tests for FederationSyncEngine inbound event dispatch.
// Verifies that applyInbound routes insert, update, and delete
// records correctly through each conflict policy.

import Testing
import Foundation
import SubstrateTypes
import ConvergenceKit
import ConvergenceKitFederation
import PersistenceKit
import PersistenceKitInMemory

@Suite("Federation inbound event dispatch")
struct FederationInboundEventTests {

    func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "TestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [
                        .uuid("id"),
                        .text("note"),
                        .bitmap("flags")
                    ],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        return storage
    }

    func makeManifest(policy: ConflictPolicy = .lastWriterWinsByHLC) -> SyncManifest {
        SyncManifest(
            kitID: "TestKit",
            schemaVersion: 1,
            zoneIdentifier: "test-zone",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id", conflictPolicy: policy)]
        )
    }

    /// Pairs two engines via a shared relay and returns (engineA, engineB, storageA, storageB).
    func setupPair(policy: ConflictPolicy) async throws -> (
        FederationSyncEngine, FederationSyncEngine, any Storage, any Storage
    ) {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let engineA = FederationSyncEngine()
        let engineB = FederationSyncEngine()
        try await engineA.enable(manifest: makeManifest(policy: policy), storage: storageA)
        try await engineB.enable(manifest: makeManifest(policy: policy), storage: storageB)
        let relay = FederationRelay()
        let family = HyperplaneFamilySpec(seed: 0xDEADBEEF)
        try await engineA.pair(with: engineB, via: relay, family: family)
        return (engineA, engineB, storageA, storageB)
    }

    /// Inserts a row into storageA, waits for the observer, and completes one push/pull cycle.
    func seedRow(
        id: UUID,
        note: String,
        engineA: FederationSyncEngine,
        engineB: FederationSyncEngine,
        storageA: any Storage
    ) async throws {
        _ = try await storageA.rowStore.insert(
            table: "items",
            values: ["id": .uuid(id), "note": .text(note), "flags": .bitmap(0)]
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let pushReceipt = try await engineA.push()
        #expect(pushReceipt.pushed > 0, "seed push should have at least one record")
        let pullReceipt = try await engineB.pull()
        #expect(pullReceipt.pulled > 0, "seed pull should have at least one record")
    }

    // MARK: - Existing paths still work

    @Test("remote insert still replicates to B")
    func remoteInsertReplicates() async throws {
        let (engineA, engineB, storageA, storageB) = try await setupPair(policy: .lastWriterWinsByHLC)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        let rowID = UUID()
        try await seedRow(id: rowID, note: "insert-test", engineA: engineA, engineB: engineB, storageA: storageA)

        let rows = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1, "inserted row should replicate to B")
        #expect(rows[0]["note"] == .text("insert-test"))
    }

    @Test("remote update still replicates to B")
    func remoteUpdateReplicates() async throws {
        let (engineA, engineB, storageA, storageB) = try await setupPair(policy: .lastWriterWinsByHLC)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        let rowID = UUID()
        try await seedRow(id: rowID, note: "original", engineA: engineA, engineB: engineB, storageA: storageA)

        // Update on A.
        _ = try await storageA.rowStore.update(
            table: "items",
            values: ["note": .text("updated")],
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await engineA.push()
        _ = try await engineB.pull()

        let rows = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1, "updated row should replicate to B")
        #expect(rows[0]["note"] == .text("updated"))
    }

    // MARK: - Delete paths

    @Test("remote delete is applied under remoteWins policy")
    func remoteDeleteAppliedUnderRemoteWins() async throws {
        let (engineA, engineB, storageA, storageB) = try await setupPair(policy: .remoteWins)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        let rowID = UUID()
        try await seedRow(id: rowID, note: "to-delete", engineA: engineA, engineB: engineB, storageA: storageA)

        // Verify B has the row.
        let before = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(before.count == 1, "row should exist on B before delete")

        // Delete from A, push to B.
        _ = try await storageA.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let pushReceipt = try await engineA.push()
        #expect(pushReceipt.pushed > 0, "delete should have been pushed")
        _ = try await engineB.pull()

        let after = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(after.count == 0, "row should be deleted from B under remoteWins")
    }

    @Test("remote delete is applied under lastWriterWinsByHLC policy")
    func remoteDeleteAppliedUnderLastWriterWinsByHLC() async throws {
        let (engineA, engineB, storageA, storageB) = try await setupPair(policy: .lastWriterWinsByHLC)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        let rowID = UUID()
        try await seedRow(id: rowID, note: "to-delete-lww", engineA: engineA, engineB: engineB, storageA: storageA)

        // Delete from A.
        _ = try await storageA.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let pushReceipt = try await engineA.push()
        #expect(pushReceipt.pushed > 0, "delete should have been pushed")
        _ = try await engineB.pull()

        let after = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(after.count == 0, "row should be deleted from B under lastWriterWinsByHLC")
    }

    @Test("remote delete is rejected under appendOnly policy")
    func remoteDeleteRejectedUnderAppendOnly() async throws {
        let (engineA, engineB, storageA, storageB) = try await setupPair(policy: .appendOnly)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        let rowID = UUID()
        try await seedRow(id: rowID, note: "append-only-row", engineA: engineA, engineB: engineB, storageA: storageA)

        // Delete from A.
        _ = try await storageA.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await engineA.push()
        _ = try await engineB.pull()

        let after = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        // appendOnly: remote delete silently rejected; row preserved on B.
        #expect(after.count == 1, "row should be preserved on B under appendOnly: remote deletes rejected")
    }

    @Test("remote delete is rejected under localWins when local row exists")
    func remoteDeleteRejectedUnderLocalWinsRowExists() async throws {
        let (engineA, engineB, storageA, storageB) = try await setupPair(policy: .localWins)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        let rowID = UUID()
        // Seed: A inserts, B accepts (row doesn't exist on B yet, so localWins inserts it).
        try await seedRow(id: rowID, note: "local-wins-row", engineA: engineA, engineB: engineB, storageA: storageA)

        let before = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(before.count == 1, "row should exist on B after seeding via localWins insert")

        // Delete from A. B's localWins policy means B keeps its local copy.
        _ = try await storageA.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await engineA.push()
        _ = try await engineB.pull()

        let after = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        // localWins: remote delete silently rejected; local row preserved.
        #expect(after.count == 1, "row should be preserved on B under localWins: remote deletes rejected")
    }
}
