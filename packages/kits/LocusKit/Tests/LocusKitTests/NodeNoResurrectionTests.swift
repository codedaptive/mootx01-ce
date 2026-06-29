import Foundation
import Testing
import PersistenceKit
import PersistenceKitSQLite
import SubstrateTypes
@testable import LocusKit

/// No-resurrection guard conformance tests (ADR-017 §5).
///
/// These tests verify that tombstoned nodes are structurally invisible
/// to create-on-demand resolution:
///   - A tombstoned node is never returned by createNode resolution.
///   - A fresh active node can be created with the same lookupName as
///     a tombstoned one.
///   - Resolution never flips a tombstoned node back to active.
///   - Both active and tombstoned can exist with the same lookupName
///     under the same parent.
struct NodeNoResurrectionTests {

    // MARK: - Helpers

    private func makeStore() async throws -> NodeStore {
        let url = TestStorage.tempURL()
        let storage = TestStorage.sqlite(url)
        try await storage.open(schema: LocusKitSchema.schema)
        return NodeStore(storage: storage)
    }

    // MARK: - No-resurrection guard

    @Test func tombstonedNodeInvisibleToResolution() async throws {
        let store = try await makeStore()
        let root = try await store.createRoot(
            displayName: "Estate", now: Date(timeIntervalSince1970: 1000))
        let wing = try await store.createNode(
            displayName: "Wing", parentId: root.id,
            now: Date(timeIntervalSince1970: 1001))
        _ = try await store.tombstoneNode(
            id: wing.id, now: Date(timeIntervalSince1970: 1002))

        // Create-on-demand with same name — must NOT return the
        // tombstoned node. A fresh node is minted instead.
        let fresh = try await store.createNode(
            displayName: "Wing", parentId: root.id,
            now: Date(timeIntervalSince1970: 1003))
        #expect(fresh.id != wing.id)
        #expect(fresh.isActive)
        #expect(fresh.lookupName == "wing")
    }

    @Test func freshNodeAllowedWithSameLookupNameAsTombstoned() async throws {
        let store = try await makeStore()
        let root = try await store.createRoot(
            displayName: "Estate", now: Date(timeIntervalSince1970: 1000))
        let original = try await store.createNode(
            displayName: "My Wing", parentId: root.id,
            now: Date(timeIntervalSince1970: 1001))
        _ = try await store.tombstoneNode(
            id: original.id, now: Date(timeIntervalSince1970: 1002))

        let fresh = try await store.createNode(
            displayName: "my wing", parentId: root.id,
            now: Date(timeIntervalSince1970: 1003))

        // Fresh node is distinct from the tombstoned one.
        #expect(fresh.id != original.id)
        #expect(fresh.isActive)
        // The tombstoned node is still tombstoned.
        let tombstoned = try await store.getNode(id: original.id)
        #expect(tombstoned?.isTombstoned == true)
    }

    @Test func resolutionNeverFlipsTombstonedToActive() async throws {
        let store = try await makeStore()
        let root = try await store.createRoot(
            displayName: "Estate", now: Date(timeIntervalSince1970: 1000))
        let wing = try await store.createNode(
            displayName: "Wing", parentId: root.id,
            now: Date(timeIntervalSince1970: 1001))
        _ = try await store.tombstoneNode(
            id: wing.id, now: Date(timeIntervalSince1970: 1002))

        // Multiple create-on-demand calls should never reactivate.
        _ = try await store.createNode(
            displayName: "Wing", parentId: root.id,
            now: Date(timeIntervalSince1970: 1003))
        _ = try await store.createNode(
            displayName: "wing", parentId: root.id,
            now: Date(timeIntervalSince1970: 1004))

        let original = try await store.getNode(id: wing.id)
        #expect(original?.isTombstoned == true)
        #expect(original?.lifecycle == 1)
    }

    @Test func activeAndTombstonedCoexistWithSameLookupName() async throws {
        let store = try await makeStore()
        let root = try await store.createRoot(
            displayName: "Estate", now: Date(timeIntervalSince1970: 1000))

        // Create and tombstone two nodes with the same name.
        let first = try await store.createNode(
            displayName: "Wing", parentId: root.id,
            now: Date(timeIntervalSince1970: 1001))
        _ = try await store.tombstoneNode(
            id: first.id, now: Date(timeIntervalSince1970: 1002))

        let second = try await store.createNode(
            displayName: "Wing", parentId: root.id,
            now: Date(timeIntervalSince1970: 1003))
        _ = try await store.tombstoneNode(
            id: second.id, now: Date(timeIntervalSince1970: 1004))

        // Create a third — fresh active node.
        let third = try await store.createNode(
            displayName: "Wing", parentId: root.id,
            now: Date(timeIntervalSince1970: 1005))

        // All three coexist: two tombstoned, one active.
        #expect(first.id != second.id)
        #expect(second.id != third.id)
        #expect(first.id != third.id)

        let f = try await store.getNode(id: first.id)
        let s = try await store.getNode(id: second.id)
        let t = try await store.getNode(id: third.id)
        #expect(f?.isTombstoned == true)
        #expect(s?.isTombstoned == true)
        #expect(t?.isActive == true)
    }

    @Test func childNodesExcludesTombstoned() async throws {
        let store = try await makeStore()
        let root = try await store.createRoot(
            displayName: "Estate", now: Date(timeIntervalSince1970: 1000))
        let w1 = try await store.createNode(
            displayName: "Alpha", parentId: root.id,
            now: Date(timeIntervalSince1970: 1001))
        _ = try await store.createNode(
            displayName: "Beta", parentId: root.id,
            now: Date(timeIntervalSince1970: 1002))
        _ = try await store.tombstoneNode(
            id: w1.id, now: Date(timeIntervalSince1970: 1003))

        let children = try await store.childNodes(parentId: root.id)
        #expect(children.count == 1)
        #expect(children[0].lookupName == "beta")
    }
}
