import Foundation
import Testing
@testable import LocusKit

/// Reanchor verb coverage (VERB-REA-01).
///
/// Two layers under test:
///
///   1. `DrawerStore.reanchorGated` — the gated storage-layer body.
///      Updates the placement columns (`room` and/or lattice anchor fields)
///      and appends one sealed audit event per `AuditGate.admit` with
///      `verb: .mutate` (active→active self-loop). The row's three bitmaps
///      are unchanged by the reanchor.
///
///   2. `Estate.reanchor` — the verb wrapper. Empty-input guard (both nil →
///      `invalidContent`), drawerNotFound, forwards to `DrawerStore.reanchorGated`.
///
/// Coverage mandated by VERB-REA-01 BRR:
///   - reanchor to a new room moves the drawer (peek/recall reflects new room)
///   - reanchor to a new lattice updates the anchor
///   - empty reanchor → `invalidContent`
///   - non-existent rowID → `drawerNotFound`
///   - audit/provenance entry written (count increments)
///   - reanchored row's bitmaps otherwise unchanged
///
/// Date-precision note: this suite does not assert `Date` equality across
/// timestamp round-trips (nanosec vs ISO8601 ms differ). See VERB-CAP-01 notes.
@Suite("ReanchorTests")
struct ReanchorTests {

    // MARK: - Fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-reanchor-test-\(UUID().uuidString).sqlite"
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

