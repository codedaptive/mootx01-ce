// CKRecordMappingTests.swift
//
// Peer coverage for Sources/ConvergenceKitCloudKit/CKRecordMapping.swift
// (CKRecordMapping, DecodedRecord, SyncMeta). The deterministic reference path:
// recordType formatting, recordID, and an in-memory CKRecord
// encode→decode round-trip. No live iCloud container or network — the
// CKRecord objects are constructed and read entirely in process, the
// same way the existing CloudKit stub test instantiates CloudKit types.
//
// Note: CKRecordMapping.decode() reads CKRecord
// values back as NS-bridged objects, so integers decode as `.int`, not
// `.bitmap` — the `.bitmap` discriminator is not carried on the wire.
// The round-trip asserts `.int`, matching that documented behavior.
//
// LWW tests use @testable import to reach CloudKitStateActor.applyInbound
// directly, exercising the HLC durability fix without a live CloudKit stack.

import Testing
import Foundation
import CloudKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import ConvergenceKit
@testable import ConvergenceKitCloudKit

@Suite("CKRecord mapping")
struct CKRecordMappingTests {

    @Test("recordType is kitID + underscore + table name")
    func recordTypeFormat() {
        #expect(CKRecordMapping.recordType(kitID: "MyKit", table: "drawers") == "MyKit_drawers")
    }

    @Test("recordID carries the row key as its record name")
    func recordIDUsesRowKey() {
        let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
        let rowKey = UUID()
        let id = CKRecordMapping.recordID(rowKey: rowKey, zone: zoneID)
        #expect(id.recordName == rowKey.uuidString)
    }

    @Test("a record encodes and decodes back with metadata and values intact")
    func recordRoundtrip() throws {
        let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
        let rowKey = UUID()
        let hlc = HLC(physicalTime: 1000, logicalCount: 5, nodeID: 3)
        let values: [String: TypedValue] = [
            "note": .text("hello"),
            "count": .int(42)
        ]

        let record = try CKRecordMapping.record(
            from: values,
            table: "items",
            rowKey: rowKey,
            hlc: hlc,
            schemaVersion: 2,
            kitID: "MyKit",
            zone: zoneID
        )
        #expect(record.recordType == "MyKit_items")

        let decoded = try CKRecordMapping.decode(record)
        #expect(decoded.table == "items")
        #expect(decoded.rowKey == rowKey)
        #expect(decoded.kitID == "MyKit")
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.values["note"] == .text("hello"))
        #expect(decoded.values["count"] == .int(42))

        // HLC survives the packed Int64 transit (48/12/4 bit layout).
        #expect(decoded.hlc.physicalTime == 1000)
        #expect(decoded.hlc.logicalCount == 5)
        #expect(decoded.hlc.nodeID == 3)
    }
}

// MARK: - SyncMeta preservation

extension CKRecordMappingTests {

    @Test("decode populates syncMeta and values contains no _sync* keys")
    func syncMetaPreservedThroughDecode() throws {
        let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
        let rowKey = UUID()
        let hlc = HLC(physicalTime: 9000, logicalCount: 7, nodeID: 2)
        let record = try CKRecordMapping.record(
            from: ["x": .text("y")],
            table: "items",
            rowKey: rowKey,
            hlc: hlc,
            schemaVersion: 3,
            kitID: "K",
            zone: zoneID
        )
        let decoded = try CKRecordMapping.decode(record)

        // syncMeta carries all three fields correctly.
        #expect(decoded.syncMeta.hlc.physicalTime == 9000)
        #expect(decoded.syncMeta.hlc.logicalCount == 7)
        #expect(decoded.syncMeta.hlc.nodeID == 2)
        #expect(decoded.syncMeta.schemaVersion == 3)
        #expect(decoded.syncMeta.kitID == "K")

        // values must not leak _sync* keys.
        #expect(decoded.values["_syncHLC"] == nil)
        #expect(decoded.values["_syncSchemaVersion"] == nil)
        #expect(decoded.values["_syncKitID"] == nil)
    }
}

// MARK: - Corrupt remote identity tests

@Suite("Corrupt remote identity rejection")
struct CorruptRemoteIdentityTests {

    // Helper: build a CKRecord whose recordName is not a valid UUID string.
    // CKRecord.ID accepts arbitrary strings so this is reachable from
    // a corrupt or tampered CloudKit row.
    private func makeRecordWithCorruptName(_ name: String) -> CKRecord {
        let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
        let id = CKRecord.ID(recordName: name, zoneID: zoneID)
        let record = CKRecord(recordType: "TestKit_items", recordID: id)
        record["_syncHLC"] = NSNumber(value: Int64(1000))
        record["_syncSchemaVersion"] = NSNumber(value: 1)
        record["_syncKitID"] = "TestKit" as NSString
        record["note"] = "test-value" as NSString
        return record
    }

