// EncryptedValuesTests.swift
//
// Tests for CKRecord.encryptedValues adoption (FAB5-EV).
// Covers: golden byte-identity (empty declaration), encode routing,
// decode dual-read, type-tag round-trip via encrypted channel, and
// SyncManifest.validateEncryptedColumns rejection rules.
//
// No live iCloud container or network — CKRecord objects are constructed
// and read entirely in process, identical to CKRecordMappingTests.swift.

import Testing
import Foundation
import CloudKit
import SubstrateTypes
import PersistenceKit
import ConvergenceKit
@testable import ConvergenceKitCloudKit

// MARK: - Helpers

private let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
private let baseHLC = HLC(physicalTime: 2000, logicalCount: 1, nodeID: 1)

private func encRecord(
    _ values: [String: TypedValue],
    encryptedColumns: Set<String> = [],
    table: String = "items"
) throws -> CKRecord {
    try CKRecordMapping.record(
        from: values,
        table: table,
        rowKey: UUID(),
        hlc: baseHLC,
        schemaVersion: 1,
        kitID: "TestKit",
        zone: zoneID,
        encryptedColumns: encryptedColumns
    )
}

// MARK: - Golden byte-identity (empty declaration)

@Suite("encryptedValues — golden byte-identity with empty declaration")
struct EncryptedValuesGoldenTests {

    @Test("empty encryptedColumns: column lands in plaintext, not in encryptedValues")
    func goldenPlaintextChannel() throws {
        let record = try encRecord(["note": .text("hello")])
        // Column must be readable from the plaintext channel.
        #expect(record["note"] != nil)
        // Encrypted channel must NOT contain this undeclared column.
        #expect(record.encryptedValues["note"] == nil)
    }

    @Test("empty encryptedColumns: decode produces identical values to baseline")
    func goldenDecodeIdentical() throws {
        let values: [String: TypedValue] = ["note": .text("hi"), "count": .int(7)]
        let record = try encRecord(values)
        let decoded = try CKRecordMapping.decode(record)
        #expect(decoded.values["note"] == .text("hi"))
        #expect(decoded.values["count"] == .int(7))
    }
}

// MARK: - Encode routing

@Suite("encryptedValues — encode routing")
struct EncryptedValuesEncodeTests {

    @Test("declared column routes to encryptedValues, not plaintext")
    func declaredColumnGoesToEncryptedChannel() throws {
        let record = try encRecord(
            ["secret": .text("s3cr3t"), "public": .text("open")],
            encryptedColumns: ["secret"]
        )
        // Declared column: readable via encrypted channel, absent from plaintext.
        #expect(record.encryptedValues["secret"] != nil)
        #expect(record["secret"] == nil)
        // Undeclared column: readable via plaintext, absent from encrypted.
        #expect(record["public"] != nil)
        #expect(record.encryptedValues["public"] == nil)
    }

    @Test("multiple declared columns all route to encryptedValues")
    func multipleDeclaredColumnsEncrypted() throws {
        let record = try encRecord(
            ["a": .int(1), "b": .int(2), "c": .int(3)],
            encryptedColumns: ["a", "b"]
        )
        // Declared columns: readable via encrypted channel, absent from plaintext.
        #expect(record.encryptedValues["a"] != nil)
        #expect(record["a"] == nil)
        #expect(record.encryptedValues["b"] != nil)
        #expect(record["b"] == nil)
        // "c" is undeclared — stays plaintext.
        #expect(record["c"] != nil)
        #expect(record.encryptedValues["c"] == nil)
    }
}

// MARK: - Decode dual-read

@Suite("encryptedValues — decode dual-read")
struct EncryptedValuesDualReadTests {

    @Test("encrypted column round-trips through encode→decode")
    func encryptedRoundTrip() throws {
        let record = try encRecord(
            ["secret": .text("s3cr3t"), "public": .text("open")],
            encryptedColumns: ["secret"]
        )
        let decoded = try CKRecordMapping.decode(record)
        #expect(decoded.values["secret"] == .text("s3cr3t"))
        #expect(decoded.values["public"] == .text("open"))
    }

