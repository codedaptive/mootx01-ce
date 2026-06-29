// SubstrateNodeTopologyProvider.swift
//
// Concrete adapter (ADR-017 §10) that bridges LocusKit's NodeStore
// (UUID ids, async throws) to GeniusLocusKit's GLKNodeTopologyProvider
// protocol (String ids, async non-throwing).
//
// The adapter shares the estate's NodeStore directly (NT-Q1),
// eliminating the redundant HLC generator and extra connection.
// All operations are read-only (getNode, rootNode, childNodes);
// the adapter never writes to the nodes table.
//
// String-UUID conversion at the boundary: incoming String ids are
// parsed to UUID via UUID(uuidString:); outgoing UUIDs are formatted
// via .uuidString. Invalid strings are swallowed (the protocol is
// non-throwing) and logged.
//
// Tree walk strategy for treeEdges: BFS from the root node, collecting
// all active parent-child pairs. The tree is fixed-depth (max depth 2:
// estate→wing→room), so the walk is bounded and fast.

import Foundation
import LocusKit
import OSLog

private let log = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit.SubstrateNodeTopologyProvider")

/// Adapter wrapping LocusKit's NodeStore to satisfy GLK's
/// GLKNodeTopologyProvider protocol, converting String↔UUID at the
/// boundary.
///
/// Created automatically when an estate is opened (Part 2:
/// auto-registration in EstateCoordinator.open). Callers of
/// `.nodeTreeNative` recall mode get substrate-native topology
/// without supplying a host-side provider.
// @unchecked: final class with Sendable stored property (actor);
// class types do not auto-synthesize Sendable in Swift 6.
public final class SubstrateNodeTopologyProvider: GLKNodeTopologyProvider, @unchecked Sendable {

    /// The estate's shared NodeStore. Read-only usage — the adapter
    /// never calls mutation methods (createNode, createRoot,
    /// tombstoneNode) — only getNode, rootNode, childNodes.
    private let nodeStore: NodeStore

    /// Construct from the estate's shared NodeStore (NT-Q1).
    ///
    /// Shares the same NodeStore the estate uses, eliminating the
    /// redundant HLC generator that the old Storage-based init created.
    ///
    /// - Parameter nodeStore: the estate's NodeStore, now public.
    public init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    // MARK: - GLKNodeTopologyProvider

    /// Return the parent node id of `nodeID`, or nil if it is a root.
    ///
    /// Swallows throws at the adapter boundary (the protocol is
    /// non-throwing). Logs errors and returns nil on failure.
    public func parentID(of nodeID: String) async -> String? {
        guard let uuid = UUID(uuidString: nodeID) else {
            log.warning("parentID: invalid UUID string '\(nodeID, privacy: .public)'")
            return nil
        }
        do {
            guard let node = try await nodeStore.getNode(id: uuid) else {
                return nil
            }
            return node.parentId?.uuidString
        } catch {
            log.error("parentID failed for \(nodeID, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    /// Return the direct children of `nodeID` as String UUIDs.
    ///
    /// Returns an empty array when `nodeID` is a leaf, is not present,
    /// or on any error.
    public func childIDs(of nodeID: String) async -> [String] {
        guard let uuid = UUID(uuidString: nodeID) else {
            log.warning("childIDs: invalid UUID string '\(nodeID, privacy: .public)'")
            return []
        }
        do {
            let children = try await nodeStore.childNodes(parentId: uuid)
            return children.map { $0.id.uuidString }
        } catch {
            log.error("childIDs failed for \(nodeID, privacy: .public): \(error, privacy: .public)")
            return []
        }
    }

    /// Return the induced edge set for the given scope.
    ///
    /// Walks the substrate's node tree via BFS from the root, collecting
    /// all active parent-child pairs. The tree is fixed-depth (max
    /// depth 2: estate→wing→room per ADR-017 I-NT-2), so the walk is
    /// bounded.
    ///
    /// When `scope` is nil, the full forest is returned. When `scope`
    /// is provided, only pairs where BOTH endpoints are in scope are
    /// included (induced edge set contract, locked).
    public func treeEdges(scope: [String]?) async -> [(parent: String, child: String)] {
        do {
            let allEdges = try await collectAllEdges()
            guard let scope else { return allEdges }
            let scopeSet = Set(scope)
            return allEdges.filter { scopeSet.contains($0.parent) && scopeSet.contains($0.child) }
        } catch {
            log.error("treeEdges failed: \(error, privacy: .public)")
            return []
        }
    }

    // MARK: - Internal

    /// BFS from root, collecting all active parent→child edge pairs.
    ///
    /// Fixed-depth tree (max depth 2) guarantees bounded traversal.
    /// Returns edges as (parent: String, child: String) with UUID
    /// strings.
    private func collectAllEdges() async throws -> [(parent: String, child: String)] {
        guard let root = try await nodeStore.rootNode() else {
            return []
        }
        var edges: [(parent: String, child: String)] = []
        var queue: [Node] = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = try await nodeStore.childNodes(parentId: current.id)
            for child in children {
                edges.append((
                    parent: current.id.uuidString,
                    child: child.id.uuidString
                ))
                queue.append(child)
            }
        }
        return edges
    }
}
