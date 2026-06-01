import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// GLK `recallTunnels(_:wing:)` — the coordinator-level read over the
/// estate's association graph. Resolves the handle through `estate(for:)`
/// and returns the tunnels originating in `wing`. Peer of the Rust
/// `EstateCoordinator::recall_tunnels`; the surface the structural
/// reasoning-lens recipes read the drawer graph through.
@Suite("GLK recallTunnels")
struct RecallTunnelsTests {

    private func makeStorage() -> InMemoryStorage {
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        return InMemoryStorage(configuration: config)
    }

    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-recall-tunnels")
        let storage = makeStorage()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func tunnelFrame(source: String, target: String, label: String) -> TunnelCaptureFrame {
        TunnelCaptureFrame(
            sourceWing: source, sourceRoom: "r1",
            targetWing: target, targetRoom: "r2",
            label: label, addedBy: "bilby",
            sourceDrawerId: nil, targetDrawerId: nil, kind: .references
        )
    }

    // Tunnels captured into the estate are returned by the wing's read.
    @Test("recallTunnels returns the wing's outgoing tunnels")
    func returnsOutgoing() async throws {
        let (kit, handle) = try await openOneEstate()
        let estate = try await kit.estate(for: handle)
        _ = try await estate.capture(tunnelFrame(source: "study", target: "kitchen", label: "links"))
        _ = try await estate.capture(tunnelFrame(source: "study", target: "garden", label: "relates"))

        let tunnels = try await kit.recallTunnels(handle, wing: "study")
        #expect(tunnels.count == 2)
        #expect(Set(tunnels.map(\.targetWing)) == ["kitchen", "garden"])
        #expect(tunnels.allSatisfy { $0.sourceWing == "study" })
    }

    // A wing with no outgoing tunnels reads empty (never throws).
    @Test("recallTunnels is empty for a wing with no tunnels")
    func emptyForUnlinkedWing() async throws {
        let (kit, handle) = try await openOneEstate()
        let estate = try await kit.estate(for: handle)
        _ = try await estate.capture(tunnelFrame(source: "study", target: "kitchen", label: "links"))

        let tunnels = try await kit.recallTunnels(handle, wing: "attic")
        #expect(tunnels.isEmpty)
    }

    // A stale handle surfaces estateNotOpen rather than an empty result.
    @Test("recallTunnels throws estateNotOpen for a stale handle")
    func throwsForStaleHandle() async throws {
        let (kit, handle) = try await openOneEstate()
        try await kit.close(handle)
        await #expect(throws: GeniusLocusKitError.self) {
            _ = try await kit.recallTunnels(handle, wing: "study")
        }
    }
}
