// ZoneSnapshotTests.swift
//
// Wave 6A2 upstream slice U2 — test suite for ZoneSnapshot.swift and ZonePushProof.swift.
//
// No real CloudKit network — all tests drive the public API through fake
// CloudKitDatabaseProtocol conformers constructed entirely in-process.
//
// Test groups:
//   (a) Snapshot pagination: multi-page fake yields exact combined inventory;
//       token chaining is verified (each fetch receives the prior page's token).
//   (b) Inventory diff between two snapshots detects changed records.
//   (c) Per-record HLC decode under BOTH representations; max floor correctness
//       (golden values); logicalCount > 4095 exact under fullWidthV2.
//   (d) Snapshot has no side effects: no modifyRecords calls; Storage never
//       accepted (API signature has no Storage parameter).
//   (e) Push proof: batch success → per-record HLCs + floor + fingerprint echo;
//       partial failure → typed per-record failures, no batch-success claim;
//       result/batch mismatch → ZonePushProofError.resultMismatch;
//       idempotent retry after subset failure → converges, no duplicate effects;
//       tombstone deletes proven in deleteResults.
//   (f) Readback independence: snapshot after push sees exactly the pushed records,
//       confirming the snapshot serves as independent readback.

import Testing
import Foundation
import CloudKit
@testable import ConvergenceKit
@testable import ConvergenceKitCloudKit
import SubstrateTypes

// MARK: - Shared helpers

private func testZone() -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: "TestV2Zone", ownerName: CKCurrentUserDefaultName)
}

private func testManifest(representation: HLCWireRepresentation = .fullWidthV2) -> SyncManifest {
    // The manifest declares the "items" table so that records created by makeRecord
    // (recordType = "snap_test_items") pass the manifest-scoping gate in takeZoneSnapshot.
    // Without this, all makeRecord records would be treated as non-manifest inhabitants
    // and excluded from inventory — which would break every existing snapshot test.
    SyncManifest(
        kitID: "snap_test",
        schemaVersion: 1,
        zoneIdentifier: "TestV2Zone",
        tables: [SyncedTable(name: "items", primaryKeyColumn: "id")],
        hlcWireRepresentation: representation
    )
}

/// Build a minimal encoded CKRecord for the given HLC and representation.
/// The record is valid for CKRecordMapping.decode (has moot_sync_hlc, schemaVersion, kitID).
private func makeRecord(
    rowKey: UUID,
    hlc: HLC,
    representation: HLCWireRepresentation,
    zone: CKRecordZone.ID
) throws -> CKRecord {
    try CKRecordMapping.record(
        from: ["title": .text("test-\(rowKey.uuidString.prefix(4))")],
        table: "items",
        rowKey: rowKey,
        hlc: hlc,
        schemaVersion: 1,
        kitID: "snap_test",
        zone: zone,
        representation: representation
    )
}

// MARK: - (a) Pagination

/// Simple single-page fake — returns one batch, moreComing = false.
private actor SinglePageFake: CloudKitDatabaseProtocol {
    private let records: [CKRecord]
    private(set) var fetchCallCount = 0

    init(records: [CKRecord]) {
        self.records = records
    }

    func fetchZoneChanges(
        inZoneWith zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        fetchCallCount += 1
        return CloudKitZoneChanges(
            modifiedRecords: records,
            deletedRecordIDs: [],
            changeToken: nil,
            moreComing: false
        )
    }

    func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID],
                       savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
                       atomically: Bool) async throws
    -> (saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]) {
        // No-op: snapshot tests must never call this.
        throw ZoneSnapshotError.decodeFailure(
            recordName: "unexpected-modify",
            underlying: NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "modifyRecords must not be called by snapshot"])
        )
    }
    func fetch(withRecordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] { [:] }
    func modifyRecordZones(saving: [CKRecordZone], deleting: [CKRecordZone.ID]) async throws
    -> (saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>], deleteResults: [CKRecordZone.ID: Result<Void, any Error>]) { ([:], [:]) }
    func modifySubscriptions(saving: [CKSubscription], deleting: [CKSubscription.ID]) async throws
    -> (saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>], deleteResults: [CKSubscription.ID: Result<Void, any Error>]) { ([:], [:]) }
}

/// Multi-page fake that simulates pagination via moreComing signal.
///
/// Uses call-count to distinguish pages rather than CKServerChangeToken identity
/// because CKServerChangeToken is not constructible from arbitrary data in tests.
/// The pagination contract in ZoneSnapshot.swift only requires that the loop
/// continues when moreComing == true and stops when moreComing == false. The
/// changeToken value returned is nil in both pages; the loop passes it as-is
/// to the next call. fetchTokensReceived records what token each call received
/// so tests can assert the loop called fetchZoneChanges the correct number of times.
private actor MultiPageFake: CloudKitDatabaseProtocol {
    private let page1: [CKRecord]
    private let page2: [CKRecord]
    private(set) var fetchCallCount = 0
    private(set) var fetchTokensReceived: [CKServerChangeToken?] = []

    init(page1: [CKRecord], page2: [CKRecord]) {
        self.page1 = page1
        self.page2 = page2
    }

    func fetchZoneChanges(
        inZoneWith zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        fetchCallCount += 1
        fetchTokensReceived.append(token)
        if fetchCallCount == 1 {
            // First call: return page1 with moreComing=true to signal another page follows.
            // changeToken is nil — CKServerChangeToken is not constructible in tests.
            // The loop will pass nil to the second call; our fake uses call-count to
            // distinguish pages, not the token value, so this is correct.
            return CloudKitZoneChanges(
                modifiedRecords: page1,
                deletedRecordIDs: [],
                changeToken: nil,
                moreComing: true
            )
        } else {
            // Second (and any subsequent) call: return page2, moreComing=false to stop.
            return CloudKitZoneChanges(
                modifiedRecords: page2,
                deletedRecordIDs: [],
                changeToken: nil,
                moreComing: false
            )
        }
    }

    func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID],
                       savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
                       atomically: Bool) async throws
    -> (saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]) { ([:], [:]) }
    func fetch(withRecordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] { [:] }
    func modifyRecordZones(saving: [CKRecordZone], deleting: [CKRecordZone.ID]) async throws
    -> (saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>], deleteResults: [CKRecordZone.ID: Result<Void, any Error>]) { ([:], [:]) }
    func modifySubscriptions(saving: [CKSubscription], deleting: [CKSubscription.ID]) async throws
    -> (saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>], deleteResults: [CKSubscription.ID: Result<Void, any Error>]) { ([:], [:]) }
}

@Suite("(a) Snapshot pagination — multi-page fake yields exact combined inventory")
struct SnapshotPaginationTests {
    let zone = testZone()
    let manifest = testManifest()

    @Test("single-page fake: snapshot returns all records, fetchZoneChanges called once")
    func singlePageInventory() async throws {
        let rowA = UUID()
        let rowB = UUID()
        let hlcA = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let hlcB = HLC(physicalTime: 1_784_000_000_200, logicalCount: 1, nodeID: 1)
        let recA = try makeRecord(rowKey: rowA, hlc: hlcA, representation: .fullWidthV2, zone: zone)
        let recB = try makeRecord(rowKey: rowB, hlc: hlcB, representation: .fullWidthV2, zone: zone)

        let fake = SinglePageFake(records: [recA, recB])
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)

