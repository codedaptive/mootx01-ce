// MockPacketsClient.swift
//
// In-process WorkPacketEstateClient stub for PacketsEngine tests.
//
// Respects the Filter.exportable filterChain entry: drawers planted with
// adjectiveBitmap encoding AdjectiveExportability.public_ (raw 32 at bits
// 12–17) pass the filter; others (adjectiveBitmap == 0, the .private_ default)
// are excluded when the filterChain contains .exportable.

import Foundation
import LocusKit
import WorkPacketKit

// MARK: - MockPacketsClient

/// Minimal stub conforming to WorkPacketEstateClient.
///
/// Planted drawers are stored in memory. `listDrawers` honours the
/// `.exportable` filter by inspecting each drawer's adjectiveBitmap.
/// All other RecallFrame fields (wing, room, ordering, limit) are
/// applied with the same degree of faithfulness as the existing
/// WorkPacketKit MockEstateClient.
final class MockPacketsClient: WorkPacketEstateClient, @unchecked Sendable {

    // MARK: - Storage

    private var drawers: [String: Drawer] = [:]

    // MARK: - WorkPacketEstateClient

    func capture(_ frame: CaptureFrame) async throws -> Drawer {
        let drawer = Drawer(
            content: frame.content,
            parentNodeId: "room-node",
            addedBy: frame.addedBy,
            filedAt: Self.epoch,
            embeddingModelID: frame.embeddingModelID,
            udcCode: frame.latticeAnchor.udcCode
        )
        drawers[drawer.id] = drawer
        return drawer
    }

    func captureTunnel(_ frame: TunnelCaptureFrame) async throws -> Tunnel {
        Tunnel(
            id: UUID().uuidString,
            sourceWing: frame.sourceWing,
            sourceRoom: frame.sourceRoom,
            sourceDrawerId: frame.sourceDrawerId,
            targetWing: frame.targetWing,
            targetRoom: frame.targetRoom,
            targetDrawerId: frame.targetDrawerId,
            label: frame.label,
            kind: frame.kind,
            adjectiveBitmap: 0,
            operationalBitmap: 0,
            provenanceBitmap: 0,
            addedBy: frame.addedBy,
            filedAt: Self.epoch
        )
    }

    /// Return stored drawers, optionally filtered by the `.exportable` case.
    ///
    /// The `.exportable` filter checks whether bits 12–17 of `adjectiveBitmap`
    /// equal `AdjectiveExportability.public_.rawValue` (32). This mirrors the
    /// SQL evaluation the real estate performs for this filterChain entry.
    func listDrawers(_ frame: RecallFrame) async throws -> [Drawer] {
        let wantExportable = frame.filterChain.contains {
            if case .exportable = $0 { return true }
            return false
        }
        var results = drawers.values.filter { drawer in
            guard wantExportable else { return true }
            // exportability field occupies bits 12–17; .public_ raw value is 32.
            return (drawer.adjectiveBitmap >> 12) & 0x3F == 32
        }
        .sorted { $0.filedAt > $1.filedAt }
        if let limit = frame.limit {
            results = Array(results.prefix(limit))
        }
        return results
    }

    func getDrawers(ids: [String]) async throws -> [Drawer] {
        ids.compactMap { drawers[$0] }
    }

    // MARK: - Test helpers

    /// Plant a pre-encoded WorkPacket content string as a drawer.
    ///
    /// - Parameters:
    ///   - id:         Drawer ID (returned as the key). Defaults to UUID.
    ///   - content:    JSON-encoded WorkPacket string.
    ///   - exportable: When true, stamps adjectiveBitmap with .public_ (bits 12–17 = 32).
    ///                 When false (default), leaves adjectiveBitmap = 0 (.private_).
    @discardableResult
    func plant(id: String = UUID().uuidString,
               content: String,
               exportable: Bool) -> Drawer {
        // exportability at bits 12–17: .public_ = 32 << 12.
        let bitmap: Int64 = exportable ? (Int64(32) << 12) : 0
        let drawer = Drawer(
            id: id,
            content: content,
            parentNodeId: "room-node",
            addedBy: "MockPacketsClient",
            filedAt: Self.epoch,
            embeddingModelID: "none",
            adjectiveBitmap: bitmap
        )
        drawers[id] = drawer
        return drawer
    }

    // MARK: - Private

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
}
