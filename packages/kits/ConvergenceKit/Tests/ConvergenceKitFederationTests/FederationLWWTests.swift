// FederationLWWTests.swift
//
// Force-tests for FederationSyncEngine last-writer-wins-by-HLC semantics.
//
// These tests cover four cases per port:
//   1. stale-inbound-loses: an older inbound write must not overwrite a newer
//      local row (the core LWW contract).
//   2. newer-inbound-wins: a newer inbound write must overwrite an older
//      local row.
//   3. stale-delete-loses: a delete whose HLC is older than the local row's
//      _syncHLC must not remove the local row.
//   4. newer-delete-wins: a delete whose HLC is >= the local row's _syncHLC
//      must hard-delete the local row.
//
// Tests drive FederationStateActor.applyInbound directly (via @testable import)
// so HLC values are fully controlled without relying on wall-clock timing.
// This mirrors the approach in LWWDurableHLCTests for the CloudKit path.

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

@Suite("Federation LWW force-tests")
struct FederationLWWTests {

    // MARK: - Helpers

    /// Open InMemory storage with an `items` table; no _syncHLC column
    /// declaration needed — InMemory accepts extra columns on upsert.
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
                    columns: [.uuid("id"), .text("note"), .bitmap("flags")],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        return storage
    }

    let syncedTable = SyncedTable(
        name: "items",
        primaryKeyColumn: "id",
        conflictPolicy: .lastWriterWinsByHLC
    )

    /// Build a SyncRecord for an upsert with explicit HLC physical time.
    func makeRecord(id: UUID, note: String, hlcTime: Int64) -> SyncRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        return SyncRecord(
            table: "items",
            event: .update,
            rowKey: id,
            values: SyncValueMap(["id": .uuid(id), "note": .text(note), "flags": .bitmap(0)]),
            hlc: PackedHLC(hlc),
            schemaVersion: 1,
            kitID: "TestKit"
        )
    }

    /// Build a SyncRecord for a delete with explicit HLC physical time.
    func makeDeleteRecord(id: UUID, hlcTime: Int64) -> SyncRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        return SyncRecord(
            table: "items",
            event: .delete,
            rowKey: id,
            values: nil,
            hlc: PackedHLC(hlc),
            schemaVersion: 1,
            kitID: "TestKit"
        )
    }

    // MARK: - Upsert path

    @Test("stale inbound write does not overwrite newer local row")
    func staleInboundDoesNotOverwriteNewerLocalRow() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // First inbound at T=1000 — wins; _syncHLC must be persisted.
        let first = makeRecord(id: rowID, note: "first-at-T1000", hlcTime: 1000)
        try await actor.applyInbound(first, syncedTable: syncedTable, storage: storage)

        // Second inbound at T=500 — older; must be rejected.
        let stale = makeRecord(id: rowID, note: "stale-at-T500", hlcTime: 500)
        try await actor.applyInbound(stale, syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1)
        #expect(rows[0]["note"] == .text("first-at-T1000"),
                "stale inbound must not overwrite the newer local row")
    }

    @Test("newer inbound write overwrites older local row")
    func newerInboundOverwritesOlderLocalRow() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // First inbound at T=500.
        let old = makeRecord(id: rowID, note: "old-at-T500", hlcTime: 500)
        try await actor.applyInbound(old, syncedTable: syncedTable, storage: storage)

        // Second inbound at T=1000 — newer; must win.
        let newer = makeRecord(id: rowID, note: "newer-at-T1000", hlcTime: 1000)
        try await actor.applyInbound(newer, syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1)
        #expect(rows[0]["note"] == .text("newer-at-T1000"),
                "newer inbound write must win LWW")
    }

    @Test("_syncHLC is written durably so the next inbound comparison fires")
    func syncHLCPersistedAfterApply() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // Apply at T=2000 — _syncHLC must be stored in the row.
        let first = makeRecord(id: rowID, note: "local-at-T2000", hlcTime: 2000)
        try await actor.applyInbound(first, syncedTable: syncedTable, storage: storage)

        let stored = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(stored.count == 1)
        guard case .hlc(_) = stored[0]["_syncHLC"] ?? .null else {
            Issue.record("_syncHLC not persisted in row after first write — LWW cannot guard on next inbound")
            return
        }

        // Stale second inbound at T=1500 — must be rejected because
        // the persisted _syncHLC (T=2000) is newer.
        let stale = makeRecord(id: rowID, note: "stale-at-T1500", hlcTime: 1500)
        try await actor.applyInbound(stale, syncedTable: syncedTable, storage: storage)

        let finalRows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(finalRows.count == 1)
        #expect(finalRows[0]["note"] == .text("local-at-T2000"),
                "persisted _syncHLC must guard against stale second inbound")
    }

    // MARK: - Delete path

    @Test("stale delete does not remove a newer local row")
    func staleDeleteDoesNotRemoveNewerLocalRow() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // Seed the row at T=1000 — establishes _syncHLC=1000.
        let seed = makeRecord(id: rowID, note: "keep-me", hlcTime: 1000)
        try await actor.applyInbound(seed, syncedTable: syncedTable, storage: storage)

        // Stale delete at T=500 — older than local _syncHLC; must be rejected.
        let staleDelete = makeDeleteRecord(id: rowID, hlcTime: 500)
        try await actor.applyInbound(staleDelete, syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1,
                "stale delete must not remove a row whose _syncHLC is newer")
    }

    @Test("newer delete removes the local row")
    func newerDeleteRemovesLocalRow() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // Seed the row at T=500 — establishes _syncHLC=500.
        let seed = makeRecord(id: rowID, note: "delete-me", hlcTime: 500)
        try await actor.applyInbound(seed, syncedTable: syncedTable, storage: storage)

        // Newer delete at T=1000 — >= local _syncHLC; must hard-delete the row.
        let newerDelete = makeDeleteRecord(id: rowID, hlcTime: 1000)
        try await actor.applyInbound(newerDelete, syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 0,
                "newer delete must hard-delete the local row")
    }
}
