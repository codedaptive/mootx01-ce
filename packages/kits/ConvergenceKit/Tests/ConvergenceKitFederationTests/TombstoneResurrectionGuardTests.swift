// TombstoneResurrectionGuardTests.swift
//
// Gap 2 fix verification — Federation FederationStateActor.applyInbound
// `.fieldLevelLWW` arm.
//
// Swift twin of ConvergenceKitCloudKitTests/TombstoneResurrectionGuardTests.swift.
// See that file's header for the full gap-2 writeup. Summary: `.fieldLevelLWW`'s
// normal-apply arm read only ColumnHLCStore (column-grain), which cannot
// distinguish "column never written" from "history cleared by a tombstone"
// (ColumnHLCStore.clearAll wipes it on tombstone-wins). A stale edit predating
// a delete looked like a first-ever write and got applied, resurrecting a
// correctly-deleted row — reproducible via clock skew or a 3-device race, no
// crash required. Fixed by gating on the ROW-GRAIN tombstone HLC
// (`_fed_sync_meta.is_deleted == 1`, the A6 signal, untouched by gap 3):
// an edit strictly older than the tombstone is rejected; an edit at or after
// the tombstone HLC proceeds to a normal apply, correctly resurrecting the row.

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

@Suite("Gap 2 — fieldLevelLWW tombstone-resurrection guard (Federation)")
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
        try await FederationStateActor.ensureFedSyncMetaTable(storage: storage)
        return storage
    }

    let flwwTable = SyncedTable(
        name: "items", primaryKeyColumn: "id", conflictPolicy: .fieldLevelLWW
    )

    func makeUpsert(id: UUID, note: String, hlcTime: Int64) -> SyncRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        return SyncRecord(
            table: "items",
            event: .update,
            rowKey: id,
            values: SyncValueMap(["id": .uuid(id), "note": .text(note)]),
            hlc: PackedHLC(hlc),
            schemaVersion: 1,
            kitID: "TestKit",
            columnHLCs: ColumnHLCMap.stampAll(keys: ["note"], hlc: PackedHLC(hlc))
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

    func rowExists(id: UUID, storage: any Storage) async throws -> StorageRow? {
        try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(id))
        ).first
    }

    // MARK: - (a) STALE edit after delete — must NOT resurrect

    @Test("stale edit (editHLC < tombstoneHLC) after delete: row stays deleted, no resurrection")
    func staleEditAfterTombstoneDoesNotResurrect() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        try await actor.applyInbound(makeUpsert(id: rowID, note: "original", hlcTime: 100),
                                      syncedTable: flwwTable, storage: storage)
        try await actor.applyInbound(makeTombstone(id: rowID, hlcTime: 200),
                                      syncedTable: flwwTable, storage: storage)
        #expect(try await rowExists(id: rowID, storage: storage) == nil, "row must be deleted after the tombstone")

        // A stale edit at T=150 (< tombstone T=200) arrives late.
        try await actor.applyInbound(makeUpsert(id: rowID, note: "STALE-MUST-NOT-RESURRECT", hlcTime: 150),
                                      syncedTable: flwwTable, storage: storage)

        // THE MONEY ASSERTION: row must still be deleted.
        #expect(try await rowExists(id: rowID, storage: storage) == nil,
                "stale edit predating the tombstone must NOT resurrect the row (gap 2 money test)")
    }

    // MARK: - (b) LEGITIMATE fresh edit after delete — MUST resurrect (guard against over-reject)

    @Test("fresh edit (editHLC > tombstoneHLC) after delete: row correctly resurrects")
    func freshEditAfterTombstoneResurrectsCorrectly() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        try await actor.applyInbound(makeUpsert(id: rowID, note: "original", hlcTime: 100),
                                      syncedTable: flwwTable, storage: storage)
        try await actor.applyInbound(makeTombstone(id: rowID, hlcTime: 200),
                                      syncedTable: flwwTable, storage: storage)
        #expect(try await rowExists(id: rowID, storage: storage) == nil, "row must be deleted after the tombstone")

        // A genuinely NEW edit at T=300 (> tombstone T=200) — a legitimate
        // post-delete revival.
        try await actor.applyInbound(makeUpsert(id: rowID, note: "LEGITIMATE-REVIVAL", hlcTime: 300),
                                      syncedTable: flwwTable, storage: storage)

        let row = try await rowExists(id: rowID, storage: storage)
        #expect(row != nil, "edit newer than the tombstone must resurrect the row")
        #expect(row?["note"] == .text("LEGITIMATE-REVIVAL"), "resurrected row must carry the new edit's value")
    }

    // MARK: - (c) Trigger-agnostic: order-independence (3-device / clock-skew race variant)

    @Test("order-independence: stale-edit-then-tombstone and tombstone-then-stale-edit converge to the same (deleted) state")
    func orderIndependenceConvergesToDeletedState() async throws {
        // Estate A: edit@50 then tombstone@100 (expected order).
        let storageA = try await makeStorage()
        let actorA = FederationStateActor()
        let rowID = UUID()
        try await actorA.applyInbound(makeUpsert(id: rowID, note: "v1", hlcTime: 50),
                                       syncedTable: flwwTable, storage: storageA)
        try await actorA.applyInbound(makeTombstone(id: rowID, hlcTime: 100),
                                       syncedTable: flwwTable, storage: storageA)

        // Estate B: the SAME two records in the OPPOSITE order — tombstone@100
        // arrives first, then the stale edit@50 arrives late (race/skew).
        let storageB = try await makeStorage()
        let actorB = FederationStateActor()
        try await actorB.applyInbound(makeTombstone(id: rowID, hlcTime: 100),
                                       syncedTable: flwwTable, storage: storageB)
        try await actorB.applyInbound(makeUpsert(id: rowID, note: "v1", hlcTime: 50),
                                       syncedTable: flwwTable, storage: storageB)

        let rowA = try await rowExists(id: rowID, storage: storageA)
        let rowB = try await rowExists(id: rowID, storage: storageB)
        #expect(rowA == nil, "estate A (edit-then-tombstone order) must converge to deleted")
        #expect(rowB == nil, "estate B (tombstone-then-edit order) must converge to deleted")
    }
}
