import Foundation
import PersistenceKit
import Testing
@testable import LocusKit

/// `Estate.tunnelsFromWing(_:)` — the estate-level public read over the
/// association graph (`DrawerStore.tunnelsFrom(wing:)`). The reasoning
/// graph the structural reasoning lenses consume is built from these
/// edges; the read is the Swift peer of the Rust `Estate::tunnels_from_wing`.
@Suite("EstateTunnelReadTests")
struct EstateTunnelReadTests {

    private func makeEstate() async throws -> Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-tunnelread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        return try await Estate.create(
            storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
    }

    private func frame(source: String, target: String, label: String) -> TunnelCaptureFrame {
        TunnelCaptureFrame(
            sourceWing: source, sourceRoom: "r1",
            targetWing: target, targetRoom: "r2",
            label: label, addedBy: "bilby",
            sourceDrawerId: nil, targetDrawerId: nil, kind: .references
        )
    }

    // Tunnels captured from a wing are returned by that wing's read.
    @Test("tunnelsFromWing returns the wing's outgoing tunnels")
    func returnsOutgoing() async throws {
        let estate = try await makeEstate()
        _ = try await estate.capture(frame(source: "study", target: "kitchen", label: "links"))
        _ = try await estate.capture(frame(source: "study", target: "garden", label: "relates"))

        let tunnels = try await estate.tunnelsFromWing("study")
        #expect(tunnels.count == 2)
        #expect(Set(tunnels.map(\.targetWing)) == ["kitchen", "garden"])
        #expect(tunnels.allSatisfy { $0.sourceWing == "study" })
    }

    // A wing with no outgoing tunnels reads empty (never throws).
    @Test("tunnelsFromWing is empty for a wing with no tunnels")
    func emptyForUnlinkedWing() async throws {
        let estate = try await makeEstate()
        _ = try await estate.capture(frame(source: "study", target: "kitchen", label: "links"))

        let tunnels = try await estate.tunnelsFromWing("attic")
        #expect(tunnels.isEmpty)
    }

    // The tunnel graph read applies the same no-claims sensitivity ceiling as
    // drawer recall: a restricted/secret edge (sensitivity inherited from a
    // restricted endpoint drawer) is excluded; Normal-tier edges are visible.
    @Test("tunnelsFromWing excludes restricted/secret edges")
    func excludesRestrictedEdges() async throws {
        let estate = try await makeEstate()
        // A restricted drawer; a tunnel touching it inherits restricted
        // sensitivity (max over endpoints).
        let secretDrawer = try await estate.capture(CaptureFrame(
            content: "restricted endpoint",
            channel: .typed, room: "r1",
            latticeAnchor: .udc("000"),
            addedBy: "bilby", embeddingModelID: "test-v1",
            sensitivity: .restricted))
        // Tunnel from study touching the restricted drawer → restricted edge.
        _ = try await estate.capture(TunnelCaptureFrame(
            sourceWing: "study", sourceRoom: "r1",
            targetWing: "vault", targetRoom: "r2",
            label: "sensitive-link", addedBy: "bilby",
            sourceDrawerId: secretDrawer.id, targetDrawerId: nil, kind: .references))
        // A plain Normal-tier tunnel from study → visible.
        _ = try await estate.capture(frame(source: "study", target: "kitchen", label: "normal-link"))

        let tunnels = try await estate.tunnelsFromWing("study")
        #expect(Set(tunnels.map(\.targetWing)) == ["kitchen"],
            "only the Normal-tier edge is visible; the restricted edge is excluded")
    }

    // The read is scoped to the source wing — other wings' tunnels are excluded.
    @Test("tunnelsFromWing is scoped to the source wing")
    func scopedToSourceWing() async throws {
        let estate = try await makeEstate()
        _ = try await estate.capture(frame(source: "study", target: "kitchen", label: "a"))
        _ = try await estate.capture(frame(source: "garden", target: "kitchen", label: "b"))

        let fromStudy = try await estate.tunnelsFromWing("study")
        #expect(fromStudy.count == 1)
        #expect(fromStudy.first?.sourceWing == "study")
    }

    // MARK: - Estate.allTunnels

    // allTunnels returns all non-tombstoned tunnels across every wing.
    // The dreaming daemon calls this to suppress duplicate proposals.
    @Test("allTunnels returns all tunnels across all wings")
    func allTunnelsReturnsAll() async throws {
        let estate = try await makeEstate()
        _ = try await estate.capture(frame(source: "study",  target: "kitchen", label: "a"))
        _ = try await estate.capture(frame(source: "garden", target: "kitchen", label: "b"))
        _ = try await estate.capture(frame(source: "attic",  target: "study",   label: "c"))

        let all = try await estate.allTunnels()
        #expect(all.count == 3)
        let labels = Set(all.map(\.label))
        #expect(labels == ["a", "b", "c"])
    }

    @Test("allTunnels returns empty array when estate has no tunnels")
    func allTunnelsEmptyEstate() async throws {
        let estate = try await makeEstate()
        let all = try await estate.allTunnels()
        #expect(all.isEmpty)
    }

    @Test("allTunnels cross-wing: includes tunnels that tunnelsFromWing misses")
    func allTunnelsCrossWing() async throws {
        let estate = try await makeEstate()
        _ = try await estate.capture(frame(source: "alpha", target: "beta",  label: "x"))
        _ = try await estate.capture(frame(source: "gamma", target: "delta", label: "y"))

        // allTunnels must find both; tunnelsFromWing("alpha") would miss "y".
        let all = try await estate.allTunnels()
        #expect(all.count == 2)

        let fromAlpha = try await estate.tunnelsFromWing("alpha")
        #expect(fromAlpha.count == 1, "sanity: tunnelsFromWing only sees its wing")
    }
}
