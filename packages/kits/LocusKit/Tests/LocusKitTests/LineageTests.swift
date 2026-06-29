import Foundation
import Testing
@testable import LocusKit

/// Lineage identifier and supersession cascade tests for
/// LOCI_V035_03. Per spec § 5.10, every drawer carries a
/// `lineageID: UUID` (substrate-generated when the caller omits one).
/// Per § 6.2 and § 6.3, capturing a new drawer with a `lineageID`
/// that matches an existing know-now drawer transitions the prior
/// drawer to `state = .superseded` (6-bit state field raw value 16,
/// bits 0–5 of `adjectiveBitmap`) and creates a directional
/// `.supersedes` tunnel from successor to predecessor.
@Suite("LineageTests")
struct LineageTests {

    // MARK: - Test fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-lineage-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    /// Bundles a DrawerStore and NodeStore over a shared SQLite file.
    private struct TestFixture {
        let store: DrawerStore
        let nodeStore: NodeStore
        let url: URL
        /// Room node whose UUID is used as parentNodeId.
        let roomNode: Node
    }

    private func makeStore() async throws -> (DrawerStore, URL) {
        let url = makeTempURL()
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    /// Creates a DrawerStore with a provisioned node tree (root→wing→room)
    /// so that tunnel resolution via resolveNodeNames works.
    private func makeFixture(wingName: String = "w", roomName: String = "r") async throws -> TestFixture {
        let url = makeTempURL()
        let storage = TestStorage.sqlite(url)
        let store = try await DrawerStore(storage: storage)
        let nodeStore = NodeStore(storage: storage)
        let root = try await nodeStore.createRoot(displayName: "Estate", now: t(0))
        let wing = try await nodeStore.createNode(displayName: wingName, parentId: root.id, now: t(1))
        let room = try await nodeStore.createNode(displayName: roomName, parentId: wing.id, now: t(2))
        return TestFixture(store: store, nodeStore: nodeStore, url: url, roomNode: room)
    }

    private func sampleDrawer(
        id: String = "d1",
        parentNodeId: String = "test-parent",
        filedAt: Date? = nil,
        lineageID: UUID? = nil,
        adjectiveBitmap: Int64 = 0
    ) -> Drawer {
        Drawer(
            id: id,
            content: "content-\(id)",
            parentNodeId: parentNodeId,
            addedBy: "bilby",
            filedAt: filedAt ?? t(1_700_000_000),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: adjectiveBitmap,
            lineageID: lineageID ?? UUID()
        )
    }

    // MARK: - lineageID round-trip

    /// A drawer's `lineageID` survives insert and fetch byte-for-byte.
    /// This is the simplest contract per spec § 5.10: substrate stores
    /// what was filed.
    @Test("lineageID round-trips through addDrawer and getDrawer")
    func lineageIDRoundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let lineage = UUID()
        let d = sampleDrawer(id: "11111111-1111-4111-8111-111111111111", lineageID: lineage)
        try await store.addDrawer(d)
        let loaded = try await store.getDrawer(id: "11111111-1111-4111-8111-111111111111")
        #expect(loaded?.lineageID == lineage)
    }

    /// Two drawers constructed without an explicit `lineageID` receive
    /// distinct substrate-generated values. Per spec § 5.10 the default
    /// is `UUID()`, which guarantees uniqueness with overwhelming
    /// probability — so distinct drawers are not silently treated as
    /// the same lineage.
    @Test("default lineageID generates a unique UUID per drawer")
    func defaultLineageIDIsUnique() throws {
        let d1 = sampleDrawer(id: "aaaaaaaa-1111-4111-8111-111111111111")
        let d2 = sampleDrawer(id: "bbbbbbbb-2222-4222-8222-222222222222")
        #expect(d1.lineageID != d2.lineageID)
    }

    // MARK: - Cascade