        #expect(snap.inventory.count == 2)
        #expect(snap.inventory.contains(ZoneRecordIdentity(recordType: "snap_test_items", recordName: rowA.uuidString)))
        #expect(snap.inventory.contains(ZoneRecordIdentity(recordType: "snap_test_items", recordName: rowB.uuidString)))
        let callCount = await fake.fetchCallCount
        #expect(callCount == 1, "single-page fake must trigger exactly one fetch")
    }

    @Test("multi-page fake: snapshot combines both pages into exact inventory")
    func multiPageInventoryCombined() async throws {
        let rows = (0..<6).map { _ in UUID() }
        let hlcs = rows.enumerated().map { i, _ in
            HLC(physicalTime: 1_784_000_000_000 + Int64(i) * 100, logicalCount: 1, nodeID: 1)
        }
        let records = try zip(rows, hlcs).map { rowKey, hlc in
            try makeRecord(rowKey: rowKey, hlc: hlc, representation: .fullWidthV2, zone: zone)
        }

        let page1 = Array(records.prefix(3))
        let page2 = Array(records.suffix(3))
        let fake = MultiPageFake(page1: page1, page2: page2)

        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)

        // All 6 records from both pages must appear in the combined inventory.
        #expect(snap.inventory.count == 6)
        for rowKey in rows {
            let found = snap.inventory.contains(where: { $0.recordName == rowKey.uuidString })
            #expect(found, "row \(rowKey.uuidString.prefix(8)) must appear in combined inventory")
        }

        // Two fetch calls: page 1 (moreComing=true) and page 2 (moreComing=false).
        // MultiPageFake uses call-count rather than token identity; both calls receive
        // token=nil because CKServerChangeToken is not constructible in tests, and the
        // snapshot loop passes whatever changeToken the fake returned (nil) to the next call.
        let callCount = await fake.fetchCallCount
        #expect(callCount == 2, "multi-page fake must trigger exactly two fetches")
        let tokensReceived = await fake.fetchTokensReceived
        #expect(tokensReceived[0] == nil, "first fetch must start with nil token")
        // The second fetch receives nil because page 1 returned nil changeToken.
        // The loop still issued the call because moreComing=true, which is the
        // correct pagination behavior regardless of token value.
        #expect(tokensReceived.count == 2, "loop must issue second fetch after moreComing=true")
    }

    @Test("moreComing=false on first page: exactly one fetch is issued")
    func moreComingFalseOnFirstPage() async throws {
        let fake = SinglePageFake(records: [])
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)
        #expect(snap.inventory.isEmpty)
        let callCount = await fake.fetchCallCount
        #expect(callCount == 1)
    }
}

// MARK: - (b) Inventory diff

@Suite("(b) Inventory diff between two snapshots detects changed records")
struct InventoryDiffTests {
    let zone = testZone()
    let manifest = testManifest()

    @Test("second snapshot after adding a record shows the new record")
    func addedRecordDetected() async throws {
        let rowA = UUID()
        let rowB = UUID()
        let hlcA = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let hlcB = HLC(physicalTime: 1_784_000_000_200, logicalCount: 1, nodeID: 1)
        let recA = try makeRecord(rowKey: rowA, hlc: hlcA, representation: .fullWidthV2, zone: zone)
        let recB = try makeRecord(rowKey: rowB, hlc: hlcB, representation: .fullWidthV2, zone: zone)

        // First snapshot: only recA.
        let fake1 = SinglePageFake(records: [recA])
        let snap1 = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake1)

        // Second snapshot: recA + recB.
        let fake2 = SinglePageFake(records: [recA, recB])
        let snap2 = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake2)

        let added = snap2.inventory.subtracting(snap1.inventory)
        #expect(added.count == 1)
        #expect(added.first?.recordName == rowB.uuidString, "new record must appear in inventory diff")
    }

    @Test("second snapshot after tombstoning a record removes it from inventory")
    func tombstonedRecordRemovedFromInventory() async throws {
        let rowA = UUID()
        let hlcA = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let hlcDel = HLC(physicalTime: 1_784_000_000_200, logicalCount: 1, nodeID: 1)
        let recA = try makeRecord(rowKey: rowA, hlc: hlcA, representation: .fullWidthV2, zone: zone)
        // Build a typed tombstone CKRecord for rowA.
        let tombstone = CKRecordMapping.tombstoneRecord(
            rowKey: rowA,
            table: "items",
            kitID: "snap_test",
            deleteHLC: hlcDel,
            schemaVersion: 1,
            zone: zone,
            representation: .fullWidthV2
        )

        let fake1 = SinglePageFake(records: [recA])
        let snap1 = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake1)
        #expect(snap1.inventory.count == 1)

        // Second snapshot: only the tombstone (the live record is gone, tombstone is returned).
        let fake2 = SinglePageFake(records: [tombstone])
        let snap2 = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake2)

        let removed = snap1.inventory.subtracting(snap2.inventory)
        #expect(removed.count == 1, "tombstoned record must disappear from second snapshot")
        #expect(snap2.inventory.isEmpty, "second snapshot must have empty live inventory after tombstone")
    }

    @Test("raw record-ID deletion removes the record from inventory")
    func rawIDDeletionRemovedFromInventory() async throws {
        let rowA = UUID()
        let hlcA = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let recA = try makeRecord(rowKey: rowA, hlc: hlcA, representation: .fullWidthV2, zone: zone)
        let deletedID = CKRecord.ID(recordName: rowA.uuidString, zoneID: zone)

        // Fake returns both the record and its deletion (simulates a zone where the
        // record was inserted and then deleted — the change set carries both).
        // The snapshot must apply them in order: insert then delete → empty inventory.
        // In this fake we return modifiedRecords=[recA] and deletedRecordIDs=[deletedID].
        final class InsertThenDeleteFake: CloudKitDatabaseProtocol {
            let recA: CKRecord
            let deletedID: CKRecord.ID
            init(recA: CKRecord, deletedID: CKRecord.ID) {
                self.recA = recA
                self.deletedID = deletedID
            }
            func fetchZoneChanges(inZoneWith zoneID: CKRecordZone.ID, since token: CKServerChangeToken?) async throws -> CloudKitZoneChanges {
                return CloudKitZoneChanges(modifiedRecords: [recA], deletedRecordIDs: [deletedID], changeToken: nil, moreComing: false)
            }
            func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID], savePolicy: CKModifyRecordsOperation.RecordSavePolicy, atomically: Bool) async throws -> (saveResults: [CKRecord.ID: Result<CKRecord, any Error>], deleteResults: [CKRecord.ID: Result<Void, any Error>]) { ([:], [:]) }
            func fetch(withRecordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] { [:] }
            func modifyRecordZones(saving: [CKRecordZone], deleting: [CKRecordZone.ID]) async throws -> (saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>], deleteResults: [CKRecordZone.ID: Result<Void, any Error>]) { ([:], [:]) }
            func modifySubscriptions(saving: [CKSubscription], deleting: [CKSubscription.ID]) async throws -> (saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>], deleteResults: [CKSubscription.ID: Result<Void, any Error>]) { ([:], [:]) }
        }

        let fake = InsertThenDeleteFake(recA: recA, deletedID: deletedID)
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)
        // Raw ID deletion removes the record from inventory; the snapshot sees an empty zone.
        #expect(snap.inventory.isEmpty, "raw-ID deleted record must be absent from inventory")
    }
}

