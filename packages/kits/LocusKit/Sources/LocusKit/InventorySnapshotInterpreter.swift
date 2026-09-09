import Foundation
import PersistenceKit
import SubstrateTypes

/// A drawer together with the validated root-to-room ancestry from one
/// immutable PersistenceKit inventory snapshot.
public struct LocusInventorySnapshotDrawer: Sendable, Equatable {
    public let drawer: Drawer
    /// Ordered as estate root, wing, then room.
    public let ancestry: [Node]

    public init(drawer: Drawer, ancestry: [Node]) {
        self.drawer = drawer
        self.ancestry = ancestry
    }
}

/// Strictly decoded LocusKit inventory state. The source rows are not kept.
public struct LocusInventorySnapshot: Sendable, Equatable {
    public let drawers: [LocusInventorySnapshotDrawer]

    public init(drawers: [LocusInventorySnapshotDrawer]) {
        self.drawers = drawers
    }
}

public enum LocusInventorySnapshotError: Error, Sendable, Equatable {
    case corruptRow(table: String, column: String, reason: String)
    case invalidTopology(reason: String)
}

/// The LocusKit authority for interpreting raw, immutable inventory rows.
///
/// Inventory callers must use this instead of `DrawerStore` scan APIs: those
/// APIs may intentionally skip corrupt corpus rows and cannot guarantee that
/// drawers and nodes came from the same storage snapshot.
public enum LocusInventorySnapshotInterpreter {
    public static func decode(_ snapshot: InventorySnapshot) throws -> LocusInventorySnapshot {
        let nodes = try snapshot.nodes.map { try decodeNode($0) }
        let nodeByID = try indexNodes(nodes)
        try validateNodes(nodes, nodeByID: nodeByID)

        var seenDrawerIDs = Set<UUID>()
        let drawers = try snapshot.drawers.map { row -> LocusInventorySnapshotDrawer in
            let drawer = try decodeDrawer(row)
            guard let drawerID = UUID(uuidString: drawer.id) else {
                throw corrupt("drawers", "id", "must be a UUID")
            }
            guard seenDrawerIDs.insert(drawerID).inserted else {
                throw corrupt("drawers", "id", "duplicates another drawer row")
            }
            let ancestry = try ancestry(for: drawer, nodes: nodeByID)
            if drawer.tombstonedAt == nil, ancestry.contains(where: { !$0.isActive }) {
                throw LocusInventorySnapshotError.invalidTopology(reason: "live drawer \(drawerID) has tombstoned ancestry")
            }
            return .init(drawer: drawer, ancestry: ancestry)
        }
        return .init(drawers: drawers)
    }

    private static func indexNodes(_ nodes: [Node]) throws -> [UUID: Node] {
        var result: [UUID: Node] = [:]
        for node in nodes {
            guard result[node.id] == nil else {
                throw corrupt("nodes", "id", "duplicates another node row")
            }
            result[node.id] = node
        }
        return result
    }