    @Test("plaintext fallback: pre-migration row (no encryptedColumns used) still decodes")
    func plaintextFallbackForLegacyRow() throws {
        // Simulate a pre-migration row: no encryptedColumns, everything in plaintext.
        let legacyRecord = try encRecord(
            ["content": .text("legacy"), "tag": .int(99)]
            // encryptedColumns: [] (default)
        )
        // Decoder must recover both values from the plaintext channel.
        let decoded = try CKRecordMapping.decode(legacyRecord)
        #expect(decoded.values["content"] == .text("legacy"))
        #expect(decoded.values["tag"] == .int(99))
    }

    @Test("_sync* keys never appear in decoded values regardless of channel")
    func syncKeysFilteredFromBothChannels() throws {
        let record = try encRecord(["real": .text("data")], encryptedColumns: ["real"])
        let decoded = try CKRecordMapping.decode(record)
        // No _sync* keys should leak into values.
        for key in decoded.values.keys {
            #expect(!key.hasPrefix("_sync"))
        }
    }
}

// MARK: - Lossy discriminator restoration via encrypted channel

@Suite("encryptedValues — type-tag restoration for lossy discriminators")
struct EncryptedValuesTypeTagTests {

    @Test(".uuid discriminator round-trips via encrypted channel")
    func uuidViaEncryptedChannel() throws {
        let id = UUID()
        let record = try encRecord(["uid": .uuid(id)], encryptedColumns: ["uid"])
        let decoded = try CKRecordMapping.decode(record)
        #expect(decoded.values["uid"] == .uuid(id))
    }

    @Test(".bitmap discriminator round-trips via encrypted channel")
    func bitmapViaEncryptedChannel() throws {
        let record = try encRecord(["flags": .bitmap(0xCAFEBABE)], encryptedColumns: ["flags"])
        let decoded = try CKRecordMapping.decode(record)
        #expect(decoded.values["flags"] == .bitmap(0xCAFEBABE))
    }

    @Test(".json discriminator round-trips via encrypted channel")
    func jsonViaEncryptedChannel() throws {
        let payload = Data("{\"k\":1}".utf8)
        let record = try encRecord(["meta": .json(payload)], encryptedColumns: ["meta"])
        let decoded = try CKRecordMapping.decode(record)
        #expect(decoded.values["meta"] == .json(payload))
    }
}

// MARK: - SyncManifest validation

@Suite("SyncManifest — validateEncryptedColumns")
struct ManifestValidationTests {

    private func manifest(encryptedContentColumns: [String: Set<String>]) -> SyncManifest {
        SyncManifest(
            kitID: "TestKit",
            schemaVersion: 1,
            zoneIdentifier: "TestZone",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id")],
            encryptedContentColumns: encryptedContentColumns
        )
    }

    @Test("valid declaration passes validation")
    func validDeclarationPasses() throws {
        let m = manifest(encryptedContentColumns: ["items": ["content", "body"]])
        #expect(throws: Never.self) { try m.validateEncryptedColumns() }
    }

    @Test("empty declaration passes validation")
    func emptyDeclarationPasses() throws {
        let m = manifest(encryptedContentColumns: [:])
        #expect(throws: Never.self) { try m.validateEncryptedColumns() }
    }

    @Test("_sync* column is rejected")
    func syncPrefixColumnRejected() throws {
        let m = manifest(encryptedContentColumns: ["items": ["_syncHLC"]])
        #expect(throws: SyncError.self) { try m.validateEncryptedColumns() }
    }

    @Test("_ck_* table is rejected")
    func ckPrefixTableRejected() throws {
        let m = manifest(encryptedContentColumns: ["_ck_device_slot": ["device_uuid"]])
        #expect(throws: SyncError.self) { try m.validateEncryptedColumns() }
    }

    @Test("registry table rejected even with valid-looking column names")
    func registryTableAlwaysRejected() throws {
        let m = manifest(encryptedContentColumns: ["_ck_side_table": ["epoch"]])
        #expect(throws: SyncError.self) { try m.validateEncryptedColumns() }
    }
}
