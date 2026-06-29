// MerkleRollup.swift
//
// Merkle content-integrity rollup: room → wing → estate (NT-L3).
//
// The rollup is called explicitly — not automatically after each drawer
// write. Current capture paths defer it. When invoked, it recomputes
// the affected subtree bottom-up:
//   1. Room root: MerkleHash.interior over the room's active drawers.
//   2. Wing root: MerkleHash.interior over the wing's room roots.
//   3. Estate root: MerkleHash.interior over the wing roots.
//
// The dirty-chain strategy limits recomputation to the changed subtree
// (one room, one wing, one estate). The full-recompute verb
// (recomputeAllMerkleRoots) does a bottom-up scan of every room.
//
// Content hashes are read from the `content_hash` column when stored
// (by the hash-on-write hook). For rows without a stored hash (NULL),
// a leaf hash is computed on-demand from the drawer's content.

import Foundation
import OSLog
import PersistenceKit
import SubstrateLib
import SubstrateTypes
import SubstrateKernel

private let rollupLog = Logger(subsystem: "com.mootx01.kit", category: "LocusKit.MerkleRollup")

// MARK: - Incremental rollup (Parts 1–2)

extension Estate {

    /// Recompute Merkle roots up the containment tree from a room to the
    /// estate root. Called after a drawer write to incrementally update
    /// the affected subtree.
    ///
    /// Resolves the wing and estate nodes from the room's parent chain
    /// so callers only need to supply the room node ID.
    ///
    /// - Parameters:
    ///   - roomNodeId: The room node whose drawers changed.
    ///   - now: Deterministic wall-clock for node updated_at.
    /// Roll up the Merkle roots of the rooms the given drawers live in — each
    /// room exactly ONCE (coalesced), using the room's drawers' latest `filedAt`
    /// as the deterministic `now`.
    ///
    /// This is the deferred, off-the-capture-path rollup. Capture no longer rolls
    /// up inline (that is O(room) per write → O(N²) for a bulk import and pegs the
    /// CPU); instead the rollup rides the estate's single QueueKit work queue —
    /// the encode drain worker hands this method the drawer ids it just drained,
    /// and the touched rooms roll up here, off the write path and coalesced. Ids
    /// that don't resolve to a live drawer are skipped (e.g. the queue wake
    /// marker). Deterministic: each room's `now` comes from its own drawers'
    /// `filedAt`, never a wall clock. Mirrors Rust `Estate::rollup_rooms_for_drawers`.
    public func rollupRoomsForDrawers(_ drawerIds: [String]) async throws {
        // room node id → latest filedAt among this batch's drawers in that room.
        var rooms: [UUID: Date] = [:]
        let drawers = try await store.getDrawers(ids: drawerIds)
        for drawer in drawers {
            guard let room = UUID(uuidString: drawer.parentNodeId) else { continue }
            if let existing = rooms[room] {
                if drawer.filedAt > existing { rooms[room] = drawer.filedAt }
            } else {
                rooms[room] = drawer.filedAt
            }
        }
        for (room, now) in rooms {
            try await rollupMerkleRoots(roomNodeId: room, now: now)
        }
    }

    public func rollupMerkleRoots(
        roomNodeId: UUID,
        now: Date
    ) async throws {
        // Step 1: Room root — hash over active drawers in this room.
        let roomRoot = try await computeRoomMerkleRoot(roomNodeId: roomNodeId)
        try await nodeStore.updateMerkleRoot(
            nodeId: roomNodeId,
            merkleRoot: roomRoot,
            now: now
        )

        // Resolve wing from room's parent chain.
        guard let roomNode = try await nodeStore.getNode(id: roomNodeId),
              let wingNodeId = roomNode.parentId else {
            rollupLog.warning("MerkleRollup: room node \(roomNodeId) not found or has no parent")
            return
        }

        // Step 2: Wing root — hash over room roots in this wing.
        let wingRoot = try await computeWingMerkleRoot(wingNodeId: wingNodeId)
        try await nodeStore.updateMerkleRoot(
            nodeId: wingNodeId,
            merkleRoot: wingRoot,
            now: now
        )

        // Step 3: Estate root — hash over wing roots.
        guard let rootNode = try await nodeStore.rootNode() else {
            rollupLog.warning("MerkleRollup: estate root node not found")
            return
        }
        let estateRoot = try await computeEstateOrWingMerkleRoot(parentNodeId: rootNode.id)
        try await nodeStore.updateMerkleRoot(
            nodeId: rootNode.id,
            merkleRoot: estateRoot,
            now: now
        )
    }

    // MARK: - Room-level root