    private static func validateNodes(_ nodes: [Node], nodeByID: [UUID: Node]) throws {
        let roots = nodes.filter { $0.depth == 0 }
        guard roots.count == 1, roots[0].parentId == nil, roots[0].isActive else {
            throw LocusInventorySnapshotError.invalidTopology(reason: "inventory must contain exactly one active root node")
        }
        var activeNames = Set<String>()
        for node in nodes {
            guard (0...2).contains(node.depth) else {
                throw LocusInventorySnapshotError.invalidTopology(reason: "node \(node.id) has unsupported depth \(node.depth)")
            }
            guard !node.displayName.isEmpty,
                  node.lookupName == Node.normalizeLookupName(node.displayName) else {
                throw LocusInventorySnapshotError.invalidTopology(reason: "node \(node.id) has invalid names")
            }
            guard node.lifecycle == 0 || node.lifecycle == 1 else {
                throw LocusInventorySnapshotError.invalidTopology(reason: "node \(node.id) has invalid lifecycle")
            }
            if node.isActive {
                guard node.tombstonedHlc == nil, node.tombstonedAt == nil else {
                    throw LocusInventorySnapshotError.invalidTopology(reason: "active node \(node.id) has tombstone fields")
                }
            } else {
                guard node.tombstonedHlc != nil, node.tombstonedAt != nil else {
                    throw LocusInventorySnapshotError.invalidTopology(reason: "tombstoned node \(node.id) lacks tombstone fields")
                }
            }
            if let parentID = node.parentId {
                guard let parent = nodeByID[parentID], parent.depth + 1 == node.depth else {
                    throw LocusInventorySnapshotError.invalidTopology(reason: "node \(node.id) has invalid parent ancestry")
                }
                if node.isActive {
                    let key = "\(parentID.uuidString.lowercased())\u{0}\(node.lookupName)"
                    guard activeNames.insert(key).inserted else {
                        throw LocusInventorySnapshotError.invalidTopology(reason: "active siblings duplicate a lookup name")
                    }
                }
            } else if node.depth != 0 {
                throw LocusInventorySnapshotError.invalidTopology(reason: "non-root node \(node.id) lacks a parent")
            }
            try validateNoCycle(from: node, nodeByID: nodeByID)
        }
    }

    private static func validateNoCycle(from node: Node, nodeByID: [UUID: Node]) throws {
        var current: Node? = node
        var seen = Set<UUID>()
        while let value = current {
            guard seen.insert(value.id).inserted else {
                throw LocusInventorySnapshotError.invalidTopology(reason: "node ancestry contains a cycle")
            }
            current = value.parentId.flatMap { nodeByID[$0] }
        }
    }

    private static func ancestry(for drawer: Drawer, nodes: [UUID: Node]) throws -> [Node] {
        guard let roomID = UUID(uuidString: drawer.parentNodeId),
              let room = nodes[roomID], room.depth == 2,
              let wingID = room.parentId, let wing = nodes[wingID], wing.depth == 1,
              let rootID = wing.parentId, let root = nodes[rootID], root.depth == 0,
              root.parentId == nil else {
            throw LocusInventorySnapshotError.invalidTopology(reason: "drawer \(drawer.id) does not resolve to room, wing, and root")
        }
        return [root, wing, room]
    }

    private static func decodeDrawer(_ row: StorageRow) throws -> Drawer {
        let id = try uuidText(row, "drawers", "id")
        let parent = try uuidText(row, "drawers", "parent_node_id")
        let filedAt = try timestamp(row, "drawers", "filedAt")
        let eventTime = try optionalTimestamp(row, "drawers", "eventTime") ?? filedAt
        let lineageText = try text(row, "drawers", "lineageID")
        let lineageID: UUID
        if lineageText.isEmpty {
            // Existing LocusKit compatibility rule for pre-lineage rows.
            lineageID = UUID()
        } else if let parsed = UUID(uuidString: lineageText) {
            lineageID = parsed
        } else {
            throw corrupt("drawers", "lineageID", "must be an empty legacy sentinel or UUID")
        }
        try optionalJSON(row, "drawers", "ext")
        _ = try optionalText(row, "drawers", "keyID")
        try optionalDigest(row, "drawers", "content_hash")
        try optionalDigest(row, "drawers", "content_fingerprint")
        let subject = try optionalText(row, "drawers", "subject")
        let subjectVersion = try optionalText(row, "drawers", "subject_pipeline_version")
        let subjectAt = try optionalTimestamp(row, "drawers", "subject_at")
        guard (subject == nil && subjectVersion == nil && subjectAt == nil)
                || (subject != nil && subjectVersion != nil && subjectAt != nil) else {
            throw corrupt("drawers", "subject", "subject fields must be null together or populated together")
        }
        let adjectiveBitmap = try bitmap(row, "drawers", "adjectiveBitmap")
        try validateDrawerAdjectiveBitmap(adjectiveBitmap)
        return Drawer(
            id: id.uuidString.lowercased(),
            content: try text(row, "drawers", "content"),
            parentNodeId: parent.uuidString.lowercased(),
            sourceFile: try optionalText(row, "drawers", "sourceFile"),
            chunkIndex: try optionalInt(row, "drawers", "chunkIndex").map(Int.init),
            addedBy: try text(row, "drawers", "addedBy"),
            filedAt: filedAt,
            eventTime: eventTime,
            embeddingModelID: try text(row, "drawers", "embeddingModelID"),
            tombstonedAt: try optionalTimestamp(row, "drawers", "tombstonedAt"),
            removedByBatch: try optionalText(row, "drawers", "removedByBatch"),
            provenance: try bitmap(row, "drawers", "provenance"),
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: try bitmap(row, "drawers", "operationalBitmap"),
            lineageID: lineageID,
            udcCode: try text(row, "drawers", "udcCode"),
            udcFacets: try optionalText(row, "drawers", "udcFacets"),
            wikidataQID: try optionalText(row, "drawers", "wikidataQID"),
            wikidataQidsSecondary: try optionalText(row, "drawers", "wikidataQidsSecondary"),
            sscFacts: try optionalText(row, "drawers", "ssc_facts"),
            subject: subject,
            subjectPipelineVersion: subjectVersion,
            subjectAt: subjectAt
        )
    }

