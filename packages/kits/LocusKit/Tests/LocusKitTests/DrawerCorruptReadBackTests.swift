// DrawerCorruptReadBackTests.swift
//
// Verifies that DrawerStore throws LocusKitError.corruptStoredValue when
// a stored TEXT value in a required column cannot be parsed to its declared
// type (UUID or ISO 8601 timestamp).
//
// Strategy: write a valid drawer via the public DrawerStore API, let the
// store go out of scope so the WAL is checkpointed, corrupt the stored value
// directly via a raw SQLite UPDATE (bypassing the kit's codec), reopen the
// store, then assert the structured error — never a silently wrong value
// (random UUID, epoch-0 date, fabricated tombstone).
//
// INTENTIONAL CONTRACT (not under test here — those are correct behaviour):
//   - Empty-string lineageID yields a fresh UUID (the "unset" sentinel).
//   - .text/.int type-tolerant decode of VALID values stays non-throwing.
// Only parse-failure fabrication is under test.

import Foundation
import Testing
import SQLite3
@testable import LocusKit
import PersistenceKit

// MARK: - Helpers

/// Execute a raw SQL statement against a SQLite file, bypassing the kit.
/// Used exclusively to corrupt stored values for negative-path testing.
private func rawExec(_ url: URL, _ sql: String) throws {
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

private func sampleDrawer(id: String, lineageID: UUID? = nil) -> Drawer {
    Drawer(
        id: TestStorage.tid(id),
        content: "corrupt read-back test content",
        parentNodeId: "test-parent",
        addedBy: "test",
        filedAt: t(1_700_000_000),
        embeddingModelID: "test-v1",
        lineageID: lineageID ?? UUID()
    )
}

// MARK: - lineageID corruption tests

@Suite("DrawerStore corrupt lineageID read-back")
struct DrawerCorruptLineageIDReadBackTests {

    @Test("corrupt non-empty lineageID TEXT throws corruptStoredValue, not random UUID")
    func corruptLineageIDThrows() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }

        let drawerID = TestStorage.tid("lineage-corrupt-d1")
        // Write via store, then let store go out of scope (WAL checkpoint).
        do {
            let store = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store.addDrawer(sampleDrawer(id: "lineage-corrupt-d1"),
                                      now: t(1_700_000_000))
            // Verify clean round-trip before corruption.
            let clean = try await store.getDrawer(id: drawerID)
            #expect(clean != nil)
        }

        // Store is out of scope — WAL checkpointed. Corrupt the lineageID.
        try rawExec(url, """
            UPDATE "drawers" SET "lineageID" = 'NOT-A-UUID'
            WHERE "id" = '\(drawerID)'
            """)

        // Reopen and attempt read-back — must throw, not silently substitute.
        let store2 = try await TestStorage.openStore(url)
        await #expect(throws: LocusKitError.corruptStoredValue(
            table: "drawers",
            column: "lineageID",
            storedText: "NOT-A-UUID"
        )) {
            _ = try await store2.getDrawer(id: drawerID)
        }
    }

    @Test("empty-string lineageID is the intentional unset sentinel — does not throw")
    func emptyLineageIDYieldsFreshUUID() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }

        let drawerID = TestStorage.tid("lineage-empty-d2")
        do {
            let store = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store.addDrawer(sampleDrawer(id: "lineage-empty-d2"),
                                      now: t(1_700_000_000))
        }

        // Force lineageID to empty string — the documented "unset" sentinel
        // that becomes a fresh per-row UUID on read-back (intentional contract).
        try rawExec(url, """
            UPDATE "drawers" SET "lineageID" = ''
            WHERE "id" = '\(drawerID)'
            """)

        let store2 = try await TestStorage.openStore(url)
        // Must not throw; the resulting drawer has a fresh (non-nil) UUID.
        let d = try await store2.getDrawer(id: drawerID)
        let lineage = try #require(d?.lineageID)
        // A fresh UUID is never the nil UUID (all-zeros).
        #expect(lineage != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    }

    @Test("valid UUID lineageID round-trips without throwing")
    func validLineageIDRoundTrips() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }

        let fixedLineage = UUID()
        let drawerID = TestStorage.tid("lineage-valid-d3")
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        try await store.addDrawer(sampleDrawer(id: "lineage-valid-d3",
                                               lineageID: fixedLineage),
                                  now: t(1_700_000_000))
        let d = try await store.getDrawer(id: drawerID)
        #expect(d?.lineageID == fixedLineage)
    }
}

