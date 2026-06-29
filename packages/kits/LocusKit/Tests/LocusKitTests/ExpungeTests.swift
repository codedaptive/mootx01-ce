import Foundation
import SQLite3
import SubstrateTypes
import Testing
@testable import LocusKit

/// Expunge verb coverage (cookbook §10.5 + §9.5.1, F17 second pass
/// item 1). Two layers under test:
///
///   1. `DrawerStore.expungeGated` — the gated storage-layer body.
///      Tombstones the state through `AuditGate.admit` with TWO
///      FieldWrites (state slot → 33, flags slot → preserve 24-25 |
///      set bit 26), zeros the content blob, stamps `tombstonedAt`,
///      and appends one sealed audit event in a single transaction.
///   2. `Estate.expunge` — the verb wrapper. Confirmation gate,
///      drawerNotFound, forwards to `DrawerStore.expungeGated`.
///
/// What's NOT covered here:
///   - Cross-kit RAG vector delete (F17 second pass item 4, GLK lane)
///   - Estate-level `expunge_allowed` toggle + immutability (item 2,
///     cookbook design pass pending)
///   - Dreaming-pass worklist drainer that clears bit 26 (item 3)
///   - Aggregates exemption assertions (per §9.5.1 they are not
///     touched; no roll-up state exists in these fixtures to assert
///     against either way)
@Suite("ExpungeTests")
struct ExpungeTests {

    // MARK: - Fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-expunge-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func makeEstate() async throws -> (Estate, URL) {
        let url = makeTempURL()
        let estate = try await Estate.create(
            storage: TestStorage.sqlite(url),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
        return (estate, url)
    }

    static let idActive    = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    static let idAccepted  = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    static let idAbsent    = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    private func sampleDrawer(
        id: String = idActive,
        adjectiveBitmap: Int64 = 0
    ) -> Drawer {
        Drawer(
            id: id,
            content: "content-\(id)",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: 0
        )
    }

    private func auditEventCount(_ store: DrawerStore, _ id: String) async throws -> Int {
        let uuid = UUID(uuidString: id)!
        return try await store.auditEventCountForRow(uuid)
    }

    // MARK: - DrawerStore.expungeGated happy path

    @Test("expungeGated: active row → tombstoned + bit 26 set + content zeroed + tombstonedAt set + audit event appended")
    func expungeGatedHappyPath() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        try await store.addDrawer(sampleDrawer(id: Self.idActive))

        // Before: active, content non-empty, no tombstone, bit 26 clear.
        let before = try await store.getDrawer(id: Self.idActive)
        #expect(before?.state == .active)
        #expect(before?.content == "content-\(Self.idActive)")
        #expect(before?.tombstonedAt == nil)
        #expect(before?.dreamingRecalcRequired == false)
        let countBefore = try await auditEventCount(store, Self.idActive)
        #expect(countBefore == 1)  // genesis capture event

        try await store.expungeGated(
            drawerId: Self.idActive,
            changedBy: "test",
            reason: "GDPR delete request 2026-05-29",
            now: t(1_700_000_500)
        )

