import Foundation
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
            wing: "wing-a",
            room: "room-a",
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
}
