// TombstoneLWWTests.swift
//
// Force-tests for tombstone (delete) LWW semantics in CloudKitStateActor.applyInbound.
// Exercises the D1 + D2 + A6 fixes introduced in CVK-ICLOUD P1-M7:
//
//   D1: CKRecord.ID deletions carry no record type — fixed by pushing
//       tombstone CKRecords with a typed recordType instead.
//   D2: Inbound deletions bypassed the HLC gate — fixed by routing
//       tombstone records through the standard LWW comparison.
//   A6: Delete HLC must persist in _ck_sync_meta after hard-delete so
//       stale-resurrect inserts are still gated.
//
// Five cases:
//   1. stale-delete-loses: a tombstone with HLC < local HLC must not delete.
//   2. newer-delete-wins: a tombstone with HLC >= local HLC must hard-delete.
//   3. stale-resurrect-rejected: a stale insert after a delete is gated by
//      the tombstone HLC in _ck_sync_meta (A6).
//   4. delete-then-recreate: a newer insert after a delete is accepted (intentional
//      re-creation must pass the LWW gate).
//   5. cross-table-isolation: deleting a UUID in table A must not remove
//      the same UUID from table B (D1 regression guard).
//
// Tests call CloudKitStateActor.applyInbound directly (@testable import)
// so HLC values are fully controlled without a live CloudKit stack.

import Testing
import Foundation
import CloudKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import ConvergenceKit
@testable import ConvergenceKitCloudKit

@Suite("Tombstone LWW force-tests")
struct TombstoneLWWTests {

    // MARK: - Helpers