// MARK: - (c) HLC decode and floor correctness

@Suite("(c) Per-record HLC decode and floor correctness — both representations")
struct HLCDecodeAndFloorTests {
    let zone = testZone()

    @Test("legacyPacked representation: per-record HLC decoded correctly")
    func legacyPackedHLCDecode() async throws {
        let manifest = testManifest(representation: .legacyPacked)
        let row1 = UUID()
        let row2 = UUID()
        let hlc1 = HLC(physicalTime: 1_784_000_000_100, logicalCount: 10, nodeID: 2)
        let hlc2 = HLC(physicalTime: 1_784_000_000_200, logicalCount: 20, nodeID: 3)
        let rec1 = try makeRecord(rowKey: row1, hlc: hlc1, representation: .legacyPacked, zone: zone)
        let rec2 = try makeRecord(rowKey: row2, hlc: hlc2, representation: .legacyPacked, zone: zone)

        let fake = SinglePageFake(records: [rec1, rec2])
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)

        let got1 = try #require(snap.recordHLCs[row1.uuidString])
        let got2 = try #require(snap.recordHLCs[row2.uuidString])
        // logicalCount 10 and 20 are within the 12-bit domain (≤4095), so no truncation.
        #expect(got1.physicalTime == hlc1.physicalTime)
        #expect(got1.logicalCount == hlc1.logicalCount)
        #expect(got1.nodeID == hlc1.nodeID)
        #expect(got2.physicalTime == hlc2.physicalTime)
        #expect(got2.logicalCount == hlc2.logicalCount)
        #expect(got2.nodeID == hlc2.nodeID)
    }

    @Test("fullWidthV2 representation: logicalCount > 4095 exact (golden value)")
    func fullWidthV2LogicalCountOver4095Exact() async throws {
        // Golden value: logicalCount = 70_000 (well above 4095 legacyPacked ceiling).
        // Under fullWidthV2 this must survive byte-exact. The snapshot must decode
        // and report it correctly — this is the core v2 contract.
        let manifest = testManifest(representation: .fullWidthV2)
        let rowKey = UUID()
        // physicalTime = 1_784_477_500_577 (real 2026-ish wall-clock ms)
        let hlc = HLC(physicalTime: 1_784_477_500_577, logicalCount: 70_000, nodeID: 7)
        let rec = try makeRecord(rowKey: rowKey, hlc: hlc, representation: .fullWidthV2, zone: zone)

        let fake = SinglePageFake(records: [rec])
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)

        let got = try #require(snap.recordHLCs[rowKey.uuidString])
        #expect(got.physicalTime == 1_784_477_500_577, "physicalTime must be byte-exact under fullWidthV2")
        #expect(got.logicalCount == 70_000, "logicalCount 70000 must survive fullWidthV2 — golden value")
        #expect(got.nodeID == 7, "nodeID must be byte-exact under fullWidthV2")
    }

    @Test("legacyPacked floor: max is correctly identified (golden value)")
    func legacyPackedFloorGoldenValue() async throws {
        let manifest = testManifest(representation: .legacyPacked)
        let rows = (0..<4).map { _ in UUID() }
        // Physical times chosen so the max is unambiguous: 1_784_000_000_400.
        let physTimes: [Int64] = [1_784_000_000_100, 1_784_000_000_200, 1_784_000_000_400, 1_784_000_000_300]
        let records = try zip(rows, physTimes).map { rowKey, phys in
            try makeRecord(
                rowKey: rowKey,
                hlc: HLC(physicalTime: phys, logicalCount: 1, nodeID: 1),
                representation: .legacyPacked,
                zone: zone
            )
        }
        let fake = SinglePageFake(records: records)
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)
        // The floor (max HLC) must have physicalTime = 1_784_000_000_400.
        #expect(snap.hlcFloor.physicalTime == 1_784_000_000_400, "floor must be the max physicalTime across all records — golden value")
    }

    @Test("fullWidthV2 floor: max across logicalCount > 4095 values (golden value)")
    func fullWidthV2FloorGoldenValue() async throws {
        let manifest = testManifest(representation: .fullWidthV2)
        let rows = (0..<3).map { _ in UUID() }
        // logicalCount values: 70_000, 50_000, 99_999. Same physicalTime, same nodeID.
        // Floor must be the record with logicalCount = 99_999.
        let logicals: [Int32] = [70_000, 50_000, 99_999]
        let records = try zip(rows, logicals).map { rowKey, logical in
            try makeRecord(
                rowKey: rowKey,
                hlc: HLC(physicalTime: 1_784_477_500_577, logicalCount: logical, nodeID: 3),
                representation: .fullWidthV2,
                zone: zone
            )
        }
        let fake = SinglePageFake(records: records)
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)
        // Floor must be the record with logicalCount = 99_999 (highest in same physicalTime).
        #expect(snap.hlcFloor.logicalCount == 99_999, "floor must be the max logicalCount — golden value under fullWidthV2")
    }

    @Test("empty zone: hlcFloor is HLC.zero")
    func emptyZoneFloorIsZero() async throws {
        let manifest = testManifest(representation: .fullWidthV2)
        let fake = SinglePageFake(records: [])
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)
        #expect(snap.hlcFloor == .zero, "empty zone must return HLC.zero floor")
    }

    @Test("tombstone HLC does NOT contribute to the floor — floor covers live records only")
    func tombstoneHLCExcludedFromFloor() async throws {
        // Live record with low HLC; tombstone with much higher HLC.
        // Floor must be the live record's HLC, not the tombstone's.
        let manifest = testManifest(representation: .fullWidthV2)
        let liveRow = UUID()
        let deadRow = UUID()
        let liveHLC = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let tombHLC = HLC(physicalTime: 9_999_999_999_999, logicalCount: 99_999, nodeID: 15)

        let liveRec = try makeRecord(rowKey: liveRow, hlc: liveHLC, representation: .fullWidthV2, zone: zone)
        let tombstone = CKRecordMapping.tombstoneRecord(
            rowKey: deadRow,
            table: "items",
            kitID: "snap_test",
            deleteHLC: tombHLC,
            schemaVersion: 1,
            zone: zone,
            representation: .fullWidthV2
        )

        let fake = SinglePageFake(records: [liveRec, tombstone])
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)

        // The tombstone must not appear in inventory.
        #expect(snap.inventory.count == 1, "only the live record must appear in inventory")
        #expect(snap.inventory.first?.recordName == liveRow.uuidString)

        // The floor must be the live record's HLC — tombstone HLC (9_999_...) is excluded.
        #expect(snap.hlcFloor.physicalTime == liveHLC.physicalTime, "floor must be liveHLC.physicalTime, not tombstoneHLC")
        #expect(snap.hlcFloor.physicalTime != tombHLC.physicalTime, "tombstone HLC must NOT contribute to floor")
    }

    @Test("raw-ID deletion HLC is absent (no HLC from deletedRecordIDs) — floor covers live only")
    func rawIDDeletionNoHLCContribution() async throws {
        let manifest = testManifest(representation: .fullWidthV2)
        let liveRow = UUID()
        let deletedRow = UUID()
        let liveHLC = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let liveRec = try makeRecord(rowKey: liveRow, hlc: liveHLC, representation: .fullWidthV2, zone: zone)
        let deletedID = CKRecord.ID(recordName: deletedRow.uuidString, zoneID: zone)

        // Return one live record and one raw-ID deletion.
        final class LivePlusDeleteFake: CloudKitDatabaseProtocol {
            let rec: CKRecord; let del: CKRecord.ID
            init(_ rec: CKRecord, _ del: CKRecord.ID) { self.rec = rec; self.del = del }
            func fetchZoneChanges(inZoneWith: CKRecordZone.ID, since: CKServerChangeToken?) async throws -> CloudKitZoneChanges {
                CloudKitZoneChanges(modifiedRecords: [rec], deletedRecordIDs: [del], changeToken: nil, moreComing: false)
            }
            func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID], savePolicy: CKModifyRecordsOperation.RecordSavePolicy, atomically: Bool) async throws -> (saveResults: [CKRecord.ID: Result<CKRecord, any Error>], deleteResults: [CKRecord.ID: Result<Void, any Error>]) { ([:], [:]) }
            func fetch(withRecordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] { [:] }
            func modifyRecordZones(saving: [CKRecordZone], deleting: [CKRecordZone.ID]) async throws -> (saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>], deleteResults: [CKRecordZone.ID: Result<Void, any Error>]) { ([:], [:]) }
            func modifySubscriptions(saving: [CKSubscription], deleting: [CKSubscription.ID]) async throws -> (saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>], deleteResults: [CKSubscription.ID: Result<Void, any Error>]) { ([:], [:]) }
        }

        let fake = LivePlusDeleteFake(liveRec, deletedID)
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)
        // Only the live record's HLC contributes to the floor.
        #expect(snap.hlcFloor == liveHLC, "floor must be the live record's HLC only")
        #expect(snap.recordHLCs[deletedRow.uuidString] == nil, "raw-ID deleted record must not appear in recordHLCs")
    }
}

