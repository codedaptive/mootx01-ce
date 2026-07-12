// HLCRoundTripTests.swift
//
// Round-trip tests for HLC storage in the SQLite backend.
//
// These tests verify that an HLC stored to a .hlc column and read back
// produces the SAME HLC value. They would FAIL against the old unpack
// (which decoded with the wrong layout) and PASS after the fix
// (which uses the canonical HLC(packed:) inverse).
//
// Known-answer: physicalTime=0x0102030405, logicalCount=0x0607, nodeID=0x08
// Packed layout (node<<56 | logical<<40 | phys):
//   = 0x0806070102030405
// Old wrong decode (physical<<16 | logical<<4 | node):
//   physical = (0x0806070102030405 >> 16) & mask = 0x080607010203 ≠ 0x0102030405
//   → wrong physicalTime, wrong logicalCount, wrong nodeID.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite
// SQLCipher: the chronological-ordering backfill test manipulates the raw DB
// file via the C API (same vendored engine as CorruptReadBackTests).
import SQLCipher

// MARK: - SQLite HLC column round-trip

@Suite("SQLite HLC round-trip")
struct SQLiteHLCRoundTripTests {

    func makeStorage() throws -> SQLiteStorage {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hlc-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("hlc.sqlite")
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
    }

    func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "HLCTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "events",
                    columns: [
                        .uuid("id"),
                        .hlc("stamp")    // Declared .hlc so readColumn returns .hlc
                    ],
                    primaryKey: ["id"]
                )
            ]
        )
    }

    @Test("HLC with known fields survives SQLite round-trip")
    func hlcRoundTripKnownAnswer() async throws {
        // physicalTime fits in 40 bits, logicalCount in 16 bits, nodeID in 8 bits.
        // These exact values expose the layout difference between the old wrong
        // decode and the correct one.
        let original = HLC(physicalTime: 0x0102030405, logicalCount: 0x0607, nodeID: 0x08)
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "events",
            values: ["id": .uuid(rowID), "stamp": .hlc(original)]
        )

        let rows = try await storage.rowStore.query(
            table: "events",
            where: .eq(Column(table: "events", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1)

        // The read-back value must be .hlc — not .int — because the schema
        // declares the column as .hlc.
        guard case .hlc(let readBack) = rows[0]["stamp"] else {
            Issue.record("expected .hlc but got \(String(describing: rows[0]["stamp"]))")
            return
        }

        // Each field must match exactly. Any layout mismatch shows up here.
        #expect(readBack.physicalTime == original.physicalTime,
                "physicalTime mismatch: \(readBack.physicalTime) ≠ \(original.physicalTime)")
        #expect(readBack.logicalCount == original.logicalCount,
                "logicalCount mismatch: \(readBack.logicalCount) ≠ \(original.logicalCount)")
        #expect(readBack.nodeID == original.nodeID,
                "nodeID mismatch: \(readBack.nodeID) ≠ \(original.nodeID)")
        #expect(readBack == original, "HLC must be identical after round-trip")

        await storage.close()
    }

    @Test("HLC zero round-trips correctly")
    func hlcZeroRoundTrip() async throws {
        let original = HLC.zero
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "events",
            values: ["id": .uuid(rowID), "stamp": .hlc(original)]
        )
        let rows = try await storage.rowStore.query(
            table: "events",
            where: .eq(Column(table: "events", name: "id"), .uuid(rowID))
        )
        guard case .hlc(let readBack) = rows[0]["stamp"] else {
            Issue.record("expected .hlc"); return
        }
        #expect(readBack == original)
        await storage.close()
    }

    @Test("HLC with maximum 40-bit physical time round-trips correctly")
    func hlcMaxPhysicalRoundTrip() async throws {
        // 40 bits = 0xFF_FFFF_FFFF; this is the maximum physicalTime that
        // fits in the packed layout without truncation.
        let original = HLC(physicalTime: 0xFF_FFFF_FFFF, logicalCount: 0xFFFF, nodeID: 0x7F)
        let storage = try makeStorage()
        try await storage.open(schema: makeSchema())

        let rowID = UUID()
        _ = try await storage.rowStore.insert(
            table: "events",
            values: ["id": .uuid(rowID), "stamp": .hlc(original)]
        )
        let rows = try await storage.rowStore.query(
            table: "events",
            where: .eq(Column(table: "events", name: "id"), .uuid(rowID))
        )
        guard case .hlc(let readBack) = rows[0]["stamp"] else {
            Issue.record("expected .hlc"); return
        }
        #expect(readBack == original)
        await storage.close()
    }
}

// MARK: - SQLite audit-log HLC round-trip

@Suite("SQLite audit HLC round-trip")
struct SQLiteAuditHLCRoundTripTests {

