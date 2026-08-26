import Foundation
import PersistenceKit
import SubstrateTypes
import Testing
@testable import LocusKit

/// A2/A3 audit markers (benchmark reset 2026-08-13).
///
/// A2: `appendEncodeCompleteMarker` seals ONE informational audit event per
/// encode drain unit — verb `encodeComplete`, actor `encode_worker`,
/// `reason: "session=<id> rows=<n>"` — anchored on the unit's first drawer,
/// with before == after bitmaps (nothing mutates; no AuditGate involvement).
/// This is the encode-END timestamp finding P2 said the audit log lacked:
/// INGEST time becomes derivable as (marker HLC − capture HLC).
///
/// A3: `appendDreamCycleMarker` brackets a dream cycle with `dreamStart` /
/// `dreamEnd` events anchored on the ESTATE row id, both carrying the same
/// session id, so CYCLE-dreamt time is attributable from the audit log alone.
///
/// The Rust suite `encode_marker_tests` mirrors this file case-for-case
/// (twin-parity gate).
@Suite("EncodeMarkerTests")
struct EncodeMarkerTests {

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-marker-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func makeStore() async throws -> (DrawerStore, URL) {
        let url = makeTempURL()
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    private func sampleDrawer(id: String = "m1") -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "Marker test content: one drawer standing in for a drain unit.",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
    }

    // MARK: - A2 encode-completion marker

    @Test("encode marker seals verb/actor/reason on the anchor row")
    func encodeMarkerSealsEvent() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        let rowID = try #require(UUID(uuidString: d.id))
        let before = try await store.auditEventsForRow(rowID).count

        try await store.appendEncodeCompleteMarker(
            drawerId: d.id,
            rowCount: 37,
            unitSessionID: "unit-abc",
            at: t(1_700_000_100))

        let events = try await store.auditEventsForRow(rowID)
        #expect(events.count == before + 1)
        let marker = try #require(events.last)
        #expect(marker.verb == DrawerStore.encodeCompleteVerb)
        #expect(marker.actor == DrawerStore.encodeWorkerActor)
        #expect(marker.reason == "session=unit-abc rows=37")
        // Informational event: nothing mutates, so before == after.
        #expect(marker.beforeBitmaps?.adjective == marker.afterBitmaps.adjective)
        #expect(marker.beforeBitmaps?.operational == marker.afterBitmaps.operational)
        #expect(marker.beforeBitmaps?.provenance == marker.afterBitmaps.provenance)
    }

    @Test("encode marker on an absent drawer is a silent no-op")
    func encodeMarkerAbsentRowNoOp() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        // Valid UUID, no such row: must not throw, must not seal an event —
        // the drawer may be expunged between encode completion and the
        // marker write, and a marker must never fail the drain worker.
        let ghost = UUID().uuidString
        try await store.appendEncodeCompleteMarker(
            drawerId: ghost, rowCount: 1, unitSessionID: "unit-x", at: t(1_700_000_200))
        let events = try await store.auditEventsForRow(try #require(UUID(uuidString: ghost)))
        #expect(events.isEmpty)
    }

    @Test("encode marker refuses an empty session id")
    func encodeMarkerEmptySessionRefused() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer(id: "m2")
        try await store.addDrawer(d)
        await #expect(throws: LocusKitError.self) {
            try await store.appendEncodeCompleteMarker(
                drawerId: d.id, rowCount: 1, unitSessionID: "", at: t(1_700_000_300))
        }
    }

    // MARK: - A3 dream-cycle bracket markers

    @Test("dream brackets share a session id on the estate anchor row")
    func dreamBracketsShareSession() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let estateRow = await store.estateUuid

        try await store.appendDreamCycleMarker(
            phase: .start, unitSessionID: "cycle-7", at: t(1_700_001_000))
        try await store.appendDreamCycleMarker(
            phase: .end, unitSessionID: "cycle-7", at: t(1_700_001_060))

        let events = try await store.auditEventsForRow(estateRow)
        let brackets = events.filter { $0.reason == "session=cycle-7" }
        #expect(brackets.count == 2)
        #expect(brackets.first?.verb == DrawerStore.DreamCyclePhase.start.rawValue)
        #expect(brackets.last?.verb == DrawerStore.DreamCyclePhase.end.rawValue)
        #expect(brackets.allSatisfy { $0.actor == "dreaming_daemon" })
        // Start precedes end under HLC ordering — asserted via the array
        // order (auditEventsForRow returns HLC-ascending). physicalTime alone
        // is NOT comparable here: the store HLC's max(physical, last)
        // semantics can collapse both markers onto one physical instant with
        // a logical tie-break when the injected `now` sits behind the clock.
    }

    // MARK: - C3 reindex-completion marker

    @Test("reindex marker seals verb/actor/reason on the estate row")
    func reindexMarkerSealsEventOnEstateRow() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let estateRow = await store.estateUuid

        try await store.appendReindexCompleteMarker(
            rowCount: 512, unitSessionID: "reindex-9", at: t(1_700_002_000))

        let events = try await store.auditEventsForRow(estateRow)
        let marker = try #require(events.last)
        #expect(marker.verb == "reindexComplete")
        #expect(marker.actor == "reindex_worker")
        #expect(marker.reason == "session=reindex-9 rows=512")
        // Informational event: nothing mutates, so before == after.
        #expect(marker.beforeBitmaps?.adjective == marker.afterBitmaps.adjective)
        #expect(marker.beforeBitmaps?.operational == marker.afterBitmaps.operational)
        #expect(marker.beforeBitmaps?.provenance == marker.afterBitmaps.provenance)
    }

    @Test("reindex marker refuses an empty session id")
    func reindexMarkerEmptySessionRefused() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        await #expect(throws: LocusKitError.self) {
            try await store.appendReindexCompleteMarker(
                rowCount: 1, unitSessionID: "", at: t(1_700_002_100))
        }
    }
}
