// TombstoneResurrectionGuardTests.swift
//
// Gap 2 fix verification — CloudKit ApplyInbound.swift `.fieldLevelLWW` arm.
//
// GAP 2 (fulcrum P4.3/P4.5 batch — CONFLICT_P4.3_FIELDLEVELLWW_TOMBSTONE_
// RESURRECTION): `.fieldLevelLWW`'s normal (non-tombstone) apply arm reads
// ONLY `ColumnHLCStore` (column-grain, `_ck_sync_meta_cols`) to decide which
// incoming columns win. When a tombstone wins, `ColumnHLCStore.clearAll`
// wipes ALL column entries for that row (correctly — the row is gone). But
// this leaves `FieldLWWMerge.merge` with no way to distinguish "this column
// was never written" from "this column's history was cleared by a
// tombstone" — both read as `localColumnHLCs.entries[column] == nil`, which
// hits the "first write wins" fallback (`shouldApply = true`). Result: a
// stale edit whose HLC PREDATES the tombstone looks like a first-ever write
// and gets applied, resurrecting a row that was correctly deleted. No crash
// required — reproducible via ordinary clock skew or a 3-device race
// (P4.5 proved both).
//
// THE FIX: gate the `.fieldLevelLWW` normal-apply arm on the ROW-GRAIN
// tombstone HLC (`_ck_sync_meta.is_deleted == 1` + its `sync_hlc`, the A6
// signal — untouched by gap 3, which only ever writes ColumnHLCStore on
// local writes). `readTombstoneHLC` returns the tombstone's HLC ONLY when
// the row is currently tombstoned; if the incoming edit's HLC is strictly
// less than that, the edit predates the delete and is rejected outright
// (row stays deleted). An edit whose HLC is >= the tombstone HLC is a
// legitimate post-delete revival and proceeds to a normal apply, correctly
// resurrecting the row.
//
// THE CRITICAL BOUNDARY (tested explicitly, both directions):
//   - editHLC < tombstoneHLC  → REJECT (test staleEditAfterTombstone...)
//   - editHLC > tombstoneHLC  → MUST APPLY (test freshEditAfterTombstone...)
// Getting this wrong in either direction is a data-loss bug (over-reject,
// a legitimate post-delete edit silently dropped) or a zombie-row bug
// (under-reject, gap 2 itself).

import Testing
import Foundation
import CloudKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import ConvergenceKit
@testable import ConvergenceKitCloudKit

@Suite("Gap 2 — fieldLevelLWW tombstone-resurrection guard (CloudKit)")
struct TombstoneResurrectionGuardTests {

    // MARK: - Helpers

