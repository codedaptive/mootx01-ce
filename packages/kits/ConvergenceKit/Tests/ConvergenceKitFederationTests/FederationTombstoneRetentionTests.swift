// FederationTombstoneRetentionTests.swift
//
// Tests for tombstone-apply payload retention purge on the Federation backend
// (P5-M1b, Perkins P4-M4 advisory).
//
// Mirrors TombstonePayloadRetentionTests for the CloudKit backend but drives
// FederationStateActor.applyInbound directly with SyncRecord (not DecodedRecord).
//
// COVERED CASES:
//   1. tombstone purges older _fed_pending_skew entry (lastWriterWinsByHLC)
//   2. tombstone purges parked outbox entry (lastWriterWinsByHLC)
//   3. newer skew entry survives tombstone (HLC after tombstone)
//   4. non-matching rows untouched
//   5. fieldLevelLWW tombstone purges older skew + parked outbox

import Testing
import Foundation
@testable import ConvergenceKitFederation
@testable import ConvergenceKitCloudKit
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

@Suite("Federation tombstone payload retention purge (P5-M1b)")
struct FederationTombstoneRetentionTests {

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
                )
            ],
            indices: [],
            migrations: []
        ))
        // Ensure _fed_sync_meta, _fed_sync_meta_cols, and _fed_pending_skew.
        try await FederationStateActor.ensureFedSyncMetaTable(storage: storage)
        // Ensure _ck_outbox (and other CK side tables) so OutboxStore.deleteMatchingParked
        // can be exercised in tests that verify the outbox-purge path on Federation.
        // In production, a device may have both CloudKit and Federation side schemas
        // present (e.g. during a backend migration or mixed-deployment scenario).
        try await CKSideSchema.ensure(storage: storage)
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

    func makeUpsert(id: UUID, note: String, hlcTime: Int64) -> SyncRecord {
        SyncRecord(
            table: "items", event: .update, rowKey: id,
            values: SyncValueMap(["id": .uuid(id), "note": .text(note), "flags": .bitmap(0)]),
            hlc: PackedHLC(HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)),
            schemaVersion: 1, kitID: "TestKit"
        )
    }

    func makeUpsertFLWW(id: UUID, note: String, hlcTime: Int64) -> SyncRecord {
        let hlc = PackedHLC(HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1))
        return SyncRecord(
            table: "items", event: .update, rowKey: id,
            values: SyncValueMap(["id": .uuid(id), "note": .text(note), "flags": .bitmap(0)]),
            hlc: hlc,
            schemaVersion: 1, kitID: "TestKit",
            columnHLCs: ColumnHLCMap.stampAll(keys: ["id", "note", "flags"], hlc: hlc)
        )
    }

    func makeTombstone(id: UUID, hlcTime: Int64) -> SyncRecord {
        SyncRecord(
            table: "items", event: .delete, rowKey: id,
            values: nil,
            hlc: PackedHLC(HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)),
            schemaVersion: 1, kitID: "TestKit"
        )
    }

    func enqueueSkewEntry(
        id: UUID, note: String, hlcTime: Int64, schemaVersion: Int = 2,
        storage: any Storage
    ) async throws {
        let record = SyncRecord(
            table: "items", event: .update, rowKey: id,
            values: SyncValueMap(["id": .uuid(id), "note": .text(note), "flags": .bitmap(0)]),
            hlc: PackedHLC(HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)),
            schemaVersion: schemaVersion, kitID: "TestKit"
        )
        try await PendingSkewQueue.enqueue(
            record, to: storage, sideTable: FederationStateActor.fedPendingSkewTable)
    }

    func enqueueParkedOutbox(rowKey: UUID, hlcTime: Int64, storage: any Storage) async throws {
        let rawHLC = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        let entry = OutboxEntry(
            id: UUID(),
            tableName: "items",
            rowKey: rowKey.uuidString,
            event: .update,
            valuesData: nil,
            hlcWireBytes: Data(rawHLC.wireBytes),
            enqueuedAt: ISO8601DateFormatter().string(from: Date()),
            retryCount: 3,
            isParked: true
        )
        try await OutboxStore.append(entry: entry, to: storage)
        try await OutboxStore.park(id: entry.id, from: storage)
    }

    func fedSkewCount(rowKey: UUID, storage: any Storage) async throws -> Int {
        let rows = try await storage.rowStore.query(
            table: FederationStateActor.fedPendingSkewTable,
            where: .and([
                .eq(Column(table: FederationStateActor.fedPendingSkewTable,
                           name: "table_name"), .text("items")),
                .eq(Column(table: FederationStateActor.fedPendingSkewTable,
                           name: "row_key"), .text(rowKey.uuidString))
            ])
        )
        return rows.count
    }

    func parkedOutboxCount(rowKey: UUID, storage: any Storage) async throws -> Int {
        let rows = try await OutboxStore.parkedEntries(from: storage)
        return rows.filter { $0.tableName == "items" && $0.rowKey == rowKey.uuidString }.count
    }

    // MARK: - Case 1: tombstone purges older skew entry (lastWriterWinsByHLC)

    @Test("Federation tombstone purges older _fed_pending_skew entry (lastWriterWinsByHLC)")
    func fedTombstonePurgesOlderSkewEntry() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // Seed the row at T=500.
        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "row", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)

        // Enqueue an older-schema skew entry with HLC=800 < tombstone T=1000.
        try await enqueueSkewEntry(id: rowID, note: "fed-skew", hlcTime: 800, storage: storage)
        let before = try await fedSkewCount(rowKey: rowID, storage: storage)
        #expect(before == 1, "skew entry must exist before tombstone apply")

        // Apply tombstone at T=1000 — wins LWW gate.
        try await actor.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: lwwTable, storage: storage)

        let after = try await fedSkewCount(rowKey: rowID, storage: storage)
        #expect(after == 0,
                "Federation: older skew entry must be purged when tombstone applies (P5-M1b)")
    }

    // MARK: - Case 2: tombstone purges parked outbox entry (lastWriterWinsByHLC)

    @Test("Federation tombstone purges parked outbox entry (lastWriterWinsByHLC)")
    func fedTombstonePurgesParkedOutbox() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "row", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)

        try await enqueueParkedOutbox(rowKey: rowID, hlcTime: 600, storage: storage)
        let before = try await parkedOutboxCount(rowKey: rowID, storage: storage)
        #expect(before == 1, "parked outbox entry must exist before tombstone apply")

        try await actor.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: lwwTable, storage: storage)

        let after = try await parkedOutboxCount(rowKey: rowID, storage: storage)
        #expect(after == 0,
                "Federation: parked outbox entry must be purged when tombstone applies (P5-M1b)")
    }

    // MARK: - Case 3: newer skew entry survives tombstone

    @Test("Federation: skew entry with HLC newer than tombstone survives")
    func fedNewerSkewEntrySurvives() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        try await actor.applyInbound(
            makeUpsert(id: rowID, note: "row", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)

        // Skew entry HLC=2000 > tombstone T=1000 — must survive.
        try await enqueueSkewEntry(id: rowID, note: "future-write", hlcTime: 2000, storage: storage)
        let before = try await fedSkewCount(rowKey: rowID, storage: storage)
        #expect(before == 1, "newer skew entry must exist before tombstone apply")

        try await actor.applyInbound(
            makeTombstone(id: rowID, hlcTime: 1000),
            syncedTable: lwwTable, storage: storage)

        let after = try await fedSkewCount(rowKey: rowID, storage: storage)
        #expect(after == 1,
                "Federation: newer skew entry (HLC > tombstone) must not be purged (P5-M1b)")
    }

    // MARK: - Case 4: non-matching rows untouched

    @Test("Federation tombstone purge does not affect entries for a different rowKey")
    func fedNonMatchingRowsUntouched() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let targetID = UUID()
        let otherID  = UUID()

        try await actor.applyInbound(
            makeUpsert(id: targetID, note: "target", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)
        try await actor.applyInbound(
            makeUpsert(id: otherID, note: "other", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)

        // Enqueue for OTHER row.
        try await enqueueSkewEntry(id: otherID, note: "other-skew", hlcTime: 800, storage: storage)
        try await enqueueParkedOutbox(rowKey: otherID, hlcTime: 600, storage: storage)

        // Apply tombstone for TARGET only.
        try await actor.applyInbound(
            makeTombstone(id: targetID, hlcTime: 1000),
            syncedTable: lwwTable, storage: storage)

        let otherSkew = try await fedSkewCount(rowKey: otherID, storage: storage)
        let otherParked = try await parkedOutboxCount(rowKey: otherID, storage: storage)
        #expect(otherSkew == 1,
                "Federation: tombstone must not purge skew entry for different rowKey")
        #expect(otherParked == 1,
                "Federation: tombstone must not purge parked outbox entry for different rowKey")
    }

    // MARK: - Case 5: fieldLevelLWW tombstone purges older skew + parked outbox

    @Test("Federation fieldLevelLWW tombstone purges older skew + parked outbox")
    func fedFieldLevelLWWTombstonePurges() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // Seed with column HLCs at T=500.
        try await actor.applyInbound(
            makeUpsertFLWW(id: rowID, note: "row", hlcTime: 500),
            syncedTable: flwwTable, storage: storage)

        try await enqueueSkewEntry(id: rowID, note: "flww-skew", hlcTime: 800, storage: storage)
        try await enqueueParkedOutbox(rowKey: rowID, hlcTime: 600, storage: storage)

        let beforeSkew = try await fedSkewCount(rowKey: rowID, storage: storage)
        let beforeParked = try await parkedOutboxCount(rowKey: rowID, storage: storage)
        #expect(beforeSkew == 1, "skew entry must exist before fieldLevelLWW tombstone apply")
        #expect(beforeParked == 1, "parked outbox entry must exist before fieldLevelLWW tombstone apply")

        // Tombstone at T=1000 beats all column HLCs (T=500).
        // Build a SyncRecord tombstone — Federation path uses SyncRecord.syncDeleted = true
        // OR event == .delete; both route isTombstone = true.
        let tombstone = SyncRecord(
            table: "items", event: .delete, rowKey: rowID,
            values: nil,
            hlc: PackedHLC(HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)),
            schemaVersion: 1, kitID: "TestKit",
            syncDeleted: true
        )
        try await actor.applyInbound(tombstone, syncedTable: flwwTable, storage: storage)

        let afterSkew = try await fedSkewCount(rowKey: rowID, storage: storage)
        let afterParked = try await parkedOutboxCount(rowKey: rowID, storage: storage)
        #expect(afterSkew == 0,
                "Federation fieldLevelLWW: older skew entry must be purged by tombstone (P5-M1b)")
        #expect(afterParked == 0,
                "Federation fieldLevelLWW: parked outbox entry must be purged by tombstone (P5-M1b)")
    }
}

