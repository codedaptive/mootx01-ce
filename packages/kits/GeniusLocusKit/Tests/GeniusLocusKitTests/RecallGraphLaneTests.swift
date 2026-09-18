// RecallGraphLaneTests.swift
//
// Verifies that graph/tunnel-expansion candidates (step 4.35 in recallUnionBest)
// carry the `bitLocusGraph` source bit and have `.locusGraph` in their evidence
// paths. This is the attribution gate: a drawer surfaced ONLY because a tunnel
// points to it (not because it matched the locus bitmap, BM25, or vector lanes)
// must be attributable to the `.locusGraph` evidence lane.
//
// Tests:
//  1. graphExpansionCandidateCarriesBitLocusGraph — a drawer linked from a locus
//     hit via a tunnel appears in unionBest results with .locusGraph in sources
//     and bitLocusGraph set in the buffer's sourceMask (verified via the hit's
//     sources set, which step 11 of recallUnionBest builds from the sourceMask).
//
//  2. directLocusHitDoesNotCarryBitLocusGraph — a drawer that is a direct locus
//     hit (in the locus bitmap slice) carries .locusBitmap but NOT .locusGraph,
//     confirming the bits are disjoint for pure locus candidates.
//
//  3. graphNeighborCarriesBothBitsWhenAlsoInLocusSlice — if a drawer is BOTH a
//     direct locus hit AND a tunnel neighbour, it carries both .locusBitmap and
//     .locusGraph (the sourceMask union in buffer.merge sets both bits).

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("Recall graph-lane expansion — bitLocusGraph attribution")
struct RecallGraphLaneTests {

    // MARK: - Estate factory

