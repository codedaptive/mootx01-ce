import Foundation
import Testing
import PersistenceKit
import PersistenceKitSQLite
import SubstrateTypes
@testable import LocusKit

/// Shared test-skeleton helper for the NT mission family.
///
/// Provides a minimal estate skeleton: root node, one wing, one room.
/// Every subsequent NT mission test that needs a containment tree
/// uses this helper instead of building the tree by hand.
enum NodeTestSkeleton {

    /// A minimal three-node estate skeleton.
    struct Skeleton {
        let store: NodeStore
        let root: Node
        let wing: Node
        let room: Node
    }

    /// Stand up a fresh SQLite-backed NodeStore with a root, one wing,
    /// and one room. The wing is named "Default Wing" and the room is
    /// named "Default Room".
    static func make(
        wingName: String = "Default Wing",
        roomName: String = "Default Room",
        now: Date = Date(timeIntervalSince1970: 1000)
    ) async throws -> Skeleton {
        let url = TestStorage.tempURL()
        let storage = TestStorage.sqlite(url)
        try await storage.open(schema: LocusKitSchema.schema)
        let store = NodeStore(storage: storage)

        let root = try await store.createRoot(displayName: "Estate", now: now)
        let wing = try await store.createNode(
            displayName: wingName, parentId: root.id,
            now: Date(timeIntervalSince1970: now.timeIntervalSince1970 + 1))
        let room = try await store.createNode(
            displayName: roomName, parentId: wing.id,
            now: Date(timeIntervalSince1970: now.timeIntervalSince1970 + 2))

        return Skeleton(store: store, root: root, wing: wing, room: room)
    }
}

/// Verify the skeleton helper itself works and produces valid nodes.
struct NodeTestSkeletonTests {

    @Test func skeletonProducesValidThreeNodeTree() async throws {
        let skel = try await NodeTestSkeleton.make()
        #expect(skel.root.depth == 0)
        #expect(skel.root.parentId == nil)
        #expect(skel.root.isActive)

        #expect(skel.wing.depth == 1)
        #expect(skel.wing.parentId == skel.root.id)
        #expect(skel.wing.lookupName == "default wing")
        #expect(skel.wing.isActive)

        #expect(skel.room.depth == 2)
        #expect(skel.room.parentId == skel.wing.id)
        #expect(skel.room.lookupName == "default room")
        #expect(skel.room.isActive)
    }

    @Test func skeletonCustomNames() async throws {
        let skel = try await NodeTestSkeleton.make(
            wingName: "Science", roomName: "Lab A")
        #expect(skel.wing.displayName == "Science")
        #expect(skel.room.displayName == "Lab A")
    }

    @Test func skeletonChildNodesCorrect() async throws {
        let skel = try await NodeTestSkeleton.make()
        let wings = try await skel.store.childNodes(parentId: skel.root.id)
        #expect(wings.count == 1)
        #expect(wings[0].id == skel.wing.id)

        let rooms = try await skel.store.childNodes(parentId: skel.wing.id)
        #expect(rooms.count == 1)
        #expect(rooms[0].id == skel.room.id)
    }
}