    func makeStorage() throws -> SQLiteStorage {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-hlc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("audit.sqlite")
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
    }

    @Test("audit-log HLC survives SQLite round-trip")
    func auditHLCRoundTrip() async throws {
        // This exercises the decodeAuditRow path which has its own HLC decode.
        let original = HLC(physicalTime: 0x0102030405, logicalCount: 0x0607, nodeID: 0x08)
        let storage = try makeStorage()
        try await storage.open(schema: SchemaDeclaration(
            kitID: "AuditTest", version: 1, tables: []
        ))

        let rowID = UUID()
        let event = AuditEvent(
            estateUuid: UUID(),
            rowId: rowID,
            hlc: original,
            verb: "test-verb",
            beforeBitmaps: nil,
            afterBitmaps: (1, 2, 3),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: LatticeAnchor(udcCode: 0),
            actor: "test-actor"
        )
        try await storage.auditLog.append(event)

        // iterate(after: nil) returns all events from the beginning.
        let events = try await storage.auditLog.iterate(after: nil, rowID: nil, limit: 10)
        #expect(events.count == 1)

        let readBack = events[0].hlc
        #expect(readBack.physicalTime == original.physicalTime,
                "physicalTime mismatch in audit HLC: \(readBack.physicalTime) ≠ \(original.physicalTime)")
        #expect(readBack.logicalCount == original.logicalCount,
                "logicalCount mismatch in audit HLC: \(readBack.logicalCount) ≠ \(original.logicalCount)")
        #expect(readBack.nodeID == original.nodeID,
                "nodeID mismatch in audit HLC: \(readBack.nodeID) ≠ \(original.nodeID)")
        #expect(readBack == original, "audit HLC must be identical after round-trip")

        await storage.close()
    }
}

// MARK: - SQLite audit-log reason round-trip

/// Verify that the `reason` column persists and reads back with fidelity through
/// the SQLite audit path. Two cases: a supplied reason (Some) and no reason (None).
/// These tests catch any regression where reason is dropped at the INSERT or
/// decode site in `SQLiteStorage.appendAuditEvent` / `decodeAuditRow`.
@Suite("SQLite audit reason round-trip")
struct SQLiteAuditReasonRoundTripTests {

    func makeStorage() throws -> SQLiteStorage {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-reason-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("audit-reason.sqlite")
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
    }

    @Test("reason is persisted and read back when supplied")
    func reasonRoundTripSome() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: SchemaDeclaration(kitID: "ReasonTest", version: 1, tables: []))

        let event = AuditEvent(
            estateUuid: UUID(),
            rowId: UUID(),
            hlc: HLC(physicalTime: 1_000_000, logicalCount: 0, nodeID: 1),
            verb: "expunge",
            beforeBitmaps: nil,
            afterBitmaps: (1, 2, 3),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: LatticeAnchor(udcCode: 0),
            actor: "test-actor",
            reason: "GDPR erasure request #42"
        )
        try await storage.auditLog.append(event)

        let events = try await storage.auditLog.iterate(after: nil, rowID: nil, limit: 10)
        #expect(events.count == 1)
        // The reason must survive the INSERT → decodeAuditRow path unchanged.
        #expect(events[0].reason == "GDPR erasure request #42",
                "reason should round-trip through SQLite; got \(String(describing: events[0].reason))")

        await storage.close()
    }

    @Test("reason reads back as nil when not supplied")
    func reasonRoundTripNone() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: SchemaDeclaration(kitID: "ReasonTest", version: 1, tables: []))

        let event = AuditEvent(
            estateUuid: UUID(),
            rowId: UUID(),
            hlc: HLC(physicalTime: 2_000_000, logicalCount: 0, nodeID: 1),
            verb: "mutate",
            beforeBitmaps: nil,
            afterBitmaps: (4, 5, 6),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: LatticeAnchor(udcCode: 0),
            actor: "test-actor"
            // reason omitted; defaults to nil
        )
        try await storage.auditLog.append(event)

        let events = try await storage.auditLog.iterate(after: nil, rowID: nil, limit: 10)
        #expect(events.count == 1)
        // A nil reason must be stored as NULL and read back as nil.
        #expect(events[0].reason == nil,
                "reason should be nil when not supplied; got \(String(describing: events[0].reason))")

        await storage.close()
    }
}

// MARK: - SQLite audit chronological ordering (HLC_PACKED_ORDER_UNSOUND)

/// Audit reads must return CHRONOLOGICAL (physicalTime, logicalCount, nodeID)
/// order. The packed `hlc` integer's field layout (node in the top byte,
/// logical above physical) does not preserve that order, so any read keyed on
/// the packed column mis-orders a same-millisecond burst (logical > 0)
/// against a later write (logical 0) — the regression these tests pin.
@Suite("SQLite audit chronological ordering")
struct SQLiteAuditChronologicalOrderTests {

