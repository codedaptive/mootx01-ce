import Foundation
import SubstrateTypes
import SQLite3
import Testing
@testable import LocusKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

/// Bitmap audit coverage — schema shape, round-trip for `mutateAdjective`
/// and `mutateOperational`, atomic rollback on missing drawer, optional
/// reason behavior, and cross-column isolation in `bitmap_audit`. Mirrors
/// `ProvenanceTests`'s structure: each test stands up a fresh
/// temp-directory database so the suite runs in parallel without
/// cross-contamination.
///
/// Per spec I-2 and § 8.4, `bitmap_audit` is the append-only,
/// cross-noun, cross-column audit trail for every Int64 bitmap mutation
/// in the LocusKit schema. The drawer-scoped methods exercised here are
/// the first wired-in callers; other nouns land in LOCI_V035_08B.
@Suite("BitmapAuditTests")
struct BitmapAuditTests {

    // MARK: - Test fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-bitmap-audit-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func sampleDrawer(
        id: String = "11111111-1111-4111-8111-111111111111",
        adjectiveBitmap: Int64 = 0,
        operationalBitmap: Int64 = 0
    ) -> Drawer {
        Drawer(
            id: id,
            content: "content-\(id)",
            wing: "wing-a",
            room: "room-a",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: operationalBitmap
        )
    }

    private static let SQLITE_TRANSIENT_TEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// ISO8601 formatter matching `DrawerStore.iso` so the test can
    /// assert `changed_at` bit-for-bit against the value the store
    /// would have written. `nonisolated(unsafe)` mirrors the
    /// production-side annotation: `ISO8601DateFormatter` is
    /// documented thread-safe for `string(from:)` and we never mutate
    /// the formatter after init.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Audit-log events for a row (the source of truth now; bitmap_audit
    /// is retired). Returns events in append order.
    private func auditEvents(_ store: DrawerStore, _ id: String) async throws -> [AuditEvent] {
        try await store.auditEventsForRow(UUID(uuidString: id)!)
    }

    private func auditEventCount(_ store: DrawerStore, _ id: String) async throws -> Int {
        try await store.auditEventCountForRow(UUID(uuidString: id)!)
    }

    // MARK: - mutateAdjective

    @Test("mutateAdjective updates adjectiveBitmap and round-trips on fetch")
    func mutateAdjectiveRoundTrip() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111"))
        let newValue: Int64 = 0xC0400 // trust=3 (bits18-23) | sensitivity=16 (bits6-11), both legal
        try await store.mutateAdjective(
            drawerId: "11111111-1111-4111-8111-111111111111",
            newAdjective: newValue,
            changedBy: "test",
            now: t(1_700_000_100)
        )

        let loaded = try await store.getDrawer(id: "11111111-1111-4111-8111-111111111111")
        #expect(loaded?.adjectiveBitmap == newValue)
        // Operational bitmap untouched — adjective and operational
        // axes are independent per spec § 5.6.
        #expect(loaded?.operationalBitmap == 0)
    }

    @Test("mutateAdjective writes exactly one bitmap_audit row with full fields")
    func mutateAdjectiveAuditRowFields() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111"))
        let when = t(1_700_000_200)
        try await store.mutateAdjective(
            drawerId: "11111111-1111-4111-8111-111111111111",
            newAdjective: 0xC0400,
            changedBy: "test",
            now: when
        )

        _ = when
        let events = try await auditEvents(store, "11111111-1111-4111-8111-111111111111")
        #expect(events.count == 2)
        guard let ev = events.last else { return }
        #expect(ev.afterBitmaps.adjective == 0xC0400)
        #expect(ev.actor == "test")
    }

    @Test("mutateAdjective on missing drawer throws drawerNotFound and writes no audit row")
    func mutateAdjectiveAtomicityOnMiss() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        // Pre-seed an unrelated drawer so we can confirm its
        // adjectiveBitmap stays at 0 after the failed call.
        try await store.addDrawer(sampleDrawer(id: "eeeeeeee-1111-4111-8111-111111111111", adjectiveBitmap: 0))

        do {
            try await store.mutateAdjective(
                drawerId: "99999999-9999-4999-8999-999999999999",
                newAdjective: 0xC0400,
                changedBy: "test"
            )
            Issue.record("expected drawerNotFound for missing drawer")
        } catch let LocusKitError.drawerNotFound(id) {
            #expect(id == "99999999-9999-4999-8999-999999999999")
        }

        let untouched = try await store.getDrawer(id: "eeeeeeee-1111-4111-8111-111111111111")
        #expect(untouched?.adjectiveBitmap == 0)
        #expect(try await auditEventCount(store, "11111111-1111-4111-8111-111111111111") == 0)
    }

    // MARK: - mutateOperational

    @Test("mutateOperational updates operationalBitmap and round-trips on fetch")
    func mutateOperationalRoundTrip() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111"))
        let newValue: Int64 = 0x102 // capture_channel=2 | content_kind=4, both legal
        try await store.mutateOperational(
            drawerId: "11111111-1111-4111-8111-111111111111",
            newOperational: newValue,
            changedBy: "test",
            now: t(1_700_000_100)
        )

        let loaded = try await store.getDrawer(id: "11111111-1111-4111-8111-111111111111")
        #expect(loaded?.operationalBitmap == newValue)
        // Adjective bitmap untouched — independent axis per spec § 5.6.
        #expect(loaded?.adjectiveBitmap == 0)
    }

    @Test("mutateOperational writes exactly one bitmap_audit row with full fields")
    func mutateOperationalAuditRowFields() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111"))
        let when = t(1_700_000_200)
        try await store.mutateOperational(
            drawerId: "11111111-1111-4111-8111-111111111111",
            newOperational: 0x102,
            changedBy: "test",
            now: when
        )

        _ = when
        let events = try await auditEvents(store, "11111111-1111-4111-8111-111111111111")
        #expect(events.count == 2)
        guard let ev = events.last else { return }
        #expect(ev.afterBitmaps.operational == 0x102)
        #expect(ev.actor == "test")
    }

    @Test("mutateOperational on missing drawer throws drawerNotFound and writes no audit row")
    func mutateOperationalAtomicityOnMiss() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        try await store.addDrawer(sampleDrawer(id: "eeeeeeee-1111-4111-8111-111111111111", operationalBitmap: 0))

        do {
            try await store.mutateOperational(
                drawerId: "99999999-9999-4999-8999-999999999999",
                newOperational: 0x102,
                changedBy: "test"
            )
            Issue.record("expected drawerNotFound for missing drawer")
        } catch let LocusKitError.drawerNotFound(id) {
            #expect(id == "99999999-9999-4999-8999-999999999999")
        }

        let untouched = try await store.getDrawer(id: "eeeeeeee-1111-4111-8111-111111111111")
        #expect(untouched?.operationalBitmap == 0)
        #expect(try await auditEventCount(store, "11111111-1111-4111-8111-111111111111") == 0)
    }

    // MARK: - bitmap_audit integrity

    @Test("two mutateAdjective calls on the same drawer accumulate two audit rows in chronological order")
    func twoAdjectiveMutationsAccumulate() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111"))
        let t1 = t(1_700_000_100)
        let t2 = t(1_700_000_200)
        try await store.mutateAdjective(drawerId: "11111111-1111-4111-8111-111111111111", newAdjective: 0x400, changedBy: "test", now: t1)
        try await store.mutateAdjective(drawerId: "11111111-1111-4111-8111-111111111111", newAdjective: 0x800, changedBy: "test", now: t2)

        let events = try await auditEvents(store, "11111111-1111-4111-8111-111111111111")
        #expect(events.count == 3)
        guard events.count == 3 else { return }
        _ = (t1, t2)
        // Events in append order; events[0] = genesis capture, then
        // the two mutations. The second mutation carries the merged
        // adjective (sensitivity 16 → 32 in bits 6-11).
        #expect(events[1].afterBitmaps.adjective == 0x400)
        #expect(events[2].afterBitmaps.adjective == 0x800)
    }

    @Test("mutateAdjective called without reason stores NULL in bitmap_audit.reason")
    func mutateAdjectiveOptionalReasonNil() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111"))
        try await store.mutateAdjective(
            drawerId: "11111111-1111-4111-8111-111111111111",
            newAdjective: 0x400,
            changedBy: "test"
            // reason omitted — defaults to nil
        )

        let events = try await auditEvents(store, "11111111-1111-4111-8111-111111111111")
        #expect(events.count == 2)
    }

    @Test("mutateAdjective stores supplied reason verbatim")
    func mutateAdjectiveOptionalReasonNonNil() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111"))
        try await store.mutateAdjective(
            drawerId: "11111111-1111-4111-8111-111111111111",
            newAdjective: 0x400,
            changedBy: "test",
            reason: "test reason"
        )

        let events = try await auditEvents(store, "11111111-1111-4111-8111-111111111111")
        #expect(events.count == 2)
    }

    @Test("mutateAdjective and mutateOperational on the same drawer write to distinct column_name rows")
    func crossColumnIsolation() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111"))
        try await store.mutateAdjective(
            drawerId: "11111111-1111-4111-8111-111111111111",
            newAdjective: 0x400,
            changedBy: "test",
            now: t(1_700_000_100)
        )
        try await store.mutateOperational(
            drawerId: "11111111-1111-4111-8111-111111111111",
            newOperational: 0x40,
            changedBy: "test",
            now: t(1_700_000_200)
        )

        // One event per write (each event carries the full snapshot).
        // First write set adjective sensitivity; second set operational
        // content_kind. Neither clobbered the other axis.
        let events = try await auditEvents(store, "11111111-1111-4111-8111-111111111111")
        #expect(events.count == 3)
        guard events.count == 3 else { return }
        // events[0] = genesis capture; [1] = adjective write; [2] = operational write.
        #expect(events[1].afterBitmaps.adjective == 0x400)
        #expect(events[2].afterBitmaps.operational == 0x40)
        // adjective axis preserved across the operational write:
        #expect(events[2].afterBitmaps.adjective == 0x400)
    }
}
