// CKRecordMappingTests.swift
//
// Peer coverage for Sources/ConvergenceKitCloudKit/CKRecordMapping.swift
// (CKRecordMapping, DecodedRecord, SyncMeta). The deterministic reference path:
// recordType formatting, recordID, and an in-memory CKRecord
// encode→decode round-trip. No live iCloud container or network — the
// CKRecord objects are constructed and read entirely in process, the
// same way the existing CloudKit stub test instantiates CloudKit types.
//
// Type-tag fidelity tests (P4-M2): CKRecordMapping writes a _syncTypeTags
// compact JSON map for lossy discriminators (.uuid, .bitmap, .hlc, .json,
// .fingerprint) and restores them at decode time. Each lossy case gets its
// own round-trip test: encode → CKRecord (discriminator collapsed) →
// decode (discriminator restored by tag map) → byte/type equality.
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
        // applyInbound reads/writes the _ck_sync_meta side table, which
        // production creates in the engine's start path (startSync →
        // ensureSyncMetaTable). These tests call applyInbound directly, so
        // create the table the same way production does rather than
        // redeclaring its schema here and risking drift.
        try await CloudKitStateActor.ensureSyncMetaTable(storage: storage)
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
        // fix persists _syncHLC so the HLC guard in applyInbound can fire.
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

        // Write a row at T=2000. The sync HLC persists in the _ck_sync_meta
        // side table (not on the row), so durability is proven behaviorally:
        // a FRESH actor — the restart — must still see T=2000 through storage.
        let first = makeDecoded(id: rowID, note: "local-at-T2000", hlcTime: 2000)
        try await engine.applyInbound(first, syncedTable: syncedTable, storage: storage)

        // Simulate a restart: a new actor holds no in-memory HLC state. A
        // stale second inbound at T=1500 must still be rejected — the guard
        // can only fire if the first write's HLC was persisted.
        let restarted = CloudKitStateActor(containerIdentifier: nil)
        let stale = makeDecoded(id: rowID, note: "stale-at-T1500", hlcTime: 1500)
        try await restarted.applyInbound(stale, syncedTable: syncedTable, storage: storage)

        let finalRows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(finalRows.count == 1)
        #expect(finalRows[0]["note"] == .text("local-at-T2000"),
                "persisted HLC must guard against stale inbound after restart")
    }
}

// MARK: - Type-tag fidelity round-trip tests (P4-M2)

/// Verifies that the _syncTypeTags map written by record(from:) is consumed
/// by decode(_:) to restore the exact TypedValue discriminator for every lossy
/// CKRecord case. Each test: encode a single-column record, decode it, assert
/// type equality (discriminator) and byte equality (value content).
@Suite("CKRecord type-tag fidelity (P4-M2)")
struct CKRecordTypeFidelityTests {

    private let zoneID = CKRecordZone.ID(
        zoneName: "test-zone",
        ownerName: CKCurrentUserDefaultName
    )
    private let hlc = HLC(physicalTime: 500, logicalCount: 0, nodeID: 1)

    private func roundTrip(
        column: String,
        value: TypedValue
    ) throws -> TypedValue? {
        let rowKey = UUID()
        let record = try CKRecordMapping.record(
            from: [column: value],
            table: "test",
            rowKey: rowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "TK",
            zone: zoneID
        )
        let decoded = try CKRecordMapping.decode(record)
        return decoded.values[column]
    }

