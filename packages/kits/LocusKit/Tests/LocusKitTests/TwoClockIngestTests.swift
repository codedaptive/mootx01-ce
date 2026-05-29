// TwoClockIngestTests.swift
//
// Mission ING-01. Verifies the two-clock separation: `filedAt` is the
// ingest instant (when the row entered the store, the CRDT/audit
// anchor), `eventTime` is when the thing happened or was authored in
// the world. For streaming capture the two coincide; for bulk
// historical ingestion the caller supplies `eventTime` explicitly.
//
// The eight tests cover: CaptureFrame threading (1, 2), persistence
// round-trip (3, 4), fingerprint correctness — captureWeekBucket keys
// off eventTime not filedAt (5, 6), and read-path backfill for rows
// that predate the column (7, 8). Backfill lives in the read path
// because the schema is declarative (LocusKitSchema): a row written
// without `eventTime` reads back with eventTime == filedAt.

import Testing
import Foundation
import PersistenceKit
@testable import LocusKit

@Suite("Two-clock ingest — event time vs ingest time (ING-01)")
struct TwoClockIngestTests {

    // A historical authorship date well before any plausible ingest
    // instant — a four-year-old document imported "today".
    private let historical = Date(timeIntervalSince1970: 0)

    /// Build a fresh estate on a unique temp path (mirrors
    /// EstateVerbTests.makeEstate).
    private func makeEstate() async throws -> Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-ing01-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        return try await Estate.create(storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner"))
    }

    private func frame(eventTime: Date? = nil) -> CaptureFrame {
        CaptureFrame(
            content: "imported message",
            channel: .importedFile,
            room: "inbox",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "importer",
            embeddingModelID: "minilm-v6",
            eventTime: eventTime
        )
    }

    // MARK: - 1, 2: CaptureFrame threading

    @Test("explicit eventTime is preserved; filedAt is the capture instant")
    func explicitEventTime() async throws {
        let estate = try await makeEstate()
        let before = Date()
        let drawer = try await estate.capture(frame(eventTime: historical))
        #expect(drawer.eventTime == historical)
        // filedAt is "now", distinct from the historical authorship date.
        #expect(drawer.filedAt >= before)
        #expect(drawer.filedAt.timeIntervalSince(historical) > 1_000_000)
    }

    @Test("nil eventTime defaults to the capture instant (≈ filedAt)")
    func nilEventTimeDefaultsToFiledAt() async throws {
        let estate = try await makeEstate()
        let drawer = try await estate.capture(frame(eventTime: nil))
        #expect(abs(drawer.eventTime.timeIntervalSince(drawer.filedAt)) < 1.0)
    }

    // MARK: - 3, 4: persistence round-trip

    @Test("eventTime round-trips through persistence intact")
    func eventTimeRoundTrips() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }
        let d = Drawer(content: "c", wing: "w", room: "r", addedBy: "a",
                       filedAt: Date(), eventTime: historical,
                       embeddingModelID: "m")
        try await store.addDrawer(d)
        let back = try #require(try await store.getDrawer(id: d.id))
        #expect(back.eventTime == historical)
    }

    @Test("both clocks are distinct and correct after round-trip")
    func bothClocksDistinctAfterRoundTrip() async throws {
        let (store, url) = try await TestStorage.makeStore()
        defer { TestStorage.cleanup(url) }
        let filed = Date()
        let d = Drawer(content: "c", wing: "w", room: "r", addedBy: "a",
                       filedAt: filed, eventTime: historical,
                       embeddingModelID: "m")
        try await store.addDrawer(d)
        let back = try #require(try await store.getDrawer(id: d.id))
        #expect(back.eventTime == historical)
        // filedAt survives as the recent ingest instant, not collapsed
        // onto eventTime.
        #expect(abs(back.filedAt.timeIntervalSince(filed)) < 1.0)
        #expect(back.filedAt != back.eventTime)
    }

    // MARK: - 5, 6: fingerprint keys off eventTime

    private func fpDrawer(filedAt: Date, eventTime: Date) -> Drawer {
        // Identical content / bitmaps / lineage / lattice across calls;
        // only the two clocks vary per test.
        Drawer(content: "same", wing: "w", room: "r", addedBy: "a",
               filedAt: filedAt, eventTime: eventTime, embeddingModelID: "m",
               lineageID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
               udcCode: "613.71", wikidataQID: "Q42")
    }

    @Test("different eventTime, identical content → different fingerprints")
    func differentEventTimeDifferentFingerprint() {
        let fam = EstateFingerprintFamilies(estateUUID: "11111111-1111-1111-1111-111111111111")
        let filed = Date(timeIntervalSince1970: 1_700_000_000)
        // Two event times in different capture-week buckets.
        let a = fpDrawer(filedAt: filed, eventTime: Date(timeIntervalSince1970: 1_580_000_000)) // 2020
        let b = fpDrawer(filedAt: filed, eventTime: Date(timeIntervalSince1970: 1_700_000_000)) // 2023
        #expect(fam.fingerprint(of: a) != fam.fingerprint(of: b))
    }

    @Test("same eventTime, different filedAt → identical fingerprints")
    func sameEventTimeIdenticalFingerprint() {
        let fam = EstateFingerprintFamilies(estateUUID: "11111111-1111-1111-1111-111111111111")
        let event = Date(timeIntervalSince1970: 1_600_000_000)
        // filedAt differs by years; the fingerprint must not move.
        let a = fpDrawer(filedAt: Date(timeIntervalSince1970: 1_600_000_000), eventTime: event)
        let b = fpDrawer(filedAt: Date(timeIntervalSince1970: 1_750_000_000), eventTime: event)
        #expect(fam.fingerprint(of: a) == fam.fingerprint(of: b))
    }

    // MARK: - 7, 8: read-path backfill for rows lacking eventTime

    /// Raw-inject a drawers row that omits `eventTime`, simulating a row
    /// written before the column existed. The column is nullable, so the
    /// insert succeeds with eventTime = NULL; drawerFromRow backfills.
    private func injectLegacyRow(_ storage: any Storage, id: String, filedAt: Date) async throws {
        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: [
                "id": .text(id),
                "content": .text("legacy content"),
                "wing": .text("w"),
                "room": .text("r"),
                "addedBy": .text("a"),
                "filedAt": .timestamp(filedAt),
                "embeddingModelID": .text("m")
                // eventTime intentionally omitted (pre-column row)
            ]
        )
    }

    @Test("opening a store over rows that lack eventTime succeeds")
    func legacyRowOpensWithoutError() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)
        let store = try await DrawerStore(storage: storage)
        try await injectLegacyRow(storage, id: "legacy-1", filedAt: Date())
        // Read back: no throw, row surfaces.
        let back = try await store.getDrawer(id: "legacy-1")
        #expect(back != nil)
    }

    @Test("rows lacking eventTime backfill to filedAt on read")
    func legacyRowBackfillsEventTimeToFiledAt() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)
        let store = try await DrawerStore(storage: storage)
        let filed = Date(timeIntervalSince1970: 1_650_000_000)
        try await injectLegacyRow(storage, id: "legacy-2", filedAt: filed)
        let back = try #require(try await store.getDrawer(id: "legacy-2"))
        #expect(back.eventTime == back.filedAt)
        #expect(abs(back.eventTime.timeIntervalSince(filed)) < 1.0)
    }
}
