import Foundation
import Testing
@testable import LocusKit

/// Lineage identifier and supersession cascade tests for
/// LOCI_V035_03. Per spec § 5.10, every drawer carries a
/// `lineageID: UUID` (substrate-generated when the caller omits one).
/// Per § 6.2 and § 6.3, capturing a new drawer with a `lineageID`
/// that matches an existing know-now drawer transitions the prior
/// drawer to `state = .superseded` (adjective bits 0–3 = 3) and
/// creates a directional `supersedes` tunnel from successor to
/// predecessor — atomically.
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

    private func makeStore() async throws -> (DrawerStore, URL) {
        let url = makeTempURL()
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    private func sampleDrawer(
        id: String = "d1",
        wing: String = "wing-a",
        room: String = "room-a",
        filedAt: Date? = nil,
        lineageID: UUID? = nil,
        adjectiveBitmap: Int64 = 0
    ) -> Drawer {
        Drawer(
            id: id,
            content: "content-\(id)",
            wing: wing,
            room: room,
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
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let lineage = UUID()
        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111", wing: "w", room: "r", lineageID: lineage))
        try await store.addDrawer(sampleDrawer(id: "22222222-2222-4222-8222-222222222222", wing: "w", room: "r", lineageID: lineage))
        let tunnels = try await store.tunnelsFrom(wing: "w", room: "r")
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
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let lineage = UUID()
        // Capture must start a row in active or pending state per the
        // gate's prior==nil branch. To exercise "D1 is in the knew-past
        // cluster before D2 lands," capture-active then withdraw via
        // the verb — that is how a row actually arrives at withdrawn.
        try await store.addDrawer(sampleDrawer(
            id: "11111111-1111-4111-8111-111111111111", wing: "w", room: "r",
            lineageID: lineage
        ))
        try await store.mutateState(
            drawerId: "11111111-1111-4111-8111-111111111111",
            to: .withdrawn, via: .retract,
            changedBy: "test"
        )
        try await store.addDrawer(sampleDrawer(id: "22222222-2222-4222-8222-222222222222", wing: "w", room: "r", lineageID: lineage))
        let d1 = try await store.getDrawer(id: "11111111-1111-4111-8111-111111111111")
        // D1's state is still withdrawn after D2's insert (no cascade).
        #expect((d1?.adjectiveBitmap ?? -1) & 0x3F == Int64(State.withdrawn.rawValue))
        // No supersedes tunnel was created (D1 was knew-past, not active).
        let tunnels = try await store.tunnelsFrom(wing: "w", room: "r")
        #expect(tunnels.filter { $0.label == "supersedes" }.isEmpty)
    }

    /// Two drawers with distinct lineageIDs are independent — neither
    /// is superseded, no tunnel is created.
    @Test("non-supersession leaves both drawers active and creates no tunnel")
    func nonSupersessionLeavesBothActive() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: "11111111-1111-4111-8111-111111111111", wing: "w", room: "r", lineageID: UUID()))
        try await store.addDrawer(sampleDrawer(id: "22222222-2222-4222-8222-222222222222", wing: "w", room: "r", lineageID: UUID()))
        let d1 = try await store.getDrawer(id: "11111111-1111-4111-8111-111111111111")
        let d2 = try await store.getDrawer(id: "22222222-2222-4222-8222-222222222222")
        #expect(d1?.state == .active)
        #expect(d2?.state == .active)
        let tunnels = try await store.tunnelsFrom(wing: "w", room: "r")
        #expect(tunnels.filter { $0.label == "supersedes" }.isEmpty)
    }

}