    func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "TestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("note")],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        try await CloudKitStateActor.ensureSyncMetaTable(storage: storage)
        return storage
    }

    let flwwTable = SyncedTable(
        name: "items", primaryKeyColumn: "id", conflictPolicy: .fieldLevelLWW
    )

    func makeUpsert(id: UUID, note: String, hlcTime: Int64) -> DecodedRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        return DecodedRecord(
            table: "items",
            rowKey: id,
            values: ["id": .uuid(id), "note": .text(note)],
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: 1, kitID: "TestKit"),
            columnHLCs: ColumnHLCMap.stampAll(keys: ["note"], hlc: PackedHLC(hlc))
        )
    }

    func makeTombstone(id: UUID, hlcTime: Int64) -> DecodedRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        var decoded = DecodedRecord(
            table: "items",
            rowKey: id,
            values: [:],
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: 1, kitID: "TestKit")
        )
        decoded.isTombstone = true
        return decoded
    }

    func rowExists(id: UUID, storage: any Storage) async throws -> StorageRow? {
        try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(id))
        ).first
    }

    // MARK: - (a) STALE edit after delete — must NOT resurrect

    @Test("stale edit (editHLC < tombstoneHLC) after delete: row stays deleted, no resurrection")
    func staleEditAfterTombstoneDoesNotResurrect() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed the row at T=100, then delete it at T=200.
        try await engine.applyInbound(makeUpsert(id: rowID, note: "original", hlcTime: 100),
                                       syncedTable: flwwTable, storage: storage)
        try await engine.applyInbound(makeTombstone(id: rowID, hlcTime: 200),
                                       syncedTable: flwwTable, storage: storage)
        #expect(try await rowExists(id: rowID, storage: storage) == nil, "row must be deleted after the tombstone")

        // A stale edit at T=150 (< tombstone T=200) arrives LATE — clock skew
        // or network delay, no crash involved.
        try await engine.applyInbound(makeUpsert(id: rowID, note: "STALE-MUST-NOT-RESURRECT", hlcTime: 150),
                                       syncedTable: flwwTable, storage: storage)

        // THE MONEY ASSERTION: row must still be deleted. Before the gap-2 fix,
        // this failed — ColumnHLCStore had no entry for "note" (cleared by the
        // tombstone), so FieldLWWMerge.merge's first-write-wins fallback applied
        // the stale edit unconditionally, resurrecting the row.
        #expect(try await rowExists(id: rowID, storage: storage) == nil,
                "stale edit predating the tombstone must NOT resurrect the row (gap 2 money test)")
    }

    // MARK: - (b) LEGITIMATE fresh edit after delete — MUST resurrect (guard against over-reject)

    @Test("fresh edit (editHLC > tombstoneHLC) after delete: row correctly resurrects")
    func freshEditAfterTombstoneResurrectsCorrectly() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        try await engine.applyInbound(makeUpsert(id: rowID, note: "original", hlcTime: 100),
                                       syncedTable: flwwTable, storage: storage)
        try await engine.applyInbound(makeTombstone(id: rowID, hlcTime: 200),
                                       syncedTable: flwwTable, storage: storage)
        #expect(try await rowExists(id: rowID, storage: storage) == nil, "row must be deleted after the tombstone")

        // A genuinely NEW edit at T=300 (> tombstone T=200) arrives — a legitimate
        // post-delete revival (the user recreated the row).
        try await engine.applyInbound(makeUpsert(id: rowID, note: "LEGITIMATE-REVIVAL", hlcTime: 300),
                                       syncedTable: flwwTable, storage: storage)

        // THE GUARD ASSERTION: this MUST apply. A fix that over-rejects (e.g. by
        // comparing against the wrong HLC, or using <= instead of <) would
        // silently drop a legitimate edit — a data-loss bug in the opposite
        // direction from gap 2 itself.
        let row = try await rowExists(id: rowID, storage: storage)
        #expect(row != nil, "edit newer than the tombstone must resurrect the row")
        #expect(row?["note"] == .text("LEGITIMATE-REVIVAL"), "resurrected row must carry the new edit's value")
    }

    // MARK: - (c) Trigger-agnostic: order-independence (3-device / clock-skew race variant)

    @Test("order-independence: stale-edit-then-tombstone and tombstone-then-stale-edit converge to the same (deleted) state")
    func orderIndependenceConvergesToDeletedState() async throws {
        // Estate A processes in "expected" order: edit@50, then tombstone@100.
        let storageA = try await makeStorage()
        let engineA = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()
        try await engineA.applyInbound(makeUpsert(id: rowID, note: "v1", hlcTime: 50),
                                        syncedTable: flwwTable, storage: storageA)
        try await engineA.applyInbound(makeTombstone(id: rowID, hlcTime: 100),
                                        syncedTable: flwwTable, storage: storageA)

        // Estate B processes the SAME two records in the OPPOSITE order — the
        // race/skew scenario: tombstone@100 arrives first, then the stale
        // edit@50 arrives late.
        let storageB = try await makeStorage()
        let engineB = CloudKitStateActor(containerIdentifier: nil)
        try await engineB.applyInbound(makeTombstone(id: rowID, hlcTime: 100),
                                        syncedTable: flwwTable, storage: storageB)
        try await engineB.applyInbound(makeUpsert(id: rowID, note: "v1", hlcTime: 50),
                                        syncedTable: flwwTable, storage: storageB)

        // Both estates must converge to the SAME state (deleted), regardless of
        // arrival order — this is the trigger-agnostic property P4.5 verified.
        let rowA = try await rowExists(id: rowID, storage: storageA)
        let rowB = try await rowExists(id: rowID, storage: storageB)
        #expect(rowA == nil, "estate A (edit-then-tombstone order) must converge to deleted")
        #expect(rowB == nil, "estate B (tombstone-then-edit order) must converge to deleted")
    }
}