    /// Inserting D2 with the same lineageID as an active D1 transitions
    /// D1 to `state = .superseded` (adjective bitmap bits 0–3 = 3) per
    /// spec § 6.2.
    @Test("cascade transitions prior drawer's state to superseded")
    func cascadeSetsPriorStateSuperseded() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let lineage = UUID()
        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111", lineageID: lineage))
        try await store.addDrawer(sampleDrawer(id: "22222222-2222-4222-8222-222222222222", lineageID: lineage))
        let d1 = try await store.getDrawer(id: "11111111-1111-4111-8111-111111111111")
        #expect((d1?.adjectiveBitmap ?? -1) & 0x3F == Int64(State.superseded.rawValue))
    }

    /// The cascade creates a directional `supersedes` tunnel from
    /// successor to predecessor per spec § 6.3. The label is the
    /// string `"supersedes"`; LOCI_V035_05A will add the typed
    /// `Tunnel.kind` field and migrate this site.
    @Test("cascade creates a supersedes tunnel from successor to predecessor")
    func cascadeCreatesSupersedesTunnel() async throws {
        let fixture = try await makeFixture(wingName: "w", roomName: "r")
        defer { cleanup(fixture.url) }
        let lineage = UUID()
        let roomId = fixture.roomNode.id.uuidString
        try await fixture.store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111", parentNodeId: roomId, lineageID: lineage))
        try await fixture.store.addDrawer(sampleDrawer(id: "22222222-2222-4222-8222-222222222222", parentNodeId: roomId, lineageID: lineage))
        let tunnels = try await fixture.store.tunnelsFrom(wing: "w", room: "r")
        let supersedes = tunnels.filter { $0.label == "supersedes" }
        #expect(supersedes.count == 1)
        #expect(supersedes.first?.sourceDrawerId == "22222222-2222-4222-8222-222222222222")
        #expect(supersedes.first?.targetDrawerId == "11111111-1111-4111-8111-111111111111")
    }

    /// The newly-inserted drawer remains in the active state cluster
    /// (bits 0–3 = 0). Only the predecessor flips to superseded.
    @Test("cascade leaves the new drawer in active state")
    func cascadeLeavesNewDrawerActive() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let lineage = UUID()
        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111", lineageID: lineage))
        try await store.addDrawer(sampleDrawer(id: "22222222-2222-4222-8222-222222222222", lineageID: lineage))
        let d2 = try await store.getDrawer(id: "22222222-2222-4222-8222-222222222222")
        #expect(d2?.state == .active)
    }

    /// When the prior drawer's state is already outside the know-now
    /// cluster (state ≥ 3), the cascade does not fire — there is no
    /// active version to supersede. Withdrawn (raw 5) is in the
    /// knew-past cluster per spec § 6.1.
    @Test("no cascade when no prior active version exists")
    func noCascadeWhenPriorIsKnewPast() async throws {
        let fixture = try await makeFixture(wingName: "w", roomName: "r")
        defer { cleanup(fixture.url) }
        let lineage = UUID()
        let roomId = fixture.roomNode.id.uuidString
        // Capture must start a row in active or pending state per the
        // gate's prior==nil branch. To exercise "D1 is in the knew-past
        // cluster before D2 lands," capture-active then withdraw via
        // the verb — that is how a row actually arrives at withdrawn.
        try await fixture.store.addDrawer(sampleDrawer(
            id: "11111111-1111-4111-8111-111111111111", parentNodeId: roomId,
            lineageID: lineage
        ))
        try await fixture.store.mutateState(
            drawerId: "11111111-1111-4111-8111-111111111111",
            to: .withdrawn, via: .retract,
            changedBy: "test"
        )
        try await fixture.store.addDrawer(sampleDrawer(id: "22222222-2222-4222-8222-222222222222", parentNodeId: roomId, lineageID: lineage))
        let d1 = try await fixture.store.getDrawer(id: "11111111-1111-4111-8111-111111111111")
        // D1's state is still withdrawn after D2's insert (no cascade).
        #expect((d1?.adjectiveBitmap ?? -1) & 0x3F == Int64(State.withdrawn.rawValue))
        // No supersedes tunnel was created (D1 was knew-past, not active).
        let tunnels = try await fixture.store.tunnelsFrom(wing: "w", room: "r")
        #expect(tunnels.filter { $0.label == "supersedes" }.isEmpty)
    }

    /// Two drawers with distinct lineageIDs are independent — neither
    /// is superseded, no tunnel is created.
    @Test("non-supersession leaves both drawers active and creates no tunnel")
    func nonSupersessionLeavesBothActive() async throws {
        let fixture = try await makeFixture(wingName: "w", roomName: "r")
        defer { cleanup(fixture.url) }
        let roomId = fixture.roomNode.id.uuidString
        try await fixture.store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111", parentNodeId: roomId, lineageID: UUID()))
        try await fixture.store.addDrawer(sampleDrawer(id: "22222222-2222-4222-8222-222222222222", parentNodeId: roomId, lineageID: UUID()))
        let d1 = try await fixture.store.getDrawer(id: "11111111-1111-4111-8111-111111111111")
        let d2 = try await fixture.store.getDrawer(id: "22222222-2222-4222-8222-222222222222")
        #expect(d1?.state == .active)
        #expect(d2?.state == .active)
        let tunnels = try await fixture.store.tunnelsFrom(wing: "w", room: "r")
        #expect(tunnels.filter { $0.label == "supersedes" }.isEmpty)
    }

    // MARK: - B1 Finding #3 regression — cascade atomicity

    /// The supersession cascade must be atomic: the successor drawer insert
    /// and the `supersedes` tunnel insert must either both succeed or both be
    /// absent. The predecessor state flip must only happen AFTER the tunnel
    /// insert succeeds.
    ///
    /// Pre-fix: `gatedCapture` (drawer INSERT) and the tunnel INSERT ran in
    /// separate transactions, so a concurrent interleave or partial failure
    /// could produce a drawer with no tunnel (recall gap), or a predecessor
    /// permanently stuck in `superseded` with no tunnel to the active successor.
    ///
    /// Post-fix: both operations share a single `storage.transaction`, and
    /// `mutateState` (predecessor flip) runs after the wrapping transaction
    /// commits. This test verifies the post-fix happy path: all three
    /// invariants hold simultaneously.
    ///
    /// (Full fault-injection test requires a breaking StorageTransaction
    /// fixture not currently in the test harness. Tracked as a follow-up.
    /// This happy-path test regression-guards the fix did not break the
    /// success path — planned security hardening B1 finding #3.)
    @Test("cascade atomic: drawer, tunnel, and predecessor flip are all consistent (B1 finding #3)")
    func cascadeAtomicAllThreeInvariantsConsistent() async throws {
        let fixture = try await makeFixture(wingName: "mem", roomName: "study")
        defer { cleanup(fixture.url) }
        let lineage = UUID()
        let roomId = fixture.roomNode.id.uuidString

        // Insert the predecessor, then the successor in the same lineage.
        try await fixture.store.addDrawer(
            sampleDrawer(id: "cc001111-0000-4000-8000-000000000001", parentNodeId: roomId, lineageID: lineage))
        try await fixture.store.addDrawer(
            sampleDrawer(id: "cc002222-0000-4000-8000-000000000002", parentNodeId: roomId, lineageID: lineage))

        // Invariant 1: successor is present and active.
        let successor = try await fixture.store.getDrawer(id: "cc002222-0000-4000-8000-000000000002")
        #expect(successor?.state == .active, "successor must be active")

        // Invariant 2: supersedes tunnel exists from successor → predecessor.
        let tunnels = try await fixture.store.tunnelsFrom(wing: "mem", room: "study")
        let supersedesTunnel = tunnels.first(where: { $0.label == "supersedes" })
        #expect(supersedesTunnel != nil, "supersedes tunnel must be filed")
        #expect(supersedesTunnel?.sourceDrawerId == "cc002222-0000-4000-8000-000000000002")
        #expect(supersedesTunnel?.targetDrawerId == "cc001111-0000-4000-8000-000000000001")

        // Invariant 3: predecessor is superseded — and only AFTER the tunnel
        // committed (structural enforcement, not observable from the happy path
        // but proven by the Rust ordering test and the implementation diff).
        let predecessor = try await fixture.store.getDrawer(id: "cc001111-0000-4000-8000-000000000001")
        #expect((predecessor?.adjectiveBitmap ?? -1) & 0x3F == Int64(State.superseded.rawValue),
                "predecessor must be superseded after successful cascade")
    }

}
