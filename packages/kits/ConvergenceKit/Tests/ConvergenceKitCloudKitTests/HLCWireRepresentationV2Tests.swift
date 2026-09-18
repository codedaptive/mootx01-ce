// HLCWireRepresentationV2Tests.swift
//
// Wave 6A2 upstream slice U1 — HLCWireRepresentation test suite.
//
// Four groups:
//   (a) Legacy golden values: default representation → moot_sync_hlc is packed
//       Int64 NSNumber with correct 48/12/4 bit layout. Byte-identical to
//       all pre-v2 zones.
//   (b) fullWidthV2 round-trip: logicalCount > 4095 (which silently truncates
//       under legacyPacked), large physicalTime, all nodeID nibble values,
//       tombstone HLC, TypedValue.hlc columns.
//   (c) Refusal matrix: fullWidthV2 decode of packed NSNumber → error;
//       wrong-length Data → error; legacyPacked decode of 16-byte Data → error;
//       mixed TypedValue.hlc representation → error.
//   (d) Manifest default: SyncManifest(…) without hlcWireRepresentation
//       parameter → .legacyPacked (backward-compat contract).
//
// All tests use Swift Testing (import Testing) per repo convention.
// CKRecord is exercised through CKRecordMapping's public API without hitting
// live CloudKit — in-process only.

import Testing
import Foundation
import CloudKit
@testable import ConvergenceKit
@testable import ConvergenceKitCloudKit
import SubstrateTypes

// MARK: - Helpers

private func testZone() -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
}

/// A fixed row key used across tests — deterministic, UUID-valid string.
private let fixedRowKey = UUID(uuidString: "DEADBEEF-1234-5678-9ABC-DEF012345678")!

/// physicalTime above the old 40-bit HLC.packed ceiling (0xFF_FFFF_FFFF = 1099511627775).
/// Representative of a real 2026-ish wall-clock millisecond value.
private let realPhysicalTime: Int64 = 1_784_477_500_577

// MARK: - Suite (a): Legacy golden values

@Suite("(a) Legacy golden values — legacyPacked default")
struct LegacyGoldenValueTests {

    /// Calling record(from:…) without representation uses the .legacyPacked default.
    /// moot_sync_hlc must be NSNumber, not Data.
    @Test("default representation → moot_sync_hlc is packed NSNumber")
    func defaultRepresentationProducesPackedNSNumber() throws {
        let hlc = HLC(physicalTime: 1_784_000_000_000, logicalCount: 1, nodeID: 3)
        let record = try CKRecordMapping.record(
            from: ["title": .text("hello")],
            table: "items",
            rowKey: fixedRowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone()
            // representation omitted → defaults to .legacyPacked
        )
        let rawHLC = record["moot_sync_hlc"]
        #expect(rawHLC is NSNumber, "legacyPacked: moot_sync_hlc must be NSNumber")
        #expect(!(rawHLC is Data), "legacyPacked: moot_sync_hlc must NOT be Data")
    }

    /// Verify the 48/12/4 bit layout: (phys & 0xFFFF_FFFF_FFFF) << 16 | (log & 0xFFF) << 4 | (node & 0xF).
    @Test("48/12/4 packed layout matches hand-computed expected value")
    func packedLayoutMatchesExpected() throws {
        // physicalTime=1000, logicalCount=2, nodeID=5
        // packed = (1000 << 16) | (2 << 4) | 5 = 65_536_037
        let hlc = HLC(physicalTime: 1000, logicalCount: 2, nodeID: 5)
        let record = try CKRecordMapping.record(
            from: [:],
            table: "items",
            rowKey: fixedRowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone(),
            representation: .legacyPacked
        )
        let packed = (record["moot_sync_hlc"] as? NSNumber)?.int64Value
        let expected: Int64 = (1000 << 16) | (2 << 4) | 5
        #expect(packed == expected, "packed Int64 must match 48/12/4 bit layout")
    }

