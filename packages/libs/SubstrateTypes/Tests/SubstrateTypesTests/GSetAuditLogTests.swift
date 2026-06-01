// GSetAuditLogTests.swift
//
// Per-type suite for GSetAuditLog (grow-only-set CRDT audit log) +
// AuditEntry / AuditVerb / AuditValue. Mirrors the Rust `gset.rs`
// inline #[test] set: add_is_idempotent, merge_is_commutative,
// merge_is_idempotent, ordered_entries_are_hlc_sorted,
// entries_since_excludes_cutoff.

import Foundation
import Testing
@testable import SubstrateTypes

@Suite("GSetAuditLog CRDT")
struct GSetAuditLogTests {

    /// A content-addressed entry whose 32-byte id is filled with one
    /// byte value, mirroring the Rust test helper.
    private func makeEntry(idByte: UInt8, physicalTime: Int64,
                           nodeID: Int32, rowID: UUID) -> AuditEntry {
        AuditEntry(
            id: [UInt8](repeating: idByte, count: 32),
            hlc: HLC(physicalTime: physicalTime, logicalCount: 0, nodeID: nodeID),
            verb: .capture,
            rowID: rowID,
            fieldPath: "test.field",
            beforeValue: nil,
            afterValue: .integer(42))
    }

    @Test("add is idempotent (same content hash dedupes)")
    func addIsIdempotent() {
        let row = UUID()
        var log = GSetAuditLog()
        let e = makeEntry(idByte: 0xAA, physicalTime: 1000, nodeID: 1, rowID: row)
        log.add(e)
        log.add(e)
        #expect(log.count == 1)
    }

    @Test("merge is commutative")
    func mergeIsCommutative() {
        let row = UUID()
        let e1 = makeEntry(idByte: 0x01, physicalTime: 1000, nodeID: 1, rowID: row)
        let e2 = makeEntry(idByte: 0x02, physicalTime: 2000, nodeID: 2, rowID: row)
        let a = GSetAuditLog(entries: [e1])
        let b = GSetAuditLog(entries: [e2])

        var aThenB = a
        aThenB.merge(b)
        var bThenA = b
        bThenA.merge(a)

        #expect(aThenB.count == bThenA.count)
        #expect(aThenB.orderedEntries == bThenA.orderedEntries)
    }

    @Test("merge is idempotent")
    func mergeIsIdempotent() {
        let e = makeEntry(idByte: 0x05, physicalTime: 1000, nodeID: 1, rowID: UUID())
        var log = GSetAuditLog(entries: [e])
        let copy = log
        log.merge(copy)
        #expect(log.count == 1)
    }

    @Test("orderedEntries are sorted by HLC")
    func orderedEntriesAreHLCSorted() {
        let row = UUID()
        let e1 = makeEntry(idByte: 0x01, physicalTime: 3000, nodeID: 1, rowID: row)
        let e2 = makeEntry(idByte: 0x02, physicalTime: 1000, nodeID: 1, rowID: row)
        let e3 = makeEntry(idByte: 0x03, physicalTime: 2000, nodeID: 1, rowID: row)
        let log = GSetAuditLog(entries: [e1, e2, e3])
        let ordered = log.orderedEntries
        #expect(ordered[0].hlc.physicalTime == 1000)
        #expect(ordered[1].hlc.physicalTime == 2000)
        #expect(ordered[2].hlc.physicalTime == 3000)
    }

    @Test("entries(since:) excludes the cutoff (strictly greater)")
    func entriesSinceExcludesCutoff() {
        let row = UUID()
        let e1 = makeEntry(idByte: 0x01, physicalTime: 1000, nodeID: 1, rowID: row)
        let e2 = makeEntry(idByte: 0x02, physicalTime: 2000, nodeID: 1, rowID: row)
        let e3 = makeEntry(idByte: 0x03, physicalTime: 3000, nodeID: 1, rowID: row)
        let log = GSetAuditLog(entries: [e1, e2, e3])
        let cutoff = HLC(physicalTime: 2000, logicalCount: 0, nodeID: 1)
        let since = log.entries(since: cutoff)
        #expect(since.count == 1)
        #expect(since[0].hlc.physicalTime == 3000)
    }

    @Test("AuditValue encodes to the externally-tagged single-key wire shape")
    func auditValueWireShape() throws {
        let data = try JSONEncoder().encode(AuditValue.integer(-1))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == "{\"integer\":-1}")
        let back = try JSONDecoder().decode(AuditValue.self, from: data)
        #expect(back == .integer(-1))
    }
}
