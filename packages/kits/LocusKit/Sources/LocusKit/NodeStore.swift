// NodeStore.swift
//
// Storage for the estate's containment tree.
//
// NodeStore is an actor wrapping PersistenceKit's Storage, mirroring
// DrawerStore's architecture. It owns:
//   - create-on-demand resolution (§7): derive lookupName from
//     displayName (§8), match active-only by lookupName under parentId,
//     create if absent, return existing if present. Tombstoned nodes
//     are invisible to resolution (§5 no-resurrection guard).
//   - CRUD: getNode, childNodes (active only), tombstoneNode, rootNode.
//   - Invariant enforcement at write time: I-NT-1 single root,
//     I-NT-2 depth consistency (parent.depth + 1, max 3; depth 3 = chest, ADR-026),
//     I-NT-4 name uniqueness within parent (active only),
//     I-NT-5 referential integrity on parent_id.
//
// Race safety for create-on-demand is provided by actor serialization:
// `DrawerStore` is an actor, so all find-then-insert sequences are
// serialized without INSERT-OR-IGNORE or conflict columns. Two concurrent
// creates of the same name under the same parent produce exactly one node.
//
// Date columns are TEXT ISO8601 (PersistenceKit maps .timestamp to TEXT,
// per fleet rule). The store passes `now` as a Date parameter to every
// mutation method (deterministic-engine rule).

import Foundation
import MootProductIdentity
import OSLog
import EngramLib
import PersistenceKit
import SubstrateML
import SubstrateTypes

private let nodeStoreLog = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "LocusKit.NodeStore")

