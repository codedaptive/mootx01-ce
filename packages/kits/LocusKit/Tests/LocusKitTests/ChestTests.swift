// ChestTests.swift — chests below rooms (ADR-026, LocusKit spec § 12):
// placement on capture and reanchor, the whole-room re-bin, the room read
// over the subtree, the per-chest Merkle roots and the room's fold over them (ADR-027 D1).
// Twins of the Rust `chest_*` tests in estate_verbs.rs.
import EngramLib
import Foundation
import SubstrateML
import SubstrateTypes
import Testing
@testable import LocusKit

@Suite("Chests (ADR-026, spec § 12)")
struct ChestTests {
    private func makeEstate() async throws -> Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-chest-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try await Estate.create(
            storage: TestStorage.sqlite(dir.appendingPathComponent("estate.sqlite3")),
            owner: OwnerCredentials(ownerIdentifier: "test-owner"))
    }

    private func frame(_ content: String, room: String = "study") -> CaptureFrame {
        var f = CaptureFrame(content: content, channel: .typed, room: room,
                             latticeAnchor: LatticeAnchor(udcCode: "004"),
                             addedBy: "bilby", embeddingModelID: "minilm-v6")
        f.wing = "w"
        return f
    }

    /// The key hex of a content string: the value a chest name is compared to.
    private func keyHex(_ content: String) -> String {
        ChestPlacement.key(ContentFingerprint.fingerprint(of: content)).hex
    }

    /// Spec § 12 placement rule over a chest list, computed independently
    /// of `NodeStore.placementParent`.
    private func expectedChest(for content: String, in chests: [ChestRange]) -> String {
        let hex = keyHex(content)
        let below = chests.filter { $0.lowKey.hex <= hex }
        return (below.last ?? chests.first!).chestNodeId
    }

    @Test("re-bin deals sorted content keys into ⌈n/250⌉ chests with derived ids, one audit event, a root per chest folded into the room root, and is idempotent")
    func rebinDealsSortedKeysIntoDerivedChests() async throws {
        let estate = try await makeEstate()
        let drawers = try await estate.captureBatch((0..<600).map { frame("note \($0) on topic \($0 % 7)") })
        let roomId = UUID(uuidString: drawers[0].parentNodeId)!
        #expect(try await estate.nodeStore.getNode(id: roomId)?.depth == 2, "before a re-bin a drawer sits on the room")
        let rootBefore = try await estate.computeRoomMerkleRoot(roomNodeId: roomId)
        let auditBefore = try await estate.store.storage.auditLog.count()

        let count = try await estate.rebinRoom(wing: "w", room: "study", now: Date(timeIntervalSince1970: 1_700_000_100))
        #expect(count == 3)
        let chests = try await estate.chests(in: "w", room: "study")
        #expect(chests.map(\.count) == [250, 250, 100])
        #expect(chests.map(\.lowKey) == chests.map(\.lowKey).sorted(), "chests come back in key order")
        for chest in chests {
            #expect(chest.chestNodeId == NodeStore.chestId(roomId: roomId, lowKeyHex: chest.lowKey.hex).uuidString,
                    "a chest id is derived from the room id and its low key")
            #expect(try await estate.nodeStore.getNode(id: UUID(uuidString: chest.chestNodeId)!)?.depth == 3)
        }
        #expect(try await estate.store.storage.auditLog.count() == auditBefore + 1, "one event per re-bin")

        // Every drawer moved into the chest its key selects; the room read is unchanged.
        let after = try await estate.drawersIn(wing: "w", room: "study")
        #expect(Set(after.map(\.id)) == Set(drawers.map(\.id)))
        let chestIds = Set(chests.map(\.chestNodeId))
        for d in after {
            #expect(chestIds.contains(d.parentNodeId))
            #expect(d.parentNodeId == expectedChest(for: d.content, in: chests))
        }
        // ADR-027 D1: each chest carries its own root and the room folds
        // them, so the room root changes shape at the first re-bin; the
        // incremental rollup and the full recompute must then agree.
        try await estate.recomputeAllMerkleRoots(now: Date(timeIntervalSince1970: 1_700_000_101))
        for chest in chests {
            let node = try await estate.nodeStore.getNode(id: UUID(uuidString: chest.chestNodeId)!)
            #expect(node?.merkleRoot != nil, "a chest carries its own Merkle root")
            #expect(node?.merkleRoot == (try await estate.computeChestMerkleRoot(chestNodeId: node!.id)))
        }
        let roomRoot = try await estate.computeRoomMerkleRoot(roomNodeId: roomId)
        #expect(roomRoot != rootBefore, "the room root folds its chests' roots")
        #expect(try await estate.nodeStore.getNode(id: roomId)?.merkleRoot == roomRoot)
        // Every room-set read and count covers the chests.
        #expect(try await estate.store.drawersIn(wing: "w").count == 600)
        #expect(try await estate.store.listWings().map(\.drawerCount) == [600])
        #expect(try await estate.store.listRooms(in: "w").map(\.drawerCount) == [600])

        // Idempotent: the same chests, the same ids, nothing moved, one more event.
        let parentsBefore = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0.parentNodeId) })
        #expect(try await estate.rebinRoom(wing: "w", room: "study", now: Date(timeIntervalSince1970: 1_700_000_200)) == 3)
        let chestsAgain = try await estate.chests(in: "w", room: "study")
        #expect(chestsAgain == chests)
        for d in try await estate.drawersIn(wing: "w", room: "study") {
            #expect(parentsBefore[d.id] == d.parentNodeId)
        }
        #expect(try await estate.store.storage.auditLog.count() == auditBefore + 2)
    }

    @Test("after a re-bin, capture and reanchor place by the content key; withdraw in a chest rolls the room up")
    func captureAndReanchorPlaceByKey() async throws {
        let estate = try await makeEstate()
        _ = try await estate.captureBatch((0..<300).map { frame("entry \($0) about \($0 % 5)") })
        try await estate.rebinRoom(wing: "w", room: "study", now: Date(timeIntervalSince1970: 1_700_000_100))
        let chests = try await estate.chests(in: "w", room: "study")
        #expect(chests.count == 2)

        let fresh = try await estate.capture(frame("a fresh note about gardening"))
        #expect(fresh.parentNodeId == expectedChest(for: fresh.content, in: chests))

        let elsewhere = try await estate.capture(frame("moved from the kitchen", room: "kitchen"))
        #expect(try await estate.nodeStore.getNode(id: UUID(uuidString: elsewhere.parentNodeId)!)?.depth == 2)
        try await estate.reanchor(rowID: elsewhere.id, toRoom: "study")
        let moved = try await estate.store.getDrawer(id: elsewhere.id)!
        #expect(moved.parentNodeId == expectedChest(for: moved.content, in: chests))
        #expect(try await estate.drawersIn(wing: "w", room: "study").count == 302)
        #expect(try await estate.drawersIn(wing: "w", room: "kitchen").isEmpty)

        try await estate.withdraw(rowID: fresh.id)
        let roomId = try await estate.nodeStore.roomNode(forParent: UUID(uuidString: fresh.parentNodeId)!)!.id
        #expect(try await estate.nodeStore.getNode(id: roomId)?.merkleRoot != nil, "withdraw rolled the room up through its chest")
    }

    @Test("a room whose drawers all left re-bins to no chests, the old chests are tombstoned, and a new capture sits on the room again")
    func emptyRoomRebinRetiresChests() async throws {
        let estate = try await makeEstate()
        let drawers = try await estate.captureBatch((0..<3).map { frame("short \($0)") })
        try await estate.rebinRoom(wing: "w", room: "study", now: Date(timeIntervalSince1970: 1_700_000_100))
        let chests = try await estate.chests(in: "w", room: "study")
        #expect(chests.count == 1)
        for d in drawers { try await estate.reanchor(rowID: d.id, toRoom: "attic") }
        #expect(try await estate.rebinRoom(wing: "w", room: "study", now: Date(timeIntervalSince1970: 1_700_000_200)) == 0)
        #expect(try await estate.chests(in: "w", room: "study").isEmpty)
        let retired = try await estate.nodeStore.getNode(id: UUID(uuidString: chests[0].chestNodeId)!)
        #expect(retired?.isTombstoned == true)
        let back = try await estate.capture(frame("short again"))
        #expect(try await estate.nodeStore.getNode(id: UUID(uuidString: back.parentNodeId)!)?.depth == 2)
        // A later re-bin that names the same chest again brings the tombstoned row back with the same id.
        #expect(try await estate.rebinRoom(wing: "w", room: "study", now: Date(timeIntervalSince1970: 1_700_000_300)) == 1)
        let revived = try await estate.chests(in: "w", room: "study")
        #expect(revived[0].chestNodeId == NodeStore.chestId(roomId: UUID(uuidString: back.parentNodeId)!, lowKeyHex: revived[0].lowKey.hex).uuidString)
        #expect(try await estate.nodeStore.getNode(id: UUID(uuidString: revived[0].chestNodeId)!)?.isActive == true)
        #expect(try await estate.chests(in: "w", room: "no-such-room").isEmpty)
        await #expect(throws: LocusKitError.self) {
            try await estate.rebinRoom(wing: "w", room: "no-such-room", now: Date(timeIntervalSince1970: 1_700_000_400))
        }
    }
}
