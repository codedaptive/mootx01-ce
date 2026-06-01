// WireFormatConformanceTests.swift
//
// Swift↔Rust JSON wire-format conformance gate for SubstrateLib.
//
// What this tests, and what it doesn't:
//
//   This file tests value-equivalence, not byte-identity. Swift's
//   JSONEncoder for auto-synthesized Codable does NOT guarantee
//   declaration-order key emission — observed output puts the
//   keys in what looks like hash-bucket order, which varies by
//   struct. Rust serde_json preserves declaration order. So
//   byte-identical JSON across the two ports would require
//   custom CodingKeys + custom encode(to:) on the Swift side
//   (to control order) OR alphabetic-key normalization on both.
//
//   Neither is wrong; both are bigger swaps. F16.A pins the gate
//   at the level that actually matters for cross-port consumers:
//   the JSON KEY NAMES match Swift↔Rust, and the value-encoding
//   conventions match (integer raws for RowState, camelCase
//   string raws for RowVerb / AuditVerb, etc.).
//
//   Each type has two tests:
//
//     1. Round-trip — construct, encode, decode, assert equality.
//        Catches value-encoding drift.
//
//     2. Key-name fixture — decode a known JSON string with the
//        EXPECTED key names (the same string the Rust test
//        decodes), assert fields populate correctly. Catches
//        rename drift.
//
//   The sibling Rust test (`tests/wire_format_conformance.rs`)
//   decodes the same fixture strings. If a rename diverges, that
//   side's fixture-decode fails loudly.
//
//   The byte-identity question (for audit-log content-hash
//   dedup, federation transports, etc.) remains open and is
//   tracked under F16.B alongside the AuditValue wire-format
//   design decision.

import Foundation
import Testing
@testable import SubstrateLib
import SubstrateML
import SubstrateKernel
import SubstrateTypes