    private static func decodeNode(_ row: StorageRow) throws -> Node {
        let id = try uuidTextOrNative(row, "nodes", "id")
        let parent = try optionalUUIDTextOrNative(row, "nodes", "parent_id")
        let lifecycle = try integer(row, "nodes", "lifecycle")
        let tombstoneHLC = try optionalHLC(row, "nodes", "tombstoned_hlc")
        let tombstoneDate = try optionalTimestamp(row, "nodes", "tombstoned_at")
        try optionalJSON(row, "nodes", "ext")
        guard let depth = Int(exactly: try integer(row, "nodes", "depth")) else {
            throw corrupt("nodes", "depth", "is outside Int range")
        }
        return Node(
            id: id,
            parentId: parent,
            displayName: try text(row, "nodes", "display_name"),
            lookupName: try text(row, "nodes", "lookup_name"),
            depth: depth,
            lifecycle: Int(lifecycle),
            createdHlc: try hlc(row, "nodes", "created_hlc"),
            tombstonedHlc: tombstoneHLC,
            tombstonedAt: tombstoneDate,
            merkleRoot: try optionalMerkleRoot(row, "nodes", "merkle_root"),
            createdAt: try timestamp(row, "nodes", "created_at"),
            updatedAt: try timestamp(row, "nodes", "updated_at")
        )
    }

    private static func text(_ row: StorageRow, _ table: String, _ column: String) throws -> String {
        guard case .text(let value)? = row[column] else { throw corrupt(table, column, "must be text") }
        return value
    }

    private static func optionalText(_ row: StorageRow, _ table: String, _ column: String) throws -> String? {
        guard let value = row[column] else { return nil }
        switch value {
        case .null: return nil
        case .text(let result): return result
        default: throw corrupt(table, column, "must be text or null")
        }
    }

    private static func uuidText(_ row: StorageRow, _ table: String, _ column: String) throws -> UUID {
        let value = try text(row, table, column)
        guard let result = UUID(uuidString: value) else { throw corrupt(table, column, "must be a UUID") }
        return result
    }

    private static func optionalUUIDText(_ row: StorageRow, _ table: String, _ column: String) throws -> UUID? {
        guard let value = try optionalText(row, table, column) else { return nil }
        guard let result = UUID(uuidString: value) else { throw corrupt(table, column, "must be a UUID or null") }
        return result
    }

    private static func uuidTextOrNative(_ row: StorageRow, _ table: String, _ column: String) throws -> UUID {
        switch row[column] {
        case .uuid(let value): return value
        case .text(let value):
            guard let result = UUID(uuidString: value) else {
                throw corrupt(table, column, "must be a UUID")
            }
            return result
        default: throw corrupt(table, column, "must be a UUID")
        }
    }