    /// Round-trip: record(from:) + decode() under legacyPacked — HLC and values survive.
    @Test("legacyPacked round-trip preserves logicalCount ≤ 4095")
    func legacyRoundTripPreservesSmallLogicalCount() throws {
        let hlc = HLC(physicalTime: 1_700_000_000_000, logicalCount: 99, nodeID: 2)
        let record = try CKRecordMapping.record(
            from: ["score": .int(42)],
            table: "items",
            rowKey: fixedRowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone(),
            representation: .legacyPacked
        )
        let decoded = try CKRecordMapping.decode(record, representation: .legacyPacked)
        #expect(decoded.syncMeta.hlc.physicalTime == hlc.physicalTime)
        #expect(decoded.syncMeta.hlc.logicalCount == hlc.logicalCount)
        #expect(decoded.syncMeta.hlc.nodeID == hlc.nodeID)
        #expect(decoded.values["score"] == .int(42))
    }
}

// MARK: - Suite (b): fullWidthV2 round-trips

@Suite("(b) fullWidthV2 round-trips — lossless, logicalCount > 4095")
struct FullWidthV2RoundTripTests {

    /// The core v2 contract: logicalCount 70000 (above 4095) must survive byte-exact.
    @Test("logicalCount 70000 round-trips byte-exact under fullWidthV2")
    func logicalCountOverflowRoundTrip() throws {
        // logicalCount = 70_000, well above the 12-bit (4095) legacyPacked ceiling.
        let hlc = HLC(physicalTime: realPhysicalTime, logicalCount: 70_000, nodeID: 7)
        let record = try CKRecordMapping.record(
            from: [:],
            table: "items",
            rowKey: fixedRowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone(),
            representation: .fullWidthV2
        )
        // The field must be Data (16 bytes), not NSNumber.
        let rawHLC = record["moot_sync_hlc"]
        #expect(rawHLC is Data, "fullWidthV2: moot_sync_hlc must be Data not NSNumber")
        let hlcData = try #require(rawHLC as? Data)
        #expect(hlcData.count == 16, "wireBytes must be exactly 16 bytes")

        let decoded = try CKRecordMapping.decode(record, representation: .fullWidthV2)
        #expect(decoded.syncMeta.hlc.physicalTime == hlc.physicalTime, "physicalTime must be byte-exact")
        #expect(decoded.syncMeta.hlc.logicalCount == hlc.logicalCount, "logicalCount 70000 must survive fullWidthV2")
        #expect(decoded.syncMeta.hlc.nodeID == hlc.nodeID, "nodeID must be byte-exact")
    }

    /// Prove truncation under legacyPacked to document the defect fullWidthV2 fixes.
    @Test("logicalCount 70000 DOES truncate under legacyPacked — documents the gap fullWidthV2 fixes")
    func legacyPackedTruncatesLargeLogicalCount() throws {
        let hlc = HLC(physicalTime: 1_000_000_000, logicalCount: 70_000, nodeID: 1)
        let record = try CKRecordMapping.record(
            from: [:],
            table: "items",
            rowKey: fixedRowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone(),
            representation: .legacyPacked
        )
        let decoded = try CKRecordMapping.decode(record, representation: .legacyPacked)
        // legacyPacked truncates logicalCount to 12 bits: 70_000 & 0xFFF = 70_000 % 4096
        let truncated = Int32(70_000 & 0xFFF)
        #expect(decoded.syncMeta.hlc.logicalCount == truncated, "legacyPacked must truncate 70000 to 12-bit value")
        #expect(decoded.syncMeta.hlc.logicalCount != hlc.logicalCount, "legacyPacked MUST lose logicalCount above 4095")
    }