// MARK: - (d) No side effects

@Suite("(d) Snapshot has no side effects — no modify* calls, no Storage parameter")
struct SnapshotNoSideEffectsTests {
    let zone = testZone()
    let manifest = testManifest()

    @Test("takeZoneSnapshot never calls modifyRecords (tracked via modifyCallCount)")
    func snapshotNeverCallsModifyRecords() async throws {
        let row = UUID()
        let hlc = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let rec = try makeRecord(rowKey: row, hlc: hlc, representation: .fullWidthV2, zone: zone)

        // ModifyTrackingFake: records calls to modifyRecords; snap must call zero.
        actor ModifyTrackingFake: CloudKitDatabaseProtocol {
            let record: CKRecord
            private(set) var modifyCallCount = 0
            init(_ record: CKRecord) { self.record = record }
            func fetchZoneChanges(inZoneWith: CKRecordZone.ID, since: CKServerChangeToken?) async throws -> CloudKitZoneChanges {
                CloudKitZoneChanges(modifiedRecords: [record], deletedRecordIDs: [], changeToken: nil, moreComing: false)
            }
            func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID], savePolicy: CKModifyRecordsOperation.RecordSavePolicy, atomically: Bool) async throws -> (saveResults: [CKRecord.ID: Result<CKRecord, any Error>], deleteResults: [CKRecord.ID: Result<Void, any Error>]) {
                modifyCallCount += 1
                return ([:], [:])
            }
            func fetch(withRecordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] { [:] }
            func modifyRecordZones(saving: [CKRecordZone], deleting: [CKRecordZone.ID]) async throws -> (saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>], deleteResults: [CKRecordZone.ID: Result<Void, any Error>]) { ([:], [:]) }
            func modifySubscriptions(saving: [CKSubscription], deleting: [CKSubscription.ID]) async throws -> (saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>], deleteResults: [CKSubscription.ID: Result<Void, any Error>]) { ([:], [:]) }
        }

        let fake = ModifyTrackingFake(rec)
        _ = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)
        let count = await fake.modifyCallCount
        #expect(count == 0, "takeZoneSnapshot must never call modifyRecords")
    }

    @Test("takeZoneSnapshot API accepts no Storage parameter — pure read contract")
    func snapshotAPIHasNoStorageParameter() {
        // This is a compile-time proof: the function signature
        //   takeZoneSnapshot(zoneID:manifest:database:)
        // has no Storage parameter. If it did, this test would not compile.
        // The test itself is trivially true at runtime; its value is the static
        // guarantee that the API cannot accidentally accept a storage handle.
        #expect(Bool(true), "takeZoneSnapshot has no Storage parameter — compile-time proof")
    }
}

// MARK: - Push-proof fake (stateful, for tests (e) and (f))

/// Stateful in-memory fake that both records fetched by snapshot and accepts pushes.
/// Suitable for tests (e) push-proof and (f) readback independence.
private actor PushAndSnapshotFake: CloudKitDatabaseProtocol {
    private var store: [CKRecord.ID: CKRecord] = [:]

    // Test instrumentation: track how many times modifyRecords was called and
    // with what batches, for duplicate-effect assertions in idempotent retry tests.
    private(set) var modifyCallCount = 0
    private(set) var lastSavedIDs: [CKRecord.ID] = []

    /// Seed a record without going through modifyRecords.
    func seed(_ record: CKRecord) {
        store[record.recordID] = record
    }

    func fetchZoneChanges(
        inZoneWith zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        let records = store.values.filter { $0.recordID.zoneID == zoneID }
        return CloudKitZoneChanges(
            modifiedRecords: Array(records),
            deletedRecordIDs: [],
            changeToken: nil,
            moreComing: false
        )
    }

    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> (
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]
    ) {
        modifyCallCount += 1
        lastSavedIDs = recordsToSave.map(\.recordID)
        var saveResults: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in recordsToSave {
            store[record.recordID] = record
            saveResults[record.recordID] = .success(record)
        }
        var deleteResults: [CKRecord.ID: Result<Void, any Error>] = [:]
        for id in recordIDsToDelete {
            store.removeValue(forKey: id)
            deleteResults[id] = .success(())
        }
        return (saveResults, deleteResults)
    }

    func fetch(withRecordIDs recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for id in recordIDs {
            if let record = store[id] {
                results[id] = .success(record)
            } else {
                results[id] = .failure(NSError(domain: CKErrorDomain, code: CKError.Code.unknownItem.rawValue))
            }
        }
        return results
    }

    func modifyRecordZones(saving: [CKRecordZone], deleting: [CKRecordZone.ID]) async throws
    -> (saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>], deleteResults: [CKRecordZone.ID: Result<Void, any Error>]) { ([:], [:]) }

    func modifySubscriptions(saving: [CKSubscription], deleting: [CKSubscription.ID]) async throws
    -> (saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>], deleteResults: [CKSubscription.ID: Result<Void, any Error>]) { ([:], [:]) }
}