// MARK: - filedAt / date corruption tests

@Suite("DrawerStore corrupt filedAt read-back")
struct DrawerCorruptFiledAtReadBackTests {

    @Test("corrupt filedAt TEXT surfaces a fail-loud error, not epoch-0")
    func corruptFiledAtNotFabricated() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }

        let drawerID = TestStorage.tid("filedat-corrupt-d1")
        do {
            let store = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store.addDrawer(sampleDrawer(id: "filedat-corrupt-d1"),
                                      now: t(1_700_000_000))
        }

        // Corrupt filedAt with a non-empty, non-ISO8601 string.
        // filedAt is declared ColumnType.timestamp; PersistenceKit's
        // readColumn throws StorageError.corruptStoredValue before the row
        // reaches drawerFromRow — the caller sees a fail-loud error, not
        // a silently fabricated epoch-0 date.
        try rawExec(url, """
            UPDATE "drawers" SET "filedAt" = 'NOT-A-DATE'
            WHERE "id" = '\(drawerID)'
            """)

        let store2 = try await TestStorage.openStore(url)
        // The read must fail loudly with the SPECIFIC corruption error — a
        // catch-all here would also pass on a nil return or a wrong error type,
        // proving less than the contract (Adams post-flight finding #1).
        await #expect(throws: StorageError.corruptStoredValue(
            table: "drawers",
            column: "filedAt",
            storedText: "NOT-A-DATE"
        )) {
            _ = try await store2.getDrawer(id: drawerID)
        }
    }

    @Test("corrupt tombstonedAt TEXT surfaces a fail-loud error, not epoch-0 tombstone")
    func corruptTombstonedAtNotFabricated() async throws {
        // tombstonedAt is declared ColumnType.timestamp in the schema; PersistenceKit's
        // readColumn throws StorageError.corruptStoredValue before the row reaches
        // optDate(). A corrupt tombstonedAt must surface as an error — never silently
        // become Date(timeIntervalSince1970: 0), which would fabricate a real
        // 1970-01-01 tombstone date that misrepresents the drawer's state.
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }

        let drawerID = TestStorage.tid("tombstone-corrupt-d1")
        do {
            let store = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store.addDrawer(sampleDrawer(id: "tombstone-corrupt-d1"),
                                      now: t(1_700_000_000))
            let live = try await store.getDrawer(id: drawerID)
            #expect(live?.tombstonedAt == nil)
        }

        // Corrupt tombstonedAt with a non-empty, non-ISO8601 string.
        try rawExec(url, """
            UPDATE "drawers" SET "tombstonedAt" = 'NOT-A-DATE'
            WHERE "id" = '\(drawerID)'
            """)

        let store2 = try await TestStorage.openStore(url)
        // The read must fail loudly with the SPECIFIC corruption error (see
        // corruptFiledAtNotFabricated above; Adams post-flight finding #1).
        await #expect(throws: StorageError.corruptStoredValue(
            table: "drawers",
            column: "tombstonedAt",
            storedText: "NOT-A-DATE"
        )) {
            _ = try await store2.getDrawer(id: drawerID)
        }
    }

    @Test("valid filedAt round-trips without fabrication")
    func validFiledAtRoundTrips() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }

        let now = t(1_700_000_000)
        let drawerID = TestStorage.tid("filedat-valid-d1")
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        try await store.addDrawer(sampleDrawer(id: "filedat-valid-d1"), now: now)
        let d = try await store.getDrawer(id: drawerID)
        // filedAt must round-trip within ISO8601 millisecond precision.
        let diff = abs(d!.filedAt.timeIntervalSince(now))
        #expect(diff < 0.001)
    }
}