    /// Large physicalTime (real 2026-ish wall-clock) round-trips byte-exact under fullWidthV2.
    @Test("large physicalTime (2026 real magnitude) round-trips byte-exact under fullWidthV2")
    func largePhysicalTimeRoundTrip() throws {
        let hlc = HLC(physicalTime: realPhysicalTime, logicalCount: 50_000, nodeID: 5)
        let record = try CKRecordMapping.record(
            from: [:],
            table: "items",
            rowKey: fixedRowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone(),
            representation: .fullWidthV2
        )
        let decoded = try CKRecordMapping.decode(record, representation: .fullWidthV2)
        #expect(decoded.syncMeta.hlc.physicalTime == realPhysicalTime, "physicalTime must be byte-exact")
        #expect(decoded.syncMeta.hlc.logicalCount == 50_000, "logicalCount must survive fullWidthV2")
        #expect(decoded.syncMeta.hlc.nodeID == 5, "nodeID must be byte-exact")
    }

    /// All 16 valid nodeID nibble values (0–15) round-trip byte-exact under fullWidthV2.
    @Test("all nodeID nibble values 0–15 round-trip byte-exact under fullWidthV2")
    func allNodeIDsRoundTrip() throws {
        for nodeID in Int32(0)...Int32(15) {
            let hlc = HLC(physicalTime: 1_000_000_000, logicalCount: 70_000, nodeID: nodeID)
            let record = try CKRecordMapping.record(
                from: [:],
                table: "items",
                rowKey: fixedRowKey,
                hlc: hlc,
                schemaVersion: 1,
                kitID: "testkit",
                zone: testZone(),
                representation: .fullWidthV2
            )
            let decoded = try CKRecordMapping.decode(record, representation: .fullWidthV2)
            #expect(decoded.syncMeta.hlc.nodeID == nodeID, "nodeID must round-trip byte-exact")
            #expect(decoded.syncMeta.hlc.logicalCount == 70_000, "logicalCount must be preserved for each nodeID")
        }
    }

    /// Tombstone: delete HLC with logicalCount > 4095 round-trips byte-exact under fullWidthV2.
    @Test("tombstone moot_sync_hlc with logicalCount > 4095 round-trips byte-exact under fullWidthV2")
    func tombstoneHLCRoundTrip() throws {
        let deleteHLC = HLC(physicalTime: realPhysicalTime, logicalCount: 99_999, nodeID: 3)
        let tombstone = CKRecordMapping.tombstoneRecord(
            rowKey: fixedRowKey,
            table: "items",
            kitID: "testkit",
            deleteHLC: deleteHLC,
            schemaVersion: 1,
            zone: testZone(),
            representation: .fullWidthV2
        )
        let rawHLC = tombstone["moot_sync_hlc"]
        #expect(rawHLC is Data, "fullWidthV2 tombstone: moot_sync_hlc must be Data")
        let hlcData = try #require(rawHLC as? Data)
        #expect(hlcData.count == 16, "wireBytes must be exactly 16 bytes")

        let decoded = try CKRecordMapping.decode(tombstone, representation: .fullWidthV2)
        #expect(decoded.isTombstone, "tombstone marker must survive decode")
        #expect(decoded.syncMeta.hlc.physicalTime == deleteHLC.physicalTime, "tombstone physicalTime byte-exact")
        #expect(decoded.syncMeta.hlc.logicalCount == deleteHLC.logicalCount, "tombstone logicalCount 99999 must survive")
        #expect(decoded.syncMeta.hlc.nodeID == deleteHLC.nodeID, "tombstone nodeID byte-exact")
    }

    /// TypedValue.hlc column with logicalCount > 4095 round-trips through assign/decode.
    @Test("TypedValue.hlc column with logicalCount > 4095 round-trips byte-exact under fullWidthV2")
    func typedValueHLCColumnRoundTrip() throws {
        let columnHLC = HLC(physicalTime: 1_784_000_000_000, logicalCount: 65_535, nodeID: 9)
        let rowHLC = HLC(physicalTime: 1_784_000_000_001, logicalCount: 1, nodeID: 9)
        let record = try CKRecordMapping.record(
            from: ["updated_at": .hlc(columnHLC)],
            table: "items",
            rowKey: fixedRowKey,
            hlc: rowHLC,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone(),
            representation: .fullWidthV2
        )
        // The TypedValue.hlc column must be stored as 16-byte Data.
        let rawColumn = record["updated_at"]
        #expect(rawColumn is Data, "fullWidthV2: TypedValue.hlc column must be Data not NSNumber")

        // Round-trip decode restores .hlc discriminator via type-tag map.
        let decoded = try CKRecordMapping.decode(record, representation: .fullWidthV2)
        guard case .hlc(let restored) = decoded.values["updated_at"] else {
            Issue.record("TypedValue.hlc column must decode back to .hlc")
            return
        }
        #expect(restored.physicalTime == columnHLC.physicalTime, "column physicalTime byte-exact")
        #expect(restored.logicalCount == columnHLC.logicalCount, "column logicalCount 65535 must survive fullWidthV2")
        #expect(restored.nodeID == columnHLC.nodeID, "column nodeID byte-exact")
    }