    /// Compute the Merkle root for a room by hashing its live drawers.
    ///
    /// Queries raw rows to read the `content_hash` column directly. For
    /// rows without a stored hash (pre-existing data), computes a leaf
    /// hash on-demand from the drawer's content.
    ///
    /// Excludes both tombstoned and withdrawn drawers from the snapshot.
    /// Tombstoned drawers have `tombstonedAt IS NOT NULL`. Withdrawn drawers
    /// have `tombstonedAt IS NULL` but carry state raw value 18 in bits 0-5
    /// of `adjectiveBitmap` (mask 0x3F). Including withdrawn drawers in the
    /// snapshot would allow retrieval of content that the user retracted,
    /// violating snapshot completeness (WS2-F1, fixed 2026-06-28).
    func computeRoomMerkleRoot(roomNodeId: UUID) async throws -> MerkleRoot {
        let rows = try await store.storage.rowStore.query(
            table: "drawers",
            where: .and([
                .eq(Column(table: "drawers", name: "parent_node_id"),
                    .text(roomNodeId.uuidString)),
                // Exclude tombstoned drawers (irreversible deletion).
                .isNull(Column(table: "drawers", name: "tombstonedAt")),
                // Exclude withdrawn drawers (state 18, bits 0-5 of adjectiveBitmap).
                // Withdrawn means the user retracted the drawer; it must not
                // appear in the live snapshot that commits hash to.
                .not(.bitwiseEq(Column(table: "drawers", name: "adjectiveBitmap"),
                                expected: 18, mask: 0x3F)),
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )

        var childHashes: [(UUID, ContentHash)] = []
        for row in rows {
            guard let drawerIdStr = Self.textValue(row["id"]) else { continue }
            let drawerUUID = Self.deterministicUUID(from: drawerIdStr)
            let contentHash: ContentHash

            if case .blob(let data) = row["content_hash"], data.count == 32 {
                // Stored hash from the hash-on-write hook.
                contentHash = ContentHash(bytes: Array(data))
            } else {
                // No stored hash — compute on-demand from drawer content.
                let content = Self.textValue(row["content"]) ?? ""
                contentHash = MerkleHash.leaf(
                    drawerId: drawerUUID,
                    content: Array(content.utf8),
                    vectors: []
                )
            }
            childHashes.append((drawerUUID, contentHash))
        }

        return MerkleHash.interior(childHashes: childHashes)
    }

    // MARK: - Wing and estate root

    /// Compute the Merkle root for a wing by hashing its room nodes'
    /// merkle_roots, or for the estate by hashing its wings' roots.
    ///
    /// Uses the typed `interior(childRoots:)` overload (NT-Q1) so
    /// child MerkleRoots flow through without type punning.
    func computeEstateOrWingMerkleRoot(parentNodeId: UUID) async throws -> MerkleRoot {
        let children = try await nodeStore.childNodes(parentId: parentNodeId)
        var childRoots: [(UUID, MerkleRoot)] = []
        for child in children {
            let root = child.merkleRoot ?? MerkleRoot.empty
            childRoots.append((child.id, root))
        }
        return MerkleHash.interior(childRoots: childRoots)
    }

    /// Convenience for wing-level: computes from room children.
    func computeWingMerkleRoot(wingNodeId: UUID) async throws -> MerkleRoot {
        try await computeEstateOrWingMerkleRoot(parentNodeId: wingNodeId)
    }

    // MARK: - Full recompute (Part 4)

    /// Bottom-up recompute of every Merkle root in the estate.
    ///
    /// Walks the containment tree: for each room, computes the room root
    /// from its drawers; for each wing, computes from its rooms; finally
    /// computes the estate root from its wings. Used after bulk import,
    /// migration, or corruption recovery — not on the normal write path.
    ///
    /// - Parameter now: Deterministic wall-clock for node updated_at.
    public func recomputeAllMerkleRoots(now: Date) async throws {
        guard let rootNode = try await nodeStore.rootNode() else {
            rollupLog.warning("recomputeAllMerkleRoots: estate root node not found")
            return
        }

        let wings = try await nodeStore.childNodes(parentId: rootNode.id)
        for wing in wings {
            let rooms = try await nodeStore.childNodes(parentId: wing.id)
            for room in rooms {
                let roomRoot = try await computeRoomMerkleRoot(roomNodeId: room.id)
                try await nodeStore.updateMerkleRoot(
                    nodeId: room.id,
                    merkleRoot: roomRoot,
                    now: now
                )
            }
            // Wing root from freshly updated room roots.
            let wingRoot = try await computeWingMerkleRoot(wingNodeId: wing.id)
            try await nodeStore.updateMerkleRoot(
                nodeId: wing.id,
                merkleRoot: wingRoot,
                now: now
            )
        }

        // Estate root from freshly updated wing roots.
        let estateRoot = try await computeEstateOrWingMerkleRoot(parentNodeId: rootNode.id)
        try await nodeStore.updateMerkleRoot(
            nodeId: rootNode.id,
            merkleRoot: estateRoot,
            now: now
        )
    }

    /// Full-tree Merkle rollup for the batch-capture reindex pass (NT_R1).
    ///
    /// Thin alias over `recomputeAllMerkleRoots`. Called after a
    /// `captureBatch` pass that deliberately deferred per-drawer rollup to
    /// avoid O(N²) recomputation during bulk import. Produces the same
    /// result as N incremental `rollupMerkleRoots` calls but in O(N).
    ///
    /// - Parameter now: Deterministic wall-clock for node `updated_at`.
    public func rollupAllMerkleRoots(now: Date) async throws {
        try await recomputeAllMerkleRoots(now: now)
    }

    // MARK: - Snapshot attestation (Part 3)

    /// Create a snapshot with Merkle root attestations for every wing
    /// and the estate root, plus any additional attestations from
    /// composition-layer kits (e.g. CorpusKit roots via GeniusLocusKit).
    ///
    /// Reads the current merkle_root from each wing node and the estate
    /// root node, writes them as attestation rows alongside the snapshot
    /// registry entry. The `additionalAttestations` parameter allows the
    /// composition layer to inject attestations from other kits without
    /// LocusKit depending on them directly.
    ///
    /// - Parameters:
    ///   - label: Optional human-readable label for the snapshot.
    ///   - now: Deterministic wall-clock for timestamps.
    ///   - additionalAttestations: Extra attestations from higher kits.
    /// - Returns: The created SnapshotRecord.
    @discardableResult
    public func createSnapshot(
        label: String?,
        now: Date,
        additionalAttestations: [SnapshotAttestation] = []
    ) async throws -> SnapshotRecord {
        // Barrier: capture defers Merkle rollups off the write path, so node
        // roots may be stale here. Recompute the full tree before attesting so a
        // snapshot always commits the current roots. O(N) but snapshots are rare.
        try await recomputeAllMerkleRoots(now: now)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let hlc = await nodeStore.generateHLC(nowMs: nowMs)

        var attestations: [SnapshotAttestation] = []
        let dummyId = SnapshotId("")

        // Estate root attestation.
        if let rootNode = try await nodeStore.rootNode() {
            let estateHex = (rootNode.merkleRoot ?? MerkleRoot.empty).hexString
            attestations.append(SnapshotAttestation(
                snapshotId: dummyId,
                subjectKind: "estate",
                subjectId: rootNode.id.uuidString,
                merkleRoot: estateHex
            ))

            // Wing-level attestations.
            let wings = try await nodeStore.childNodes(parentId: rootNode.id)
            for wing in wings {
                let wingHex = (wing.merkleRoot ?? MerkleRoot.empty).hexString
                attestations.append(SnapshotAttestation(
                    snapshotId: dummyId,
                    subjectKind: "wing",
                    subjectId: wing.id.uuidString,
                    merkleRoot: wingHex
                ))
            }
        }

        // Append composition-layer attestations (CorpusKit, etc.).
        attestations.append(contentsOf: additionalAttestations)

        return try await SnapshotRegistryOps.createSnapshot(
            rowStore: store.storage.rowStore,
            hlc: hlc,
            label: label,
            createdAt: now,
            attestations: attestations
        )
    }

    // MARK: - Helpers

    /// Extract a text value from a TypedValue, handling both .text and
    /// .uuid forms (SQLite read-back can return either).
    static func textValue(_ v: TypedValue?) -> String? {
        switch v {
        case .text(let s): return s
        case .uuid(let u): return u.uuidString
        case .none, .some(.null): return nil
        default: return nil
        }
    }

    /// Convert a drawer string ID to a deterministic UUID.
    /// Parses as UUID when possible; otherwise derives a stable UUID
    /// from SHA-256 of the string (first 16 bytes with UUID v5 version
    /// and variant bits set).
    static func deterministicUUID(from stringId: String) -> UUID {
        if let uuid = UUID(uuidString: stringId) {
            return uuid
        }
        let hash = SHA256.hash(Array(stringId.utf8))
        var bytes = Array(hash.prefix(16))
        // Set version nibble (byte 6 high nibble) to 5 (name-based SHA-1
        // by convention, repurposed here for deterministic derivation).
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        // Set variant bits (byte 8 high 2 bits) to 10.
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

}
