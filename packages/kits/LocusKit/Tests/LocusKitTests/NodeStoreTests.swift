import Foundation
import Testing
import PersistenceKit
import PersistenceKitSQLite
import SubstrateTypes
@testable import LocusKit

/// Tests for NodeStore: create-on-demand resolution, invariants,
/// tombstone lifecycle, and the no-resurrection guard (ADR-017).
struct NodeStoreTests {

    // MARK: - Helpers

    private func makeStore() async throws -> NodeStore {
        let url = TestStorage.tempURL()
        let storage = TestStorage.sqlite(url)
        try await storage.open(schema: LocusKitSchema.schema)
        return NodeStore(storage: storage)
    }

    // MARK: - Root creation

    @Test func createRootAndRetrieve() async throws {
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1000)
        let root = try await store.createRoot(displayName: "Estate", now: now)
        #expect(root.depth == 0)
        #expect(root.displayName == "Estate")
        #expect(root.lookupName == "estate")
        #expect(root.isActive)
        #expect(root.parentId == nil)

        let fetched = try await store.rootNode()
        #expect(fetched != nil)
        #expect(fetched?.id == root.id)
    }

    @Test func createRootIdempotent() async throws {
        let store = try await makeStore()
        let first = try await store.createRoot(displayName: "Estate", now: Date(timeIntervalSince1970: 1000))
        let second = try await store.createRoot(displayName: "Other", now: Date(timeIntervalSince1970: 1001))
        #expect(first.id == second.id)
    }

    // MARK: - Wing and room creation

    @Test func createWingAndRoom() async throws {
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1000)
        let root = try await store.createRoot(displayName: "Estate", now: now)

        let wing = try await store.createNode(
            displayName: "My Wing", parentId: root.id, now: Date(timeIntervalSince1970: 1001))
        #expect(wing.depth == 1)
        #expect(wing.displayName == "My Wing")
        #expect(wing.lookupName == "my wing")

        let room = try await store.createNode(
            displayName: "Room A", parentId: wing.id, now: Date(timeIntervalSince1970: 1002))
        #expect(room.depth == 2)
        #expect(room.displayName == "Room A")
        #expect(room.lookupName == "room a")
    }

    // MARK: - Create-on-demand resolution

    @Test func resolutionReturnsExisting() async throws {
        let store = try await makeStore()
        let root = try await store.createRoot(displayName: "Estate", now: Date(timeIntervalSince1970: 1000))
        let w1 = try await store.createNode(
            displayName: "Wing", parentId: root.id, now: Date(timeIntervalSince1970: 1001))
        let w2 = try await store.createNode(
            displayName: "  WING  ", parentId: root.id, now: Date(timeIntervalSince1970: 1002))
        #expect(w1.id == w2.id)
        #expect(w2.displayName == "Wing")
    }

    // MARK: - Invariant enforcement

    @Test func depthExceedsMaximum() async throws {
        let store = try await makeStore()
        let root = try await store.createRoot(displayName: "Estate", now: Date(timeIntervalSince1970: 1000))
        let wing = try await store.createNode(
            displayName: "Wing", parentId: root.id, now: Date(timeIntervalSince1970: 1001))
        let room = try await store.createNode(
            displayName: "Room", parentId: wing.id, now: Date(timeIntervalSince1970: 1002))

        await #expect(throws: LocusKitError.self) {
            _ = try await store.createNode(
                displayName: "Sub", parentId: room.id, now: Date(timeIntervalSince1970: 1003))
        }
    }

    @Test func parentMustExist() async throws {
        let store = try await makeStore()
        let fakeParent = UUID()

        await #expect(throws: LocusKitError.self) {
            _ = try await store.createNode(
                displayName: "Wing", parentId: fakeParent, now: Date(timeIntervalSince1970: 1000))
        }
    }

    // MARK: - Child nodes

    @Test func childNodesReturnsActiveOnly() async throws {
        let store = try await makeStore()
        let root = try await store.createRoot(displayName: "Estate", now: Date(timeIntervalSince1970: 1000))
        let w1 = try await store.createNode(
            displayName: "Alpha", parentId: root.id, now: Date(timeIntervalSince1970: 1001))
        let w2 = try await store.createNode(
            displayName: "Beta", parentId: root.id, now: Date(timeIntervalSince1970: 1002))
        _ = try await store.tombstoneNode(id: w1.id, now: Date(timeIntervalSince1970: 1003))

        let children = try await store.childNodes(parentId: root.id)
        #expect(children.count == 1)
        #expect(children[0].id == w2.id)
    }

    // MARK: - Tombstone

    @Test func tombstoneNodeSetsLifecycle() async throws {
        let store = try await makeStore()
        let root = try await store.createRoot(displayName: "Estate", now: Date(timeIntervalSince1970: 1000))
        let wing = try await store.createNode(
            displayName: "Wing", parentId: root.id, now: Date(timeIntervalSince1970: 1001))
        #expect(wing.isActive)

        let tombstoned = try await store.tombstoneNode(id: wing.id, now: Date(timeIntervalSince1970: 1002))
        #expect(tombstoned != nil)
        #expect(tombstoned!.isTombstoned)
        #expect(tombstoned!.tombstonedHlc != nil)
        #expect(tombstoned!.tombstonedAt != nil)
    }

    @Test func tombstoneIdempotent() async throws {
        let store = try await makeStore()
        let root = try await store.createRoot(displayName: "Estate", now: Date(timeIntervalSince1970: 1000))
        let wing = try await store.createNode(
            displayName: "Wing", parentId: root.id, now: Date(timeIntervalSince1970: 1001))
        let t1 = try await store.tombstoneNode(id: wing.id, now: Date(timeIntervalSince1970: 1002))
        let t2 = try await store.tombstoneNode(id: wing.id, now: Date(timeIntervalSince1970: 1003))
        #expect(t1!.tombstonedHlc!.packed == t2!.tombstonedHlc!.packed)
    }

    @Test func tombstoneNonexistentReturnsNil() async throws {
        let store = try await makeStore()
        let result = try await store.tombstoneNode(id: UUID(), now: Date(timeIntervalSince1970: 1000))
        #expect(result == nil)
    }

    // MARK: - Get node

    @Test func getNodeById() async throws {
        let store = try await makeStore()
        let root = try await store.createRoot(displayName: "Estate", now: Date(timeIntervalSince1970: 1000))
        let fetched = try await store.getNode(id: root.id)
        #expect(fetched?.id == root.id)

        let missing = try await store.getNode(id: UUID())
        #expect(missing == nil)
    }
}