    /// Multiple TypedValue.hlc columns in one record all round-trip independently.
    @Test("multiple TypedValue.hlc columns all round-trip byte-exact under fullWidthV2")
    func multipleHLCColumnsRoundTrip() throws {
        let hlc1 = HLC(physicalTime: 1_784_000_000_000, logicalCount: 65_535, nodeID: 1)
        let hlc2 = HLC(physicalTime: 1_784_000_000_001, logicalCount: 70_000, nodeID: 2)
        let rowHLC = HLC(physicalTime: 1_784_000_000_002, logicalCount: 1, nodeID: 1)
        let record = try CKRecordMapping.record(
            from: ["created_at": .hlc(hlc1), "modified_at": .hlc(hlc2)],
            table: "items",
            rowKey: fixedRowKey,
            hlc: rowHLC,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone(),
            representation: .fullWidthV2
        )
        let decoded = try CKRecordMapping.decode(record, representation: .fullWidthV2)

        guard case .hlc(let restored1) = decoded.values["created_at"] else {
            Issue.record("created_at must decode as .hlc")
            return
        }
        guard case .hlc(let restored2) = decoded.values["modified_at"] else {
            Issue.record("modified_at must decode as .hlc")
            return
        }
        #expect(restored1.logicalCount == hlc1.logicalCount, "created_at logicalCount must be byte-exact")
        #expect(restored2.logicalCount == hlc2.logicalCount, "modified_at logicalCount must be byte-exact")
    }
}

// MARK: - Suite (c): Refusal matrix

@Suite("(c) Refusal matrix — mixed representation rejected, wrong-length Data rejected")
struct RefusalMatrixTests {

