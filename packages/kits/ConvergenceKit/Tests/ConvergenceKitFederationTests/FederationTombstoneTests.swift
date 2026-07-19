// FederationTombstoneTests.swift
//
// Tombstone-specific tests for FederationStateActor (CVK-ICLOUD P1-M7).
// Complements FederationLWWTests which covers the basic stale-delete and
// newer-delete LWW matrix.
//
// Focus:
//   A6 adjudication: after a Federation delete, the delete HLC must persist
//     in `_fed_sync_meta` with `is_deleted = 1` so subsequent stale inserts
//     for the same (table, rowKey) are gated (stale-resurrect protection).
//   Wire: SyncRecord with `sync_deleted = true` JSON round-trip via the
//     standard serde_json wire format (C-8 parity test on the Swift side).
//   Stale resurrect: explicit Federation path variant to complement the
//     CloudKit-side test in TombstoneLWWTests.
//
// Tests drive FederationStateActor.applyInbound directly (@testable import)
// with fully-controlled HLC values, no network stack.

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

@Suite("Federation tombstone and A6 adjudication tests")
struct FederationTombstoneTests {

    // MARK: - Helpers

    /// Open InMemory storage with an `items` table and the `_fed_sync_meta`
    /// side table required by the A6 LWW side-table path.
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
        // A6: ensure _fed_sync_meta exists so applyInbound can read/write HLCs.
        // In production this is called from enable(). Tests call applyInbound
        // directly so must create the table manually.
        try await FederationStateActor.ensureFedSyncMetaTable(storage: storage)
        return storage
    }

    let syncedTable = SyncedTable(
        name: "items",
        primaryKeyColumn: "id",
        conflictPolicy: .lastWriterWinsByHLC
    )

    func makeUpsert(id: UUID, note: String, hlcTime: Int64) -> SyncRecord {
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

    func makeTombstone(id: UUID, hlcTime: Int64) -> SyncRecord {
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

    // MARK: - Wire round-trip

    @Test("SyncRecord with syncDeleted = true round-trips through JSON (C-8 wire parity)")
    func syncDeletedFieldRoundTrips() throws {
        let id = UUID()
        let hlc = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)

        // 1. Tombstone record: syncDeleted = true must survive JSON round-trip.
        let tombstone = SyncRecord(
            table: "items",
            event: .delete,
            rowKey: id,
            values: nil,
            hlc: PackedHLC(hlc),
            schemaVersion: 1,
            kitID: "TestKit",
            syncDeleted: true
        )
        let tombstoneData = try JSONEncoder().encode(tombstone)
        let decodedTombstone = try JSONDecoder().decode(SyncRecord.self, from: tombstoneData)

        #expect(decodedTombstone.syncDeleted == true,
                "syncDeleted = true must survive JSON round-trip (C-8 wire parity)")
        #expect(decodedTombstone.event == .delete, "event must survive round-trip")
        #expect(decodedTombstone.rowKey == id, "rowKey must survive round-trip")
        #expect(decodedTombstone.table == "items", "table must survive round-trip")

        // 2. Non-tombstone record: syncDeleted must be omitted from JSON when nil.
        let normalRecord = SyncRecord(
            table: "items",
            event: .update,
            rowKey: id,
            values: nil,
            hlc: PackedHLC(hlc),
            schemaVersion: 1,
            kitID: "TestKit"
            // syncDeleted defaults to nil
        )
        #expect(normalRecord.syncDeleted == nil,
                "syncDeleted must be nil by default for non-delete records")

        let normalData = try JSONEncoder().encode(normalRecord)
        let normalJSON = String(decoding: normalData, as: UTF8.self)
        #expect(!normalJSON.contains("syncDeleted"),
                "syncDeleted must be omitted from JSON when nil (wire compactness, C-8 parity)")
    }

    // MARK: - A6: tombstone HLC persists in _fed_sync_meta

    @Test("tombstone HLC persists in _fed_sync_meta with is_deleted=1 after hard-delete (A6)")
    func tombstoneHLCPersistedAfterDelete() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // Seed at T=500, then delete at T=1000.
        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "temp", hlcTime: 500),
            syncedTable: syncedTable, storage: storage)
        try await actor.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: syncedTable, storage: storage)

        // Verify _fed_sync_meta entry exists with is_deleted = 1 (A6 adjudication).
        let metaRows = try await storage.rowStore.query(
            table: "_fed_sync_meta",
            where: .and([
                .eq(Column(table: "_fed_sync_meta", name: "table_name"), .text("items")),
                .eq(Column(table: "_fed_sync_meta", name: "primary_key"), .text(rowID.uuidString))
            ])
        )
        #expect(metaRows.count == 1,
                "tombstone HLC must persist in _fed_sync_meta after delete (A6)")
        #expect(metaRows[0]["is_deleted"] == .int(1),
                "is_deleted must be 1 for tombstone entries")
        // Gap 6 (D38.1): sync_hlc_wire is the authoritative full-width column;
        // the legacy sync_hlc INT column is dead (retained, always 0).
        guard case .blob(let wire) = metaRows[0]["sync_hlc_wire"] else {
            Issue.record("sync_hlc_wire not found in _fed_sync_meta tombstone entry")
            return
        }
        let decoded = try HLC(wireBytes: [UInt8](wire))
        #expect(decoded.physicalTime != 0, "tombstone sync_hlc_wire must be non-zero")
    }

    // MARK: - Stale resurrect via Federation

    @Test("stale resurrect rejected: insert with HLC older than tombstone is dropped (A6)")
    func staleResurrectRejectedViaFederation() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // Seed at T=500.
        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "row-before-delete", hlcTime: 500),
            syncedTable: syncedTable, storage: storage)

        // Delete at T=1000 — hard-deletes row + persists tombstone HLC in _fed_sync_meta.
        try await actor.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: syncedTable, storage: storage)

        // Stale insert at T=400 arrives late (out-of-order delivery or slow peer).
        // The tombstone HLC in _fed_sync_meta (T=1000) must block this insert (A6).
        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "stale-resurrect", hlcTime: 400),
            syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 0,
                "stale resurrect via Federation must be gated by tombstone HLC in _fed_sync_meta (A6)")
    }

    @Test("delete-then-recreate via Federation: newer insert after delete is accepted")
    func deleteThenRecreateViaFederation() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // Seed at T=500, delete at T=1000.
        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "first-version", hlcTime: 500),
            syncedTable: syncedTable, storage: storage)
        try await actor.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: syncedTable, storage: storage)

        // Intentional recreate at T=2000 — newer than tombstone HLC; must succeed.
        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "second-version", hlcTime: 2000),
            syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1, "intentional recreate with HLC > tombstone must succeed")
        #expect(rows[0]["note"] == .text("second-version"),
                "recreated row must carry the newer data")

        // After recreate, the _fed_sync_meta entry must have is_deleted = 0 (live row).
        let metaRows = try await storage.rowStore.query(
            table: "_fed_sync_meta",
            where: .and([
                .eq(Column(table: "_fed_sync_meta", name: "table_name"), .text("items")),
                .eq(Column(table: "_fed_sync_meta", name: "primary_key"), .text(rowID.uuidString))
            ])
        )
        #expect(metaRows.count == 1, "_fed_sync_meta must have an entry after recreate")
        #expect(metaRows[0]["is_deleted"] == .int(0),
                "is_deleted must flip to 0 after a successful recreate replaces the tombstone entry")
    }
}
