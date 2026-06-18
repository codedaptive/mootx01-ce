import Foundation
import Testing
@testable import LocusKit
import SQLCipher

/// Persistence and migration coverage for the LOCI_V035_07B diary
/// `operationalBitmap` column per spec § 5.6.
///
/// Bit layout under test (per spec § 5.6, low-to-high):
///   bits 0–3   DiaryEventClass      (4 bits, contiguous, 12 cases)
///   bits 4–6   DiarySeverity        (3 bits, scale-gapped 0/2/4/6)
///   bits 7–9   DiaryActorClass      (3 bits, contiguous, 5 cases)
///   bits 10–12 DiaryBatchMembership (3 bits, contiguous, 4 cases)
///   bit  13    requiresFollowup     (1 bit, exclusive)
///
/// Mirrors `TunnelBitmapTests.swift`: SQLite-backed tests exercise the
/// round-trip through `DrawerStore.addDiaryEntry` / `getDiaryEntry`,
/// and a raw-SQLite fixture exercises the pre-07B migration path.
@Suite("DiaryBitmapTests")
struct DiaryBitmapTests {

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func freshStoreURL() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return base.appendingPathComponent("store.sqlite")
    }

    /// Composite fixture per mission spec § 5.6:
    ///   eventClass = .learn        (raw 6,  bits 0–3)   = 0x0006
    ///   severity   = .warning      (raw 4,  bits 4–6)   = 0x0040
    ///   actorClass = .mcpAgent     (raw 2,  bits 7–9)   = 0x0100
    ///   batch      = .batchMember  (raw 2,  bits 10–12) = 0x0800
    ///   followup   = true          (bit 13)             = 0x2000
    ///   operationalBitmap                               = 0x2946
    @Test("addDiaryEntry + getDiaryEntry round-trips operationalBitmap 0x2946 and all five accessors")
    func compositeBitmapSQLiteRoundTrip() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let original = DiaryEntry(
            id: "d-composite",
            agentName: "bilby",
            entry: "fixture",
            topic: "test",
            wing: "wing_bilby",
            room: "diary",
            filedAt: t(1_700_000_000),
            embeddingModelID: "test-model",
            operationalBitmap: 0x2946
        )
        try await store.addDiaryEntry(original)
        let loaded = try #require(try await store.getDiaryEntry(id: original.id))
        #expect(loaded.operationalBitmap == 0x2946)
        #expect(loaded.eventClass == .learn)
        #expect(loaded.severity == .warning)
        #expect(loaded.actorClass == .mcpAgent)
        #expect(loaded.batchMembership == .batchMember)
        #expect(loaded.requiresFollowup == true)
    }

    @Test("addDiaryEntry without operationalBitmap defaults to 0 and zero-case accessors")
    func defaultZeroPersistence() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let original = DiaryEntry(
            id: "d-default",
            agentName: "bilby",
            entry: "fixture",
            topic: "test",
            wing: "wing_bilby",
            room: "diary",
            filedAt: t(1_700_000_000),
            embeddingModelID: "test-model"
        )
        try await store.addDiaryEntry(original)
        let loaded = try #require(try await store.getDiaryEntry(id: original.id))
        #expect(loaded.operationalBitmap == 0)
        #expect(loaded.eventClass == .capture)
        #expect(loaded.severity == .trace)
        #expect(loaded.actorClass == .user)
        #expect(loaded.batchMembership == .standalone)
        #expect(loaded.requiresFollowup == false)
    }

    @Test("Migration adds operationalBitmap column to a pre-07B diary table")
    func preV07BMigrationRoundTrip() async throws {
        // Build a pre-07B diary schema by hand against a raw SQLite
        // handle, INSERT a legacy row, close, then reopen via
        // DrawerStore so the new ALTER guard runs its migration path.
        // Reading the row back must yield operationalBitmap = 0 (the
        // documented default for a backfilled row).
        let url = freshStoreURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        #expect(sqlite3_open_v2(url.path, &raw, flags, nil) == SQLITE_OK)
        defer { if let raw = raw { sqlite3_close_v2(raw) } }

        // Pre-07B schema — ten columns, no operationalBitmap.
        let createPreV07B = """
            CREATE TABLE diary (
                id TEXT PRIMARY KEY NOT NULL,
                agentName TEXT NOT NULL,
                entry TEXT NOT NULL,
                topic TEXT NOT NULL,
                wing TEXT NOT NULL,
                room TEXT NOT NULL,
                filedAt TEXT NOT NULL,
                embeddingModelID TEXT NOT NULL,
                tombstonedAt TEXT,
                removedByBatch TEXT
            )
            """
        #expect(sqlite3_exec(raw, createPreV07B, nil, nil, nil) == SQLITE_OK)

        let insertLegacy = """
            INSERT INTO diary
                (id, agentName, entry, topic, wing, room,
                 filedAt, embeddingModelID, tombstonedAt, removedByBatch)
            VALUES ('legacy', 'bilby', 'pre-07B row', 'test',
                    'wing_bilby', 'diary', '2026-01-01T00:00:00.000Z',
                    'test-model', NULL, NULL)
            """
        #expect(sqlite3_exec(raw, insertLegacy, nil, nil, nil) == SQLITE_OK)

        sqlite3_close_v2(raw)
        raw = nil

        // Reopen via DrawerStore — the new ALTER guard must add the
        // column and the legacy row must come back with operationalBitmap = 0.
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        let loaded = try #require(try await store.getDiaryEntry(id: "legacy"))
        #expect(loaded.operationalBitmap == 0)
        #expect(loaded.eventClass == .capture)
        #expect(loaded.severity == .trace)
    }

    @Test("DiarySeverity is Comparable for retrieval filters")
    func severityComparable() {
        // Confirms that the Comparable conformance composes the way
        // retrieval filters need it to: severity >= .warning excludes
        // .trace and .info but includes .warning and .error.
        #expect(DiarySeverity.warning > DiarySeverity.info)
        #expect(DiarySeverity.error >= DiarySeverity.warning)
        #expect(DiarySeverity.trace < DiarySeverity.warning)
    }
}
