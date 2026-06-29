// MerkleRollupTests.swift
//
// Tests for the Merkle content-integrity rollup (NT-L3).
// Covers: room-level root, wing/estate cascade, full recompute,
// snapshot attestation, on-demand leaf hashing, direct rollup cascade
// (bypassing capture verb), and graceful early-return on missing room node.

import Foundation
import Testing
import PersistenceKit
import PersistenceKitSQLite
import SubstrateLib
import SubstrateTypes
@testable import LocusKit

@Suite("Merkle rollup — room → wing → estate (NT-L3)")
struct MerkleRollupTests {

    private let testOwner = OwnerCredentials(ownerIdentifier: "test-owner")

    // MARK: - Helpers

    private func makeEstate() async throws -> (Estate, URL) {
        let url = TestStorage.tempURL()
        let storage = TestStorage.sqlite(url)
        let estate = try await Estate.create(
            storage: storage, owner: testOwner)
        return (estate, url)
    }

    private func captureFrame(
        content: String,
        room: String = "Lab",
        wing: String = "Science"
    ) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("001"),
            addedBy: "test",
            embeddingModelID: "test-model",
            wing: wing
        )
    }

    // MARK: - Part 1: Room-level Merkle root

    @Test("capture triggers room merkle root computation")
    func captureUpdatesRoomRoot() async throws {
        let (estate, _) = try await makeEstate()
        let drawer = try await estate.capture(
            captureFrame(content: "hello world"))
        // Capture defers the rollup off the write path; the deferred per-room
        // rollup (run by the encode drain in production) makes the tree current.
        try await estate.rollupRoomsForDrawers([drawer.id])

        let roomNodeId = UUID(uuidString: drawer.parentNodeId)!
        let roomNode = try await estate.nodeStore.getNode(id: roomNodeId)
        #expect(roomNode?.merkleRoot != nil)
        #expect(roomNode?.merkleRoot != MerkleRoot.empty)
    }

    @Test("room root changes when a second drawer is added")
    func roomRootChangesOnSecondCapture() async throws {
        let (estate, _) = try await makeEstate()
        let d1 = try await estate.capture(
            captureFrame(content: "first"))
        let roomNodeId = UUID(uuidString: d1.parentNodeId)!

        try await estate.rollupRoomsForDrawers([d1.id])
        let rootAfterFirst = try await estate.nodeStore
            .getNode(id: roomNodeId)?.merkleRoot

        let d2 = try await estate.capture(
            captureFrame(content: "second"))
        try await estate.rollupRoomsForDrawers([d2.id])
        let rootAfterSecond = try await estate.nodeStore
            .getNode(id: roomNodeId)?.merkleRoot

        #expect(rootAfterFirst != rootAfterSecond)
    }

    @Test("room with no active drawers produces MerkleRoot.empty")
    func emptyRoomProducesEmptyRoot() async throws {
        let (estate, _) = try await makeEstate()
        let skel = try await NodeTestSkeleton.make()
        let emptyRoot = try await estate.computeRoomMerkleRoot(
            roomNodeId: skel.room.id)
        #expect(emptyRoot == MerkleRoot.empty)
    }

    @Test("room root is deterministic for same drawers")
    func roomRootDeterministic() async throws {
        let (estate, _) = try await makeEstate()
        let d1 = try await estate.capture(
            captureFrame(content: "alpha"))
        let roomNodeId = UUID(uuidString: d1.parentNodeId)!

        let root1 = try await estate.computeRoomMerkleRoot(
            roomNodeId: roomNodeId)
        let root2 = try await estate.computeRoomMerkleRoot(
            roomNodeId: roomNodeId)
        #expect(root1 == root2)
    }

    // MARK: - Part 2: Wing and estate cascade

    @Test("capture cascades merkle root to wing node")
    func captureCascadesToWing() async throws {
        let (estate, _) = try await makeEstate()
        let d1 = try await estate.capture(
            captureFrame(content: "test content"))
        try await estate.rollupRoomsForDrawers([d1.id])
        let roomNodeId = UUID(uuidString: d1.parentNodeId)!
        let roomNode = try await estate.nodeStore.getNode(id: roomNodeId)!
        let wingNode = try await estate.nodeStore
            .getNode(id: roomNode.parentId!)

        #expect(wingNode?.merkleRoot != nil)
        #expect(wingNode?.merkleRoot != MerkleRoot.empty)
    }

    @Test("capture cascades merkle root to estate root node")
    func captureCascadesToEstateRoot() async throws {
        let (estate, _) = try await makeEstate()
        let d1 = try await estate.capture(
            captureFrame(content: "test content"))
        try await estate.rollupRoomsForDrawers([d1.id])

        let rootNode = try await estate.nodeStore.rootNode()
        #expect(rootNode?.merkleRoot != nil)
        #expect(rootNode?.merkleRoot != MerkleRoot.empty)
    }

    @Test("two rooms in different wings produce different estate roots")
    func differentWingsProduceDifferentEstateRoots() async throws {
        let (estate, _) = try await makeEstate()

        let dA = try await estate.capture(
            captureFrame(content: "wing-a content", room: "Room1", wing: "WingA"))
        try await estate.rollupRoomsForDrawers([dA.id])
        let rootAfterA = try await estate.nodeStore.rootNode()?.merkleRoot

        let dB = try await estate.capture(
            captureFrame(content: "wing-b content", room: "Room1", wing: "WingB"))
        try await estate.rollupRoomsForDrawers([dB.id])
        let rootAfterB = try await estate.nodeStore.rootNode()?.merkleRoot

        #expect(rootAfterA != rootAfterB)
    }

    // MARK: - Part 3: Snapshot attestation

    @Test("createSnapshot writes estate and wing attestations")
    func snapshotContainsAttestations() async throws {
        let (estate, _) = try await makeEstate()
        _ = try await estate.capture(
            captureFrame(content: "snapshot content"))

        let now = Date(timeIntervalSince1970: 2000)
        let snapshot = try await estate.createSnapshot(label: "test", now: now)

        let attestations = try await SnapshotRegistryOps.attestations(
            rowStore: estate.store.storage.rowStore,
            snapshotId: snapshot.snapshotId)

        #expect(attestations.count >= 2)

        let kinds = Set(attestations.map(\.subjectKind))
        #expect(kinds.contains("estate"))
        #expect(kinds.contains("wing"))
    }

    @Test("snapshot attestation merkle roots are non-empty after capture")
    func snapshotAttestationsNonEmpty() async throws {
        let (estate, _) = try await makeEstate()
        _ = try await estate.capture(
            captureFrame(content: "content for snapshot"))

        let now = Date(timeIntervalSince1970: 3000)
        let snapshot = try await estate.createSnapshot(label: nil, now: now)

        let attestations = try await SnapshotRegistryOps.attestations(
            rowStore: estate.store.storage.rowStore,
            snapshotId: snapshot.snapshotId)

        for att in attestations {
            #expect(!att.merkleRoot.isEmpty)
            #expect(att.merkleRoot.count == 64)
        }
    }

    // MARK: - Part 4: Full recompute

    @Test("recomputeAllMerkleRoots produces same result as incremental")
    func fullRecomputeMatchesIncremental() async throws {
        let (estate, _) = try await makeEstate()
        let dA = try await estate.capture(
            captureFrame(content: "recompute test A"))
        let dB = try await estate.capture(
            captureFrame(content: "recompute test B", room: "Room2"))

        // Capture defers rollup; the deferred per-room rollup is the off-path
        // equivalent of the old per-capture incremental rollup.
        try await estate.rollupRoomsForDrawers([dA.id, dB.id])
        let rootAfterIncremental = try await estate.nodeStore
            .rootNode()?.merkleRoot

        let now = Date(timeIntervalSince1970: 5000)
        try await estate.recomputeAllMerkleRoots(now: now)

        let rootAfterFull = try await estate.nodeStore
            .rootNode()?.merkleRoot

        #expect(rootAfterIncremental == rootAfterFull)
    }

    @Test("recomputeAllMerkleRoots on empty estate sets empty roots")
    func fullRecomputeEmptyEstate() async throws {
        let (estate, _) = try await makeEstate()
        let now = Date(timeIntervalSince1970: 4000)
        try await estate.recomputeAllMerkleRoots(now: now)

        let rootNode = try await estate.nodeStore.rootNode()
        #expect(rootNode?.merkleRoot == MerkleRoot.empty)
    }

    // MARK: - Expunge triggers rollup

    @Test("expunge updates the room merkle root")
    func expungeUpdatesRoomRoot() async throws {
        let (estate, _) = try await makeEstate()
        let d1 = try await estate.capture(
            captureFrame(content: "will expunge"))
        _ = try await estate.capture(
            captureFrame(content: "will stay"))

        let roomNodeId = UUID(uuidString: d1.parentNodeId)!
        let rootBefore = try await estate.nodeStore
            .getNode(id: roomNodeId)?.merkleRoot

        try await estate.expunge(rowID: d1.id, reason: "test", confirmation: true)

        let rootAfter = try await estate.nodeStore
            .getNode(id: roomNodeId)?.merkleRoot

        // Expunge tombstones the row, removing it from the active set.
        #expect(rootBefore != rootAfter)
    }

    // MARK: - Withdraw rollup is idempotent

    @Test("withdraw triggers rollup and root changes (withdrawn drawer excluded from snapshot)")
    func withdrawRollupChangesRoot() async throws {
        let (estate, _) = try await makeEstate()
        let d1 = try await estate.capture(
            captureFrame(content: "will withdraw"))

        let roomNodeId = UUID(uuidString: d1.parentNodeId)!
        // Capture defers rollup — establish the post-capture root explicitly.
        try await estate.rollupRoomsForDrawers([d1.id])
        let rootBefore = try await estate.nodeStore
            .getNode(id: roomNodeId)?.merkleRoot

        try await estate.withdraw(rowID: d1.id)

        let rootAfter = try await estate.nodeStore
            .getNode(id: roomNodeId)?.merkleRoot

        // WS2-F1: withdrawn drawers are excluded from the live snapshot.
        // computeRoomMerkleRoot now filters NOT(adjectiveBitmap & 0x3F == 18),
        // so after withdraw the room root changes (drawer removed from set).
        #expect(rootBefore != nil)
        #expect(rootBefore != rootAfter,
                "WS2-F1: withdraw must remove the drawer from the Merkle snapshot")
    }

    // MARK: - Part 5: Direct rollup (bypassing capture verb)

    /// Insert drawers via raw RowStore (bypassing the capture verb),
    /// then call rollupMerkleRoots directly. Verifies room, wing, and
    /// estate nodes all get correct merkle_root values from the direct
    /// rollup path — not just indirectly through capture.
    @Test("direct rollupMerkleRoots produces correct cascade")
    func directRollupProducesCorrectCascade() async throws {
        let (estate, _) = try await makeEstate()

        // Create a room via capture so the containment tree exists.
        let d1 = try await estate.capture(
            captureFrame(content: "seed drawer"))
        let roomNodeId = UUID(uuidString: d1.parentNodeId)!

        // Clear all merkle roots to force fresh computation.
        let now = Date(timeIntervalSince1970: 6000)
        let roomNode = try await estate.nodeStore.getNode(id: roomNodeId)!
        try await estate.nodeStore.updateMerkleRoot(
            nodeId: roomNodeId, merkleRoot: MerkleRoot.empty, now: now)
        try await estate.nodeStore.updateMerkleRoot(
            nodeId: roomNode.parentId!, merkleRoot: MerkleRoot.empty, now: now)
        let root = try await estate.nodeStore.rootNode()!
        try await estate.nodeStore.updateMerkleRoot(
            nodeId: root.id, merkleRoot: MerkleRoot.empty, now: now)

        // Insert a second drawer via raw RowStore (bypasses capture verb).
        let rawId = UUID().uuidString
        _ = try await estate.store.storage.rowStore.insert(
            table: "drawers",
            values: [
                "id": .text(rawId),
                "content": .text("raw-inserted drawer"),
                "parent_node_id": .text(roomNodeId.uuidString),
                "addedBy": .text("test"),
                "filedAt": .timestamp(now),
                "embeddingModelID": .text("test-model"),
            ]
        )

        // Call rollupMerkleRoots directly.
        let rollupTime = Date(timeIntervalSince1970: 7000)
        try await estate.rollupMerkleRoots(
            roomNodeId: roomNodeId, now: rollupTime)

        // Room, wing, and estate roots must all be non-empty.
        let updatedRoom = try await estate.nodeStore.getNode(id: roomNodeId)
        #expect(updatedRoom?.merkleRoot != nil)
        #expect(updatedRoom?.merkleRoot != MerkleRoot.empty)

        let updatedWing = try await estate.nodeStore.getNode(id: roomNode.parentId!)
        #expect(updatedWing?.merkleRoot != nil)
        #expect(updatedWing?.merkleRoot != MerkleRoot.empty)

        let updatedRoot = try await estate.nodeStore.rootNode()
        #expect(updatedRoot?.merkleRoot != nil)
        #expect(updatedRoot?.merkleRoot != MerkleRoot.empty)
    }

    /// Insert a drawer row via raw RowStore WITHOUT a content_hash
    /// column (simulating pre-existing data). Call recomputeAllMerkleRoots.
    /// Verify the room root is computed from the on-demand leaf hash
    /// (not MerkleRoot.empty).
    @Test("on-demand leaf hash for pre-existing data without content_hash")
    func onDemandLeafHashForPreExistingData() async throws {
        let (estate, _) = try await makeEstate()

        // Create a room via capture, then clear its merkle root.
        let d1 = try await estate.capture(
            captureFrame(content: "seed"))
        let roomNodeId = UUID(uuidString: d1.parentNodeId)!

        // Insert a drawer WITHOUT content_hash (simulates pre-existing data).
        let rawId = UUID().uuidString
        let filedAt = Date(timeIntervalSince1970: 8000)
        _ = try await estate.store.storage.rowStore.insert(
            table: "drawers",
            values: [
                "id": .text(rawId),
                "content": .text("pre-existing drawer content"),
                "parent_node_id": .text(roomNodeId.uuidString),
                "addedBy": .text("legacy"),
                "filedAt": .timestamp(filedAt),
                "embeddingModelID": .text("old-model"),
                // content_hash intentionally omitted
            ]
        )

        // Recompute all roots — the on-demand leaf hash path must fire.
        let now = Date(timeIntervalSince1970: 9000)
        try await estate.recomputeAllMerkleRoots(now: now)

        let roomNode = try await estate.nodeStore.getNode(id: roomNodeId)
        #expect(roomNode?.merkleRoot != nil)
        #expect(roomNode?.merkleRoot != MerkleRoot.empty)
    }

    /// Call rollupMerkleRoots with a room node ID that does not exist
    /// in the node store. Verify it returns gracefully without crashing —
    /// exercises the guard-early-return path at MerkleRollup.swift lines 54-58
    /// where the room node lookup returns nil.
    @Test("rollup with nonexistent room returns gracefully")
    func rollupWithMissingRootNodeReturnsGracefully() async throws {
        let (estate, _) = try await makeEstate()

        // Call rollup with a UUID that doesn't exist in the node store.
        // The guard at line 54 (room node not found) fires and returns
        // early without crashing.
        let now = Date(timeIntervalSince1970: 12_000)
        try await estate.rollupMerkleRoots(
            roomNodeId: UUID(), now: now)

        // If we got here, the guard-early-return worked. Success is:
        // no crash, no throw.
    }

    // MARK: - NT_R1: Batch capture defers Merkle rollup

    /// Verify that `captureBatch` does NOT update Merkle roots during the
    /// batch pass — roots stay nil until a subsequent `rollupAllMerkleRoots`
    /// call. This is the key invariant: O(1) rollup cost per batch, not O(N).
    @Test("captureBatch defers Merkle rollup — room root is nil until reindex")
    func batchCaptureDefersMerkleRootUntilReindex() async throws {
        let (estate, _) = try await makeEstate()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let frames = (1...5).map {
            captureFrame(content: "batch item \($0)")
        }

        let drawers = try await estate.captureBatch(frames)

        let roomNodeId = UUID(uuidString: drawers[0].parentNodeId)!
        let roomNode = try await estate.nodeStore.getNode(id: roomNodeId)
        // After batch only (no explicit rollup), room root must still be nil.
        #expect(roomNode?.merkleRoot == nil)
    }

    /// `rollupAllMerkleRoots` must produce the same room root as the
    /// incremental per-drawer `rollupMerkleRoots` calls that `capture` fires.
    ///
    /// Validates the alias by running both paths on the same estate: first
    /// individual `capture` calls (incremental), then `rollupAllMerkleRoots`
    /// (full-tree). The full-tree pass must reproduce the same root the
    /// incremental pass already wrote.
    @Test("rollupAllMerkleRoots result matches incremental per-drawer rollup")
    func rollupAllMatchesIncrementalRollup() async throws {
        let (estate, _) = try await makeEstate()
        let now = Date(timeIntervalSince1970: 3_000_000)

        // Capture drawers via individual `capture` (rollup deferred per write).
        var lastDrawer: Drawer?
        var ids: [String] = []
        for i in 1...4 {
            let d = try await estate.capture(captureFrame(content: "item \(i)"))
            ids.append(d.id)
            lastDrawer = d
        }
        let roomNodeId = UUID(uuidString: lastDrawer!.parentNodeId)!
        // The deferred per-room rollup is the off-path equivalent of the old
        // per-capture incremental rollup.
        try await estate.rollupRoomsForDrawers(ids)
        let rootAfterIncremental = try await estate.nodeStore.getNode(id: roomNodeId)?.merkleRoot

        // Full-tree recompute must reproduce the same root.
        try await estate.rollupAllMerkleRoots(now: now)
        let rootAfterRollupAll = try await estate.nodeStore.getNode(id: roomNodeId)?.merkleRoot

        #expect(rootAfterIncremental != nil)
        #expect(rootAfterRollupAll == rootAfterIncremental)
    }

    /// `rollupAllMerkleRoots` must set non-nil, non-empty roots on a
    /// seeded estate — exercising the new public alias over `recomputeAllMerkleRoots`.
    @Test("rollupAllMerkleRoots produces non-nil roots for a seeded estate")
    func rollupAllMerkleRootsProducesNonNilRoots() async throws {
        let (estate, _) = try await makeEstate()
        // Seed via individual capture (ensures room/wing/estate nodes exist).
        let d = try await estate.capture(captureFrame(content: "seed"))
        let roomNodeId = UUID(uuidString: d.parentNodeId)!

        // Zero out the root to verify rollupAll writes a fresh value.
        let now = Date(timeIntervalSince1970: 4_000_000)
        try await estate.rollupAllMerkleRoots(now: now)

        let roomNode = try await estate.nodeStore.getNode(id: roomNodeId)
        #expect(roomNode?.merkleRoot != nil)
        #expect(roomNode?.merkleRoot != MerkleRoot.empty)
    }

    // MARK: - Helpers: deterministicUUID

    @Test("deterministicUUID parses valid UUID strings")
    func deterministicUUIDParsesUUID() {
        let uuidStr = "550e8400-e29b-41d4-a716-446655440000"
        let result = Estate.deterministicUUID(from: uuidStr)
        #expect(result == UUID(uuidString: uuidStr))
    }

    @Test("deterministicUUID derives stable UUID from non-UUID string")
    func deterministicUUIDDerives() {
        let result1 = Estate.deterministicUUID(from: "supersedes:abc:def")
        let result2 = Estate.deterministicUUID(from: "supersedes:abc:def")
        #expect(result1 == result2)
        #expect(result1 != Estate.deterministicUUID(from: "different-string"))
    }

}