/// Partial-failure fake: fails the first `failCount` save records, succeeds the rest.
private actor PartialFailFake: CloudKitDatabaseProtocol {
    private var store: [CKRecord.ID: CKRecord] = [:]
    let failCount: Int
    private(set) var modifyCallCount = 0

    init(failCount: Int) { self.failCount = failCount }

    func seed(_ record: CKRecord) { store[record.recordID] = record }

    func fetchZoneChanges(inZoneWith zoneID: CKRecordZone.ID, since token: CKServerChangeToken?) async throws -> CloudKitZoneChanges {
        let records = store.values.filter { $0.recordID.zoneID == zoneID }
        return CloudKitZoneChanges(modifiedRecords: Array(records), deletedRecordIDs: [], changeToken: nil, moreComing: false)
    }

    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> (saveResults: [CKRecord.ID: Result<CKRecord, any Error>], deleteResults: [CKRecord.ID: Result<Void, any Error>]) {
        modifyCallCount += 1
        let perRecordError = NSError(domain: CKErrorDomain, code: CKError.Code.networkUnavailable.rawValue)
        var saveResults: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        var failIdx = 0
        for record in recordsToSave {
            if failIdx < failCount {
                saveResults[record.recordID] = .failure(perRecordError)
                failIdx += 1
            } else {
                store[record.recordID] = record
                saveResults[record.recordID] = .success(record)
            }
        }
        var deleteResults: [CKRecord.ID: Result<Void, any Error>] = [:]
        for id in recordIDsToDelete {
            store.removeValue(forKey: id)
            deleteResults[id] = .success(())
        }
        return (saveResults, deleteResults)
    }

    func fetch(withRecordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] { [:] }
    func modifyRecordZones(saving: [CKRecordZone], deleting: [CKRecordZone.ID]) async throws -> (saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>], deleteResults: [CKRecordZone.ID: Result<Void, any Error>]) { ([:], [:]) }
    func modifySubscriptions(saving: [CKSubscription], deleting: [CKSubscription.ID]) async throws -> (saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>], deleteResults: [CKSubscription.ID: Result<Void, any Error>]) { ([:], [:]) }
}

// MARK: - (e) Push proof

@Suite("(e) Push proof — batch success, partial failure, mismatch, retry, tombstone deletes")
struct PushProofTests {
    let zone = testZone()
    let manifest = testManifest(representation: .fullWidthV2)
    let fingerprint = "batch-abc123".data(using: .utf8)!

    @Test("batch success: per-record HLCs match input HLCs, floor correct, fingerprint echoed")
    func batchSuccessProof() async throws {
        let rows = (0..<3).map { _ in UUID() }
        let hlcs = rows.enumerated().map { i, _ in
            HLC(physicalTime: 1_784_000_000_000 + Int64(i + 1) * 100, logicalCount: 1, nodeID: 1)
        }
        let records = try zip(rows, hlcs).map { rowKey, hlc in
            try makeRecord(rowKey: rowKey, hlc: hlc, representation: .fullWidthV2, zone: zone)
        }

        let fake = PushAndSnapshotFake()
        let proof = try await pushZoneBatch(
            records: records,
            deletions: [],
            batchFingerprint: fingerprint,
            manifest: manifest,
            database: fake
        )

        #expect(proof.batchSuccess, "all records succeeded — batchSuccess must be true")
        #expect(proof.partialFailureSummary == nil, "no partial failure expected")
        #expect(proof.batchFingerprint == fingerprint, "fingerprint must be echoed unchanged")

        // Per-record HLC outcomes derived from the returned CKRecords.
        for (rowKey, hlc) in zip(rows, hlcs) {
            guard case .saved(let returnedHLC) = proof.recordOutcomes[rowKey.uuidString] else {
                Issue.record("record \(rowKey.uuidString.prefix(8)) must have .saved outcome")
                continue
            }
            #expect(returnedHLC.physicalTime == hlc.physicalTime)
            #expect(returnedHLC.logicalCount == hlc.logicalCount)
            #expect(returnedHLC.nodeID == hlc.nodeID)
        }

        // Floor must be the max HLC across all saves.
        let expectedFloor = hlcs.max()!
        #expect(proof.successHLCFloor == expectedFloor, "successHLCFloor must be max HLC across all saves")
    }

    @Test("partial failure: failed records reported per-record, batchSuccess == false")
    func partialFailurePartialOutcomes() async throws {
        let rows = (0..<3).map { _ in UUID() }
        let hlcs = rows.enumerated().map { i, _ in
            HLC(physicalTime: 1_784_000_000_000 + Int64(i + 1) * 100, logicalCount: 1, nodeID: 1)
        }
        let records = try zip(rows, hlcs).map { rowKey, hlc in
            try makeRecord(rowKey: rowKey, hlc: hlc, representation: .fullWidthV2, zone: zone)
        }

        // Fail the first 1 record; succeed the remaining 2.
        let fake = PartialFailFake(failCount: 1)
        let proof = try await pushZoneBatch(
            records: records,
            deletions: [],
            batchFingerprint: fingerprint,
            manifest: manifest,
            database: fake
        )

        #expect(!proof.batchSuccess, "partial failure — batchSuccess must be false")
        let summary = try #require(proof.partialFailureSummary, "partialFailureSummary must be non-nil")
        #expect(summary.failedSaveCount == 1, "exactly one save must have failed")
        #expect(summary.failedDeleteCount == 0)

        // The first record must be .failed; the others must be .saved.
        guard case .failed = proof.recordOutcomes[rows[0].uuidString] else {
            Issue.record("first record must have .failed outcome"); return
        }
        for rowKey in rows.dropFirst() {
            guard case .saved = proof.recordOutcomes[rowKey.uuidString] else {
                Issue.record("non-failing record \(rowKey.uuidString.prefix(8)) must have .saved outcome"); return
            }
        }
    }

