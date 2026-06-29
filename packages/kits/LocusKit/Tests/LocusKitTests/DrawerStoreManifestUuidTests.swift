// DrawerStoreManifestUuidTests.swift
//
// P1-7: the estate-uuid manifest value drives both the store's stamping
// identity and the HLC maker node id. Two cases that look the same to a
// naive reader MUST be distinguished:
//
//   • ABSENT manifest value (a fresh estate whose estate_uuid row was
//     never written) is legitimate. Opening derives a fresh identity and
//     a node id of 0 — no error.
//   • PRESENT-but-malformed UUID (a non-parseable persisted value) is
//     data corruption. Opening MUST fail loud with
//     LocusKitError.corruptStoredValue — never collapse to node 0 or a
//     random UUID, which would silently mask the corruption.
//
// Conflating the two (the original bug: both returned node 0 / a random
// UUID) hides corruption behind the fresh-estate path. These tests pin
// the distinction at the public open boundary. Parity: the Rust port's
// `estate_uuid_{valid_persisted,absent,corrupt}_*` tests in
// drawer_store_inmemory.rs.
//
// Strategy mirrors DrawerCorruptReadBackTests: open via the public store
// API, let it go out of scope (WAL checkpoint), mutate the manifest row
// directly via raw SQLite (bypassing the kit codec), reopen, assert.

import Foundation
import Testing
import SQLite3
@testable import LocusKit
import PersistenceKit
import SubstrateTypes

// MARK: - Helpers

/// Execute a raw SQL statement against a SQLite file, bypassing the kit.
/// Used exclusively to seed absent / corrupt manifest values for the
/// negative-path tests.
private func rawExecManifest(_ url: URL, _ sql: String) throws {
    var db: OpaquePointer?
    let rc = sqlite3_open(url.path, &db)
    defer { sqlite3_close(db) }
    guard rc == SQLITE_OK, let db else {
        throw LocusKitError.sqliteError("rawExec open failed rc=\(rc)")
    }
    var errMsg: UnsafeMutablePointer<CChar>?
    let rc2 = sqlite3_exec(db, sql, nil, nil, &errMsg)
    if rc2 != SQLITE_OK {
        let msg = errMsg.map { String(cString: $0) } ?? "exec failed"
        sqlite3_free(errMsg)
        throw LocusKitError.sqliteError(msg)
    }
}

private func t(_ epoch: TimeInterval) -> Date {
    Date(timeIntervalSince1970: epoch)
}

private func sampleDrawer(id: String) -> Drawer {
    Drawer(
        id: TestStorage.tid(id),
        content: "manifest-uuid test content",
        parentNodeId: "test-parent",
        addedBy: "test",
        filedAt: t(1_700_000_000),
        embeddingModelID: "test-v1",
        lineageID: UUID()
    )
}

/// Read the manifest `estate_uuid` value directly from the file via raw
/// SQLite, so a test can compute the expected maker node id from the
/// exact stored bytes (the same bytes the production path hashes).
private func readManifestEstateUuid(_ url: URL) throws -> String {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw LocusKitError.sqliteError("readManifest open failed")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "SELECT \"value\" FROM \"manifest\" WHERE \"key\" = 'estate_uuid'"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw LocusKitError.sqliteError("readManifest prepare failed")
    }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else {
        throw LocusKitError.sqliteError("readManifest no estate_uuid row")
    }
    return String(cString: c)
}

/// The expected maker node id for a persisted estate-uuid string: FNV-1a
/// 32-bit of the raw stored text, masked to a non-negative Int32. This is
/// exactly the expression DrawerStore.makerNodeID(for:) evaluates and the
/// Rust port's DrawerStoreCore::maker_node_id evaluates on identical bytes.
private func expectedMakerNodeID(_ storedText: String) -> Int32 {
    Int32(bitPattern: FNV.hash32(storedText) & 0x7FFF_FFFF)
}

// MARK: - Tests

@Suite("DrawerStore estate_uuid manifest classification (P1-7)")
struct DrawerStoreManifestUuidTests {

