// ColumnHLCMapConformanceTests.swift
//
// Golden JSON wire-format tests for ColumnHLCMap and SyncRecord.columnHLCs.
//
// These tests verify that the Swift encoding matches the Rust serde output
// (B-8 / C-8 cross-port parity). The golden JSON literals were derived from
// the Rust ColumnHLCMap serialisation (BTreeMap<String, PackedHLC> under an
// "entries" key, alphabetically ordered keys per BTreeMap).
//
// WHY golden JSON and not a live Rust call:
// The Rust leg runs in a separate binary context (cargo test); the Swift
// conformance suite cannot invoke it directly. Instead, these tests verify
// the wire shape using handwritten JSON that matches what `serde_json` would
// produce for the equivalent Rust struct. Any deviation in field naming,
// nesting, or key casing would be caught here.

import Testing
import Foundation
import SubstrateTypes
import ConvergenceKit

// MARK: - Helpers

private func hlc(physical: Int64, logical: Int32 = 0, node: Int32 = 1) -> PackedHLC {
    PackedHLC(HLC(physicalTime: physical, logicalCount: logical, nodeID: node))
}

// MARK: - ColumnHLCMap wire format

@Suite("ColumnHLCMap — wire format conformance (B-8 / C-8)")
struct ColumnHLCMapConformanceTests {

    // MARK: Encoding