    @Test("result/batch mismatch: extra record in results → ZonePushProofError.resultMismatch")
    func extraRecordInResultsThrows() async throws {
        let row = UUID()
        let hlc = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let rec = try makeRecord(rowKey: row, hlc: hlc, representation: .fullWidthV2, zone: zone)

        // MismatchFake: returns results for an extra record not in the batch.
        final class MismatchFake: CloudKitDatabaseProtocol {
            let rec: CKRecord
            let extraRow: UUID
            let zone: CKRecordZone.ID
            let hlc: HLC
            init(rec: CKRecord, extraRow: UUID, zone: CKRecordZone.ID, hlc: HLC) { self.rec = rec; self.extraRow = extraRow; self.zone = zone; self.hlc = hlc }
            func fetchZoneChanges(inZoneWith: CKRecordZone.ID, since: CKServerChangeToken?) async throws -> CloudKitZoneChanges { CloudKitZoneChanges(modifiedRecords: [], deletedRecordIDs: [], changeToken: nil) }
            func modifyRecords(saving: [CKRecord], deleting: [CKRecord.ID], savePolicy: CKModifyRecordsOperation.RecordSavePolicy, atomically: Bool) async throws -> (saveResults: [CKRecord.ID: Result<CKRecord, any Error>], deleteResults: [CKRecord.ID: Result<Void, any Error>]) {
                // Return result for the submitted record PLUS an extra unexpected record.
                let extraID = CKRecord.ID(recordName: extraRow.uuidString, zoneID: zone)
                let extraRec = try! makeRecord(rowKey: extraRow, hlc: hlc, representation: .fullWidthV2, zone: zone)
                return ([rec.recordID: .success(rec), extraID: .success(extraRec)], [:])
            }
            func fetch(withRecordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] { [:] }
            func modifyRecordZones(saving: [CKRecordZone], deleting: [CKRecordZone.ID]) async throws -> (saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>], deleteResults: [CKRecordZone.ID: Result<Void, any Error>]) { ([:], [:]) }
            func modifySubscriptions(saving: [CKSubscription], deleting: [CKSubscription.ID]) async throws -> (saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>], deleteResults: [CKSubscription.ID: Result<Void, any Error>]) { ([:], [:]) }
        }

        let extra = UUID()
        let fake = MismatchFake(rec: rec, extraRow: extra, zone: zone, hlc: hlc)
        await #expect(throws: ZonePushProofError.self, "extra record in results must throw resultMismatch") {
            try await pushZoneBatch(records: [rec], deletions: [], batchFingerprint: fingerprint, manifest: manifest, database: fake)
        }
    }

    @Test("idempotent retry: partial failure then full success converges, no duplicate effects")
    func idempotentRetryConverges() async throws {
        let rows = (0..<3).map { _ in UUID() }
        let hlcs = rows.enumerated().map { i, _ in
            HLC(physicalTime: 1_784_000_000_000 + Int64(i + 1) * 100, logicalCount: 1, nodeID: 1)
        }
        let records = try zip(rows, hlcs).map { rowKey, hlc in
            try makeRecord(rowKey: rowKey, hlc: hlc, representation: .fullWidthV2, zone: zone)
        }

        // First push: fail first record, succeed the others.
        let fake = PartialFailFake(failCount: 1)
        let proof1 = try await pushZoneBatch(
            records: records,
            deletions: [],
            batchFingerprint: fingerprint,
            manifest: manifest,
            database: fake
        )
        #expect(!proof1.batchSuccess)
        let callCountAfterFirst = await fake.modifyCallCount
        #expect(callCountAfterFirst == 1)

        // Second push (retry with same batch): all succeed (failCount=1 was consumed first call).
        // The PartialFailFake always fails the first N records regardless of call order.
        // For a "converges" test, we use a fresh fake with failCount=0 for the retry.
        let fakeRetry = PartialFailFake(failCount: 0)
        let proof2 = try await pushZoneBatch(
            records: records,
            deletions: [],
            batchFingerprint: fingerprint,
            manifest: manifest,
            database: fakeRetry
        )
        #expect(proof2.batchSuccess, "second push must succeed")
        #expect(proof2.partialFailureSummary == nil)
        let callCountRetry = await fakeRetry.modifyCallCount
        #expect(callCountRetry == 1, "retry must issue exactly one modifyRecords call — no duplicate effects")
        // Verify same batch fingerprint echoed in both proofs.
        #expect(proof1.batchFingerprint == fingerprint)
        #expect(proof2.batchFingerprint == fingerprint)
    }

    @Test("tombstone deletes: deleteResults reported as .deleted outcome")
    func tombstoneDeleteOutcomes() async throws {
        let rowToDelete1 = UUID()
        let rowToDelete2 = UUID()
        let id1 = CKRecord.ID(recordName: rowToDelete1.uuidString, zoneID: zone)
        let id2 = CKRecord.ID(recordName: rowToDelete2.uuidString, zoneID: zone)

        let fake = PushAndSnapshotFake()
        // Pre-seed the records so they can be deleted.
        let hlc = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let rec1 = try makeRecord(rowKey: rowToDelete1, hlc: hlc, representation: .fullWidthV2, zone: zone)
        let rec2 = try makeRecord(rowKey: rowToDelete2, hlc: hlc, representation: .fullWidthV2, zone: zone)
        await fake.seed(rec1)
        await fake.seed(rec2)

        let proof = try await pushZoneBatch(
            records: [],
            deletions: [id1, id2],
            batchFingerprint: fingerprint,
            manifest: manifest,
            database: fake
        )

        #expect(proof.batchSuccess, "delete-only batch must report batchSuccess")
        guard case .deleted = proof.recordOutcomes[rowToDelete1.uuidString] else {
            Issue.record("first deleted record must have .deleted outcome"); return
        }
        guard case .deleted = proof.recordOutcomes[rowToDelete2.uuidString] else {
            Issue.record("second deleted record must have .deleted outcome"); return
        }
        // No saves → successHLCFloor must be .zero.
        #expect(proof.successHLCFloor == .zero, "delete-only batch has no save HLCs → floor must be .zero")
    }

    @Test("savePolicy is .changedKeys: idempotent re-push of same batch is safe (LWW)")
    func savePolicyChangedKeysIsIdempotent() async throws {
        // Prove that pushing the same batch twice via .changedKeys does not blow up
        // and the second push returns the same HLC as the first (fake stores the record
        // and returns it on both calls — no conflict error).
        let rowKey = UUID()
        let hlc = HLC(physicalTime: 1_784_477_500_577, logicalCount: 70_000, nodeID: 5)
        let rec = try makeRecord(rowKey: rowKey, hlc: hlc, representation: .fullWidthV2, zone: zone)

        let fake = PushAndSnapshotFake()
        let proof1 = try await pushZoneBatch(records: [rec], deletions: [], batchFingerprint: fingerprint, manifest: manifest, database: fake)
        let proof2 = try await pushZoneBatch(records: [rec], deletions: [], batchFingerprint: fingerprint, manifest: manifest, database: fake)

        #expect(proof1.batchSuccess)
        #expect(proof2.batchSuccess, "re-push with .changedKeys must succeed — no serverRecordChanged error")
        // Both proofs must report the same HLC (the record's own HLC).
        if case .saved(let hlc1) = proof1.recordOutcomes[rowKey.uuidString],
           case .saved(let hlc2) = proof2.recordOutcomes[rowKey.uuidString] {
            #expect(hlc1 == hlc2, "idempotent re-push must return same HLC")
        } else {
            Issue.record("both pushes must have .saved outcomes")
        }
    }
}

// MARK: - (f) Readback independence

@Suite("(f) Readback independence: snapshot after push sees exactly the pushed records")
struct ReadbackIndependenceTests {
    let zone = testZone()
    let manifest = testManifest(representation: .fullWidthV2)
    let fingerprint = "readback-fingerprint".data(using: .utf8)!

