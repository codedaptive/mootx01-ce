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
            #expect(chest.chestNodeId == NodeStore.chestId(roomId: roomId, name: chest.lowKey.hex).uuidString,
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
        // them. The re-bin itself stores every chest's root and rolls the
        // room up over them (no recompute pass in between), so a later
        // incremental rollup folds current sibling roots; the full recompute
        // must then agree with what the re-bin stored.
        for chest in chests {
            let node = try await estate.nodeStore.getNode(id: UUID(uuidString: chest.chestNodeId)!)
            #expect(node?.merkleRoot != nil, "the re-bin stores a root on every chest it deals")
            #expect(node?.merkleRoot == (try await estate.computeChestMerkleRoot(chestNodeId: node!.id)))
        }
        let roomRoot = try await estate.computeRoomMerkleRoot(roomNodeId: roomId)
        #expect(roomRoot != rootBefore, "the room root folds its chests' roots")
        #expect(try await estate.nodeStore.getNode(id: roomId)?.merkleRoot == roomRoot, "the re-bin rolled the room up")
        var storedRoots: [MerkleRoot?] = []
        for chest in chests { storedRoots.append(try await estate.nodeStore.getNode(id: UUID(uuidString: chest.chestNodeId)!)?.merkleRoot) }
        try await estate.recomputeAllMerkleRoots(now: Date(timeIntervalSince1970: 1_700_000_101))
        var recomputedRoots: [MerkleRoot?] = []
        for chest in chests { recomputedRoots.append(try await estate.nodeStore.getNode(id: UUID(uuidString: chest.chestNodeId)!)?.merkleRoot) }
        #expect(recomputedRoots == storedRoots, "the full recompute agrees with the roots the re-bin stored")
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
        #expect(revived[0].chestNodeId == NodeStore.chestId(roomId: UUID(uuidString: back.parentNodeId)!, name: revived[0].lowKey.hex).uuidString)
        #expect(try await estate.nodeStore.getNode(id: UUID(uuidString: revived[0].chestNodeId)!)?.isActive == true)
        #expect(try await estate.chests(in: "w", room: "no-such-room").isEmpty)
        await #expect(throws: LocusKitError.self) {
            try await estate.rebinRoom(wing: "w", room: "no-such-room", now: Date(timeIntervalSince1970: 1_700_000_400))
        }
    }

    @Test("identical content deals into one chest per 250-row range, each its own node, and the audit event counts them")
    func identicalContentDoesNotCollapseChests() async throws {
        let estate = try await makeEstate()
        _ = try await estate.captureBatch((0..<500).map { _ in frame("the same note every time") })
        let auditBefore = try await estate.store.storage.auditLog.count()
        #expect(try await estate.rebinRoom(wing: "w", room: "study", now: Date(timeIntervalSince1970: 1_700_000_100)) == 2)
        let chests = try await estate.chests(in: "w", room: "study")
        #expect(chests.map(\.count) == [250, 250], "two ranges at one key are two chests, not one chest of 500")
        #expect(Set(chests.map(\.chestNodeId)).count == 2)
        #expect(chests.map(\.lowKey) == [chests[0].lowKey, chests[0].lowKey], "both chests carry the same low key")
        let hex = chests[0].lowKey.hex
        let roomId = try #require(try await estate.nodeStore.getNode(id: UUID(uuidString: chests[0].chestNodeId)!)?.parentId)
        #expect(chests.map(\.chestNodeId) == [
            NodeStore.chestId(roomId: roomId, name: NodeStore.chestName(lowKeyHex: hex, hidden: false, ordinal: 0)).uuidString,
            NodeStore.chestId(roomId: roomId, name: NodeStore.chestName(lowKeyHex: hex, hidden: false, ordinal: 1)).uuidString,
        ], "the second range at a key is named by ordinal and gets its own derived id")
        #expect(try await estate.store.storage.auditLog.count() == auditBefore + 1)
        // A new capture at the same key joins the newest range at that key.
        let more = try await estate.capture(frame("the same note every time"))
        #expect(more.parentNodeId == chests[1].chestNodeId)
    }

    @Test("restricted and secret drawers deal into hidden chests, and their presence never moves a visible drawer's chest")
    func hiddenDrawersDealApart() async throws {
        // Visible-only estate: the reference deal.
        let reference = try await makeEstate()
        _ = try await reference.captureBatch((0..<600).map { frame("note \($0) on topic \($0 % 7)") })
        _ = try await reference.rebinRoom(wing: "w", room: "study", now: Date(timeIntervalSince1970: 1_700_000_100))
        let referenceChests = try await reference.chests(in: "w", room: "study")
        let referenceParents = Dictionary(uniqueKeysWithValues:
            try await reference.drawersIn(wing: "w", room: "study").map { ($0.content, $0.parentNodeId) })

        // The same visible drawers plus 300 hidden ones interleaved by key.
        let estate = try await makeEstate()
        var frames = (0..<600).map { frame("note \($0) on topic \($0 % 7)") }
        for i in 0..<300 {
            var f = frame("hidden note \(i) on topic \(i % 5)")
            f.sensitivity = i % 2 == 0 ? .restricted : .secret
            frames.append(f)
        }
        _ = try await estate.captureBatch(frames)
        #expect(try await estate.rebinRoom(wing: "w", room: "study", now: Date(timeIntervalSince1970: 1_700_000_100)) == 5)
        let chests = try await estate.chests(in: "w", room: "study")
        let roomId = try await estate.nodeStore.getNode(id: UUID(uuidString: chests[0].chestNodeId)!)!.parentId!
        var hiddenChests = Set<String>()
        for chest in chests {
            let node = try await estate.nodeStore.getNode(id: UUID(uuidString: chest.chestNodeId)!)!
            if NodeStore.chestIsHidden(name: node.displayName) { hiddenChests.insert(chest.chestNodeId) }
        }
        #expect(hiddenChests.count == 2, "300 hidden drawers deal into two hidden chests")
        // Visible drawers sit in chests named exactly as in the reference estate:
        // hidden drawers moved no visible boundary.
        let visibleNames = Set(chests.filter { !hiddenChests.contains($0.chestNodeId) }.map(\.lowKey.hex))
        #expect(visibleNames == Set(referenceChests.map(\.lowKey.hex)))
        for d in try await estate.drawersIn(wing: "w", room: "study") {
            let node = try await estate.nodeStore.getNode(id: UUID(uuidString: d.parentNodeId)!)!
            let hidden = d.adjectiveSensitivity == .restricted || d.adjectiveSensitivity == .secret
            #expect(NodeStore.chestIsHidden(name: node.displayName) == hidden, "a drawer sits in a chest of its own class")
            if !hidden {
                let referenceNode = try await reference.nodeStore.getNode(id: UUID(uuidString: referenceParents[d.content]!)!)!
                #expect(node.displayName == referenceNode.displayName, "same visible chest as without any hidden drawer")
            }
        }
        // Placement of new captures follows the class.
        var secret = frame("a brand new secret")
        secret.sensitivity = .secret
        let placedSecret = try await estate.capture(secret)
        #expect(hiddenChests.contains(placedSecret.parentNodeId))
        let placedVisible = try await estate.capture(frame("a brand new visible note"))
        #expect(!hiddenChests.contains(placedVisible.parentNodeId) && placedVisible.parentNodeId != roomId.uuidString)
    }
}