/// Storage for the estate's containment tree.
///
/// Methods are async because every operation touches the actor's
/// isolated Storage. Multi-step paths such as `createNode` and
/// `createRoot` rely on actor serialization rather than
/// `storage.transaction` for their atomicity guarantee.
public actor NodeStore {

    let storage: any Storage

    /// The HLC clock this store stamps node creation with. Same
    /// clock-ownership model as DrawerStore: nil = top mode (make own
    /// clock), supplied = holder mode (stamped by GLK's estate-wide maker).
    var hlc: HLCGenerator

    /// Construct against a Storage. The schema must already be opened
    /// (LocusKitSchema.schema) — NodeStore does not re-open it.
    ///
    /// - Parameter hlc: an injected clock from the top entity (holder
    ///   mode), or `nil` to make this store its own clock (top mode).
    public init(storage: any Storage, hlc: HLCGenerator? = nil) {
        self.storage = storage
        if let injected = hlc {
            self.hlc = injected
        } else {
            self.hlc = HLCGenerator(nodeID: 0)
        }
    }

    // MARK: - Table name

    static let table = "nodes"

    /// Column reference shorthand for the nodes table.
    static func col(_ name: String) -> Column {
        Column(table: table, name: name)
    }

    // MARK: - Create-on-demand resolution (§7)

    /// Resolve or create a node under the given parent.
    ///
    /// Derives `lookupName` from `displayName` (§8). Searches for an
    /// active node with that lookupName under `parentId`. If found,
    /// returns the existing node (first-casing wins). If absent, creates
    /// a new node. Tombstoned nodes are invisible to resolution (§5).
    ///
    /// Enforces: I-NT-2 (depth = parent.depth + 1, max 3),
    /// I-NT-4 (no duplicate active lookupName under same parent),
    /// I-NT-5 (parent must exist).
    ///
    /// - Parameters:
    ///   - displayName: the user-visible name (first-writer casing preserved).
    ///   - parentId: the parent node's UUID.
    ///   - now: deterministic wall-clock for timestamps.
    /// - Returns: the resolved or newly created node.
    public func createNode(
        displayName: String,
        parentId: UUID,
        now: Date
    ) async throws -> Node {
        let lookupName = Node.normalizeLookupName(displayName)

        // I-NT-5: parent must exist.
        guard let parent = try await getNode(id: parentId) else {
            throw LocusKitError.invalidContent(
                "NodeStore: parent node \(parentId) does not exist (I-NT-5)")
        }

        // I-NT-2: depth = parent.depth + 1, max 3. Depth 3 is a chest, the
        // internal container below a room (ADR-026, LocusKit spec § 12);
        // chests never nest, so nothing sits below depth 3.
        let childDepth = parent.depth + 1
        if childDepth > 3 {
            throw LocusKitError.invalidContent(
                "NodeStore: depth \(childDepth) exceeds maximum 3 (I-NT-2)")
        }

        // Resolution: find active node by lookupName under this parent.
        // Tombstoned nodes are invisible (§5 no-resurrection guard).
        let existing = try await findActiveNode(
            lookupName: lookupName,
            parentId: parentId
        )
        if let existing {
            return existing
        }

        // No active match — create.
        let id = UUID()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let createdHlc = hlc.send(now: nowMs)

        let values: [String: TypedValue] = [
            "id": .uuid(id),
            "parent_id": .uuid(parentId),
            "display_name": .text(displayName),
            "lookup_name": .text(lookupName),
            "depth": .int(Int64(childDepth)),
            "lifecycle": .int(0),
            "created_hlc": .hlc(createdHlc),
            "created_at": .timestamp(now),
            "updated_at": .timestamp(now),
        ]

        // Race safety: the actor serialises all writes, so the
        // check-then-insert above is atomic. No concurrent create
        // can interleave between findActiveNode and this insert.
        _ = try await storage.rowStore.insert(
            table: Self.table,
            values: values
        )

        // Re-fetch to return the stored node with all columns populated.
        if let resolved = try await findActiveNode(
            lookupName: lookupName,
            parentId: parentId
        ) {
            return resolved
        }

        throw LocusKitError.databaseUnavailable(
            "NodeStore: create-on-demand resolution failed after insert")
    }

    /// Create the estate root node (depth 0, no parent).
    ///
    /// Enforces I-NT-1: exactly one root. If a root already exists,
    /// returns the existing root.
    ///
    /// - Parameters:
    ///   - displayName: display name for the root (typically "Estate").
    ///   - now: deterministic wall-clock for timestamps.
    /// - Returns: the root node.
    public func createRoot(
        displayName: String,
        now: Date
    ) async throws -> Node {
        // Check if root already exists (I-NT-1).
        if let existing = try await rootNode() {
            return existing
        }

        let lookupName = Node.normalizeLookupName(displayName)
        let id = UUID()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let createdHlc = hlc.send(now: nowMs)

        let values: [String: TypedValue] = [
            "id": .uuid(id),
            "display_name": .text(displayName),
            "lookup_name": .text(lookupName),
            "depth": .int(0),
            "lifecycle": .int(0),
            "created_hlc": .hlc(createdHlc),
            "created_at": .timestamp(now),
            "updated_at": .timestamp(now),
        ]

        _ = try await storage.rowStore.insert(
            table: Self.table,
            values: values
        )

        // Re-fetch to return the stored node.
        if let root = try await rootNode() {
            return root
        }

        throw LocusKitError.databaseUnavailable(
            "NodeStore: root creation failed")
    }

    // MARK: - Read

    /// Fetch a node by its UUID.
    public func getNode(id: UUID) async throws -> Node? {
        let rows = try await storage.rowStore.query(
            table: Self.table,
            where: .eq(Self.col("id"), .uuid(id)),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first else { return nil }
        return try nodeFromRow(row)
    }

    /// The estate root node (depth 0, parent_id IS NULL, active).
    public func rootNode() async throws -> Node? {
        let rows = try await storage.rowStore.query(
            table: Self.table,
            where: .and([
                .isNull(Self.col("parent_id")),
                .eq(Self.col("depth"), .int(0)),
                .eq(Self.col("lifecycle"), .int(0)),
            ]),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first else { return nil }
        return try nodeFromRow(row)
    }

    /// Active children of a node, ordered by lookup_name.
    public func childNodes(parentId: UUID) async throws -> [Node] {
        let rows = try await storage.rowStore.query(
            table: Self.table,
            where: .and([
                .eq(Self.col("parent_id"), .uuid(parentId)),
                .eq(Self.col("lifecycle"), .int(0)),
            ]),
            orderBy: [OrderClause(column: Self.col("lookup_name"))],
            limit: nil,
            offset: nil
        )
        return try rows.map { try nodeFromRow($0) }
    }

    // MARK: - Tombstone (§5)

    /// Tombstone a node. Sets lifecycle = 1, tombstoned_hlc, tombstoned_at.
    ///
    /// - Parameters:
    ///   - id: the node's UUID.
    ///   - now: deterministic wall-clock for timestamps.
    /// - Returns: the updated node, or nil if not found.
    public func tombstoneNode(id: UUID, now: Date) async throws -> Node? {
        guard let node = try await getNode(id: id) else {
            return nil
        }

        if node.isTombstoned {
            return node
        }

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let tHlc = hlc.send(now: nowMs)

        _ = try await storage.rowStore.update(
            table: Self.table,
            values: [
                "lifecycle": .int(1),
                "tombstoned_hlc": .hlc(tHlc),
                "tombstoned_at": .timestamp(now),
                "updated_at": .timestamp(now),
            ],
            where: .eq(Self.col("id"), .uuid(id))
        )

        return try await getNode(id: id)
    }

    /// The active node named `displayName` under `parentId`, resolved the
    /// way `createNode` resolves (normalised lookup name), without creating
    /// it. Nil when absent.
    public func findNode(displayName: String, parentId: UUID) async throws -> Node? {
        try await findActiveNode(lookupName: Node.normalizeLookupName(displayName), parentId: parentId)
    }

    // MARK: - Chests (ADR-026, spec § 12)

    /// The depth of a chest: the internal container below a room. Chests
    /// never nest, so this is also the tree's maximum depth (I-NT-2).
    public static let chestDepth = 3

    /// The active chests under a room, sorted by name. A chest's name is
    /// its low placement key as 128 lowercase hex characters, so name order
    /// is key order and each chest runs from its own name up to the next.
    /// Empty for a room that has never been re-binned.
    public func activeChests(roomId: UUID) async throws -> [Node] {
        let rows = try await storage.rowStore.query(
            table: Self.table,
            where: .and([
                .eq(Self.col("parent_id"), .uuid(roomId)),
                .eq(Self.col("depth"), .int(Int64(Self.chestDepth))),
                .eq(Self.col("lifecycle"), .int(0)),
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        return try rows.map { try nodeFromRow($0) }.sorted { $0.lookupName < $1.lookupName }
    }

    /// The room a drawer's parent denotes: the node itself when the parent
    /// is a room, its parent when the parent is a chest. Every reader that
    /// needs "the room" from `Drawer.parentNodeId` goes through here, so
    /// chests stay invisible above LocusKit (spec § 12). Nil for an unknown
    /// id or a node that is neither a room nor a chest.
    public func roomNode(forParent parentId: UUID) async throws -> Node? {
        guard let node = try await getNode(id: parentId) else { return nil }
        if node.depth == 2 { return node }
        guard node.depth == Self.chestDepth, let roomId = node.parentId else { return nil }
        return try await getNode(id: roomId)
    }

    /// Where a drawer with this content is filed under this room: the room
    /// itself when the room has no chests, otherwise the chest whose low
    /// key is the greatest not above the drawer's placement key, or the
    /// first chest when the key falls below every low key (spec § 12). The
    /// key is over the content fingerprint, never the stored structural
    /// one (ADR-026 D2). One node query and a binary search over names.
    /// `hidden` selects the class of chest a drawer may join: a restricted
    /// or secret drawer joins only hidden chests, every other drawer only
    /// visible ones, so a hidden drawer never moves a visible drawer's
    /// chest boundary (see `chestName`). With no chest of the drawer's
    /// class the drawer sits on the room until the next re-bin deals it.
    public func placementParent(roomId: UUID, content: String, hidden: Bool) async throws -> UUID {
        let chests = try await activeChests(roomId: roomId).filter { Self.chestIsHidden(name: $0.lookupName) == hidden }
        guard let first = chests.first else { return roomId }
        let hex = ChestPlacement.key(ContentFingerprint.fingerprint(of: content)).hex
        // The last chest whose low key <= hex. Chests come sorted by name,
        // and within one low key the ordinal suffixes sort after the bare
        // name, so the last match is the newest range at that key.
        var lo = 0, hi = chests.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if Self.chestLowKeyHex(name: chests[mid].lookupName) <= hex { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found >= 0 ? chests[found].id : first.id
    }

    /// A chest's name: the 128-hex low key of its range, `-hidden` appended
    /// for a chest of restricted or secret drawers, and `-<n>` appended for
    /// the n-th further range at the same low key within one deal.
    ///
    /// Two reasons the bare key is not enough (codex findings 2026-09-19):
    /// identical content gives identical keys, so a deal of 500 identical
    /// captures holds two 250-row ranges at one key and each must be its
    /// own chest, or one chest silently holds 500; and hidden drawers are
    /// dealt apart from visible ones so a caller without a sensitivity
    /// grant cannot read hidden content's placement off the boundaries of
    /// the visible chests it can probe. The hex prefix keeps name order
    /// equal to key order within a class.
    public static func chestName(lowKeyHex: String, hidden: Bool, ordinal: Int) -> String {
        var name = lowKeyHex
        if hidden { name += "-hidden" }
        if ordinal > 0 { name += "-\(ordinal)" }
        return name
    }

    /// The low key hex a chest name starts with (everything before the
    /// first `-`).
    public static func chestLowKeyHex(name: String) -> String {
        name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
    }

    /// True when the name marks a chest of restricted or secret drawers.
    public static func chestIsHidden(name: String) -> Bool {
        name.contains("-hidden")
    }

    /// The id of the chest named `name` under `roomId`, derived rather
    /// than random so two devices re-binning the same room name the same
    /// chest with the same id and their rows converge under sync (ADR-026
    /// D7). SHA-256 over a fixed prefix, the room id and the name, folded
    /// to a version-5-shaped UUID the same way `Estate.deterministicUUID`
    /// folds drawer ids.
    public static func chestId(roomId: UUID, name: String) -> UUID {
        Estate.deterministicUUID(from: "chest:\(roomId.uuidString.lowercased()):\(name)")
    }

    /// The chest named `name` (see `chestName`) under `roomId`, created if absent. A
    /// tombstoned chest with this derived id is brought back rather than
    /// re-inserted: the id is a function of the name, so a later re-bin
    /// that produces the same low key must land on the same row, and a
    /// chest carries nothing but its name, so bringing it back loses no
    /// history. (Rooms and wings keep the no-resurrection guard; chests
    /// are the one node kind whose identity is derived.)
    public func createChest(roomId: UUID, name: String, now: Date) async throws -> Node {
        guard let room = try await getNode(id: roomId), room.depth == 2 else {
            throw LocusKitError.invalidContent(
                "NodeStore: chest parent \(roomId) is not a room (spec § 12)")
        }
        let id = Self.chestId(roomId: roomId, name: name)
        if let existing = try await getNode(id: id) {
            if existing.isActive { return existing }
            _ = try await storage.rowStore.update(
                table: Self.table,
                values: [
                    "lifecycle": .int(0),
                    "tombstoned_hlc": .null,
                    "tombstoned_at": .null,
                    "updated_at": .timestamp(now),
                ],
                where: .eq(Self.col("id"), .uuid(id))
            )
            guard let revived = try await getNode(id: id) else {
                throw LocusKitError.databaseUnavailable("NodeStore: chest \(id) vanished after revival")
            }
            return revived
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let createdHlc = hlc.send(now: nowMs)
        _ = try await storage.rowStore.insert(
            table: Self.table,
            values: [
                "id": .uuid(id),
                "parent_id": .uuid(roomId),
                "display_name": .text(name),
                "lookup_name": .text(Node.normalizeLookupName(name)),
                "depth": .int(Int64(Self.chestDepth)),
                "lifecycle": .int(0),
                "created_hlc": .hlc(createdHlc),
                "created_at": .timestamp(now),
                "updated_at": .timestamp(now),
            ]
        )
        guard let created = try await getNode(id: id) else {
            throw LocusKitError.databaseUnavailable("NodeStore: chest create failed after insert")
        }
        return created
    }

    // MARK: - Merkle root update (NT-L3)

    /// Update a node's merkle_root column.
    ///
    /// Called by the Merkle rollup after recomputing a subtree. The
    /// MerkleRoot's 32 raw bytes are stored as a BLOB (NT-Q1).
    ///
    /// - Parameters:
    ///   - nodeId: The node whose merkle_root to update.
    ///   - merkleRoot: The new root hash.
    ///   - now: Deterministic wall-clock for updated_at timestamp.
    public func updateMerkleRoot(
        nodeId: UUID,
        merkleRoot: MerkleRoot,
        now: Date
    ) async throws {
        _ = try await storage.rowStore.update(
            table: Self.table,
            values: [
                "merkle_root": .blob(Data(merkleRoot.bytes)),
                "updated_at": .timestamp(now),
            ],
            where: .eq(Self.col("id"), .uuid(nodeId))
        )
    }

    // MARK: - HLC generation

    /// Generate an HLC timestamp. Exposed so callers outside the actor
    /// (e.g. Estate's createSnapshot) can obtain a stamped HLC without
    /// directly accessing the actor-isolated `hlc` property.
    public func generateHLC(nowMs: Int64) -> HLC {
        hlc.send(now: nowMs)
    }

    // MARK: - Internal helpers

    /// Find an active node by lookupName under a parent.
    private func findActiveNode(
        lookupName: String,
        parentId: UUID
    ) async throws -> Node? {
        let rows = try await storage.rowStore.query(
            table: Self.table,
            where: .and([
                .eq(Self.col("parent_id"), .uuid(parentId)),
                .eq(Self.col("lookup_name"), .text(lookupName)),
                .eq(Self.col("lifecycle"), .int(0)),
            ]),
            orderBy: [],
            limit: 1,
            offset: nil
        )
        guard let row = rows.first else { return nil }
        return try nodeFromRow(row)
    }

    // MARK: - Row decoding

    /// Decode a StorageRow into a Node.
    ///
    /// Handles the SQLite read-back primitive decode: .uuid and .text
    /// for UUID columns, .hlc and .int for HLC columns, .timestamp
    /// and .text for date columns.
    func nodeFromRow(_ row: StorageRow) throws -> Node {
        let id = try Self.uuid(table: Self.table, column: "id", row["id"])
        let parentId = Self.optUuid(row["parent_id"])
        let depth = Self.int64(row["depth"])
        let lifecycle = Self.int64(row["lifecycle"])
        let createdHlc = try Self.hlcValue(
            table: Self.table, column: "created_hlc", row["created_hlc"])
        let tombstonedHlc = Self.optHlc(row["tombstoned_hlc"])
        let tombstonedAt = Self.optDate(row["tombstoned_at"])
        let createdAt = try Self.date(
            table: Self.table, column: "created_at", row["created_at"])
        let updatedAt = try Self.date(
            table: Self.table, column: "updated_at", row["updated_at"])

        return Node(
            id: id,
            parentId: parentId,
            displayName: Self.string(row["display_name"]),
            lookupName: Self.string(row["lookup_name"]),
            depth: Int(depth),
            lifecycle: Int(lifecycle),
            createdHlc: createdHlc,
            tombstonedHlc: tombstonedHlc,
            tombstonedAt: tombstonedAt,
            merkleRoot: Self.optMerkleRoot(row["merkle_root"]),
            createdAt: createdAt,
            updatedAt: updatedAt,
            ext: Self.optString(row["ext"])
        )
    }

    // MARK: - Value extraction helpers

    private static func string(_ v: TypedValue?) -> String {
        switch v {
        case .text(let s): return s
        case .uuid(let u): return u.uuidString
        default: return ""
        }
    }

    private static func optString(_ v: TypedValue?) -> String? {
        switch v {
        case .text(let s): return s
        case .none, .some(.null): return nil
        default: return nil
        }
    }

    /// Decode a nullable BLOB column into a MerkleRoot.
    /// Accepts .blob (normal read-back) and returns nil for NULL.
    private static func optMerkleRoot(_ v: TypedValue?) -> MerkleRoot? {
        switch v {
        case .blob(let data) where data.count == 32:
            return MerkleRoot(bytes: Array(data))
        case .none, .some(.null):
            return nil
        default:
            return nil
        }
    }

    private static func int64(_ v: TypedValue?) -> Int64 {
        switch v {
        case .int(let i), .bitmap(let i): return i
        default: return 0
        }
    }

    /// Decode a required UUID column. Handles both .uuid (direct) and
    /// .text (SQLite read-back).
    private static func uuid(
        table: String, column: String, _ v: TypedValue?
    ) throws -> UUID {
        switch v {
        case .uuid(let u): return u
        case .text(let s):
            guard let parsed = UUID(uuidString: s) else {
                throw LocusKitError.corruptStoredValue(
                    table: table, column: column, storedText: s)
            }
            return parsed
        default:
            throw LocusKitError.corruptStoredValue(
                table: table, column: column,
                storedText: String(describing: v))
        }
    }

    /// Decode an optional UUID column.
    private static func optUuid(_ v: TypedValue?) -> UUID? {
        switch v {
        case .uuid(let u): return u
        case .text(let s): return UUID(uuidString: s)
        case .none, .some(.null): return nil
        default: return nil
        }
    }

    /// Decode a required HLC column. Handles .hlc (direct) and .int
    /// (SQLite read-back of packed HLC).
    private static func hlcValue(
        table: String, column: String, _ v: TypedValue?
    ) throws -> HLC {
        switch v {
        case .hlc(let h): return h
        case .int(let i):
            return HLC(packed: UInt64(bitPattern: i))
        default:
            throw LocusKitError.corruptStoredValue(
                table: table, column: column,
                storedText: String(describing: v))
        }
    }

    /// Decode an optional HLC column.
    private static func optHlc(_ v: TypedValue?) -> HLC? {
        switch v {
        case .hlc(let h): return h
        case .int(let i): return HLC(packed: UInt64(bitPattern: i))
        case .none, .some(.null): return nil
        default: return nil
        }
    }

    /// Decode a required date column.
    private static func date(
        table: String, column: String, _ v: TypedValue?
    ) throws -> Date {
        switch v {
        case .timestamp(let d): return d
        case .text(let s):
            if s.isEmpty { return Date(timeIntervalSince1970: 0) }
            guard let parsed = LKISO8601.date(from: s) else {
                throw LocusKitError.corruptStoredValue(
                    table: table, column: column, storedText: s)
            }
            return parsed
        default: return Date(timeIntervalSince1970: 0)
        }
    }

    /// Decode an optional date column.
    private static func optDate(_ v: TypedValue?) -> Date? {
        switch v {
        case .timestamp(let d): return d
        case .text(let s): return LKISO8601.date(from: s)
        default: return nil
        }
    }
}

// MARK: - ISO8601 formatter

/// Shared ISO8601 formatter matching DrawerStore's implementation.
private enum LKISO8601 {
    nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func date(from string: String) -> Date? { formatter.date(from: string) }
    static func string(from date: Date) -> String { formatter.string(from: date) }
}