    private static func optionalUUIDTextOrNative(_ row: StorageRow, _ table: String, _ column: String) throws -> UUID? {
        guard let value = row[column] else { return nil }
        switch value {
        case .null: return nil
        case .uuid(let result): return result
        case .text(let text):
            guard let result = UUID(uuidString: text) else {
                throw corrupt(table, column, "must be a UUID or null")
            }
            return result
        default: throw corrupt(table, column, "must be a UUID or null")
        }
    }

    private static func integer(_ row: StorageRow, _ table: String, _ column: String) throws -> Int64 {
        guard case .int(let value)? = row[column] else { throw corrupt(table, column, "must be an integer") }
        return value
    }

    private static func optionalInt(_ row: StorageRow, _ table: String, _ column: String) throws -> Int64? {
        guard let value = row[column] else { return nil }
        switch value {
        case .null: return nil
        case .int(let result): return result
        default: throw corrupt(table, column, "must be an integer or null")
        }
    }

    private static func bitmap(_ row: StorageRow, _ table: String, _ column: String) throws -> Int64 {
        guard case .bitmap(let value)? = row[column] else { throw corrupt(table, column, "must be a bitmap") }
        return value
    }

    private static func validateDrawerAdjectiveBitmap(_ bitmap: Int64) throws {
        let raw = UInt64(bitPattern: bitmap)
        let stateRaw = Int(raw & 0x3f)
        guard State(rawValue: stateRaw) != nil else {
            throw corrupt("drawers", "adjectiveBitmap", "contains a reserved state raw value")
        }
        let sensitivityRaw = Int((raw >> 6) & 0x3f)
        guard AdjectiveSensitivity(rawValue: sensitivityRaw) != nil else {
            throw corrupt("drawers", "adjectiveBitmap", "contains a reserved sensitivity raw value")
        }
    }

    private static func timestamp(_ row: StorageRow, _ table: String, _ column: String) throws -> Date {
        guard case .timestamp(let value)? = row[column] else { throw corrupt(table, column, "must be a timestamp") }
        return value
    }

    private static func optionalTimestamp(_ row: StorageRow, _ table: String, _ column: String) throws -> Date? {
        guard let value = row[column] else { return nil }
        switch value {
        case .null: return nil
        case .timestamp(let result): return result
        default: throw corrupt(table, column, "must be a timestamp or null")
        }
    }

    private static func hlc(_ row: StorageRow, _ table: String, _ column: String) throws -> HLC {
        guard case .hlc(let value)? = row[column] else { throw corrupt(table, column, "must be an HLC") }
        return value
    }

    private static func optionalHLC(_ row: StorageRow, _ table: String, _ column: String) throws -> HLC? {
        guard let value = row[column] else { return nil }
        switch value {
        case .null: return nil
        case .hlc(let result): return result
        default: throw corrupt(table, column, "must be an HLC or null")
        }
    }

    private static func optionalDigest(_ row: StorageRow, _ table: String, _ column: String) throws {
        guard let value = row[column] else { return }
        switch value {
        case .null: return
        case .blob(let bytes) where bytes.count == 32: return
        default: throw corrupt(table, column, "must be a 32-byte blob or null")
        }
    }

    private static func optionalMerkleRoot(_ row: StorageRow, _ table: String, _ column: String) throws -> MerkleRoot? {
        guard let value = row[column] else { return nil }
        switch value {
        case .null: return nil
        case .blob(let bytes) where bytes.count == 32: return MerkleRoot(bytes: Array(bytes))
        default: throw corrupt(table, column, "must be a 32-byte blob or null")
        }
    }

    private static func optionalJSON(_ row: StorageRow, _ table: String, _ column: String) throws {
        guard let value = row[column] else { return }
        switch value {
        case .null: return
        case .json(let data):
            guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
                throw corrupt(table, column, "must contain valid JSON")
            }
        default: throw corrupt(table, column, "must be JSON or null")
        }
    }

    private static func corrupt(_ table: String, _ column: String, _ reason: String) -> LocusInventorySnapshotError {
        .corruptRow(table: table, column: column, reason: reason)
    }
}