        let after = try await store.getDrawer(id: Self.idActive)
        #expect(after?.state == .tombstoned)
        #expect(after?.content == "")
        #expect(after?.tombstonedAt != nil)
        #expect(after?.dreamingRecalcRequired == true)
        let countAfter = try await auditEventCount(store, Self.idActive)
        #expect(countAfter == 2)  // genesis + expunge event
    }

    @Test("expungeGated: bits 24 and 25 of prior flags are preserved when bit 26 is set")
    func expungeGatedPreservesOtherFlagBits() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        // Capture an active row with bit 24 (state_extension) and bit 25
        // (lineage_clustering) already set. Expunge must preserve both
        // and add bit 26 on top.
        let withFlags: Int64 = (1 << 24) | (1 << 25)
        try await store.addDrawer(sampleDrawer(id: Self.idActive, adjectiveBitmap: withFlags))

        try await store.expungeGated(
            drawerId: Self.idActive,
            changedBy: "test",
            reason: nil,
            now: t(1_700_000_500)
        )
        let after = try await store.getDrawer(id: Self.idActive)
        let postBitmap = after?.adjectiveBitmap ?? 0
        // Bits 24, 25, and 26 all set.
        #expect(postBitmap & (1 << 24) != 0)
        #expect(postBitmap & (1 << 25) != 0)
        #expect(postBitmap & (1 << 26) != 0)
        #expect(after?.dreamingRecalcRequired == true)
    }

    // MARK: - DrawerStore.expungeGated rejection paths

    @Test("expungeGated: accepted row is refused (S-3: audit-grade rows survive intact)")
    func expungeGatedRejectsAccepted() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        // Capture as active with trust=canonical baked in (raw 3 at
        // shift 18 = 3 << 18 = 0x0C0000). S-1 (cookbook §9.5) requires
        // accepted rows to have trust >= canonical, so the promote
        // transition would otherwise be refused with a basisViolation.
        try await store.addDrawer(sampleDrawer(id: Self.idAccepted, adjectiveBitmap: 3 << 18))
        try await store.mutateState(
            drawerId: Self.idAccepted,
            to: .accepted,
            via: .promote,
            changedBy: "test",
            now: t(1_700_000_100)
        )
        let mid = try await store.getDrawer(id: Self.idAccepted)
        #expect(mid?.state == .accepted)

        // Expunge of an accepted row: S-3 forbids the transition.
        // RowStateAutomaton.transitions has no key (.accepted, .tombstone),
        // so the gate's verb-state-consistency check throws.
        await #expect(throws: LocusKitError.self) {
            try await store.expungeGated(
                drawerId: Self.idAccepted,
                changedBy: "test",
                reason: nil,
                now: t(1_700_000_200)
            )
        }

        // State unchanged; audit log gained no extra event from the refused write.
        let after = try await store.getDrawer(id: Self.idAccepted)
        #expect(after?.state == .accepted)
        #expect(after?.dreamingRecalcRequired == false)
        let count = try await auditEventCount(store, Self.idAccepted)
        #expect(count == 2)  // capture + promote, no expunge
    }

    @Test("expungeGated: non-existent row throws drawerNotFound")
    func expungeGatedRejectsAbsent() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        await #expect(throws: LocusKitError.self) {
            try await store.expungeGated(
                drawerId: Self.idAbsent,
                changedBy: "test",
                reason: nil,
                now: t(1_700_000_100)
            )
        }
    }

    // MARK: - Estate.expunge wrapper

    @Test("Estate.expunge: confirmation=false throws before any storage interaction")
    func estateExpungeRequiresConfirmation() async throws {
        let (estate, _) = try await makeEstate()
        let frame = CaptureFrame(
            content: "test content",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        let drawer = try await estate.capture(frame)

        await #expect(throws: LocusKitError.self) {
            try await estate.expunge(rowID: drawer.id, reason: "", confirmation: false)
        }
        // Row unchanged — hit the store directly to verify state.
        let after = try await estate.store.getDrawer(id: drawer.id)
        #expect(after?.state == .active)
        #expect(after?.dreamingRecalcRequired == false)
        #expect(after?.content == "test content")
    }

    @Test("Estate.expunge: confirmation=true forwards through to the gated path")
    func estateExpungeForwardsToStore() async throws {
        let (estate, _) = try await makeEstate()
        let frame = CaptureFrame(
            content: "test content",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        let drawer = try await estate.capture(frame)

        try await estate.expunge(
            rowID: drawer.id,
            reason: "operator request",
            confirmation: true
        )
        // The row is still readable through the unfiltered recall path,
        // but its state is now tombstoned with bit 26 set and content
        // zeroed. (Cluster-A filtering at the recall layer excludes
        // tombstoned rows; we go through the store directly to verify.)
        let after = try await estate.store.getDrawer(id: drawer.id)
        #expect(after?.state == .tombstoned)
        #expect(after?.dreamingRecalcRequired == true)
        #expect(after?.content == "")
    }

    @Test("Estate.expunge: non-existent row throws drawerNotFound")
    func estateExpungeRejectsAbsent() async throws {
        let (estate, _) = try await makeEstate()
        await #expect(throws: LocusKitError.self) {
            try await estate.expunge(rowID: Self.idAbsent, reason: "", confirmation: true)
        }
    }

    // MARK: - One-door SQLite round-trip (tombstonedAt must survive reload)

    /// SQLite-backed round-trip: expunge a drawer, close and reopen the store,
    /// reload via getDrawer, and assert that tombstonedAt is NON-nil with the
    /// exact timestamp value that was passed to expungeGated.
    ///
    /// This test is the regression guard for the one-door violation that was
    /// previously present in expungeGated: using a bare ISO8601DateFormatter()
    /// (no canonical door) produced a string that, if read by a strict
    /// fractional-seconds parser, would decode as nil. The fix writes
    /// TypedValue.timestamp(now) through the canonical PersistenceKit path,
    /// which serialises with fractional seconds and round-trips cleanly.
    ///
    /// The test uses a SQLite backend (NOT InMemory) because InMemory keeps the
    /// TypedValue in memory and never exercises the serialise/parse path. The
    /// bug only manifests on the serialise→parse round-trip through the SQLite
    /// TEXT column.
    @Test("tombstonedAt round-trips through SQLite: non-nil with exact value after store reopen")
    func tombstonedAtRoundTripsSQLite() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let expungeNow = t(1_700_001_000)

        // Write and expunge in one store lifetime, then let it go out of scope
        // so the WAL is checkpointed to the main file.
        do {
            let store = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store.addDrawer(sampleDrawer(id: Self.idActive))
            try await store.expungeGated(
                drawerId: Self.idActive,
                changedBy: "round-trip-test",
                reason: "one-door test",
                now: expungeNow
            )
            // Verify within the same store lifetime (baseline — no serialisation path).
            let withinLifetime = try await store.getDrawer(id: Self.idActive)
            #expect(withinLifetime?.tombstonedAt != nil, "tombstonedAt must be non-nil within same store lifetime")
        }

        // Reopen the store — this exercises the full serialise→read path through
        // the SQLite backend. Any format mismatch would surface here as nil.
        let store2 = try await TestStorage.openStore(url)
        let reloaded = try await store2.getDrawer(id: Self.idActive)
        #expect(reloaded != nil, "expunged drawer must be readable after store reopen")
        // The key assertion: tombstonedAt must survive the serialise/parse round-trip.
        guard let reloadedDate = reloaded?.tombstonedAt else {
            Issue.record("tombstonedAt is nil after SQLite round-trip — one-door violation: expungeGated must write TypedValue.timestamp(now), not a raw ISO8601DateFormatter string")
            return
        }
        // Timestamps round-trip through ISO-8601 with fractional-second precision
        // (0.001 s). Allow a 1 ms tolerance to absorb any sub-millisecond truncation.
        #expect(abs(reloadedDate.timeIntervalSince(expungeNow)) < 0.001,
                "tombstonedAt must survive the SQLite round-trip with the exact value passed to expungeGated")
    }

    /// allDrawers + tombstonedAt == nil filter correctly excludes expunged rows
    /// after a SQLite round-trip. This is the EstateVerbs.swift:675 pattern:
    /// .filter { $0.tombstonedAt == nil } is the Swift-layer live-row gate.
    /// If tombstonedAt decoded as nil on a tombstoned row, expunged rows would
    /// pass this filter and appear as live recall candidates — the silent data
    /// integrity failure the one-door fix prevents.
    @Test("tombstonedAt == nil filter excludes expunged rows after SQLite round-trip")
    func tombstonedAtFilterExcludesExpungedAfterRoundTrip() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let liveId   = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let expungeId = Self.idActive  // aaaaaaaa-...

        do {
            let store = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store.addDrawer(sampleDrawer(id: liveId))
            try await store.addDrawer(sampleDrawer(id: expungeId))
            try await store.expungeGated(
                drawerId: expungeId,
                changedBy: "filter-test",
                reason: "filter test",
                now: t(1_700_001_500)
            )
        }

        // Reopen and apply the EstateVerbs.swift tombstonedAt == nil filter.
        let store2 = try await TestStorage.openStore(url)
        let all = try await store2.allDrawers()
        let live = all.filter { $0.tombstonedAt == nil }

        #expect(live.count == 1, "exactly one live row after round-trip; got \(live.count)")
        #expect(live.first?.id == liveId, "the live row must be the non-expunged drawer")

        // The tombstoned row must appear in allDrawers (unfiltered) but with
        // a non-nil tombstonedAt, confirming the filter correctly excluded it.
        let tombstoned = all.first { $0.id == expungeId }
        #expect(tombstoned?.tombstonedAt != nil,
                "the expunged drawer's tombstonedAt must be non-nil after round-trip so the tombstonedAt == nil filter correctly excludes it")
    }

    /// Verify the raw stored tombstonedAt string is canonical ISO-8601 with
    /// fractional seconds (the TypedValue.timestamp canonical write format),
    /// NOT the bare ISO8601DateFormatter format that omits fractional seconds.
    ///
    /// This is the lowest-level regression guard: it reads the stored TEXT
    /// value directly from SQLite (bypassing all kit decode logic) and asserts
    /// the format. A bare ISO8601DateFormatter() produces "2026-06-19T14:00:00Z";
    /// the canonical path produces "2026-06-19T14:00:00.000Z". Both may parse
    /// successfully today (PersistenceKit accepts both shapes), but the canonical
    /// form is the contract. This test catches a future regression before it
    /// becomes a silent data-quality issue.
    @Test("tombstonedAt stored value uses canonical ISO-8601 with fractional seconds")
    func tombstonedAtStoredAsFractionalSecondsISO8601() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let drawerId = Self.idActive

        do {
            let store = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store.addDrawer(sampleDrawer(id: drawerId))
            try await store.expungeGated(
                drawerId: drawerId,
                changedBy: "format-test",
                reason: "canonical format test",
                now: t(1_700_001_234)
            )
        }
        // WAL checkpointed on store deinit. Read the raw TEXT value via sqlite3.
        var db: OpaquePointer?
        let rc = sqlite3_open(url.path, &db)
        defer { sqlite3_close(db) }
        guard rc == SQLITE_OK, let db else {
            Issue.record("rawRead: sqlite3_open failed rc=\(rc)")
            return
        }
        let sql = "SELECT tombstonedAt FROM drawers WHERE id = '\(drawerId)';"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            Issue.record("rawRead: prepare failed")
            return
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let rawBytes = sqlite3_column_text(stmt, 0) else {
            Issue.record("rawRead: no row or null tombstonedAt")
            return
        }
        let raw = String(cString: rawBytes)
        // Canonical form has a decimal point in the time component, e.g. "…:00.234Z".
        // The non-canonical (bare ISO8601DateFormatter) form omits the decimal: "…:00Z".
        #expect(raw.contains("."), "tombstonedAt stored value '\(raw)' must contain fractional seconds (a '.' in the time component) — write must use TypedValue.timestamp, not a bare ISO8601DateFormatter")
    }

    // MARK: - Lineage-wide expunge conformance (ADR-017 §17)

    /// The exact governance defect test: create D1, supersede it with D2
    /// (same lineageID), expunge D2 (the head), verify D1's content is
    /// empty. This confirms the lineage walk scrubs predecessors.
    @Test("expungeGated: superseded predecessor content is zeroed when head is expunged")
    func lineageWideExpungeConformance() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        let lineage = UUID()
        let predecessorId = "11111111-1111-4111-8111-111111111111"
        let headId = "22222222-2222-4222-8222-222222222222"

        // Step 1: create D1 with a lineageID.
        let d1 = Drawer(
            id: predecessorId,
            content: "predecessor-content",
            parentNodeId: "test-parent",
            addedBy: "test",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: 0,
            operationalBitmap: 0,
            lineageID: lineage
        )
        try await store.addDrawer(d1)

        // Step 2: supersede D1 by capturing D2 with the same lineageID.
        let d2 = Drawer(
            id: headId,
            content: "head-content",
            parentNodeId: "test-parent",
            addedBy: "test",
            filedAt: t(1_700_000_100),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: 0,
            operationalBitmap: 0,
            lineageID: lineage
        )
        try await store.addDrawer(d2)

        // Verify D1 is now superseded.
        let d1Before = try await store.getDrawer(id: predecessorId)
        #expect(d1Before?.state == .superseded)
        #expect(d1Before?.content == "predecessor-content")

        // Step 3: expunge the head (D2).
        try await store.expungeGated(
            drawerId: headId,
            changedBy: "test",
            reason: "lineage conformance test",
            now: t(1_700_000_200)
        )

        // Step 4: verify both drawers are tombstoned with empty content.
        let headAfter = try await store.getDrawer(id: headId)
        #expect(headAfter?.state == .tombstoned)
        #expect(headAfter?.content == "")

        let predecessorAfter = try await store.getDrawer(id: predecessorId)
        #expect(predecessorAfter?.state == .tombstoned)
        #expect(predecessorAfter?.content == "",
                "Predecessor content must be empty after lineage-wide expunge (ADR-017 §17)")
    }
}
