// LocalWriteColumnHLCGateTests.swift
//
// Gap 3 fix verification — CloudKit CloudKitStateActor.recordOutbound.
//
// GAP 3 (upstream memory 7F348C7C): `_ck_sync_meta_cols` (ColumnHLCStore, the
// per-column HLC store) was written ONLY by the receive side (ApplyInbound).
// A device's OWN local writes never recorded/bumped the column HLC locally.
// Result: a window where a fresh LOCAL edit is silently clobbered by a
// delayed STALE REMOTE edit — when the stale remote arrives, ApplyInbound's
// `.fieldLevelLWW` per-column comparison finds no local baseline for the
// column this device just wrote (`FieldLWWMerge.merge`:
// `localColumnHLC == nil` → `shouldApply = true`, i.e. "first write wins"),
// so the stale-but-present remote HLC wins unconditionally. No crash needed.
//
// THE FIX: `recordOutbound` already computed a `ColumnHLCMap` (`colMap`) from
// the SAME local-write HLC used to build the outbox entry, for fieldLevelLWW
// tables — but only ever encoded it into the outbox entry's wire payload,
// never persisted it locally. It now ALSO calls `ColumnHLCStore.writeAll`
// with that exact map, committed in the SAME transaction as the outbox
// append (reusing the gap-4 transaction overloads), so the local column-HLC
// baseline and the outbox entry commit or roll back together.
//
// These two tests exercise the REAL local-write path end-to-end: a live
// `CloudKitSyncEngine.enable()` wires the storage observer that calls
// `recordOutbound` asynchronously after a plain (non-sync-tagged) row write —
// exactly how a host app's local edit reaches ConvergenceKit in production.

import Testing
import Foundation
import CloudKit
@testable import ConvergenceKit
@testable import ConvergenceKitCloudKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes

@Suite("Gap 3 — local writes are HLC-gated into ColumnHLCStore (CloudKit)")
struct LocalWriteColumnHLCGateTests {

    // MARK: - Fixture

    static let manifest = SyncManifest(
        kitID: "TestKit",
        schemaVersion: 1,
        zoneIdentifier: "GAP3-CK",
        tables: [
            SyncedTable(
                name: "items",
                direction: .bidirectional,
                primaryKeyColumn: "id",
                conflictPolicy: .fieldLevelLWW
            )
        ]
    )
    static let syncedTable = manifest.tables[0]
    static let zoneID = CKRecordZone.ID(zoneName: manifest.zoneIdentifier, ownerName: CKCurrentUserDefaultName)

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
        return storage
    }

    func makeEngine(storage: any Storage, cloud: CloudZoneFake) async throws -> CloudKitSyncEngine {
        let engine = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)
        try await engine.enable(manifest: Self.manifest, storage: storage)
        return engine
    }

    /// Poll-deadline (no fixed sleeps) — mirrors the pattern used throughout
    /// this test target (TwoEstateFixture.writeLocal, DebouncerTests.pollUntil).
    func pollUntil(
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            await Task.yield()
            if try await condition() { return true }
        }
        return false
    }

    // MARK: - (a) local write records the column HLC

    @Test("a local write records the column HLC in _ck_sync_meta_cols")
    func localWriteRecordsColumnHLC() async throws {
        let storage = try await makeStorage()
        let cloud = CloudZoneFake()
        let engine = try await makeEngine(storage: storage, cloud: cloud)
        let rowID = UUID()

        let before = try await OutboxStore.readBatch(from: storage).count
        // Plain (non-sync-tagged) upsert — this is what a host app's local
        // edit looks like. origin != .syncApply, so the storage observer
        // fires recordOutbound.
        _ = try await storage.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(rowID), "note": .text("local-edit")],
            conflictColumns: ["id"]
        )

        let observed = try await pollUntil {
            try await OutboxStore.readBatch(from: storage).count > before
        }
        #expect(observed, "outbox must reflect the local write (recordOutbound must have run)")

        let columnHLCs = try await ColumnHLCStore.readAll(
            from: storage, sideTable: CKSideSchema.syncMetaColsTable,
            tableName: "items", primaryKey: rowID)
        #expect(!columnHLCs.isEmpty,
                "local write must record a column-HLC baseline in _ck_sync_meta_cols (gap 3 fix)")
        #expect(columnHLCs.entries["note"] != nil, "note column's HLC must be recorded")
        // Keep the engine alive through the poll above (its observer task must
        // stay registered); referenced here so it isn't flagged as unused.
        _ = engine
    }

    // MARK: - (b) money test: local write survives a stale remote edit that arrives afterward

    @Test("money test: local write at HLC_local survives a stale remote edit at HLC_remote < HLC_local")
    func localWriteSurvivesStaleRemoteEdit() async throws {
        let storage = try await makeStorage()
        let cloud = CloudZoneFake()
        let engine = try await makeEngine(storage: storage, cloud: cloud)
        let rowID = UUID()

        // 1. Local write at HLC_local.
        let before = try await OutboxStore.readBatch(from: storage).count
        _ = try await storage.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(rowID), "note": .text("local-fresh")],
            conflictColumns: ["id"]
        )
        let observed = try await pollUntil {
            try await OutboxStore.readBatch(from: storage).count > before
        }
        #expect(observed, "outbox must reflect the local write before the stale remote edit arrives")

        let localColumnHLCs = try await ColumnHLCStore.readAll(
            from: storage, sideTable: CKSideSchema.syncMetaColsTable,
            tableName: "items", primaryKey: rowID)
        let localPackedHLC = try #require(
            localColumnHLCs.entries["note"],
            "local write must have stamped a column HLC for 'note' (gap 3 fix) — without it this test cannot construct a definitely-older remote HLC"
        )
        let localHLC = localPackedHLC.asHLC

        // 2. THEN a stale remote edit at HLC_remote < HLC_local arrives.
        let staleHLC = HLC(
            physicalTime: max(0, localHLC.physicalTime - 1_000),
            logicalCount: 0, nodeID: 999
        )
        #expect(staleHLC < localHLC,
                "test precondition: constructed remote HLC must be strictly older than the local HLC")

        let staleRecord = DecodedRecord(
            table: "items",
            rowKey: rowID,
            values: ["id": .uuid(rowID), "note": .text("STALE-REMOTE-MUST-NOT-WIN")],
            syncMeta: SyncMeta(hlc: staleHLC, schemaVersion: 1, kitID: "TestKit"),
            columnHLCs: ColumnHLCMap.stampAll(keys: ["note"], hlc: PackedHLC(staleHLC))
        )
        try await engine.stateActor.applyInbound(staleRecord, syncedTable: Self.syncedTable, storage: storage)

        // 3. THE MONEY ASSERTION: the local value must survive. Before the gap-3
        // fix, this failed — the stale remote clobbered the local edit because
        // ColumnHLCStore had no entry for "note" (first-write-wins fallback in
        // FieldLWWMerge.merge treated the stale remote as the first-ever write).
        let rows = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rows.first?["note"] == .text("local-fresh"),
                "local write must survive a stale remote edit that arrives afterward (gap 3 money test) — got \(String(describing: rows.first?["note"])), the stale remote value must NOT have applied")
    }
}