    /// Open InMemory storage with `items` and `notes` tables plus the
    /// `_ck_sync_meta` side table required by the LWW gate.
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
                ),
                // Second table for cross-table isolation test (D1 regression guard).
                TableDeclaration(
                    name: "notes",
                    columns: [.uuid("id"), .text("body")],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        // The production path (enable → ensureSyncMetaTable) creates this table.
        // These tests call applyInbound directly, so create it explicitly here.
        try await CloudKitStateActor.ensureSyncMetaTable(storage: storage)
        return storage
    }

    let syncedTable = SyncedTable(
        name: "items",
        primaryKeyColumn: "id",
        conflictPolicy: .lastWriterWinsByHLC
    )

    let notesTable = SyncedTable(
        name: "notes",
        primaryKeyColumn: "id",
        conflictPolicy: .lastWriterWinsByHLC
    )

    /// Build a normal (non-tombstone) upsert record.
    func makeUpsert(table: String = "items", id: UUID, note: String? = nil, hlcTime: Int64) -> DecodedRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        var values: [String: TypedValue] = ["id": .uuid(id), "flags": .bitmap(0)]
        if let note { values["note"] = .text(note) }
        return DecodedRecord(
            table: table,
            rowKey: id,
            values: values,
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: 1, kitID: "TestKit")
        )
    }

    /// Build a tombstone DecodedRecord (isTombstone = true).
    func makeTombstone(table: String = "items", id: UUID, hlcTime: Int64) -> DecodedRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        var decoded = DecodedRecord(
            table: table,
            rowKey: id,
            values: [:],
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: 1, kitID: "TestKit")
        )
        // isTombstone routes applyInbound through the delete-LWW path.
        decoded.isTombstone = true
        return decoded
    }

    // MARK: - Delete LWW gate

    @Test("stale delete does not remove a newer local row")
    func staleDeleteDoesNotRemoveNewerRow() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed the row at T=1000 — establishes HLC=1000 in _ck_sync_meta.
        let seed = makeUpsert(id: rowID, note: "keep-me", hlcTime: 1000)
        try await engine.applyInbound(seed, syncedTable: syncedTable, storage: storage)

        // Stale delete at T=500 — older than local HLC; must be rejected (D2 fix).
        let staleDelete = makeTombstone(id: rowID, hlcTime: 500)
        try await engine.applyInbound(staleDelete, syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1, "stale delete must not remove a row whose HLC is newer (D2 fix)")
    }

    @Test("newer delete removes the local row")
    func newerDeleteRemovesLocalRow() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed the row at T=500.
        let seed = makeUpsert(id: rowID, note: "delete-me", hlcTime: 500)
        try await engine.applyInbound(seed, syncedTable: syncedTable, storage: storage)

        // Newer delete at T=1000 — >= local HLC; must hard-delete the row.
        let newerDelete = makeTombstone(id: rowID, hlcTime: 1000)
        try await engine.applyInbound(newerDelete, syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 0, "newer delete must hard-delete the local row")
    }

    // MARK: - A6: tombstone HLC outlives the row

    @Test("tombstone HLC persists in _ck_sync_meta with is_deleted=1 after hard-delete")
    func tombstoneHLCPersistedAfterDelete() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed then delete.
        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "temp", hlcTime: 500),
            syncedTable: syncedTable, storage: storage)
        try await engine.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: syncedTable, storage: storage)

        // Verify _ck_sync_meta entry exists with is_deleted = 1 (A6 adjudication).
        let metaRows = try await storage.rowStore.query(
            table: "_ck_sync_meta",
            where: .and([
                .eq(Column(table: "_ck_sync_meta", name: "table_name"), .text("items")),
                .eq(Column(table: "_ck_sync_meta", name: "primary_key"), .text(rowID.uuidString))
            ])
        )
        #expect(metaRows.count == 1, "tombstone HLC must persist in _ck_sync_meta after delete (A6)")
        #expect(metaRows[0]["is_deleted"] == .int(1),
                "is_deleted must be 1 for tombstone entries so TombstoneGC can identify them")
        // Gap 6 (D38.1): sync_hlc_wire is the authoritative full-width column;
        // the legacy sync_hlc INT column is dead (retained, always 0).
        guard case .blob(let wire) = metaRows[0]["sync_hlc_wire"] else {
            Issue.record("sync_hlc_wire not found in _ck_sync_meta tombstone row")
            return
        }
        let decoded = try HLC(wireBytes: [UInt8](wire))
        #expect(decoded.physicalTime != 0, "tombstone sync_hlc_wire must be non-zero")
    }

    @Test("stale resurrect rejected: insert with HLC older than tombstone is dropped (A6)")
    func staleResurrectRejected() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed at T=500, then delete at T=1000.
        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "row-before-delete", hlcTime: 500),
            syncedTable: syncedTable, storage: storage)
        try await engine.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: syncedTable, storage: storage)

        // Stale insert at T=400 arrives late (out-of-order delivery or slow peer).
        // The tombstone HLC (T=1000) in _ck_sync_meta must gate this insert (A6).
        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "stale-resurrect", hlcTime: 400),
            syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 0,
                "stale resurrect must be gated by tombstone HLC in _ck_sync_meta (A6)")
    }

    @Test("delete-then-recreate: newer insert after delete is accepted")
    func deleteThenRecreateWithNewerHLC() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed at T=500, delete at T=1000.
        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "first-version", hlcTime: 500),
            syncedTable: syncedTable, storage: storage)
        try await engine.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: syncedTable, storage: storage)

        // Intentional recreate at T=2000 — newer than tombstone HLC; must succeed.
        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "second-version", hlcTime: 2000),
            syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1, "intentional recreate with HLC > tombstone must succeed")
        #expect(rows[0]["note"] == .text("second-version"),
                "recreated row must carry the newer note value")
    }

    // MARK: - D1: cross-table isolation

    @Test("delete in table A does not affect the same UUID in table B (D1 regression guard)")
    func crossTableIsolationOnDelete() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed the same UUID in both "items" and "notes".
        try await engine.applyInbound(
            makeUpsert(table: "items", id: rowID, note: "in-items", hlcTime: 500),
            syncedTable: syncedTable, storage: storage)

        let noteRecord = DecodedRecord(
            table: "notes",
            rowKey: rowID,
            values: ["id": .uuid(rowID), "body": .text("in-notes")],
            syncMeta: SyncMeta(hlc: HLC(physicalTime: 500, logicalCount: 0, nodeID: 1),
                               schemaVersion: 1, kitID: "TestKit")
        )
        try await engine.applyInbound(noteRecord, syncedTable: notesTable, storage: storage)

        // Delete the row in "items" at T=1000 via typed tombstone.
        // The tombstone's `table` field is "items" — must NOT fan out to "notes".
        try await engine.applyInbound(
            makeTombstone(table: "items", id: rowID, hlcTime: 1000),
            syncedTable: syncedTable, storage: storage)

        // Verify the "items" row is gone.
        let itemRows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(itemRows.count == 0, "delete in items must remove only the items row")

        // Verify the "notes" row is unaffected (D1 fix: tombstones are table-scoped).
        let noteRows = try await storage.rowStore.query(
            table: "notes",
            where: .eq(Column(table: "notes", name: "id"), .uuid(rowID))
        )
        #expect(noteRows.count == 1,
                "D1 fix: typed tombstone must not fan out to other tables (notes row must survive)")
        #expect(noteRows[0]["body"] == .text("in-notes"),
                "notes row body must be unchanged after items deletion")
    }
}
