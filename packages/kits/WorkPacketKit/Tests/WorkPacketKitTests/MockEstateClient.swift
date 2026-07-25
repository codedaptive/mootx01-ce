import Foundation
import LocusKit
@testable import WorkPacketKit

// MockEstateClient — in-memory stub for WorkPacketEstateClient.
//
// Records captured drawers and tunnels in memory; returns them from
// listDrawers / getDrawers. Deterministic: filedAt uses a fixed epoch.

final class MockEstateClient: WorkPacketEstateClient, @unchecked Sendable {

    // MARK: - In-memory store

    // keyed by drawer.id (which equals packet.id)
    private var drawers: [String: Drawer] = [:]
    private var tunnels: [Tunnel] = []

    // Counters for verification in tests.
    private(set) var captureDrawerCount: Int = 0
    private(set) var captureTunnelCount: Int = 0

    // MARK: - WorkPacketEstateClient

    func capture(_ frame: CaptureFrame) async throws -> Drawer {
        captureDrawerCount += 1
        let drawer = makeDrawer(from: frame)
        drawers[drawer.id] = drawer
        return drawer
    }

    func captureTunnel(_ frame: TunnelCaptureFrame) async throws -> Tunnel {
        captureTunnelCount += 1
        let tunnel = Tunnel(
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
            filedAt: MockEstateClient.epoch
        )
        tunnels.append(tunnel)
        return tunnel
    }

    func listDrawers(_ frame: RecallFrame) async throws -> [Drawer] {
        // The mock returns all stored drawers, sorted by filedAt descending,
        // with limit applied. Room/wing filters are ignored — the test controls
        // what is planted.
        var results = drawers.values.sorted { $0.filedAt > $1.filedAt }
        if let limit = frame.limit {
            results = Array(results.prefix(limit))
        }
        return results
    }

    func getDrawers(ids: [String]) async throws -> [Drawer] {
        ids.compactMap { drawers[$0] }
    }

    // MARK: - Test helpers

    func storedTunnels() -> [Tunnel] { tunnels }
    func storedDrawer(id: String) -> Drawer? { drawers[id] }
    func allDrawers() -> [Drawer] { Array(drawers.values) }
    var drawerCount: Int { drawers.count }

    /// Plant a pre-encoded packet directly (used for lineage trace tests).
    func plant(_ packet: WorkPacket, filedAt: Date = MockEstateClient.epoch) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(packet)
        let content = String(data: data, encoding: .utf8)!
        let drawer = Drawer(
            id: packet.id,
            content: content,
            parentNodeId: "room-node",
            addedBy: "mock",
            filedAt: filedAt,
            embeddingModelID: "none",
            udcCode: "004"
        )
        drawers[packet.id] = drawer
    }

    // MARK: - Private helpers

    // Fixed epoch used for filedAt in mock drawers (determinism).
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDrawer(from frame: CaptureFrame) -> Drawer {
        Drawer(
            content: frame.content,
            parentNodeId: "room-node",
            addedBy: frame.addedBy,
            filedAt: MockEstateClient.epoch,
            eventTime: frame.eventTime,
            embeddingModelID: frame.embeddingModelID,
            udcCode: frame.latticeAnchor.udcCode
        )
    }
}
