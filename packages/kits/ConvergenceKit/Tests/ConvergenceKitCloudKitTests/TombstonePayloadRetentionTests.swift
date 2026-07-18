// TombstonePayloadRetentionTests.swift
//
// Tests for tombstone-apply payload retention purge (P5-M1b, Perkins P4-M4 advisory).
//
// When a tombstone wins the LWW gate for a (table, rowKey), two side effects
// must fire:
//
//   1. _ck_pending_skew entries for that (table, rowKey) whose stored record
//      HLC is strictly OLDER than the tombstone HLC are deleted.
//      Rationale: they would be rejected by the same LWW gate on replay after
//      a schema update — retaining them wastes storage indefinitely.
//
//   2. Parked outbox entries (is_parked = 1) for that (table, rowKey) are
//      deleted. Rationale: parked entries will never be pushed; retaining them
//      after the row is hard-deleted is indefinite payload retention. A newer
//      active entry would have prevented the tombstone from winning the LWW
//      gate in the first place, so no active entry exists at apply time.
//
// COVERED CASES (CloudKit — ApplyInbound.swift):
//   1. tombstone purges older skew entry (lastWriterWinsByHLC)
//   2. tombstone purges parked outbox entry (lastWriterWinsByHLC)
//   3. newer skew entry survives tombstone (HLC after tombstone)
//   4. non-matching rows in skew queue and outbox are untouched
//   5. fieldLevelLWW: tombstone purges older skew + parked outbox

import Testing
import Foundation
import CloudKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import ConvergenceKit
@testable import ConvergenceKitCloudKit

@Suite("Tombstone payload retention purge — CloudKit (P5-M1b)")
struct TombstonePayloadRetentionTests {

    // MARK: - Helpers

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
                TableDeclaration(
                    name: "other",
                    columns: [.uuid("id"), .text("body")],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        try await CloudKitStateActor.ensureSyncMetaTable(storage: storage)
        return storage
    }

    let lwwTable = SyncedTable(
        name: "items",
        primaryKeyColumn: "id",
        conflictPolicy: .lastWriterWinsByHLC
    )

    let flwwTable = SyncedTable(
        name: "items",
        primaryKeyColumn: "id",
        conflictPolicy: .fieldLevelLWW
    )