    /// VALID persisted UUID → the correct, stable maker node id is
    /// derived and stamped into audit events; it is never 0.
    @Test("valid persisted estate_uuid derives the correct, non-zero node id")
    func validPersistedDerivesCorrectNodeID() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }

        // First open writes a valid estate_uuid into the manifest.
        do {
            let store = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store.addDrawer(sampleDrawer(id: "valid-d1"), now: t(1_700_000_000))
        }

        let storedUuid = try readManifestEstateUuid(url)
        let expectedNode = expectedMakerNodeID(storedUuid)
        // A genuine persisted uuid never hashes to the fresh-estate node 0.
        #expect(expectedNode != 0)

        // Reopen (top mode → derive maker node id from the persisted uuid)
        // and add a drawer so a genesis audit event carries the node id.
        let store2 = try await TestStorage.openStore(url)
        let drawerID = TestStorage.tid("valid-d2")
        try await store2.addDrawer(sampleDrawer(id: "valid-d2"), now: t(1_700_000_100))
        let events = try await store2.auditEventsForRow(UUID(uuidString: drawerID)!)
        let genesis = try #require(events.first)
        // The audit HLC round-trips through the 8-bit packed node field
        // (HLC.packed keeps only the low byte of nodeID, recovered as a
        // signed Int8). So the read-back node id is the low byte of the
        // full maker node id, not the full 31-bit value. Assert against
        // that truncation — proving the stamped id is derived from the
        // persisted uuid (stable, deterministic) and not the fresh node 0.
        // `expectedNode != 0` is asserted above on the full 31-bit value;
        // here we confirm the stamped (truncated) id matches that exact
        // derivation, so the node id provably came from the persisted uuid.
        let expectedLowByte = Int32(Int8(truncatingIfNeeded: expectedNode))
        #expect(genesis.hlc.nodeID == expectedLowByte)
    }

    /// ABSENT manifest value (fresh estate, row never written) → opening
    /// succeeds with no error and the store is fully usable. The legitimate
    /// fresh path: absence is NOT treated as corruption.
    @Test("absent estate_uuid opens a fresh estate OK — no throw")
    func absentOpensFreshNoThrow() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }

        // First open seeds the manifest.
        do {
            _ = try await DrawerStore(storage: TestStorage.sqlite(url))
        }
        // Delete the estate_uuid row so the value is genuinely absent —
        // an unseeded manifest, the legitimate fresh-estate condition.
        try rawExecManifest(url, """
            DELETE FROM "manifest" WHERE "key" = 'estate_uuid'
            """)

        // Reopen MUST NOT throw. populate re-seeds a fresh estate_uuid and
        // classification reports a legitimate fresh estate (not corruption).
        let store2 = try await TestStorage.openStore(url)
        // Store is fully usable: a write through the gated path succeeds.
        let drawerID = TestStorage.tid("absent-d1")
        try await store2.addDrawer(sampleDrawer(id: "absent-d1"), now: t(1_700_000_200))
        let got = try await store2.getDrawer(id: drawerID)
        #expect(got != nil)
    }

    /// PRESENT-but-malformed UUID (data corruption) → opening fails loud
    /// with corruptStoredValue. NOT node 0, NOT a random UUID, NOT silent.
    @Test("corrupt persisted estate_uuid fails loud on open — not node 0 / random UUID")
    func corruptFailsLoud() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }

        // First open seeds a valid estate_uuid.
        do {
            _ = try await DrawerStore(storage: TestStorage.sqlite(url))
        }
        // Corrupt the persisted value in place (non-parseable text).
        try rawExecManifest(url, """
            UPDATE "manifest" SET "value" = 'not-a-uuid' WHERE "key" = 'estate_uuid'
            """)

        // Reopen MUST throw the SPECIFIC corruption error — a catch-all
        // would also pass on a wrong error type, proving less than the
        // contract. The open must NOT collapse to a fabricated default.
        await #expect(throws: LocusKitError.corruptStoredValue(
            table: "manifest",
            column: "estate_uuid",
            storedText: "not-a-uuid"
        )) {
            _ = try await TestStorage.openStore(url)
        }
    }
}