    /// fullWidthV2 decode of a legacyPacked NSNumber moot_sync_hlc → error (fail closed).
    @Test("fullWidthV2 decode of packed NSNumber moot_sync_hlc throws decodingFailure")
    func fullWidthV2RejectsPackedNSNumber() throws {
        let hlc = HLC(physicalTime: 1_000_000, logicalCount: 1, nodeID: 1)
        // Encode with legacyPacked: moot_sync_hlc is NSNumber.
        let record = try CKRecordMapping.record(
            from: [:],
            table: "items",
            rowKey: fixedRowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone(),
            representation: .legacyPacked
        )
        // fullWidthV2 decode must reject the NSNumber (not Data).
        #expect(throws: (any Error).self, "fullWidthV2 must reject legacyPacked NSNumber moot_sync_hlc") {
            try CKRecordMapping.decode(record, representation: .fullWidthV2)
        }
    }

    /// legacyPacked decode of a fullWidthV2 Data moot_sync_hlc → error (fail closed).
    @Test("legacyPacked decode of 16-byte Data moot_sync_hlc throws decodingFailure")
    func legacyPackedRejects16ByteData() throws {
        let hlc = HLC(physicalTime: 1_000_000, logicalCount: 70_000, nodeID: 1)
        // Encode with fullWidthV2: moot_sync_hlc is 16-byte Data.
        let record = try CKRecordMapping.record(
            from: [:],
            table: "items",
            rowKey: fixedRowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone(),
            representation: .fullWidthV2
        )
        // legacyPacked decode must reject the Data (not NSNumber).
        #expect(throws: (any Error).self, "legacyPacked must reject fullWidthV2 16-byte Data moot_sync_hlc") {
            try CKRecordMapping.decode(record, representation: .legacyPacked)
        }
    }

    /// Wrong-length Data (8 bytes) for moot_sync_hlc → error under fullWidthV2.
    @Test("fullWidthV2 decode of 8-byte Data moot_sync_hlc throws decodingFailure")
    func wrongLength8BytesThrows() throws {
        let record = CKRecord(
            recordType: "testkit_items",
            recordID: CKRecord.ID(recordName: fixedRowKey.uuidString, zoneID: testZone())
        )
        record["moot_sync_hlc"] = Data(repeating: 0xAB, count: 8) as NSData
        record["moot_sync_schema_version"] = NSNumber(value: 1)
        record["moot_sync_kit_id"] = "testkit" as NSString
        #expect(throws: (any Error).self, "wrong-length 8-byte Data for moot_sync_hlc must throw") {
            try CKRecordMapping.decode(record, representation: .fullWidthV2)
        }
    }

    /// Wrong-length Data (15 bytes) for moot_sync_hlc → error under fullWidthV2.
    @Test("fullWidthV2 decode of 15-byte Data moot_sync_hlc throws decodingFailure")
    func wrongLength15BytesThrows() throws {
        let record = CKRecord(
            recordType: "testkit_items",
            recordID: CKRecord.ID(recordName: fixedRowKey.uuidString, zoneID: testZone())
        )
        record["moot_sync_hlc"] = Data(repeating: 0xAB, count: 15) as NSData
        record["moot_sync_schema_version"] = NSNumber(value: 1)
        record["moot_sync_kit_id"] = "testkit" as NSString
        #expect(throws: (any Error).self, "wrong-length 15-byte Data for moot_sync_hlc must throw") {
            try CKRecordMapping.decode(record, representation: .fullWidthV2)
        }
    }

    /// Wrong-length Data (17 bytes) for moot_sync_hlc → error under fullWidthV2.
    @Test("fullWidthV2 decode of 17-byte Data moot_sync_hlc throws decodingFailure")
    func wrongLength17BytesThrows() throws {
        let record = CKRecord(
            recordType: "testkit_items",
            recordID: CKRecord.ID(recordName: fixedRowKey.uuidString, zoneID: testZone())
        )
        record["moot_sync_hlc"] = Data(repeating: 0xAB, count: 17) as NSData
        record["moot_sync_schema_version"] = NSNumber(value: 1)
        record["moot_sync_kit_id"] = "testkit" as NSString
        #expect(throws: (any Error).self, "wrong-length 17-byte Data for moot_sync_hlc must throw") {
            try CKRecordMapping.decode(record, representation: .fullWidthV2)
        }
    }

    /// Mixed TypedValue.hlc column: legacyPacked zone, but column is 16-byte Data → error.
    @Test("legacyPacked decode of TypedValue.hlc column stored as Data throws decodingFailure")
    func legacyPackedRejectsBlobHLCColumn() throws {
        let columnHLC = HLC(physicalTime: 1_000_000, logicalCount: 1, nodeID: 1)
        let rowHLC = HLC(physicalTime: 1_000_001, logicalCount: 1, nodeID: 1)
        // Encode with fullWidthV2: TypedValue.hlc column stored as 16-byte Data.
        let record = try CKRecordMapping.record(
            from: ["updated_at": .hlc(columnHLC)],
            table: "items",
            rowKey: fixedRowKey,
            hlc: rowHLC,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone(),
            representation: .fullWidthV2
        )
        // Patch moot_sync_hlc to a valid legacyPacked NSNumber so the metadata field
        // passes; only the type-tag "hlc" column restoration path must fail.
        record["moot_sync_hlc"] = CKRecordMapping.packed(rowHLC) as NSNumber

        #expect(throws: (any Error).self, "legacyPacked must reject blob-form TypedValue.hlc column") {
            try CKRecordMapping.decode(record, representation: .legacyPacked)
        }
    }

    /// Mixed TypedValue.hlc column: fullWidthV2 zone, but column is packed NSNumber → error.
    @Test("fullWidthV2 decode of TypedValue.hlc column stored as packed NSNumber throws decodingFailure")
    func fullWidthV2RejectsIntHLCColumn() throws {
        let columnHLC = HLC(physicalTime: 1_000_000, logicalCount: 1, nodeID: 1)
        let rowHLC = HLC(physicalTime: 1_000_001, logicalCount: 1, nodeID: 1)
        // Encode with legacyPacked: TypedValue.hlc column stored as NSNumber.
        let record = try CKRecordMapping.record(
            from: ["updated_at": .hlc(columnHLC)],
            table: "items",
            rowKey: fixedRowKey,
            hlc: rowHLC,
            schemaVersion: 1,
            kitID: "testkit",
            zone: testZone(),
            representation: .legacyPacked
        )
        // Patch moot_sync_hlc to valid fullWidthV2 Data so the metadata field passes;
        // only the type-tag "hlc" column restoration path must fail.
        record["moot_sync_hlc"] = Data(rowHLC.wireBytes) as NSData

        #expect(throws: (any Error).self, "fullWidthV2 must reject packed-NSNumber TypedValue.hlc column") {
            try CKRecordMapping.decode(record, representation: .fullWidthV2)
        }
    }
}