    func makeStorage() throws -> (SQLiteStorage, URL) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-chrono-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("chrono.sqlite")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
        return (storage, dbURL)
    }

    /// Raw SQL against the file, bypassing the kit — used only to simulate a
    /// pre-migration estate (full-precision columns zeroed).
    private func rawExec(_ dbURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open(dbURL.path, &db)
        defer { sqlite3_close(db) }
        guard rc == SQLITE_OK, let db else {
            throw StorageError.backendError(underlying: "rawExec open failed: \(rc)")
        }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc2 = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc2 != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errMsg)
            throw StorageError.backendError(underlying: msg)
        }
    }

    private func makeEvent(rowID: UUID, hlc: HLC, verb: String) -> AuditEvent {
        AuditEvent(
            estateUuid: UUID(),
            rowId: rowID,
            hlc: hlc,
            verb: verb,
            beforeBitmaps: nil,
            afterBitmaps: (1, 2, 3),
            beforeLatticeAnchor: nil,
            afterLatticeAnchor: LatticeAnchor(udcCode: 0),
            actor: "chrono-test"
        )
    }

    @Test("same-millisecond burst orders before a later write")
    func sameMillisecondBurstOrdersChronologically() async throws {
        let (storage, _) = try makeStorage()
        try await storage.open(schema: SchemaDeclaration(
            kitID: "ChronoTest", version: 1, tables: []
        ))
        let rowID = UUID()
        // Node low byte 0xB1 (negative as Int8) exercises the packed sign
        // flip; logical 1 at time T vs logical 0 at T+3 exercises the
        // logical-above-physical field-order defect.
        let burst = HLC(physicalTime: 1_783_833_507_371, logicalCount: 1, nodeID: 0xB1)
        let later = HLC(physicalTime: 1_783_833_507_374, logicalCount: 0, nodeID: 0x08)
        try await storage.auditLog.append(makeEvent(rowID: rowID, hlc: burst, verb: "capture"))
        try await storage.auditLog.append(makeEvent(rowID: rowID, hlc: later, verb: "mutate"))

        let all = try await storage.auditLog.iterate(after: nil, rowID: nil, limit: 10)
        #expect(all.map(\.verb) == ["capture", "mutate"],
                "iterate must return chronological order; got \(all.map(\.verb))")

        let forRow = try await storage.auditLog.iterate(after: nil, rowID: rowID, limit: 10)
        #expect(forRow.map(\.verb) == ["capture", "mutate"],
                "per-row read must return chronological order; got \(forRow.map(\.verb))")

        // The cursor is exclusive and chronological: after the burst event,
        // only the later event remains.
        let tail = try await storage.auditLog.iterate(after: burst, rowID: nil, limit: 10)
        #expect(tail.map(\.verb) == ["mutate"],
                "after-cursor must resume chronologically; got \(tail.map(\.verb))")

        await storage.close()
    }

    @Test("backfill reconstructs full-precision columns from the packed value")
    func backfillReconstructsFromPacked() async throws {
        let (storage, dbURL) = try makeStorage()
        try await storage.open(schema: SchemaDeclaration(
            kitID: "ChronoTest", version: 1, tables: []
        ))
        let rowID = UUID()
        let burst = HLC(physicalTime: 507_371, logicalCount: 1, nodeID: 0xB1)
        let later = HLC(physicalTime: 507_374, logicalCount: 0, nodeID: 0x08)
        try await storage.auditLog.append(makeEvent(rowID: rowID, hlc: burst, verb: "capture"))
        try await storage.auditLog.append(makeEvent(rowID: rowID, hlc: later, verb: "mutate"))
        await storage.close()

        // Simulate a pre-migration estate: zero out the full-precision
        // columns, leaving only the packed value, then reopen. The open-time
        // backfill must reconstruct the columns so chronological reads work.
        try rawExec(dbURL, """
            UPDATE "_storagekit_audit"
            SET "physical_time" = 0, "logical_count" = 0, "node_id" = 0
            """)

        let reopened = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
        try await reopened.open(schema: SchemaDeclaration(
            kitID: "ChronoTest", version: 1, tables: []
        ))
        let all = try await reopened.auditLog.iterate(after: nil, rowID: nil, limit: 10)
        #expect(all.map(\.verb) == ["capture", "mutate"],
                "backfilled rows must read chronologically; got \(all.map(\.verb))")
        // The packed form keeps only the node id's low byte (recovered as a
        // signed Int8), so the backfilled HLC equals HLC(packed:) recovery,
        // not the original full-width node id.
        #expect(all.first?.hlc == HLC(packed: burst.packed),
                "backfill must reconstruct exactly what the packed value carries")
        await reopened.close()
    }
}