    /// Open an InMemory estate and capture a drawer, returning the estate for
    /// direct tunnel insertion.
    private func openEstate() async throws -> (kit: GeniusLocusKit, handle: EstateHandle, estate: LocusKit.Estate) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-graph-lane-tests-\(UUID().uuidString)")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let estate = try await kit.estate(for: handle)
        return (kit, handle, estate)
    }

    /// Capture one drawer and return it.
    private func captureDrawer(
        content: String,
        room: String = "graph-lane-room",
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("000"),
            addedBy: "graph-lane-tests",
            embeddingModelID: "test-model-v1"
        )
        return try await kit.capture(handle, frame)
    }

    /// Recall frame matching every currently-believed row.
    private func activeFrame() -> RecallFrame {
        RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
    }

    // MARK: - 1. Graph-expansion candidate carries bitLocusGraph

    /// A drawer reachable only via a tunnel from a locus hit MUST appear in
    /// unionBest results with `.locusGraph` in its `sources` set.
    ///
    /// Setup:
    ///   - drawerA is a direct locus hit (currently-believed, bitmap-indexed).
    ///   - drawerB is NOT in the locus slice (different content, no bitmap match);
    ///     it is reachable from drawerA via an active tunnel.
    ///   - unionBest step 4.35 expands drawerA's tunnels, finds drawerB's ID, and
    ///     merges it with bitLocusGraph.
    ///   - Step 11 builds sources from the sourceMask; .locusGraph must appear.
    @Test("graph-expansion candidate carries .locusGraph in sources")
    func graphExpansionCandidateCarriesBitLocusGraph() async throws {
        let (kit, handle, estate) = try await openEstate()

        // drawerA: direct locus hit.
        let drawerA = try await captureDrawer(content: "locus-hit-A", room: "wing-A", kit: kit, handle: handle)

        // drawerB: tunnel neighbor, NOT a direct locus hit (different wing/room so
        // a wing-scoped recall would not include it; the default frame scans all
        // currently-believed rows, so drawerB IS reachable — but step 4.35 must
        // also fire to merge it with bitLocusGraph).
        let drawerB = try await captureDrawer(content: "tunnel-neighbor-B", room: "wing-B", kit: kit, handle: handle)

        // Create an active tunnel from drawerA → drawerB.
        let tunnelFrame = TunnelCaptureFrame(
            sourceWing: "wing-A", sourceRoom: "wing-A",
            targetWing: "wing-B", targetRoom: "wing-B",
            label: "graph-lane-test-link",
            addedBy: "graph-lane-tests",
            sourceDrawerId: drawerA.id,
            targetDrawerId: drawerB.id,
            kind: .references
        )
        _ = try await estate.capture(tunnelFrame)

        // Recall in unionBest mode over the default active frame.
        let request = GLKRecallRequest(
            frame: activeFrame(),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 20,
            fallback: .allowDegraded,
            origin: .internal
        )
        let result = try await kit.recall(handle, request)

        // drawerB must appear in results.
        let hitB = result.hits.first { $0.id == drawerB.id }
        let hitBSources = hitB?.sources ?? []
        #expect(hitB != nil, "drawerB (tunnel neighbor) must appear in unionBest results")
        #expect(hitBSources.contains(.locusGraph),
                "drawerB must have .locusGraph in sources (got \(hitBSources))")
    }

    // MARK: - 2. Direct locus hit does NOT carry .locusGraph

    /// A drawer that is a pure locus-bitmap hit (no tunnel points to it) must
    /// carry `.locusBitmap` but NOT `.locusGraph`. Confirms the bits are not
    /// conflated.
    @Test("direct locus hit carries .locusBitmap but not .locusGraph")
    func directLocusHitDoesNotCarryBitLocusGraph() async throws {
        let (kit, handle, _) = try await openEstate()

        // Single drawer with no tunnels.
        let drawer = try await captureDrawer(content: "pure-locus-hit", kit: kit, handle: handle)

        let request = GLKRecallRequest(
            frame: activeFrame(),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 10,
            fallback: .allowDegraded,
            origin: .internal
        )
        let result = try await kit.recall(handle, request)

        let hit = result.hits.first { $0.id == drawer.id }
        let sources = hit?.sources ?? []
        #expect(hit != nil, "drawer must appear in results")
        #expect(sources.contains(.locusBitmap),
                "pure-locus drawer must have .locusBitmap in sources")
        #expect(!sources.contains(.locusGraph),
                "pure-locus drawer must NOT have .locusGraph (no tunnel points to it)")
    }

    // MARK: - 3. Drawer that is BOTH a locus hit and a tunnel target carries both bits

    /// When drawerA tunnels to drawerB AND drawerB is also a direct locus hit
    /// (it is currently-believed and bitmap-indexed), drawerB's sourceMask should
    /// have BOTH `bitLocusBitmap` (from the locus lane merge) and `bitLocusGraph`
    /// (from the graph-expansion merge, via buffer.merge OR-union).
    @Test("drawer that is both locus hit and tunnel target carries both .locusBitmap and .locusGraph")
    func graphNeighborCarriesBothBitsWhenAlsoInLocusSlice() async throws {
        let (kit, handle, estate) = try await openEstate()

        let drawerA = try await captureDrawer(content: "source-drawer-A", room: "room-A", kit: kit, handle: handle)
        let drawerB = try await captureDrawer(content: "target-drawer-B", room: "room-B", kit: kit, handle: handle)

        // Tunnel from A → B. B is ALSO a direct locus hit because it is
        // currently-believed; the locus bitmap lane merges it with bitLocusBitmap
        // first, and the graph expansion then OR-unions bitLocusGraph on top.
        let tunnelFrame = TunnelCaptureFrame(
            sourceWing: "room-A", sourceRoom: "room-A",
            targetWing: "room-B", targetRoom: "room-B",
            label: "both-bits-test-link",
            addedBy: "graph-lane-tests",
            sourceDrawerId: drawerA.id,
            targetDrawerId: drawerB.id,
            kind: .references
        )
        _ = try await estate.capture(tunnelFrame)

        let request = GLKRecallRequest(
            frame: activeFrame(),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 20,
            fallback: .allowDegraded,
            origin: .internal
        )
        let result = try await kit.recall(handle, request)

        let hitB = result.hits.first { $0.id == drawerB.id }
        let sources = hitB?.sources ?? []
        #expect(hitB != nil, "drawerB must appear in results")
        #expect(sources.contains(.locusBitmap),
                "drawerB is a direct locus hit — must have .locusBitmap")
        #expect(sources.contains(.locusGraph),
                "drawerB is a tunnel target — must also have .locusGraph (got \(sources))")
    }

    // MARK: - 4. Locus ramp divisor — the normalised locus column, both ports

    /// The unionBest locus ramp divides by `frontierK`, not by the slice length.
    ///
    /// Three drawers captured oldest to newest form a slice of 3 at a frontierK
    /// of at least 64 (the clamp floor), and a tunnel from the newest to the
    /// oldest merges the graph lane's fixed 0.5 onto the oldest by max. After
    /// step 6 min-max normalisation the locus column reads 1.0 / 0.5 / 0.0
    /// (newest / middle / oldest): the ramp is 1, (K-1)/K, (K-2)/K, the 0.5
    /// never wins the max, and the middle lands exactly half-way. A
    /// slice-length divisor would give 1, 2/3, max(1/3, 0.5) = 0.5, and the
    /// middle would normalise to 1/3. The pin holds for every frontierK of 5 or
    /// more. Twin of Rust `locus_ramp_divides_by_frontier_k_not_slice_length`.
    @Test("unionBest locus ramp divides by frontierK: normalised column reads 1.0 / 0.5 / 0.0")
    func locusRampDividesByFrontierKNotSliceLength() async throws {
        let (kit, handle, estate) = try await openEstate()

        // Content strings sort the same way as capture time (content DESC is the
        // final tiebreak of the stable locus sort), so the slice order is fixed
        // even if two captures share a filedAt.
        let oldest = try await captureDrawer(content: "ramp-1-oldest", room: "ramp-room", kit: kit, handle: handle)
        let middle = try await captureDrawer(content: "ramp-2-middle", room: "ramp-room", kit: kit, handle: handle)
        let newest = try await captureDrawer(content: "ramp-3-newest", room: "ramp-room", kit: kit, handle: handle)

        let tunnelFrame = TunnelCaptureFrame(
            sourceWing: "ramp-room", sourceRoom: "ramp-room",
            targetWing: "ramp-room", targetRoom: "ramp-room",
            label: "ramp-divisor-link",
            addedBy: "graph-lane-tests",
            sourceDrawerId: newest.id,
            targetDrawerId: oldest.id,
            kind: .references
        )
        _ = try await estate.capture(tunnelFrame)

        let request = GLKRecallRequest(
            frame: activeFrame(),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 20,
            fallback: .allowDegraded,
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.hits.count == 3, "all three drawers must surface (got \(result.hits.count))")

        func locus(_ id: String) -> Float {
            result.hits.first { $0.id == id }?.score.locus ?? .nan
        }
        #expect(abs(locus(newest.id) - 1.0) < 1e-4, "newest: got \(locus(newest.id))")
        #expect(abs(locus(middle.id) - 0.5) < 1e-4, "middle: got \(locus(middle.id))")
        #expect(abs(locus(oldest.id) - 0.0) < 1e-4, "oldest: got \(locus(oldest.id))")
    }
}