@Suite("Swift↔Rust JSON wire-format conformance")
struct WireFormatConformanceTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Fingerprint256

    @Test func testFingerprint256RoundTrip() throws {
        let fp = Fingerprint256(block0: 1, block1: 2, block2: 3, block3: 4)
        let data = try encoder.encode(fp)
        let back = try decoder.decode(Fingerprint256.self, from: data)
        #expect(fp == back)
    }

    @Test func testFingerprint256KeyNames() throws {
        // EXPECTED KEYS: block0, block1, block2, block3.
        let json = #"{"block0":1,"block1":2,"block2":3,"block3":4}"#
        let fp = try decoder.decode(Fingerprint256.self,
                                    from: json.data(using: .utf8)!)
        #expect(fp.block0 == 1)
        #expect(fp.block1 == 2)
        #expect(fp.block2 == 3)
        #expect(fp.block3 == 4)
    }

    // MARK: - HLC

    @Test func testHLCRoundTrip() throws {
        let hlc = HLC(physicalTime: 1700000000000, logicalCount: 7, nodeID: 42)
        let data = try encoder.encode(hlc)
        let back = try decoder.decode(HLC.self, from: data)
        #expect(hlc == back)
    }

    @Test func testHLCKeyNames() throws {
        // EXPECTED KEYS: physicalTime, logicalCount, nodeID
        // (capital "ID", matching Swift's auto-Codable key from
        // the property name). This is the camelCase the QueueKit
        // wire format depends on.
        let json = #"{"physicalTime":1700000000000,"logicalCount":7,"nodeID":42}"#
        let hlc = try decoder.decode(HLC.self, from: json.data(using: .utf8)!)
        #expect(hlc.physicalTime == 1700000000000)
        #expect(hlc.logicalCount == 7)
        #expect(hlc.nodeID == 42)
    }

    // MARK: - RowState — encoded as raw u8 integer.

    @Test func testRowStateRoundTrip() throws {
        for state in RowState.allCases {
            let data = try encoder.encode(state)
            let back = try decoder.decode(RowState.self, from: data)
            #expect(state == back)
        }
    }

    @Test func testRowStateRawValueEncoding() throws {
        // Swift Codable for enum with UInt8 raw encodes as the
        // raw integer. Rust matches via serde_repr.
        #expect(try String(data: encoder.encode(RowState.active),
                           encoding: .utf8) == "0")
        #expect(try String(data: encoder.encode(RowState.accepted),
                           encoding: .utf8) == "3")
        #expect(try String(data: encoder.encode(RowState.withdrawn),
                           encoding: .utf8) == "18")
        #expect(try String(data: encoder.encode(RowState.tombstoned),
                           encoding: .utf8) == "33")

        // Decode a raw integer 18 → withdrawn.
        let w = try decoder.decode(RowState.self, from: "18".data(using: .utf8)!)
        #expect(w == .withdrawn)
    }

    // MARK: - RowVerb — encoded as camelCase string raw.

    @Test func testRowVerbRoundTrip() throws {
        for verb in RowVerb.allCases {
            let data = try encoder.encode(verb)
            let back = try decoder.decode(RowVerb.self, from: data)
            #expect(verb == back)
        }
    }

    @Test func testRowVerbRawValueEncoding() throws {
        #expect(try String(data: encoder.encode(RowVerb.capture),
                           encoding: .utf8) == #""capture""#)
        #expect(try String(data: encoder.encode(RowVerb.resolveContest),
                           encoding: .utf8) == #""resolveContest""#)
        let r = try decoder.decode(RowVerb.self,
                                    from: #""resolveContest""#.data(using: .utf8)!)
        #expect(r == .resolveContest)
    }

    // MARK: - CountVector256

    @Test func testCountVector256RoundTripZero() throws {
        let cv = CountVector256.zero
        let data = try encoder.encode(cv)
        let back = try decoder.decode(CountVector256.self, from: data)
        #expect(cv == back)
    }

    @Test func testCountVector256KeyNames() throws {
        // EXPECTED KEYS: counts, n. (Both match between Swift
        // and Rust — no rename needed.) The counts array is 256
        // u32 zeros.
        var json = #"{"counts":["#
        json += Array(repeating: "0", count: 256).joined(separator: ",")
        json += #"],"n":0}"#
        let cv = try decoder.decode(CountVector256.self,
                                    from: json.data(using: .utf8)!)
        #expect(cv.counts.count == 256)
        #expect(cv.counts.allSatisfy { $0 == 0 } == true)
        #expect(cv.n == 0)
    }

    // MARK: - Hyperplane + HyperplaneFamily

    @Test func testHyperplaneRoundTrip() throws {
        let h = Hyperplane(positiveMask: [255], negativeMask: [170], bitLength: 8)
        let data = try encoder.encode(h)
        let back = try decoder.decode(Hyperplane.self, from: data)
        #expect(h == back)
    }

    @Test func testHyperplaneKeyNames() throws {
        // EXPECTED KEYS: positiveMask, negativeMask, bitLength.
        let json = #"{"positiveMask":[255],"negativeMask":[170],"bitLength":8}"#
        let h = try decoder.decode(Hyperplane.self,
                                    from: json.data(using: .utf8)!)
        #expect(h.positiveMask == [255])
        #expect(h.negativeMask == [170])
        #expect(h.bitLength == 8)
    }

    @Test func testHyperplaneFamilyKeyNames() throws {
        // EXPECTED KEYS: blockIndex, inputBitLength, planes.
        // Decode bypasses the public init's 64-plane precondition.
        let json = #"{"blockIndex":0,"inputBitLength":8,"planes":[{"positiveMask":[1],"negativeMask":[2],"bitLength":8}]}"#
        let f = try decoder.decode(HyperplaneFamily.self,
                                    from: json.data(using: .utf8)!)
        #expect(f.blockIndex == 0)
        #expect(f.inputBitLength == 8)
        #expect(f.planes.count == 1)
    }

    // MARK: - AuditVerb

    @Test func testAuditVerbRoundTrip() throws {
        for v in [AuditVerb.capture, .mutate, .retract, .sync, .pair,
                  .unpair, .derive, .decay, .promote, .migrate, .dreamCompact] {
            let data = try encoder.encode(v)
            let back = try decoder.decode(AuditVerb.self, from: data)
            #expect(v == back)
        }
    }

    @Test func testAuditVerbRawValueEncoding() throws {
        #expect(try String(data: encoder.encode(AuditVerb.capture),
                           encoding: .utf8) == #""capture""#)
        #expect(try String(data: encoder.encode(AuditVerb.dreamCompact),
                           encoding: .utf8) == #""dreamCompact""#)
        let d = try decoder.decode(AuditVerb.self,
                                    from: #""dreamCompact""#.data(using: .utf8)!)
        #expect(d == .dreamCompact)
    }

    // ========================================================
    // F16.B — AuditValue, AuditEntry, GSetAuditLog
    // ========================================================

    // MARK: - AuditValue

    @Test func testAuditValueRoundTripBitmap() throws {
        let v = AuditValue.bitmap(0xCAFE_BABE_DEAD_BEEF)
        let data = try encoder.encode(v)
        let back = try decoder.decode(AuditValue.self, from: data)
        #expect(v == back)
    }

    @Test func testAuditValueRoundTripString() throws {
        let v = AuditValue.string("hello, world")
        let data = try encoder.encode(v)
        let back = try decoder.decode(AuditValue.self, from: data)
        #expect(v == back)
    }

    @Test func testAuditValueRoundTripFingerprint() throws {
        let fp = Fingerprint256(block0: 1, block1: 2, block2: 3, block3: 4)
        let v = AuditValue.fingerprint(fp)
        let data = try encoder.encode(v)
        let back = try decoder.decode(AuditValue.self, from: data)
        #expect(v == back)
    }

    @Test func testAuditValueRoundTripInteger() throws {
        let v = AuditValue.integer(-42)
        let data = try encoder.encode(v)
        let back = try decoder.decode(AuditValue.self, from: data)
        #expect(v == back)
    }

    @Test func testAuditValueWireFormat() throws {
        // Custom Codable produces externally-tagged single-key
        // objects with camelCase variant names. Match Rust's
        // default serde with `rename_all = "camelCase"`.
        let bitmap = try String(data: encoder.encode(AuditValue.bitmap(42)),
                                 encoding: .utf8)
        #expect(bitmap == #"{"bitmap":42}"#)

        let string = try String(data: encoder.encode(AuditValue.string("hi")),
                                 encoding: .utf8)
        #expect(string == #"{"string":"hi"}"#)

        let integer = try String(data: encoder.encode(AuditValue.integer(-1)),
                                  encoding: .utf8)
        #expect(integer == #"{"integer":-1}"#)
    }

    @Test func testAuditValueDecodeFromKnownFixture() throws {
        let cases: [(String, AuditValue)] = [
            (#"{"bitmap":42}"#, .bitmap(42)),
            (#"{"string":"hello"}"#, .string("hello")),
            (#"{"integer":-1}"#, .integer(-1)),
        ]
        for (json, expected) in cases {
            let v = try decoder.decode(AuditValue.self,
                                        from: json.data(using: .utf8)!)
            #expect(v == expected)
        }
    }

    // MARK: - AuditEntry

    private func sampleAuditEntry(
        beforeValue: AuditValue? = .integer(1),
        afterValue: AuditValue? = .integer(2),
        originRowID: UUID? = nil
    ) -> AuditEntry {
        return AuditEntry(
            id: Array(repeating: UInt8(0xAB), count: 32),
            hlc: HLC(physicalTime: 1700000000000, logicalCount: 0, nodeID: 1),
            verb: .mutate,
            rowID: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!,
            fieldPath: "adjective.state",
            beforeValue: beforeValue,
            afterValue: afterValue,
            originRowID: originRowID
        )
    }

    @Test func testAuditEntryRoundTripMutate() throws {
        let entry = sampleAuditEntry()
        let data = try encoder.encode(entry)
        let back = try decoder.decode(AuditEntry.self, from: data)
        #expect(entry == back)
    }

    @Test func testAuditEntryRoundTripCaptureBoundary() throws {
        // beforeValue = nil at capture (no prior value existed).
        let entry = sampleAuditEntry(beforeValue: nil, afterValue: .integer(5))
        let data = try encoder.encode(entry)
        let back = try decoder.decode(AuditEntry.self, from: data)
        #expect(entry == back)
        #expect(back.beforeValue == nil)
    }

    @Test func testAuditEntryRoundTripRetractBoundary() throws {
        let entry = sampleAuditEntry(beforeValue: .integer(7), afterValue: nil)
        let data = try encoder.encode(entry)
        let back = try decoder.decode(AuditEntry.self, from: data)
        #expect(entry == back)
        #expect(back.afterValue == nil)
    }

    @Test func testAuditEntryRoundTripWithOrigin() throws {
        let origin = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
        let entry = sampleAuditEntry(originRowID: origin)
        let data = try encoder.encode(entry)
        let back = try decoder.decode(AuditEntry.self, from: data)
        #expect(entry == back)
        #expect(back.originRowID == origin)
    }

    @Test func testAuditEntryRowIDIsUUIDString() throws {
        // Swift UUID Codable emits an UPPERCASE hyphenated UUID
        // string. Rust mirror does the same via the row_id_uuid
        // serde helper. This test pins the expected format.
        let entry = sampleAuditEntry()
        let data = try encoder.encode(entry)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains(#""rowID":"550E8400-E29B-41D4-A716-446655440000""#),
                "rowID must be encoded as an uppercase UUID string. Got: \(json)")
    }

    // MARK: - GSetAuditLog

    @Test func testGSetAuditLogRoundTripEmpty() throws {
        let log = GSetAuditLog(entries: [])
        let data = try encoder.encode(log)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == #"{"entries":[]}"#)
        let back = try decoder.decode(GSetAuditLog.self, from: data)
        #expect(back.count == 0)
    }

    @Test func testGSetAuditLogRoundTripMultiple() throws {
        var lowID = Array(repeating: UInt8(0x10), count: 32)
        lowID[31] = 0x01
        var highID = Array(repeating: UInt8(0x10), count: 32)
        highID[31] = 0x02
        let hlc = HLC(physicalTime: 1, logicalCount: 0, nodeID: 1)
        let e1 = AuditEntry(id: highID, hlc: hlc, verb: .mutate,
                             rowID: UUID(), fieldPath: "f",
                             beforeValue: nil, afterValue: .integer(2))
        let e2 = AuditEntry(id: lowID, hlc: hlc, verb: .mutate,
                             rowID: UUID(), fieldPath: "f",
                             beforeValue: nil, afterValue: .integer(1))
        // Insert in non-sorted order; encoder must produce sorted output.
        let log = GSetAuditLog(entries: [e1, e2])
        let data = try encoder.encode(log)
        let back = try decoder.decode(GSetAuditLog.self, from: data)
        #expect(back.count == 2)
        // Decoded entries indexed by id.
        #expect(back.entries[lowID]?.afterValue == .integer(1))
        #expect(back.entries[highID]?.afterValue == .integer(2))
    }
}
