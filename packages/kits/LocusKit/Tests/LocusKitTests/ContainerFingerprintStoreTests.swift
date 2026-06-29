// ContainerFingerprintStoreTests.swift
//
// Tests for the per-container OR-reduction aggregate (spec section
// 11.5) and its maintenance: incremental OR-in on capture, roll-up to
// the wing, rebuild tightening, and the backfill that Estate.open runs
// so an existing estate's aggregate covers every active row.

import Foundation
import SubstrateTypes
import Testing
@testable import LocusKit

@Suite("ContainerFingerprintStoreTests")
struct ContainerFingerprintStoreTests {

    private func makeStore() async throws -> (ContainerFingerprintStore, URL) {
        let url = TestStorage.tempURL()
        let store = try await ContainerFingerprintStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    private func drawer(id: String,
                        adj: Int64, op: Int64, prov: Int64,
                        parentNodeId: String = "test-parent") -> Drawer {
        let content = "c-" + id
        return Drawer(id: TestStorage.tid(id), content: content, parentNodeId: parentNodeId, addedBy: "t",
                      filedAt: Date(timeIntervalSince1970: 1_700_000_000),
                      embeddingModelID: "m",
                      provenance: prov,
                      adjectiveBitmap: adj,
                      operationalBitmap: op,
                      lineageID: UUID())
    }

    // MARK: - Incremental OR-in

    @Test("orIn maintains the room row and the wing roll-up")
    func orInMaintainsRoomAndWing() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        try await store.orIn(wing: "w", room: "r1", adjective: 0b0001, operational: 0b0010, provenance: 0b0100)
        try await store.orIn(wing: "w", room: "r2", adjective: 0b1000, operational: 0b0000, provenance: 0b0000)

        let r1 = try await store.get(wing: "w", room: "r1")
        #expect(r1 == ContainerFingerprint(adjective: 0b0001, operational: 0b0010, provenance: 0b0100))
        let wing = try await store.get(wing: "w", room: "")
        #expect(wing == ContainerFingerprint(adjective: 0b1001, operational: 0b0010, provenance: 0b0100))
    }