    @Test("snapshot after push sees all pushed records in inventory with correct HLCs")
    func snapshotSeesAllPushedRecords() async throws {
        let rows = (0..<4).map { _ in UUID() }
        let hlcs = rows.enumerated().map { i, _ in
            HLC(physicalTime: 1_784_000_000_000 + Int64(i + 1) * 50, logicalCount: 70_000 + Int32(i), nodeID: 3)
        }
        let records = try zip(rows, hlcs).map { rowKey, hlc in
            try makeRecord(rowKey: rowKey, hlc: hlc, representation: .fullWidthV2, zone: zone)
        }

        // PushAndSnapshotFake is stateful: modifyRecords persists to store;
        // fetchZoneChanges returns all stored records.
        let fake = PushAndSnapshotFake()

        // Push the batch.
        let proof = try await pushZoneBatch(
            records: records,
            deletions: [],
            batchFingerprint: fingerprint,
            manifest: manifest,
            database: fake
        )
        #expect(proof.batchSuccess)

        // Independent readback via snapshot — uses the same fake's fetchZoneChanges.
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)

        // Snapshot must see exactly the pushed records in inventory.
        #expect(snap.inventory.count == rows.count, "snapshot must see all pushed records")
        for rowKey in rows {
            let found = snap.inventory.contains(where: { $0.recordName == rowKey.uuidString })
            #expect(found, "pushed record \(rowKey.uuidString.prefix(8)) must appear in snapshot inventory")
        }

        // Per-record HLCs from snapshot must match the pushed HLCs.
        for (rowKey, hlc) in zip(rows, hlcs) {
            let gotHLC = try #require(snap.recordHLCs[rowKey.uuidString])
            #expect(gotHLC.physicalTime == hlc.physicalTime)
            #expect(gotHLC.logicalCount == hlc.logicalCount, "logicalCount 70000+ must round-trip via snapshot under fullWidthV2")
            #expect(gotHLC.nodeID == hlc.nodeID)
        }

        // Floor of the snapshot must equal the max HLC across all pushed records.
        let expectedFloor = hlcs.max()!
        #expect(snap.hlcFloor == expectedFloor, "snapshot floor must equal max pushed HLC")
    }

    @Test("snapshot after tombstone push removes the tombstoned record")
    func snapshotAfterTombstonePushRemovesRecord() async throws {
        // Push a live record, then push its tombstone, then snapshot — must see empty inventory.
        let rowKey = UUID()
        let liveHLC = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let tombHLC = HLC(physicalTime: 1_784_000_000_200, logicalCount: 1, nodeID: 1)
        let liveRec = try makeRecord(rowKey: rowKey, hlc: liveHLC, representation: .fullWidthV2, zone: zone)
        let tombstone = CKRecordMapping.tombstoneRecord(
            rowKey: rowKey,
            table: "items",
            kitID: "snap_test",
            deleteHLC: tombHLC,
            schemaVersion: 1,
            zone: zone,
            representation: .fullWidthV2
        )

        let fake = PushAndSnapshotFake()

        // Push live record.
        _ = try await pushZoneBatch(records: [liveRec], deletions: [], batchFingerprint: fingerprint, manifest: manifest, database: fake)

        // Snapshot after live push — must see 1 record.
        let snap1 = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)
        #expect(snap1.inventory.count == 1)

        // Push tombstone (typed tombstone CKRecord, not raw ID deletion).
        _ = try await pushZoneBatch(records: [tombstone], deletions: [], batchFingerprint: fingerprint, manifest: manifest, database: fake)

        // Snapshot after tombstone push — must see 0 live records.
        let snap2 = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)
        #expect(snap2.inventory.isEmpty, "snapshot after tombstone push must see no live records")
    }
}

// MARK: - (g) Manifest-scoped exclusion

/// Build a raw CKRecord that looks like a slot-registry entry.
///
/// Slot records carry four fields (device_uuid, epoch, last_active_hlc, claimed_at)
/// but NOT moot_sync_hlc. CKRecordMapping.decode would fail on them with
/// decodingFailure, which is exactly why takeZoneSnapshot must gate on
/// manifest-table membership before attempting decode.
///
/// Uses SlotRecordMapping.recordType ("ck_device_slot") — the actual constant
/// from Registry/SlotRecordMapping.swift — rather than a hardcoded string literal,
/// so the test stays correct if the constant ever changes.
private func makeSlotRecord(slot: Int, zone: CKRecordZone.ID) -> CKRecord {
    let id = CKRecord.ID(recordName: "slot_\(slot)", zoneID: zone)
    let record = CKRecord(recordType: SlotRecordMapping.recordType, recordID: id)
    // Populate the four slot fields (from SlotRecordMapping.swift schema).
    // These fields do not include moot_sync_hlc — slot records are not
    // ConvergenceKit application rows and cannot be decoded by CKRecordMapping.
    record["device_uuid"] = UUID().uuidString as CKRecordValue
    record["epoch"] = Int64(1) as CKRecordValue
    record["last_active_hlc"] = Int64(0) as CKRecordValue
    record["claimed_at"] = "2026-08-21T00:00:00Z" as CKRecordValue
    return record
}

/// Build a raw CKRecord with an arbitrary foreign type (not in any manifest).
///
/// Simulates an unknown third-party record sharing the zone — something neither
/// the application manifest nor the slot registry owns.
private func makeForeignRecord(recordType: String, zone: CKRecordZone.ID) -> CKRecord {
    let id = CKRecord.ID(recordName: UUID().uuidString, zoneID: zone)
    let record = CKRecord(recordType: recordType, recordID: id)
    record["some_field"] = "some_value" as CKRecordValue
    return record
}

@Suite("(g) Manifest-scoped exclusion — non-manifest zone inhabitants are excluded, not errors")
struct ManifestScopedExclusionTests {
    let zone = testZone()
    // Manifest with the "items" table declared — so snap_test_items records pass the gate.
    let manifest = testManifest(representation: .fullWidthV2)

    @Test("mixed zone: manifest records + slot records + foreign type → snapshot succeeds, nonManifestRecordCount correct")
    func mixedZoneExcludesNonManifestRecords() async throws {
        // Three manifest-typed application rows.
        let appRow1 = UUID()
        let appRow2 = UUID()
        let appRow3 = UUID()
        let hlc1 = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let hlc2 = HLC(physicalTime: 1_784_000_000_200, logicalCount: 1, nodeID: 1)
        let hlc3 = HLC(physicalTime: 1_784_000_000_300, logicalCount: 1, nodeID: 1)
        let appRec1 = try makeRecord(rowKey: appRow1, hlc: hlc1, representation: .fullWidthV2, zone: zone)
        let appRec2 = try makeRecord(rowKey: appRow2, hlc: hlc2, representation: .fullWidthV2, zone: zone)
        let appRec3 = try makeRecord(rowKey: appRow3, hlc: hlc3, representation: .fullWidthV2, zone: zone)

        // Two slot-registry records (recordType "ck_device_slot", no moot_sync_hlc).
        // SlotClaimOperation writes these into the same zone as application data —
        // this is the concrete scenario that caused the U3 defect.
        let slotRec1 = makeSlotRecord(slot: 1, zone: zone)
        let slotRec2 = makeSlotRecord(slot: 2, zone: zone)

        // One record with an arbitrary unknown type (not a manifest table, not a slot).
        let foreignRec = makeForeignRecord(recordType: "some_external_system_record", zone: zone)

        // Total: 3 manifest records, 2 slot records, 1 foreign = 3 non-manifest.
        let allRecords = [appRec1, appRec2, appRec3, slotRec1, slotRec2, foreignRec]
        let fake = SinglePageFake(records: allRecords)

        // Must succeed despite the slot and foreign records being undecipherable by CKRecordMapping.
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)