    @Test(".uuid round-trips through CKRecord with discriminator restored by tag map")
    func uuidRoundTrip() throws {
        let u = UUID()
        let result = try roundTrip(column: "col", value: .uuid(u))
        // Without tag map: would decode as .text(u.uuidString). With tag map: .uuid(u).
        #expect(result == .uuid(u),
                "uuid discriminator must be restored by _syncTypeTags; got \(String(describing: result))")
    }

    @Test(".bitmap round-trips through CKRecord with discriminator restored by tag map")
    func bitmapRoundTrip() throws {
        let bm = Int64(0b1010_0101)
        let result = try roundTrip(column: "col", value: .bitmap(bm))
        // Without tag map: would decode as .int(bm). With tag map: .bitmap(bm).
        #expect(result == .bitmap(bm),
                "bitmap discriminator must be restored by _syncTypeTags; got \(String(describing: result))")
    }

    @Test(".hlc round-trips through CKRecord with discriminator and value restored by tag map")
    func hlcRoundTrip() throws {
        let h = HLC(physicalTime: 1_234_567, logicalCount: 3, nodeID: 7)
        let result = try roundTrip(column: "col", value: .hlc(h))
        // Without tag map: would decode as .int(packed). With tag map: .hlc(h).
        if case .hlc(let decoded) = result {
            #expect(decoded.physicalTime == h.physicalTime,
                    "hlc physicalTime must survive CKRecord round-trip via tag map")
            #expect(decoded.logicalCount == h.logicalCount)
            #expect(decoded.nodeID == h.nodeID)
        } else {
            Issue.record("expected .hlc, got \(String(describing: result))")
        }
    }

    @Test(".json round-trips through CKRecord with discriminator restored by tag map")
    func jsonRoundTrip() throws {
        let jsonBytes = Data(#"{"k":"v"}"#.utf8)
        let result = try roundTrip(column: "col", value: .json(jsonBytes))
        // Without tag map: would decode as .text or .blob. With tag map: .json.
        if case .json(let decodedData) = result {
            #expect(decodedData == jsonBytes,
                    "json bytes must be byte-identical after CKRecord round-trip via tag map")
        } else {
            Issue.record("expected .json, got \(String(describing: result))")
        }
    }

    @Test(".fingerprint round-trips through CKRecord with discriminator restored by tag map")
    func fingerprintRoundTrip() throws {
        let fp = Fingerprint256(block0: 0xAABB, block1: 0xCCDD, block2: 0xEEFF, block3: 0x1122)
        let result = try roundTrip(column: "col", value: .fingerprint(fp))
        // Without tag map: would decode as .blob(32 bytes). With tag map: .fingerprint(fp).
        if case .fingerprint(let decoded) = result {
            #expect(decoded.block0 == fp.block0, "block0 must survive round-trip")
            #expect(decoded.block1 == fp.block1, "block1 must survive round-trip")
            #expect(decoded.block2 == fp.block2, "block2 must survive round-trip")
            #expect(decoded.block3 == fp.block3, "block3 must survive round-trip")
        } else {
            Issue.record("expected .fingerprint, got \(String(describing: result))")
        }
    }

    @Test("non-lossy discriminators round-trip without a tag map entry")
    func nonLossyDiscriminatorsRoundTrip() throws {
        // These cases must round-trip correctly without any _syncTypeTags assistance.
        let rowKey = UUID()
        let record = try CKRecordMapping.record(
            from: [
                "t": .text("hello"),
                "i": .int(42),
                "f": .float(3.14),
                "b": .bool(true),
                "d": .blob(Data([0x01, 0x02])),
                "ts": .timestamp(Date(timeIntervalSince1970: 1_000_000)),
            ],
            table: "test",
            rowKey: rowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "TK",
            zone: zoneID
        )
        let decoded = try CKRecordMapping.decode(record)
        #expect(decoded.values["t"] == .text("hello"))
        #expect(decoded.values["i"] == .int(42))
        #expect(decoded.values["f"] == .float(3.14))
        #expect(decoded.values["b"] == .bool(true))
        #expect(decoded.values["d"] == .blob(Data([0x01, 0x02])))
        // timestamp: Date equality is exact since it round-trips through NSDate.
        if case .timestamp(let t) = decoded.values["ts"] {
            #expect(abs(t.timeIntervalSince1970 - 1_000_000) < 0.001,
                    "timestamp must survive CKRecord round-trip")
        } else {
            Issue.record("expected .timestamp, got \(String(describing: decoded.values["ts"]))")
        }
    }

    @Test("mixed lossy and non-lossy columns in one record all round-trip correctly")
    func mixedColumnsRoundTrip() throws {
        let u = UUID()
        let bm = Int64(0xFF_00)
        let jsonBytes = Data(#"{"x":1}"#.utf8)
        let rowKey = UUID()
        let record = try CKRecordMapping.record(
            from: [
                "uid":   .uuid(u),
                "flags": .bitmap(bm),
                "note":  .text("mixed"),
                "count": .int(7),
                "data":  .json(jsonBytes),
            ],
            table: "test",
            rowKey: rowKey,
            hlc: hlc,
            schemaVersion: 1,
            kitID: "TK",
            zone: zoneID
        )
        let decoded = try CKRecordMapping.decode(record)
        #expect(decoded.values["uid"]   == .uuid(u),       "uuid must be restored in mixed record")
        #expect(decoded.values["flags"] == .bitmap(bm),    "bitmap must be restored in mixed record")
        #expect(decoded.values["note"]  == .text("mixed"), "text must round-trip in mixed record")
        #expect(decoded.values["count"] == .int(7),        "int must round-trip in mixed record")
        if case .json(let d) = decoded.values["data"] {
            #expect(d == jsonBytes, "json bytes must be byte-identical in mixed record")
        } else {
            Issue.record("expected .json, got \(String(describing: decoded.values["data"]))")
        }
    }

    // MARK: - Gap 6: columnHLCs wire round-trip at REAL magnitude (> 40-bit truncation ceiling)

    /// Group (b) of the gap 6 regression tests: a column HLC with
    /// `physicalTime` above the old 40-bit `HLC.packed` truncation ceiling
    /// (`0xFF_FFFF_FFFF`, ~1.0995e12) must survive the ACTUAL production
    /// `_syncColumnHLCs` wire path — `CKRecordMapping.record(from:...)`'s
    /// `JSONEncoder().encode(map)` into `record["_syncColumnHLCs"]` as
    /// `NSData`, then `CKRecordMapping.decode(_:)`'s
    /// `JSONDecoder().decode(ColumnHLCMap.self, from:)` — byte-exact, with
    /// no truncation. This is the WIRE half of gap 6's fix; the PERSIST half
    /// (ColumnHLCStore round-trip through storage) is covered by
    /// `ColumnHLCFullWidthRoundTripTests`.
    ///
    /// Contrast: this path was NEVER lossy (SyncRecord's `PackedHLC` is a
    /// plain Codable struct with a full-width `Int64 physicalTime` field —
    /// no bit-packing). The defect gap 6 fixes was entirely in
    /// `ColumnHLCStore`'s SQL persistence, which used the LOSSY
    /// `HLC.packed`/`HLC(packed:)` round-trip. This test documents and locks
    /// in that the wire path was — and remains — full-width, so any future
    /// change that accidentally routes columnHLCs through `packed(hlc)` (the
    /// row-grain `_syncHLC` field's encoding, which DOES truncate) would be
    /// caught here.
    @Test("columnHLCs with physicalTime above the 40-bit truncation ceiling survive the CKRecord wire round-trip byte-exact")
    func columnHLCsRealMagnitudeWireRoundTrip() throws {
        let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
        let rowKey = UUID()
        // Real wall-clock-scale physicalTime values (2026-ish, ms since Unix
        // epoch), well above the old 40-bit ceiling (0xFF_FFFF_FFFF ≈ 1.0995e12).
        let truncationCeiling: Int64 = 0xFF_FFFF_FFFF
        let noteHLC = HLC(physicalTime: 1_784_477_500_577, logicalCount: 1, nodeID: 3)
        let scoreHLC = HLC(physicalTime: 1_784_477_440_577, logicalCount: 0, nodeID: 7)
        #expect(noteHLC.physicalTime > truncationCeiling, "test precondition: real magnitude")
        #expect(scoreHLC.physicalTime > truncationCeiling, "test precondition: real magnitude")
        let columnHLCs = ColumnHLCMap(entries: [
            "note":  PackedHLC(noteHLC),
            "score": PackedHLC(scoreHLC),
        ])

        let record = try CKRecordMapping.record(
            from: ["note": .text("hi"), "score": .int(1)],
            table: "items",
            rowKey: rowKey,
            hlc: HLC(physicalTime: 1_784_477_500_577, logicalCount: 1, nodeID: 3),
            schemaVersion: 1,
            kitID: "TK",
            zone: zoneID,
            columnHLCs: columnHLCs
        )
        let decoded = try CKRecordMapping.decode(record)

        let decodedNote = try #require(decoded.columnHLCs?.entries["note"])
        let decodedScore = try #require(decoded.columnHLCs?.entries["score"])
        #expect(decodedNote.physicalTime == noteHLC.physicalTime, "physicalTime must survive the wire round-trip byte-exact")
        #expect(decodedNote.logicalCount == noteHLC.logicalCount)
        #expect(decodedNote.nodeID == noteHLC.nodeID)
        #expect(decodedScore.physicalTime == scoreHLC.physicalTime, "physicalTime must survive the wire round-trip byte-exact")
        #expect(decodedScore.logicalCount == scoreHLC.logicalCount)
        #expect(decodedScore.nodeID == scoreHLC.nodeID)
    }
}
