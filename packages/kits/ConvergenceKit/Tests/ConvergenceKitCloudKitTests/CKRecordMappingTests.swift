// CKRecordMappingTests.swift
//
// Peer coverage for Sources/ConvergenceKitCloudKit/CKRecordMapping.swift
// (CKRecordMapping, DecodedRecord). The deterministic reference path:
// recordType formatting, recordID, and an in-memory CKRecord
// encode→decode round-trip. No live iCloud container or network — the
// CKRecord objects are constructed and read entirely in process, the
// same way the existing CloudKit stub test instantiates CloudKit types.
//
// Note (per Smythe pre-flight): CKRecordMapping.decode() reads CKRecord
// values back as NS-bridged objects, so integers decode as `.int`, not
// `.bitmap` — the `.bitmap` discriminator is not carried on the wire.
// The round-trip asserts `.int`, matching that documented behavior.

import Testing
import Foundation
import CloudKit
import SubstrateTypes
import PersistenceKit
import ConvergenceKit
import ConvergenceKitCloudKit

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