    @Test("encodes with top-level 'entries' key (matches Rust struct field name)")
    func encodesEntriesKey() throws {
        let map = ColumnHLCMap(entries: [
            "col": hlc(physical: 100, logical: 0, node: 1),
        ])
        let data = try JSONEncoder().encode(map)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["entries"] != nil, "must have top-level 'entries' key")
        #expect(obj.count == 1, "no extra keys beyond 'entries'")
    }

    @Test("empty map encodes as {\"entries\":{}}")
    func emptyMapEncoding() throws {
        let map = ColumnHLCMap()
        let data = try JSONEncoder().encode(map)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "{\"entries\":{}}")
    }

    @Test("PackedHLC within entries uses camelCase field names (C-8 parity)")
    func hlcFieldsCamelCase() throws {
        let map = ColumnHLCMap(entries: [
            "score": hlc(physical: 1_000_000, logical: 7, node: 3),
        ])
        let data = try JSONEncoder().encode(map)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let entries = obj["entries"] as! [String: Any]
        let hlcObj = entries["score"] as! [String: Any]
        #expect(hlcObj["physicalTime"] != nil)
        #expect(hlcObj["logicalCount"] != nil)
        #expect(hlcObj["nodeID"] != nil)
        #expect(hlcObj["physical_time"] == nil, "no snake_case keys")
        #expect(hlcObj["node_id"] == nil, "no snake_case keys")
    }

    // MARK: Decoding — golden JSON from Rust

    @Test("decodes Rust golden JSON: single column")
    func decodesRustGoldenSingleColumn() throws {
        // This exact JSON is produced by Rust serde_json for:
        //   ColumnHLCMap { entries: BTreeMap::from([("title", PackedHLC {
        //     physical_time: 1000000, logical_count: 5, node_id: 2
        //   })]) }
        let golden = """
        {"entries":{"title":{"physicalTime":1000000,"logicalCount":5,"nodeID":2}}}
        """
        let map = try JSONDecoder().decode(ColumnHLCMap.self, from: Data(golden.utf8))
        let entry = try #require(map.entries["title"])
        #expect(entry.physicalTime == 1_000_000)
        #expect(entry.logicalCount == 5)
        #expect(entry.nodeID == 2)
    }

    @Test("decodes Rust golden JSON: multiple columns alphabetically ordered (BTreeMap)")
    func decodesRustGoldenMultiColumn() throws {
        // Rust BTreeMap sorts keys alphabetically: body < score < title
        let golden = """
        {"entries":{"body":{"physicalTime":200,"logicalCount":0,"nodeID":1},"score":{"physicalTime":300,"logicalCount":1,"nodeID":2},"title":{"physicalTime":100,"logicalCount":0,"nodeID":1}}}
        """
        let map = try JSONDecoder().decode(ColumnHLCMap.self, from: Data(golden.utf8))
        #expect(map.entries.count == 3)
        #expect(map.entries["body"]?.physicalTime  == 200)
        #expect(map.entries["score"]?.physicalTime == 300)
        #expect(map.entries["title"]?.physicalTime == 100)
    }

    @Test("decodes empty entries object")
    func decodesEmptyEntries() throws {
        let golden = "{\"entries\":{}}"
        let map = try JSONDecoder().decode(ColumnHLCMap.self, from: Data(golden.utf8))
        #expect(map.isEmpty)
    }

    // MARK: Round-trip: Swift encode → Swift decode

    @Test("round-trip through JSON preserves all entries")
    func roundTripPreservesEntries() throws {
        let original = ColumnHLCMap(entries: [
            "alpha":   hlc(physical: 1_000, logical: 0, node: 1),
            "beta":    hlc(physical: 2_000, logical: 3, node: 5),
            "gamma":   hlc(physical: 3_000, logical: 1, node: 15),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ColumnHLCMap.self, from: data)
        #expect(decoded == original)
    }

    // MARK: SyncRecord.columnHLCs wire shape

    @Test("SyncRecord with columnHLCs encodes 'columnHLCs' key")
    func syncRecordColumnHLCsKey() throws {
        let record = SyncRecord(
            table: "items",
            event: .insert,
            rowKey: UUID(),
            values: nil,
            hlc: hlc(physical: 1_000_000),
            schemaVersion: 1,
            kitID: "TestKit",
            columnHLCs: ColumnHLCMap(entries: [
                "name": hlc(physical: 1_000_000),
            ])
        )
        let data = try JSONEncoder().encode(record)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["columnHLCs"] != nil, "SyncRecord must encode 'columnHLCs' when non-nil")
    }

    @Test("SyncRecord without columnHLCs omits 'columnHLCs' key (backward compat)")
    func syncRecordColumnHLCsOmittedWhenNil() throws {
        let record = SyncRecord(
            table: "items",
            event: .insert,
            rowKey: UUID(),
            values: nil,
            hlc: hlc(physical: 1_000_000),
            schemaVersion: 1,
            kitID: "TestKit",
            columnHLCs: nil
        )
        let data = try JSONEncoder().encode(record)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["columnHLCs"] == nil, "nil columnHLCs must be omitted (encodeIfPresent)")
    }

    @Test("SyncRecord.columnHLCs round-trips through JSON")
    func syncRecordColumnHLCsRoundTrip() throws {
        let colMap = ColumnHLCMap(entries: [
            "title": hlc(physical: 1_000_000),
            "body":  hlc(physical: 1_500_000, logical: 2, node: 2),
        ])
        let record = SyncRecord(
            table: "items",
            event: .insert,
            rowKey: UUID(),
            values: nil,
            hlc: hlc(physical: 2_000_000, logical: 1, node: 3),
            schemaVersion: 1,
            kitID: "TestKit",
            columnHLCs: colMap
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SyncRecord.self, from: data)
        #expect(decoded.columnHLCs == colMap)
    }

    // MARK: ConflictPolicy.fieldLevelLWW encoding

    @Test("ConflictPolicy.fieldLevelLWW encodes as 'fieldLevelLWW' camelCase")
    func conflictPolicyEncoding() throws {
        // Verify the Rust serde rename_all camelCase contract: both legs
        // must produce "fieldLevelLWW" on the wire, not "field_level_lww"
        // or "FieldLevelLWW".
        // SyncManifest is non-Codable since P2-M3 (hook closure); the wire
        // contract lives on SyncedTable, which remains Codable.
        let table = SyncedTable(
            name: "items",
            direction: .bidirectional,
            primaryKeyColumn: "id",
            conflictPolicy: .fieldLevelLWW
        )
        let data = try JSONEncoder().encode(table)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"fieldLevelLWW\""),
                "ConflictPolicy.fieldLevelLWW must encode as camelCase string 'fieldLevelLWW'")
        #expect(!json.contains("field_level_lww"), "no snake_case encoding")
    }

    @Test("ConflictPolicy.fieldLevelLWW decodes from Rust golden JSON")
    func conflictPolicyDecodeRustGolden() throws {
        let golden = """
        {"name":"items","direction":"bidirectional","primaryKeyColumn":"id","conflictPolicy":"fieldLevelLWW"}
        """
        let table = try JSONDecoder().decode(SyncedTable.self, from: Data(golden.utf8))
        #expect(table.conflictPolicy == ConflictPolicy.fieldLevelLWW)
    }
}