    @Test("orIn into the same room accumulates by OR")
    func orInAccumulates() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        try await store.orIn(wing: "w", room: "r", adjective: 0b0001, operational: 0, provenance: 0)
        try await store.orIn(wing: "w", room: "r", adjective: 0b0010, operational: 0, provenance: 0)
        let r = try await store.get(wing: "w", room: "r")
        #expect(r?.adjective == 0b0011)
    }

    @Test("An unmaterialized container reads back as nil, meaning scan")
    func absentIsNil() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        #expect(try await store.get(wing: "w", room: "none") == nil)
    }

    // MARK: - Rebuild

    @Test("rebuildRoom tightens an over-set row to the OR of its active drawers")
    func rebuildTightens() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        // Simulate a stale over-approximation, then rebuild from a
        // smaller active set.
        try await store.orIn(wing: "w", room: "r", adjective: 0b1111, operational: 0, provenance: 0)
        let active = [drawer(id: "1", adj: 0b0001 << 26, op: 0, prov: 0),
                      drawer(id: "2", adj: 0b0010 << 26, op: 0, prov: 0)]
        try await store.rebuildRoom(wing: "w", room: "r", activeDrawers: active)
        let r = try await store.get(wing: "w", room: "r")
        #expect(r?.adjective == 0b0011 << 26)
    }

    @Test("rebuildAll covers every container and rolls up the wing")
    func rebuildAllCoversContainers() async throws {
        let (store, url) = try await makeStore()
        defer { TestStorage.cleanup(url) }
        let ds = [drawer(id: "1", adj: 0b001 << 26, op: 0, prov: 0, parentNodeId: "room-r1-node"),
                  drawer(id: "2", adj: 0b010 << 26, op: 0, prov: 0, parentNodeId: "room-r1-node"),
                  drawer(id: "3", adj: 0b100 << 26, op: 0, prov: 0, parentNodeId: "room-r2-node")]
        // rebuildAll requires nodeNames to resolve parentNodeId to wing/room.
        let nodeNames: [String: (wing: String, room: String)] = [
            "room-r1-node": (wing: "w", room: "r1"),
            "room-r2-node": (wing: "w", room: "r2")
        ]
        try await store.rebuildAll(activeDrawers: ds, nodeNames: nodeNames)
        #expect(try await store.get(wing: "w", room: "r1")?.adjective == 0b011 << 26)
        #expect(try await store.get(wing: "w", room: "r2")?.adjective == 0b100 << 26)
        #expect(try await store.get(wing: "w", room: "")?.adjective == 0b111 << 26)
    }

    // MARK: - Estate integration

    @Test("Capture maintains the aggregate across rooms and the wing roll-up")
    func captureMaintainsAggregate() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let estate = try await Estate.create(
            storage: TestStorage.sqlite(url),
            owner: OwnerCredentials(ownerIdentifier: "o"))

        // Two captures into different rooms with distinct operational bits.
        let f1 = CaptureFrame(content: "a", channel: .voiced, room: "r1",
                              latticeAnchor: LatticeAnchor(udcCode: "004"),
                              addedBy: "t", embeddingModelID: "m", kind: .prose)
        let f2 = CaptureFrame(content: "b", channel: .typed, room: "r2",
                              latticeAnchor: LatticeAnchor(udcCode: "004"),
                              addedBy: "t", embeddingModelID: "m", kind: .code)
        let d1 = try await estate.capture(f1)
        let d2 = try await estate.capture(f2)

        // Resolve wing/room names from the node tree (Drawer no longer carries them).
        let names = try await estate.resolveNodeNames(parentNodeIds: [d1.parentNodeId])
        let d1Wing = names[d1.parentNodeId]!.wing

        let room1 = try await estate.containerFP.get(wing: d1Wing, room: "r1")
        #expect(room1 == ContainerFingerprint(adjective: d1.adjectiveBitmap,
                                              operational: d1.operationalBitmap,
                                              provenance: d1.provenance))
        let wing = try await estate.containerFP.get(wing: d1Wing, room: "")
        #expect(wing == ContainerFingerprint(adjective: d1.adjectiveBitmap | d2.adjectiveBitmap,
                                             operational: d1.operationalBitmap | d2.operationalBitmap,
                                             provenance: d1.provenance | d2.provenance))
    }

    // MARK: - §11.5 Option B: add-coverage conformance

    /// After adding a drawer through the sanctioned path (`Estate.capture`),
    /// all three bitmap fields must be fully covered by both the room-level
    /// AND the wing-level container aggregate: `aggregate & drawerBits == drawerBits`
    /// for adjective, operational, and provenance. This is the structural
    /// guarantee of §11.5 Option B — coverage cannot be skipped because the
    /// only add path bundles FP maintenance.
    @Test("§11.5 coverage: capture auto-covers room and wing aggregates for all three bitmap fields")
    func addCoverageGuaranteeAllThreeBitmaps() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let estate = try await Estate.create(
            storage: TestStorage.sqlite(url),
            owner: OwnerCredentials(ownerIdentifier: "cov"))

        // Capture one drawer with non-trivial values in all three bitmap axes.
        // .voiced channel occupies bits 0–5 of operationalBitmap; .code kind
        // occupies bits 6–11; .restricted sensitivity sits in adjectiveBitmap
        // bits 6–11; .observed sourceType (raw 1) sits in provenance bits 0–5.
        let frame = CaptureFrame(
            content: "coverage-test",
            channel: .voiced,
            room: "r-cov",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "cov-tester",
            embeddingModelID: "model-v1",
            sensitivity: .restricted,
            kind: .code,
            sourceType: .observed)
        let drawer = try await estate.capture(frame)

        // Resolve wing/room display names from the node tree.
        let drawerNames = try await estate.resolveNodeNames(parentNodeIds: [drawer.parentNodeId])
        let dWing = drawerNames[drawer.parentNodeId]!.wing
        let dRoom = drawerNames[drawer.parentNodeId]!.room

        // Room-level aggregate must cover all three fields.
        let room = try await estate.containerFP.get(wing: dWing, room: dRoom)
        let roomFP = try #require(room, "room aggregate must exist after capture")
        #expect(roomFP.adjective & drawer.adjectiveBitmap == drawer.adjectiveBitmap,
                "room adjective aggregate must cover drawer.adjectiveBitmap")
        #expect(roomFP.operational & drawer.operationalBitmap == drawer.operationalBitmap,
                "room operational aggregate must cover drawer.operationalBitmap")
        #expect(roomFP.provenance & drawer.provenance == drawer.provenance,
                "room provenance aggregate must cover drawer.provenance")

        // Wing-level rollup must also cover all three fields.
        let wing = try await estate.containerFP.get(wing: dWing, room: "")
        let wingFP = try #require(wing, "wing aggregate must exist after capture")
        #expect(wingFP.adjective & drawer.adjectiveBitmap == drawer.adjectiveBitmap,
                "wing adjective aggregate must cover drawer.adjectiveBitmap")
        #expect(wingFP.operational & drawer.operationalBitmap == drawer.operationalBitmap,
                "wing operational aggregate must cover drawer.operationalBitmap")
        #expect(wingFP.provenance & drawer.provenance == drawer.provenance,
                "wing provenance aggregate must cover drawer.provenance")
    }

    /// Two drawers in the same room: aggregate covers both, so no field of
    /// either drawer is absent from the aggregate. Cross-port invariant.
    @Test("§11.5 coverage: two drawers in same room — aggregate covers both")
    func addCoverageTwoDrawersSameRoom() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let estate = try await Estate.create(
            storage: TestStorage.sqlite(url),
            owner: OwnerCredentials(ownerIdentifier: "cov2"))

        let f1 = CaptureFrame(content: "first", channel: .voiced, room: "r-cov2",
                              latticeAnchor: LatticeAnchor(udcCode: "004"),
                              addedBy: "t", embeddingModelID: "m", kind: .prose)
        let f2 = CaptureFrame(content: "second", channel: .typed, room: "r-cov2",
                              latticeAnchor: LatticeAnchor(udcCode: "004"),
                              addedBy: "t", embeddingModelID: "m", kind: .code)
        let d1 = try await estate.capture(f1)
        let d2 = try await estate.capture(f2)

        // Resolve wing name from the node tree.
        let d1Names = try await estate.resolveNodeNames(parentNodeIds: [d1.parentNodeId])
        let d1Wing = d1Names[d1.parentNodeId]!.wing

        let room = try await estate.containerFP.get(wing: d1Wing, room: "r-cov2")
        let fp = try #require(room)
        // The aggregate must cover d1's bits AND d2's bits.
        #expect(fp.adjective & d1.adjectiveBitmap == d1.adjectiveBitmap)
        #expect(fp.adjective & d2.adjectiveBitmap == d2.adjectiveBitmap)
        #expect(fp.operational & d1.operationalBitmap == d1.operationalBitmap)
        #expect(fp.operational & d2.operationalBitmap == d2.operationalBitmap)
        #expect(fp.provenance & d1.provenance == d1.provenance)
        #expect(fp.provenance & d2.provenance == d2.provenance)
    }

    @Test("Estate.open backfills the aggregate from existing rows")
    func openBackfillsAggregate() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)

        // Seed the manifest via create, then add rows through a bare
        // DrawerStore so the capture OR-in is bypassed and the
        // aggregate starts absent.
        _ = try await Estate.create(storage: storage,
                                    owner: OwnerCredentials(ownerIdentifier: "o"))
        // Seed node tree so drawers resolve wing/room at read time.
        let nodeStore = NodeStore(storage: storage)
        let root = try await nodeStore.createRoot(displayName: "Estate", now: Date())
        let wing = try await nodeStore.createNode(displayName: "w", parentId: root.id, now: Date())
        let room = try await nodeStore.createNode(displayName: "r", parentId: wing.id, now: Date())
        let roomNodeId = room.id.uuidString
        let drawerStore = try await DrawerStore(storage: storage)
        try await drawerStore.addDrawer(drawer(id: "1", adj: 0, op: 1 << 24, prov: 0, parentNodeId: roomNodeId))
        try await drawerStore.addDrawer(drawer(id: "2", adj: 0, op: 16 << 24, prov: 0, parentNodeId: roomNodeId))

        // Reopening runs the backfill, making the aggregate cover both.
        let estate = try await Estate.open(storage: storage,
                                           owner: OwnerCredentials(ownerIdentifier: "o"))
        let r = try await estate.containerFP.get(wing: "w", room: "r")
        #expect(r?.operational == 17 << 24)
    }
}