// MARK: - Suite (d): Manifest default

@Suite("(d) Manifest default — SyncManifest.hlcWireRepresentation defaults to .legacyPacked")
struct ManifestDefaultTests {

    /// SyncManifest without hlcWireRepresentation → .legacyPacked (backward-compat contract).
    @Test("SyncManifest omitting hlcWireRepresentation defaults to .legacyPacked")
    func omittedParameterDefaultsToLegacyPacked() {
        let manifest = SyncManifest(
            kitID: "mykit",
            schemaVersion: 2,
            zoneIdentifier: "MyZone",
            tables: []
            // hlcWireRepresentation omitted — must default to .legacyPacked
        )
        #expect(manifest.hlcWireRepresentation == .legacyPacked, "omitted hlcWireRepresentation must default to .legacyPacked")
    }

    /// Explicit .legacyPacked is stored as .legacyPacked.
    @Test("SyncManifest with explicit .legacyPacked stores .legacyPacked")
    func explicitLegacyPacked() {
        let manifest = SyncManifest(
            kitID: "mykit",
            schemaVersion: 1,
            zoneIdentifier: "MyZone",
            tables: [],
            hlcWireRepresentation: .legacyPacked
        )
        #expect(manifest.hlcWireRepresentation == .legacyPacked)
    }

    /// Explicit .fullWidthV2 is stored as .fullWidthV2.
    @Test("SyncManifest with explicit .fullWidthV2 stores .fullWidthV2")
    func explicitFullWidthV2() {
        let manifest = SyncManifest(
            kitID: "mykit",
            schemaVersion: 1,
            zoneIdentifier: "MyZone",
            tables: [],
            hlcWireRepresentation: .fullWidthV2
        )
        #expect(manifest.hlcWireRepresentation == .fullWidthV2)
    }

    /// schemaVersion ≠ representation: schemaVersion 2/3 callers still default to
    /// .legacyPacked without any code change (A1 binding decision).
    /// FederationTombstoneRetentionTests uses schemaVersion 2.
    /// ProjectionTests uses schemaVersion 3.
    /// Neither must gain fullWidthV2 behavior by the schemaVersion bump alone.
    @Test("schemaVersion 2 and 3 without explicit opt-in still default to .legacyPacked")
    func schemaVersion2And3DefaultToLegacyPacked() {
        for version in [1, 2, 3] {
            let manifest = SyncManifest(
                kitID: "testkit",
                schemaVersion: version,
                zoneIdentifier: "TestZone",
                tables: []
            )
            #expect(manifest.hlcWireRepresentation == .legacyPacked, "schemaVersion bump must not silently change representation")
        }
    }
}
