// FederationJSONConformanceTests.swift
//
// Golden JSON vector tests verifying the cross-port wire contract.
// These tests use handwritten JSON literals and inspect selected decoded
// Swift fields or key presence; they do not invoke the Rust port directly
// or compare Swift output against Rust bytes byte-for-byte.

import Testing
import Foundation
import SubstrateTypes
import ConvergenceKit

@Suite("Federation JSON conformance")
struct FederationJSONConformanceTests {

    // MARK: - PackedHLC

    /// Golden JSON for PackedHLC. Field names are camelCase with
    /// "nodeID" (capital D), matching the Rust serde rename.
    @Test("PackedHLC encodes camelCase field names")
    func packedHLCFieldNames() throws {
        let hlc = PackedHLC(HLC(physicalTime: 1000, logicalCount: 5, nodeID: 3))
        let json = try JSONEncoder().encode(hlc)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(dict.keys.contains("physicalTime"))
        #expect(dict.keys.contains("logicalCount"))
        #expect(dict.keys.contains("nodeID"))
        #expect(!dict.keys.contains("physical_time"))
        #expect(!dict.keys.contains("node_id"))
    }

    /// Decode the exact JSON that Rust produces for PackedHLC.
    @Test("PackedHLC decodes Rust golden JSON")
    func packedHLCDecodeRustGolden() throws {
        let golden = """
        {"physicalTime":1000,"logicalCount":5,"nodeID":3}
        """
        let hlc = try JSONDecoder().decode(PackedHLC.self, from: Data(golden.utf8))
        #expect(hlc.physicalTime == 1000)
        #expect(hlc.logicalCount == 5)
        #expect(hlc.nodeID == 3)
    }

    // MARK: - SyncRecord

    /// Golden JSON for SyncRecord. All field names are camelCase.
    @Test("SyncRecord encodes camelCase field names")
    func syncRecordFieldNames() throws {
        let uuid = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        let record = SyncRecord(
            table: "drawers",
            event: .insert,
            rowKey: uuid,
            values: nil,
            hlc: PackedHLC(HLC(physicalTime: 100, logicalCount: 0, nodeID: 1)),
            schemaVersion: 1,
            kitID: "TestKit"
        )
        let json = try JSONEncoder().encode(record)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(dict.keys.contains("rowKey"))
        #expect(dict.keys.contains("schemaVersion"))
        #expect(dict.keys.contains("kitID"))
        #expect(!dict.keys.contains("row_key"))
        #expect(!dict.keys.contains("schema_version"))
        #expect(!dict.keys.contains("kit_id"))
    }

    /// Decode the exact JSON that Rust produces for a SyncRecord.
    @Test("SyncRecord decodes Rust golden JSON")
    func syncRecordDecodeRustGolden() throws {
        let golden = """
        {"table":"drawers","event":"insert","rowKey":"e621e1f8-c36c-495a-93fc-0c247a3e6e5f","values":null,"hlc":{"physicalTime":100,"logicalCount":0,"nodeID":1},"schemaVersion":1,"kitID":"TestKit"}
        """
        let record = try JSONDecoder().decode(SyncRecord.self, from: Data(golden.utf8))
        #expect(record.table == "drawers")
        #expect(record.event == .insert)
        #expect(record.schemaVersion == 1)
        #expect(record.kitID == "TestKit")
        #expect(record.hlc.physicalTime == 100)
        #expect(record.hlc.nodeID == 1)
    }

    // MARK: - SyncManifest

    @Test("SyncManifest encodes camelCase field names")
    func syncManifestFieldNames() throws {
        let manifest = SyncManifest(
            kitID: "TestKit",
            schemaVersion: 1,
            zoneIdentifier: "zone-1",
            tables: [SyncedTable(name: "t", primaryKeyColumn: "id")]
        )
        let json = try JSONEncoder().encode(manifest)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(dict.keys.contains("kitID"))
        #expect(dict.keys.contains("schemaVersion"))
        #expect(dict.keys.contains("zoneIdentifier"))
        #expect(!dict.keys.contains("kit_id"))
        #expect(!dict.keys.contains("schema_version"))
        #expect(!dict.keys.contains("zone_identifier"))
        let tables = dict["tables"] as! [[String: Any]]
        #expect(tables[0].keys.contains("primaryKeyColumn"))
        #expect(tables[0].keys.contains("conflictPolicy"))
        #expect(!tables[0].keys.contains("primary_key_column"))
    }

