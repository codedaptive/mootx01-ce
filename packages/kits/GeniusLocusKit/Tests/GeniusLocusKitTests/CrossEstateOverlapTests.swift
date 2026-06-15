import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Lattice-overlap fan-out tests for `GeniusLocusKit.fanOutRecall`.
///
/// Three estates with distinct zoom windows. Queries scoped to a
/// region that overlaps two of them must return contributions from
/// those two and only those two. A region disjoint from every window
/// must return no contributions. This is the success criterion in
/// `GENIUSLOCUS_IMPLEMENTATION_PLAN_v0.35.md` section 2:
/// overlapping-region queries return content from all overlapping
/// estates; disjoint-region queries return only that estate's content
/// (or nothing, when nothing overlaps).
@Suite("Cross-estate overlap fan-out")
struct CrossEstateOverlapTests {

    /// Open an estate at the supplied zoom window by writing the
    /// manifest fields directly through `DrawerStore.setMeta` before
    /// the `Estate.create` call adopts the manifest defaults.
    ///
    /// LocusKit's substrate seeds the manifest on first store open
    /// with `zoom_window_low = 0` and `zoom_window_high = 99`. Tests
    /// override these by constructing the store first, writing the
    /// custom values, then handing the same storage to `Estate.create`
    /// so the kit-level handle picks them up via the manifest read
    /// the coordinator does at open time.
    private func storageWithZoom(low: Int, high: Int) async throws -> InMemoryStorage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        let store = try await DrawerStore(storage: storage)
        try await store.setMeta(key: "zoom_window_low", value: String(low))
        try await store.setMeta(key: "zoom_window_high", value: String(high))
        return storage
    }

    /// Three estates at [0,10], [5,15], [20,30]. A query at [4,8] hits
    /// the first two; a query at [25,28] hits only the third; a query
    /// at [40,50] hits none.
    @Test
    func fanOutRoutesByZoomWindowOverlap() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-overlap")

        let sLow  = try await storageWithZoom(low: 0,  high: 10)
        let sMid  = try await storageWithZoom(low: 5,  high: 15)
        let sHigh = try await storageWithZoom(low: 20, high: 30)
        _ = try await LocusKit.Estate.create(storage: sLow,  owner: owner)
        _ = try await LocusKit.Estate.create(storage: sMid,  owner: owner)
        _ = try await LocusKit.Estate.create(storage: sHigh, owner: owner)

        let hLow  = try await kit.open(storage: sLow,  owner: owner)
        let hMid  = try await kit.open(storage: sMid,  owner: owner)
        let hHigh = try await kit.open(storage: sHigh, owner: owner)

        // Sanity: handles report the windows the manifest carries.
        #expect(hLow.zoomWindowLow == 0); #expect(hLow.zoomWindowHigh == 10)
        #expect(hMid.zoomWindowLow == 5); #expect(hMid.zoomWindowHigh == 15)
        #expect(hHigh.zoomWindowLow == 20); #expect(hHigh.zoomWindowHigh == 30)

        // Region [4, 8] overlaps low ([0,10]) and mid ([5,15]); high
        // ([20,30]) is disjoint.
        let twoHit = try await kit.estatesOverlapping(LatticeRegion(low: 4, high: 8))
        #expect(Set(twoHit) == Set([hLow, hMid]))

        // Region [25, 28] overlaps high only.
        let oneHit = try await kit.estatesOverlapping(LatticeRegion(low: 25, high: 28))
        #expect(oneHit == [hHigh])

        // Region [40, 50] overlaps none.
        let zeroHit = try await kit.estatesOverlapping(LatticeRegion(low: 40, high: 50))
        #expect(zeroHit == [])
    }

    /// Capture one drawer in each of the three estates; fan out a
    /// recall to a region that overlaps two of them. Expected: two
    /// contributions, each carrying its own captured drawer; the
    /// disjoint estate is not consulted and not present in the
    /// contribution list.
    @Test
    func fanOutRecallReturnsOverlappingContributionsAndSkipsDisjoint() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-overlap-2")

        let sLow  = try await storageWithZoom(low: 0,  high: 10)
        let sMid  = try await storageWithZoom(low: 5,  high: 15)
        let sHigh = try await storageWithZoom(low: 20, high: 30)
        _ = try await LocusKit.Estate.create(storage: sLow,  owner: owner)
        _ = try await LocusKit.Estate.create(storage: sMid,  owner: owner)
        _ = try await LocusKit.Estate.create(storage: sHigh, owner: owner)

        let hLow  = try await kit.open(storage: sLow,  owner: owner)
        let hMid  = try await kit.open(storage: sMid,  owner: owner)
        let hHigh = try await kit.open(storage: sHigh, owner: owner)

        // Capture one drawer in each estate; tag the content so we can
        // verify routing put the right rows in the right contribution.
        func capture(into handle: EstateHandle, tag: String) async throws -> Drawer {
            let estate = try await kit.estate(for: handle)
            return try await estate.capture(CaptureFrame(
                content: "content-\(tag)",
                channel: .typed,
                room: "room-\(tag)",
                latticeAnchor: .udc("004"),
                addedBy: "test",
                embeddingModelID: "model-v1"
            ))
        }
        let dLow  = try await capture(into: hLow,  tag: "low")
        let dMid  = try await capture(into: hMid,  tag: "mid")
        let dHigh = try await capture(into: hHigh, tag: "high")

        // Recall with `.userConfirmed` so default-prepend does not insert
        // `.userConfirmed` (newly captured drawers have provenance==0;
        // the prepend would prune all three rows and mask routing).
        let frame = RecallFrame(filterChain: [.userConfirmed])
        let region = LatticeRegion(low: 4, high: 8) // overlaps low and mid only

        let contributions = try await kit.fanOutRecall(frame, region: region)
        let byHandle = Dictionary(uniqueKeysWithValues: contributions.map { ($0.handle, $0) })

        #expect(contributions.count == 2,
            "two estates overlap [4,8]; high is disjoint")
        #expect(byHandle[hLow] != nil)
        #expect(byHandle[hMid] != nil)
        #expect(byHandle[hHigh] == nil,
            "disjoint estate must not appear in contributions")

        let idsLow = byHandle[hLow]!.drawers.map(\.id)
        let idsMid = byHandle[hMid]!.drawers.map(\.id)
        #expect(idsLow.contains(dLow.id),
            "low contribution must carry its own captured drawer")
        #expect(idsMid.contains(dMid.id),
            "mid contribution must carry its own captured drawer")
        #expect(!idsLow.contains(dHigh.id),
            "low contribution must not carry high's drawer (storage isolation)")
        #expect(!idsMid.contains(dHigh.id),
            "mid contribution must not carry high's drawer (storage isolation)")
    }

    /// Disjoint region returns the empty contribution list — the
    /// explicit disjoint-region case from the plan section 2 success
    /// criterion.
    @Test
    func disjointRegionReturnsEmpty() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-disjoint")
        let storage = try await storageWithZoom(low: 0, high: 10)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        _ = try await kit.open(storage: storage, owner: owner)

        let frame = RecallFrame(filterChain: [.userConfirmed])
        let contributions = try await kit.fanOutRecall(
            frame, region: LatticeRegion(low: 50, high: 60)
        )
        #expect(contributions.count == 0)
    }

    /// Inverted region is a programmer error and surfaces as a typed
    /// throw rather than a silent empty result.
    @Test
    func invertedRegionThrows() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-inverted")
        let storage = try await storageWithZoom(low: 0, high: 10)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        _ = try await kit.open(storage: storage, owner: owner)

        let frame = RecallFrame(filterChain: [.userConfirmed])
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.fanOutRecall(frame, region: LatticeRegion(low: 10, high: 4))
        }
        if case .invalidLatticeRegion(let low, let high)? = thrown {
            #expect(low == 10)
            #expect(high == 4)
        } else {
            Issue.record("expected .invalidLatticeRegion, got \(String(describing: thrown))")
        }
    }
}