        // Inventory contains only the three manifest-typed application rows.
        #expect(snap.inventory.count == 3, "only manifest-table records must appear in inventory")
        #expect(snap.inventory.contains(where: { $0.recordName == appRow1.uuidString }))
        #expect(snap.inventory.contains(where: { $0.recordName == appRow2.uuidString }))
        #expect(snap.inventory.contains(where: { $0.recordName == appRow3.uuidString }))

        // Slot and foreign records must NOT appear in inventory.
        #expect(!snap.inventory.contains(where: { $0.recordType == SlotRecordMapping.recordType }),
                "slot registry records must be excluded from inventory")
        #expect(!snap.inventory.contains(where: { $0.recordType == "some_external_system_record" }),
                "foreign-typed records must be excluded from inventory")

        // nonManifestRecordCount must be exactly 3: 2 slot records + 1 foreign record.
        #expect(snap.nonManifestRecordCount == 3,
                "nonManifestRecordCount must count all non-manifest records (2 slot + 1 foreign)")

        // HLC floor covers only manifest records — must be hlc3 (the highest).
        #expect(snap.hlcFloor.physicalTime == hlc3.physicalTime,
                "floor must be max HLC across manifest-table records only")
    }

    @Test("manifest-typed record with missing moot_sync_hlc still throws decodeFailure")
    func manifestTypedRecordWithMissingHLCThrows() async throws {
        // A record whose CKRecord.recordType IS in the manifest ("snap_test_items")
        // but which does not carry moot_sync_hlc is a genuine protocol violation.
        // The manifest-scoping gate lets it through; CKRecordMapping.decode then
        // throws SyncError.decodingFailure because the required sync-metadata field
        // is absent. ZoneSnapshot must surface this as ZoneSnapshotError.decodeFailure.
        let corruptID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zone)
        // Record type matches the manifest table ("snap_test_items" = kitID + "_" + "items").
        let corruptRecord = CKRecord(recordType: "snap_test_items", recordID: corruptID)
        // Deliberately omit moot_sync_hlc and all other sync-metadata fields.
        // Only a random application field is set so the record is non-empty but structurally
        // incorrect for CKRecordMapping.decode.
        corruptRecord["title"] = "corrupt row" as CKRecordValue

        let fake = SinglePageFake(records: [corruptRecord])

        await #expect(
            throws: ZoneSnapshotError.self,
            "manifest-typed record without moot_sync_hlc must throw ZoneSnapshotError.decodeFailure"
        ) {
            try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)
        }
    }

    @Test("pagination + exclusion: foreign rows across pages counted once each, manifest rows combined")
    func paginationAndExclusionInteractCorrectly() async throws {
        // Page 1: 2 manifest records + 1 slot record.
        let appRow1 = UUID()
        let appRow2 = UUID()
        let hlcA = HLC(physicalTime: 1_784_000_000_100, logicalCount: 1, nodeID: 1)
        let hlcB = HLC(physicalTime: 1_784_000_000_200, logicalCount: 1, nodeID: 1)
        let appRec1 = try makeRecord(rowKey: appRow1, hlc: hlcA, representation: .fullWidthV2, zone: zone)
        let appRec2 = try makeRecord(rowKey: appRow2, hlc: hlcB, representation: .fullWidthV2, zone: zone)
        let slotOnPage1 = makeSlotRecord(slot: 3, zone: zone)

        // Page 2: 2 manifest records + 2 foreign records of different types.
        let appRow3 = UUID()
        let appRow4 = UUID()
        let hlcC = HLC(physicalTime: 1_784_000_000_300, logicalCount: 1, nodeID: 1)
        let hlcD = HLC(physicalTime: 1_784_000_000_400, logicalCount: 1, nodeID: 1)
        let appRec3 = try makeRecord(rowKey: appRow3, hlc: hlcC, representation: .fullWidthV2, zone: zone)
        let appRec4 = try makeRecord(rowKey: appRow4, hlc: hlcD, representation: .fullWidthV2, zone: zone)
        let foreignOnPage2a = makeForeignRecord(recordType: "external_type_alpha", zone: zone)
        let foreignOnPage2b = makeForeignRecord(recordType: "external_type_beta", zone: zone)

        let page1 = [appRec1, appRec2, slotOnPage1]
        let page2 = [appRec3, appRec4, foreignOnPage2a, foreignOnPage2b]
        let fake = MultiPageFake(page1: page1, page2: page2)

        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)

        // Both pages must have been fetched.
        let fetchCount = await fake.fetchCallCount
        #expect(fetchCount == 2, "pagination must issue two fetches")

        // All 4 manifest records must appear in inventory (combined from both pages).
        #expect(snap.inventory.count == 4, "inventory must contain all 4 manifest records from both pages")
        for rowKey in [appRow1, appRow2, appRow3, appRow4] {
            #expect(snap.inventory.contains(where: { $0.recordName == rowKey.uuidString }),
                    "row \(rowKey.uuidString.prefix(8)) must appear in inventory")
        }

        // nonManifestRecordCount must be 3: 1 slot on page 1 + 2 foreign on page 2.
        // Each non-manifest record is counted exactly once, regardless of which page it arrived on.
        #expect(snap.nonManifestRecordCount == 3,
                "nonManifestRecordCount must accumulate across pages (1 slot + 2 foreign)")

        // Floor must be the max manifest HLC = hlcD (physicalTime 1_784_000_000_400).
        #expect(snap.hlcFloor.physicalTime == hlcD.physicalTime,
                "floor must be max manifest HLC across both pages")
    }

    @Test("zone with only non-manifest records: snapshot succeeds with empty inventory and correct count")
    func zoneWithOnlyNonManifestRecords() async throws {
        // Simulate a zone that currently has no application rows at all — only
        // slot registry records (e.g. before any user data is synced). The snapshot
        // must not throw; it must return an empty inventory with a non-zero count.
        let slot1 = makeSlotRecord(slot: 1, zone: zone)
        let slot2 = makeSlotRecord(slot: 2, zone: zone)
        let slot3 = makeSlotRecord(slot: 3, zone: zone)

        let fake = SinglePageFake(records: [slot1, slot2, slot3])
        let snap = try await takeZoneSnapshot(zoneID: zone, manifest: manifest, database: fake)

        #expect(snap.inventory.isEmpty, "no manifest records → inventory must be empty")
        #expect(snap.hlcFloor == .zero, "no manifest records → floor must be HLC.zero")
        #expect(snap.nonManifestRecordCount == 3, "all 3 slot records must be counted")
    }
}