    /// Decode the exact JSON that Rust produces for a SyncManifest.
    @Test("SyncManifest decodes Rust golden JSON")
    func syncManifestDecodeRustGolden() throws {
        let golden = """
        {"kitID":"TestKit","schemaVersion":1,"zoneIdentifier":"zone-1","tables":[{"name":"drawers","direction":"bidirectional","primaryKeyColumn":"row_id","conflictPolicy":"lastWriterWinsByHLC"}]}
        """
        let manifest = try JSONDecoder().decode(SyncManifest.self, from: Data(golden.utf8))
        #expect(manifest.kitID == "TestKit")
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.zoneIdentifier == "zone-1")
        #expect(manifest.tables[0].name == "drawers")
        #expect(manifest.tables[0].primaryKeyColumn == "row_id")
        #expect(manifest.tables[0].conflictPolicy == .lastWriterWinsByHLC)
    }

    // MARK: - SyncValueBox

    /// Text value encodes as adjacently-tagged: {"kind":"text","payload":"hello"}.
    @Test("SyncValueBox text encodes adjacently-tagged")
    func syncValueBoxText() throws {
        let box = SyncValueBox(.text("hello"))
        let json = try JSONEncoder().encode(box)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(dict["kind"] as? String == "text")
        #expect(dict["payload"] as? String == "hello")
    }

    /// Null value encodes without payload (Rust serde omits content
    /// for unit variants).
    @Test("SyncValueBox null encodes without payload key")
    func syncValueBoxNull() throws {
        let box = SyncValueBox(.null)
        let json = try JSONEncoder().encode(box)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(dict["kind"] as? String == "null")
        #expect(dict["payload"] == nil)
    }

    /// Int value encodes as adjacently-tagged with numeric payload.
    @Test("SyncValueBox int encodes adjacently-tagged")
    func syncValueBoxInt() throws {
        let box = SyncValueBox(.int(42))
        let json = try JSONEncoder().encode(box)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(dict["kind"] as? String == "int")
        #expect(dict["payload"] as? Int == 42)
    }

    /// Timestamp encodes as epoch seconds (Int64), not Date.
    @Test("SyncValueBox timestamp encodes as epoch seconds")
    func syncValueBoxTimestamp() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let box = SyncValueBox(.timestamp(date))
        let json = try JSONEncoder().encode(box)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(dict["kind"] as? String == "timestamp")
        #expect(dict["payload"] as? Int == 1_700_000_000)
    }

    /// Blob encodes as a JSON array of UInt8, matching Rust's Vec<u8>.
    @Test("SyncValueBox blob encodes as byte array")
    func syncValueBoxBlob() throws {
        let box = SyncValueBox(.blob(Data([0xCA, 0xFE])))
        let json = try JSONEncoder().encode(box)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(dict["kind"] as? String == "blob")
        let bytes = dict["payload"] as? [Int]
        #expect(bytes == [202, 254])
    }

    /// HLC payload encodes as a nested object with camelCase fields.
    @Test("SyncValueBox hlc encodes nested PackedHLC")
    func syncValueBoxHLC() throws {
        let hlc = HLC(physicalTime: 500, logicalCount: 1, nodeID: 2)
        let box = SyncValueBox(.hlc(hlc))
        let json = try JSONEncoder().encode(box)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        #expect(dict["kind"] as? String == "hlc")
        let nested = dict["payload"] as? [String: Any]
        #expect(nested?["physicalTime"] as? Int == 500)
        #expect(nested?["nodeID"] as? Int == 2)
    }

    /// Round-trip: decode a Rust-produced SyncValueBox array covering
    /// text, int, null, bool, bitmap, float, and timestamp (seven types).
    @Test("SyncValueBox round-trips Rust golden JSON for common types")
    func syncValueBoxDecodeRustGolden() throws {
        let golden = """
        [{"kind":"text","payload":"hello"},{"kind":"int","payload":42},{"kind":"null"},{"kind":"bool","payload":true},{"kind":"bitmap","payload":255},{"kind":"float","payload":3.14},{"kind":"timestamp","payload":1700000000}]
        """
        let boxes = try JSONDecoder().decode([SyncValueBox].self, from: Data(golden.utf8))
        #expect(boxes.count == 7)
        #expect(boxes[0].asTypedValue == .text("hello"))
        #expect(boxes[1].asTypedValue == .int(42))
        #expect(boxes[2].asTypedValue == .null)
        #expect(boxes[3].asTypedValue == .bool(true))
        #expect(boxes[4].asTypedValue == .bitmap(255))
        #expect(boxes[5].asTypedValue == .float(3.14))
        #expect(boxes[6].asTypedValue == .timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    /// Full SyncRecord with values: decode Rust golden JSON.
    @Test("SyncRecord with SyncValueMap decodes Rust golden JSON")
    func syncRecordWithValuesDecodeRustGolden() throws {
        let golden = """
        {"table":"drawers","event":"insert","rowKey":"e621e1f8-c36c-495a-93fc-0c247a3e6e5f","values":{"entries":{"name":{"kind":"text","payload":"test"},"flags":{"kind":"bitmap","payload":7}}},"hlc":{"physicalTime":100,"logicalCount":0,"nodeID":1},"schemaVersion":1,"kitID":"TestKit"}
        """
        let record = try JSONDecoder().decode(SyncRecord.self, from: Data(golden.utf8))
        #expect(record.table == "drawers")
        let values = record.values?.asTypedValues
        #expect(values?["name"] == .text("test"))
        #expect(values?["flags"] == .bitmap(7))
    }
}