    @Test("corrupt recordName throws corruptRemoteIdentity, not a fresh UUID")
    func corruptRecordNameThrowsNotFabricates() throws {
        let record = makeRecordWithCorruptName("not-a-uuid-at-all")
        #expect(throws: SyncError.corruptRemoteIdentity(recordName: "not-a-uuid-at-all")) {
            try CKRecordMapping.decode(record)
        }
    }

    @Test("partial UUID string throws corruptRemoteIdentity")
    func partialUUIDStringThrows() throws {
        // A UUID that is truncated mid-string — plausible corruption.
        let partialUUID = "550E8400-E29B-41D4-A716"
        let record = makeRecordWithCorruptName(partialUUID)
        #expect(throws: SyncError.corruptRemoteIdentity(recordName: partialUUID)) {
            try CKRecordMapping.decode(record)
        }
    }

    @Test("valid UUID recordName still decodes correctly after the guard fix")
    func validRecordNameDecodesUnchanged() throws {
        let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
        let rowKey = UUID()
        let hlc = HLC(physicalTime: 500, logicalCount: 1, nodeID: 2)
        let record = try CKRecordMapping.record(
            from: ["note": .text("intact")],
            table: "items",
            rowKey: rowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "TestKit",
            zone: zoneID
        )
        let decoded = try CKRecordMapping.decode(record)
        // The guard must not interfere with the legitimate path.
        #expect(decoded.rowKey == rowKey)
        #expect(decoded.values["note"] == .text("intact"))
    }

    @Test("corruptRemoteIdentity case carries the corrupt recordName string")
    func errorCarriesCorruptRecordName() {
        // Verify the associated value is threaded correctly through the error.
        let name = "garbage-record-name-XYZ"
        let error = SyncError.corruptRemoteIdentity(recordName: name)
        if case .corruptRemoteIdentity(let r) = error {
            #expect(r == name)
        } else {
            Issue.record("wrong error case")
        }
    }
}

// MARK: - LWW durable HLC tests

@Suite("LWW durable HLC persistence")
struct LWWDurableHLCTests {

    func makeLWWStorage() async throws -> any Storage {
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
                    columns: [.uuid("id"), .text("note")],
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

    func makeDecoded(id: UUID, note: String, hlcTime: Int64) -> DecodedRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        return DecodedRecord(
            table: "items",
            rowKey: id,
            values: ["id": .uuid(id), "note": .text(note)],
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: 1, kitID: "TestKit")
        )
    }

    @Test("stale remote write does not overwrite newer local row")
    func staleRemoteDoesNotOverwriteNewerLocalRow() async throws {
        let storage = try await makeLWWStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // First inbound at T=1000 — wins; _syncHLC must be persisted.
        let first = makeDecoded(id: rowID, note: "first-at-T1000", hlcTime: 1000)
        try await engine.applyInbound(first, syncedTable: syncedTable, storage: storage)

        // Second inbound at T=500 — older; must be rejected because the
        // fix persists _syncHLC so the guard at line 359 can fire.
        let stale = makeDecoded(id: rowID, note: "stale-at-T500", hlcTime: 500)
        try await engine.applyInbound(stale, syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1)
        #expect(rows[0]["note"] == .text("first-at-T1000"),
                "stale remote must not overwrite the newer local row")
    }

    @Test("newer remote write overwrites older local row")
    func newerRemoteOverwritesOlderLocalRow() async throws {
        let storage = try await makeLWWStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // First inbound at T=500.
        let old = makeDecoded(id: rowID, note: "old-at-T500", hlcTime: 500)
        try await engine.applyInbound(old, syncedTable: syncedTable, storage: storage)

        // Second inbound at T=1000 — newer; must win.
        let newer = makeDecoded(id: rowID, note: "newer-at-T1000", hlcTime: 1000)
        try await engine.applyInbound(newer, syncedTable: syncedTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1)
        #expect(rows[0]["note"] == .text("newer-at-T1000"),
                "newer remote write must win LWW")
    }

    @Test("LWW comparison fires correctly after restart with persisted HLC")
    func lwwWorksAfterRestartWithPersistedHLC() async throws {
        let storage = try await makeLWWStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Write a row at T=2000 — _syncHLC must be stored durably.
        let first = makeDecoded(id: rowID, note: "local-at-T2000", hlcTime: 2000)
        try await engine.applyInbound(first, syncedTable: syncedTable, storage: storage)

        // Re-query to confirm _syncHLC is present (the fix's core invariant).
        let stored = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(stored.count == 1)
        guard case .hlc(_) = stored[0]["_syncHLC"] ?? .null else {
            Issue.record("_syncHLC not persisted in row after first write — LWW cannot guard on next inbound")
            return
        }

        // Simulate a stale second inbound at T=1500 — must be rejected
        // because the persisted _syncHLC (T=2000) is newer.
        let stale = makeDecoded(id: rowID, note: "stale-at-T1500", hlcTime: 1500)
        try await engine.applyInbound(stale, syncedTable: syncedTable, storage: storage)

        let finalRows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(finalRows.count == 1)
        #expect(finalRows[0]["note"] == .text("local-at-T2000"),
                "persisted HLC must guard against stale second inbound")
    }
}