    func makeUpsert(table: String = "items", id: UUID, note: String, hlcTime: Int64) -> DecodedRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        return DecodedRecord(
            table: table,
            rowKey: id,
            values: ["id": .uuid(id), "note": .text(note), "flags": .bitmap(0)],
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: 1, kitID: "TestKit")
        )
    }

    func makeTombstone(table: String = "items", id: UUID, hlcTime: Int64) -> DecodedRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        var decoded = DecodedRecord(
            table: table,
            rowKey: id,
            values: [:],
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: 1, kitID: "TestKit")
        )
        decoded.isTombstone = true
        return decoded
    }

    /// Manually enqueue a SyncRecord in the CK pending-skew table (mirrors PullCycle path).
    func enqueueSkewEntry(
        id: UUID, note: String, hlcTime: Int64, schemaVersion: Int = 2,
        storage: any Storage
    ) async throws {
        let record = SyncRecord(
            table: "items",
            event: .update,
            rowKey: id,
            values: SyncValueMap(["id": .uuid(id), "note": .text(note), "flags": .bitmap(0)]),
            hlc: PackedHLC(HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)),
            schemaVersion: schemaVersion,
            kitID: "TestKit"
        )
        try await PendingSkewQueue.enqueue(
            record, to: storage, sideTable: CKSideSchema.pendingSkewTable)
    }

    /// Manually add a parked outbox entry for (tableName, rowKey).
    func enqueueParkedOutbox(
        tableName: String = "items", rowKey: UUID, hlcTime: Int64,
        storage: any Storage
    ) async throws {
        let rawHLC = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        let entry = OutboxEntry(
            id: UUID(),
            tableName: tableName,
            rowKey: rowKey.uuidString,
            event: .update,
            valuesData: nil,
            // Use the substrate's canonical packed layout, then reinterpret as Int64.
            packedHLC: Int64(bitPattern: rawHLC.packed),
            enqueuedAt: ISO8601DateFormatter().string(from: Date()),
            retryCount: 3,
            isParked: true
        )
        try await OutboxStore.append(entry: entry, to: storage)
        // Force is_parked = 1 via the park() API (append may not set isParked directly).
        try await OutboxStore.park(id: entry.id, from: storage)
    }

    func skewQueueCount(rowKey: UUID, storage: any Storage) async throws -> Int {
        let rows = try await storage.rowStore.query(
            table: CKSideSchema.pendingSkewTable,
            where: .and([
                .eq(Column(table: CKSideSchema.pendingSkewTable, name: "table_name"), .text("items")),
                .eq(Column(table: CKSideSchema.pendingSkewTable, name: "row_key"), .text(rowKey.uuidString))
            ])
        )
        return rows.count
    }

    func parkedOutboxCount(tableName: String = "items", rowKey: UUID, storage: any Storage) async throws -> Int {
        let rows = try await OutboxStore.parkedEntries(from: storage)
        return rows.filter { $0.tableName == tableName && $0.rowKey == rowKey.uuidString }.count
    }

    // MARK: - Case 1: tombstone purges older skew entry (lastWriterWinsByHLC)

    @Test("tombstone purges older skew-queue entry (lastWriterWinsByHLC)")
    func tombstonePurgesOlderSkewEntry() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed the row at T=500.
        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "keep", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)

        // Enqueue a skew entry with HLC=800 (newer schema, older than tombstone T=1000).
        // On replay this entry would lose to the tombstone — purge it at tombstone-apply time.
        try await enqueueSkewEntry(id: rowID, note: "skew-note", hlcTime: 800, storage: storage)
        let beforeCount = try await skewQueueCount(rowKey: rowID, storage: storage)
        #expect(beforeCount == 1, "skew entry must be in queue before tombstone apply")

        // Apply tombstone at T=1000 — wins LWW gate (> T=500 local HLC).
        try await engine.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: lwwTable, storage: storage)

        // Skew entry with HLC=800 < 1000 must be purged.
        let afterCount = try await skewQueueCount(rowKey: rowID, storage: storage)
        #expect(afterCount == 0,
                "older skew entry must be purged when tombstone applies (P5-M1b)")
    }

    // MARK: - Case 2: tombstone purges parked outbox entry (lastWriterWinsByHLC)

    @Test("tombstone purges parked outbox entry (lastWriterWinsByHLC)")
    func tombstonePurgesParkedOutboxEntry() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed the row at T=500.
        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "row", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)

        // Enqueue a parked outbox entry for this row.
        try await enqueueParkedOutbox(rowKey: rowID, hlcTime: 600, storage: storage)
        let beforeParked = try await parkedOutboxCount(rowKey: rowID, storage: storage)
        #expect(beforeParked == 1, "parked outbox entry must exist before tombstone apply")

        // Apply tombstone at T=1000 — wins.
        try await engine.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: lwwTable, storage: storage)

        // Parked outbox entry must be purged (prevents indefinite retention, Perkins P4-M4).
        let afterParked = try await parkedOutboxCount(rowKey: rowID, storage: storage)
        #expect(afterParked == 0,
                "parked outbox entry must be purged when tombstone applies (P5-M1b / Perkins P4-M4)")
    }

    // MARK: - Case 3: newer skew entry SURVIVES tombstone

    @Test("skew entry with HLC newer than tombstone survives")
    func newerSkewEntrySurvivesTombstone() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed the row at T=500.
        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "row", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)

        // Enqueue a skew entry with HLC=2000 — NEWER than tombstone T=1000.
        // On replay this entry would WIN over the tombstone; do not purge it.
        try await enqueueSkewEntry(id: rowID, note: "future-schema-write", hlcTime: 2000, storage: storage)
        let beforeCount = try await skewQueueCount(rowKey: rowID, storage: storage)
        #expect(beforeCount == 1, "newer skew entry must exist before tombstone apply")

        // Apply tombstone at T=1000.
        try await engine.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: lwwTable, storage: storage)

        // Newer skew entry (HLC=2000 > tombstone HLC=1000) must survive.
        let afterCount = try await skewQueueCount(rowKey: rowID, storage: storage)
        #expect(afterCount == 1,
                "skew entry whose HLC is newer than tombstone must not be purged (P5-M1b)")
    }

    // MARK: - Case 4: non-matching rows are untouched

    @Test("tombstone purge does not affect entries for a different rowKey")
    func nonMatchingRowsUntouched() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let targetID = UUID()
        let otherID  = UUID()

        // Seed both rows.
        try await engine.applyInbound(
            makeUpsert(id: targetID, note: "target", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)
        try await engine.applyInbound(
            makeUpsert(id: otherID, note: "other", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)

        // Enqueue skew entry for OTHER row.
        try await enqueueSkewEntry(id: otherID, note: "other-skew", hlcTime: 800, storage: storage)
        // Enqueue parked outbox entry for OTHER row.
        try await enqueueParkedOutbox(rowKey: otherID, hlcTime: 600, storage: storage)

        // Apply tombstone only for TARGET row.
        try await engine.applyInbound(
            makeTombstone(id: targetID, hlcTime: 1000),
            syncedTable: lwwTable, storage: storage)

        // Other row's skew entry must be untouched.
        let otherSkewCount = try await skewQueueCount(rowKey: otherID, storage: storage)
        #expect(otherSkewCount == 1,
                "tombstone purge must not affect skew entries for different rowKey")

        // Other row's parked outbox entry must be untouched.
        let otherParkedCount = try await parkedOutboxCount(rowKey: otherID, storage: storage)
        #expect(otherParkedCount == 1,
                "tombstone purge must not affect parked outbox entries for different rowKey")
    }

    // MARK: - Case 5: fieldLevelLWW tombstone purges older skew + parked outbox

    @Test("fieldLevelLWW tombstone purges older skew entry and parked outbox entry")
    func fieldLevelLWWTombstonePurgesPayloads() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed via upsertSync to set up column HLC state (mirrors production apply path).
        // Use applyInbound with a fieldLevelLWW syncedTable.
        let seedRecord = DecodedRecord(
            table: "items",
            rowKey: rowID,
            values: [
                "id": .uuid(rowID),
                "note": .text("row"),
                "flags": .bitmap(0)
            ],
            syncMeta: SyncMeta(
                hlc: HLC(physicalTime: 500, logicalCount: 0, nodeID: 1),
                schemaVersion: 1, kitID: "TestKit"
            ),
            columnHLCs: ColumnHLCMap.stampAll(
                keys: ["id", "note", "flags"],
                hlc: PackedHLC(HLC(physicalTime: 500, logicalCount: 0, nodeID: 1))
            )
        )
        try await engine.applyInbound(seedRecord, syncedTable: flwwTable, storage: storage)

        // Enqueue an older skew entry (HLC=800 < tombstone T=1000).
        try await enqueueSkewEntry(id: rowID, note: "flww-skew", hlcTime: 800, storage: storage)
        // Enqueue a parked outbox entry.
        try await enqueueParkedOutbox(rowKey: rowID, hlcTime: 600, storage: storage)

        let beforeSkew = try await skewQueueCount(rowKey: rowID, storage: storage)
        let beforeParked = try await parkedOutboxCount(rowKey: rowID, storage: storage)
        #expect(beforeSkew == 1, "skew entry must exist before fieldLevelLWW tombstone apply")
        #expect(beforeParked == 1, "parked outbox entry must exist before fieldLevelLWW tombstone apply")

        // Build a tombstone that beats all column HLCs (T=1000 > T=500 seed).
        let tombstoneHLC = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)
        var tombstone = DecodedRecord(
            table: "items",
            rowKey: rowID,
            values: [:],
            syncMeta: SyncMeta(hlc: tombstoneHLC, schemaVersion: 1, kitID: "TestKit")
        )
        tombstone.isTombstone = true

        try await engine.applyInbound(tombstone, syncedTable: flwwTable, storage: storage)

        // Both must be purged.
        let afterSkew = try await skewQueueCount(rowKey: rowID, storage: storage)
        let afterParked = try await parkedOutboxCount(rowKey: rowID, storage: storage)
        #expect(afterSkew == 0,
                "fieldLevelLWW tombstone must purge older skew entry (P5-M1b)")
        #expect(afterParked == 0,
                "fieldLevelLWW tombstone must purge parked outbox entry (P5-M1b)")
    }
}