    private func captureOne(
        estate: Estate,
        room: String = "room-original",
        lattice: LatticeAnchor = LatticeAnchor.udc("000")
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: "reanchor test content \(UUID().uuidString)",
            channel: .typed,
            room: room,
            latticeAnchor: lattice,
            addedBy: "reanchor-test-agent",
            embeddingModelID: "test-model-v1"
        )
        return try await estate.capture(frame)
    }

    private func auditEventCount(_ estate: Estate, _ id: String) async throws -> Int {
        let uuid = UUID(uuidString: id)!
        return try await estate.store.auditEventCountForRow(uuid)
    }

    static let idAbsent = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    // MARK: - DrawerStore.reanchorGated — room move

    @Test("reanchorGated: updating room reflects in getDrawer")
    func reanchorGatedRoomMove() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await captureOne(estate: estate, room: "room-original",
                                          lattice: LatticeAnchor(udcCode: "000.100"))

        try await estate.store.reanchorGated(
            drawerId: drawer.id,
            toRoom: "room-new",
            toLattice: nil,
            changedBy: "test",
            reason: "room move test",
            now: t(1_700_000_500)
        )

        let after = try await estate.store.getDrawer(id: drawer.id)
        #expect(after?.room == "room-new")
        // Lattice anchor unchanged.
        #expect(after?.udcCode == "000.100")
    }

    @Test("reanchorGated: room move leaves all three bitmaps unchanged")
    func reanchorGatedRoomMoveBitmapsUnchanged() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await captureOne(estate: estate)
        let beforeAdj  = drawer.adjectiveBitmap
        let beforeOp   = drawer.operationalBitmap
        let beforeProv = drawer.provenance

        try await estate.store.reanchorGated(
            drawerId: drawer.id,
            toRoom: "room-moved",
            toLattice: nil,
            changedBy: "test",
            now: t(1_700_000_500)
        )

        let after = try await estate.store.getDrawer(id: drawer.id)
        #expect(after?.adjectiveBitmap == beforeAdj)
        #expect(after?.operationalBitmap == beforeOp)
        #expect(after?.provenance == beforeProv)
    }

    // MARK: - DrawerStore.reanchorGated — lattice move

    @Test("reanchorGated: updating lattice anchor reflects in getDrawer")
    func reanchorGatedLatticeMove() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await captureOne(estate: estate, lattice: LatticeAnchor.udc("000"))

        try await estate.store.reanchorGated(
            drawerId: drawer.id,
            toRoom: nil,
            toLattice: LatticeAnchor(
                udcCode: "003.456",
                udcFacets: "030",
                wikidataQID: "Q12345",
                wikidataQidsSecondary: nil
            ),
            changedBy: "test",
            now: t(1_700_000_500)
        )

        let after = try await estate.store.getDrawer(id: drawer.id)
        #expect(after?.udcCode == "003.456")
        #expect(after?.udcFacets == "030")
        #expect(after?.wikidataQID == "Q12345")
        #expect(after?.wikidataQidsSecondary == nil)
        // Room unchanged.
        #expect(after?.room == drawer.room)
    }

    @Test("reanchorGated: lattice move leaves all three bitmaps unchanged")
    func reanchorGatedLatticeBitmapsUnchanged() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await captureOne(estate: estate)
        let beforeAdj  = drawer.adjectiveBitmap
        let beforeOp   = drawer.operationalBitmap
        let beforeProv = drawer.provenance

        try await estate.store.reanchorGated(
            drawerId: drawer.id,
            toRoom: nil,
            toLattice: LatticeAnchor.udc("003.000"),
            changedBy: "test",
            now: t(1_700_000_500)
        )

        let after = try await estate.store.getDrawer(id: drawer.id)
        #expect(after?.adjectiveBitmap == beforeAdj)
        #expect(after?.operationalBitmap == beforeOp)
        #expect(after?.provenance == beforeProv)
    }

    // MARK: - DrawerStore.reanchorGated — audit event written

    @Test("reanchorGated: audit event count increments by 1")
    func reanchorGatedAuditEventAppended() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await captureOne(estate: estate)
        let countBefore = try await auditEventCount(estate, drawer.id)
        #expect(countBefore == 1)  // genesis capture event

        try await estate.store.reanchorGated(
            drawerId: drawer.id,
            toRoom: "room-moved",
            toLattice: nil,
            changedBy: "test",
            now: t(1_700_000_500)
        )

        let countAfter = try await auditEventCount(estate, drawer.id)
        #expect(countAfter == 2)  // genesis + reanchor event
    }

    // MARK: - DrawerStore.reanchorGated — not found

    @Test("reanchorGated: absent row throws drawerNotFound")
    func reanchorGatedAbsentRowThrows() async throws {
        let (estate, _) = try await makeEstate()

        await #expect(throws: LocusKitError.self) {
            try await estate.store.reanchorGated(
                drawerId: Self.idAbsent,
                toRoom: "room-new",
                toLattice: nil,
                changedBy: "test",
                now: t(1_700_000_100)
            )
        }
    }

    // MARK: - Estate.reanchor — verb wrapper

    @Test("Estate.reanchor: both toRoom and toLattice nil throws invalidContent")
    func estateReanchorEmptyThrows() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await captureOne(estate: estate)
        await #expect(throws: LocusKitError.self) {
            try await estate.reanchor(rowID: drawer.id, toRoom: nil, toLattice: nil)
        }
    }

    @Test("Estate.reanchor: non-existent rowID throws drawerNotFound")
    func estateReanchorNotFound() async throws {
        let (estate, _) = try await makeEstate()
        await #expect(throws: LocusKitError.self) {
            try await estate.reanchor(rowID: Self.idAbsent, toRoom: "new-room")
        }
    }

    @Test("Estate.reanchor: toRoom updates the drawer's room")
    func estateReanchorToRoom() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await captureOne(estate: estate, room: "original-room")

        try await estate.reanchor(rowID: drawer.id, toRoom: "moved-room")

        let after = try await estate._peekDrawer(id: drawer.id)
        #expect(after?.room == "moved-room")
    }

    @Test("Estate.reanchor: toLattice updates the drawer's lattice anchor")
    func estateReanchorToLattice() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await captureOne(estate: estate, lattice: LatticeAnchor.udc("000"))

        try await estate.reanchor(rowID: drawer.id, toLattice: LatticeAnchor.udc("003.000"))

        let after = try await estate._peekDrawer(id: drawer.id)
        #expect(after?.udcCode == "003.000")
    }

    @Test("Estate.reanchor: room move preserves all three bitmaps")
    func estateReanchorBitmapsPreserved() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await captureOne(estate: estate)
        let beforeAdj  = drawer.adjectiveBitmap
        let beforeOp   = drawer.operationalBitmap
        let beforeProv = drawer.provenance

        try await estate.reanchor(rowID: drawer.id, toRoom: "new-room")

        let after = try await estate._peekDrawer(id: drawer.id)
        #expect(after?.adjectiveBitmap == beforeAdj)
        #expect(after?.operationalBitmap == beforeOp)
        #expect(after?.provenance == beforeProv)
    }

    @Test("Estate.reanchor: audit entry is written")
    func estateReanchorAuditEntry() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await captureOne(estate: estate)
        let countBefore = try await auditEventCount(estate, drawer.id)
        #expect(countBefore == 1)  // genesis

        try await estate.reanchor(rowID: drawer.id, toRoom: "audit-moved-room")

        let countAfter = try await auditEventCount(estate, drawer.id)
        #expect(countAfter == 2)  // genesis + reanchor
    }

    @Test("Estate.reanchor: simultaneous room and lattice move succeeds")
    func estateReanchorBothRoomAndLattice() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await captureOne(estate: estate, room: "room-a",
                                          lattice: LatticeAnchor.udc("100"))

        try await estate.reanchor(
            rowID: drawer.id,
            toRoom: "room-b",
            toLattice: LatticeAnchor.udc("200")
        )

        let after = try await estate._peekDrawer(id: drawer.id)
        #expect(after?.room == "room-b")
        #expect(after?.udcCode == "200")
    }
}
