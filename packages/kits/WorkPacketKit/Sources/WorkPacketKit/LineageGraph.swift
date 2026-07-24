import Foundation
import LocusKit

// LineageGraph — lineage traversal over work-packet drawers.
//
// Packets embed their lineage links in JSON (WorkPacket.lineageLinks),
// which is the self-contained source of truth. This struct walks those
// links recursively to enumerate antecedents without querying tunnels
// directly (the tunnel read API is estate-internal; JSON embedding is
// the public channel).
//
// Tunnels filed by WorkPacketStore exist for the estate's own graph
// machinery (ARIA, NeuronKit topology) — not for WorkPacketKit reads.

// MARK: - LineageGraph

/// Reads the lineage of work packets by walking `WorkPacket.lineageLinks`
/// breadth-first across the estate.
public struct LineageGraph: Sendable {

    private let client: any WorkPacketEstateClient
    private let decoder: JSONDecoder

    /// - Parameter client: the same estate client the store uses.
    public init(client: any WorkPacketEstateClient) {
        self.client = client
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - trace

    /// Walk the lineage graph from `rootDrawerID` up to `maxDepth` hops.
    ///
    /// Uses a batched breadth-first strategy: each hop fetches all frontier
    /// drawers in a single `getDrawers(ids:)` call rather than one call per
    /// packet. Cycles are detected via a visited set.
    ///
    /// - Parameters:
    ///   - rootDrawerID: the drawer ID of the starting packet.
    ///   - maxDepth: maximum hops to follow. Defaults to 10.
    /// - Returns: ordered list of antecedent drawer IDs, breadth-first.
    public func trace(from rootDrawerID: String, maxDepth: Int = 10) async throws -> [String] {
        var visited: Set<String> = [rootDrawerID]
        var frontier: [String] = [rootDrawerID]
        var antecedents: [String] = []
        var depth = 0

        while !frontier.isEmpty && depth < maxDepth {
            // Collect all IDs reachable from the current frontier in one batch.
            let nextIDs = try await collectLinkTargets(for: frontier, excluding: visited)
            for id in nextIDs {
                visited.insert(id)
                antecedents.append(id)
            }
            frontier = nextIDs
            depth += 1
        }

        return antecedents
    }

    /// Batch-fetch `drawerIDs` and return the unique target IDs from all their
    /// `lineageLinks`, excluding IDs already in `visited`.
    ///
    /// Batching is important for performance: a deep lineage chain of N packets
    /// causes N+1 round-trips if fetched one by one; batching collapses each
    /// hop to a single `getDrawers(ids:)` call (Kong review note, FAB5-I1).
    private func collectLinkTargets(for drawerIDs: [String], excluding visited: Set<String>) async throws -> [String] {
        guard !drawerIDs.isEmpty else { return [] }
        let drawers = try await client.getDrawers(ids: drawerIDs)
        var targets: [String] = []
        var seen: Set<String> = visited
        for drawer in drawers {
            guard let packet = try? decodePacket(from: drawer) else { continue }
            for link in packet.lineageLinks {
                let id = link.targetPacketID
                if !seen.contains(id) {
                    targets.append(id)
                    seen.insert(id)
                }
            }
        }
        return targets
    }

    // MARK: - antecedents

    /// Convenience: fetch the full `WorkPacket` values for the antecedents
    /// of `rootDrawerID`, in breadth-first traversal order.
    ///
    /// - Parameters:
    ///   - rootDrawerID: starting packet drawer ID.
    ///   - maxDepth: maximum hops. Defaults to 10.
    /// - Returns: decoded antecedent packets in traversal order.
    public func antecedents(of rootDrawerID: String, maxDepth: Int = 10) async throws -> [WorkPacket] {
        let ids = try await trace(from: rootDrawerID, maxDepth: maxDepth)
        guard !ids.isEmpty else { return [] }
        let drawers = try await client.getDrawers(ids: ids)
        // Re-order to breadth-first traversal order (getDrawers returns storage order).
        let byID = Dictionary(drawers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { id in byID[id].flatMap { try? decodePacket(from: $0) } }
    }

    // MARK: - Private

    private func decodePacket(from drawer: Drawer) throws -> WorkPacket {
        guard let data = drawer.content.data(using: .utf8) else {
            throw WorkPacketKitError.decodingFailure("drawer \(drawer.id) is not valid UTF-8")
        }
        return try decoder.decode(WorkPacket.self, from: data)
    }
}
