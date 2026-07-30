import Foundation
import Testing
@testable import LocusKit

/// AC-2 and AC-5 (SPEC_CONSOLIDATION_VAGUE_RECALL §7): consolidation transaction
/// correctness and candidate-pool shrinkage.
///
/// AC-2 (shrinkage): on a fixture estate, the post-consolidation candidate pool
/// (drawersEligibleForConsolidation) is smaller by exactly the absorbed count.
///
/// AC-5 (supersession containment): consolidateTransactionally creates
/// `_consolidated_from` tunnels (vague→constituent), sets bit-21 on each
/// constituent in the same transaction, and never touches constituent state.
/// foldIn adds a single constituent with the same invariants, subject to the
/// level-2 cap.
///
/// Also covers constituentIDsForVagueItem round-trip and the pre-condition
/// rejection paths (< 3 constituents, non-vague drawer, level cap).
@Suite("ConsolidationTransactionTests — AC-2 / AC-5")
struct ConsolidationTransactionTests {

    // MARK: - Fixtures

    private func makeTempURL() -> URL {
        let name = "locuskit-consol-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func makeStore() async throws -> (DrawerStore, URL) {
        let url = makeTempURL()
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    private func t(_ epoch: TimeInterval) -> Date { Date(timeIntervalSince1970: epoch) }

    /// Create a plain episodic drawer (no vague bits).
    private func episodicDrawer(id: String) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "episodic content \(id)",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: t(1_700_000_000),
            embeddingModelID: "test-model-v1"
        )
    }

    /// Create a vague drawer with is_vague (bit 20) set.
    private func vagueDrawer(id: String) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "vague summary \(id)",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: t(1_700_001_000),
            embeddingModelID: "test-model-v1",
            operationalBitmap: DrawerFeatureFlags.isVague.rawValue
        )
    }

    // MARK: - Pre-condition rejection

    @Test("consolidateTransactionally rejects fewer than 3 constituents (D5)")
    func consolidate_rejectsLessThan3Constituents() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d1 = episodicDrawer(id: "d1")
        let d2 = episodicDrawer(id: "d2")
        try await store.addDrawer(d1)
        try await store.addDrawer(d2)
        let vague = vagueDrawer(id: "v1")
        await #expect(throws: (any Error).self) {
            try await store.consolidateTransactionally(
                vagueDrawer: vague,
                constituentIDs: [d1.id, d2.id],
                addedBy: "newton",
                now: t(1_700_002_000)
            )
        }
    }

    @Test("consolidateTransactionally rejects drawer without isVague bit (bit 20 must be set)")
    func consolidate_rejectsNonVagueDrawer() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d1 = episodicDrawer(id: "c1")
        let d2 = episodicDrawer(id: "c2")
        let d3 = episodicDrawer(id: "c3")
        try await store.addDrawer(d1)
        try await store.addDrawer(d2)
        try await store.addDrawer(d3)
        // Pass a non-vague drawer as the vagueDrawer parameter.
        let notVague = episodicDrawer(id: "notVague")
        await #expect(throws: (any Error).self) {
            try await store.consolidateTransactionally(
                vagueDrawer: notVague,
                constituentIDs: [d1.id, d2.id, d3.id],
                addedBy: "newton",
                now: t(1_700_002_000)
            )
        }
    }

    // MARK: - AC-5: atomic transaction correctness

    @Test("AC-5: consolidateTransactionally creates _consolidated_from tunnels (source=vague, target=constituent)")
    func consolidate_createsConsolidatedFromTunnels() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        // Insert 3 constituents.
        let d1 = episodicDrawer(id: "t-c1")
        let d2 = episodicDrawer(id: "t-c2")
        let d3 = episodicDrawer(id: "t-c3")
        try await store.addDrawer(d1)
        try await store.addDrawer(d2)
        try await store.addDrawer(d3)
        let vague = vagueDrawer(id: "t-v1")
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [d1.id, d2.id, d3.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )
        // Round-trip: constituentIDsForVagueItem should return the 3 IDs.
        let ids = try await store.constituentIDsForVagueItem(vagueDrawerID: vague.id)
        #expect(ids.count == 3, "must create exactly 3 _consolidated_from tunnels")
        #expect(Set(ids) == Set([d1.id, d2.id, d3.id]),
                "tunnel targets must be exactly the 3 constituent IDs")
    }

    @Test("AC-5: consolidateTransactionally sets representedByVague (bit 21) on every constituent")
    func consolidate_setsBit21OnConstituents() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d1 = episodicDrawer(id: "b-c1")
        let d2 = episodicDrawer(id: "b-c2")
        let d3 = episodicDrawer(id: "b-c3")
        try await store.addDrawer(d1)
        try await store.addDrawer(d2)
        try await store.addDrawer(d3)
        let vague = vagueDrawer(id: "b-v1")
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [d1.id, d2.id, d3.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )
        // Each constituent must have bit 21 set after consolidation.
        for cid in [d1.id, d2.id, d3.id] {
            let loaded = try await store.getDrawer(id: cid)
            #expect(loaded != nil)
            #expect(loaded?.representedByVague == true,
                    "constituent \(cid) must have bit-21 set after consolidation")
        }
    }

    @Test("AC-5: constituents' state is unchanged (still active) after consolidation")
    func consolidate_constituentStateUnchanged() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d1 = episodicDrawer(id: "s-c1")
        let d2 = episodicDrawer(id: "s-c2")
        let d3 = episodicDrawer(id: "s-c3")
        try await store.addDrawer(d1)
        try await store.addDrawer(d2)
        try await store.addDrawer(d3)
        let vague = vagueDrawer(id: "s-v1")
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [d1.id, d2.id, d3.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )
        // Constituents must remain active (state cluster A) — no supersession.
        // AC-5: "zero constituent lineages touched" by supersession.
        for cid in [d1.id, d2.id, d3.id] {
            let loaded = try await store.getDrawer(id: cid)
            #expect(loaded?.state == .active,
                    "constituent \(cid) state must remain .active after consolidation")
        }
    }

    // MARK: - AC-2: candidate pool shrinkage

    @Test("AC-2: drawersEligibleForConsolidation excludes vague items (bit 20) and absorbed constituents (bit 21)")
    func eligible_excludesVagueAndAbsorbed() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        // 5 plain drawers.
        let drawers = (1...5).map { episodicDrawer(id: "e-\($0)") }
        for d in drawers { try await store.addDrawer(d) }
        let vague = vagueDrawer(id: "e-v1")
        // Consolidate drawers 1-3 → they get bit-21; vague gets bit-20.
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [drawers[0].id, drawers[1].id, drawers[2].id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )
        // Eligible pool: drawers 4 and 5 only (vague excluded by bit-20,
        // drawers 1-3 excluded by bit-21).
        let eligible = try await store.drawersEligibleForConsolidation(
            olderThan: t(1_700_003_000), limit: 100)
        #expect(eligible.count == 2,
                "only drawers 4 and 5 should be eligible; vague+absorbed excluded")
        let eligibleIds = Set(eligible.map { $0.id })
        #expect(eligibleIds.contains(drawers[3].id))
        #expect(eligibleIds.contains(drawers[4].id))
    }

    @Test("AC-2: drawersEligibleForConsolidation shrinkage equals absorbed count")
    func eligible_shrinkageEqualsAbsorbedCount() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        // 6 plain drawers.
        let drawers = (1...6).map { episodicDrawer(id: "sh-\($0)") }
        for d in drawers { try await store.addDrawer(d) }
        // Before consolidation: all 6 eligible.
        let beforeCount = try await store.drawersEligibleForConsolidation(
            olderThan: t(1_700_003_000), limit: 100).count
        #expect(beforeCount == 6)
        let vague = vagueDrawer(id: "sh-v1")
        // Consolidate drawers 1-4.
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [drawers[0].id, drawers[1].id, drawers[2].id, drawers[3].id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )
        let afterCount = try await store.drawersEligibleForConsolidation(
            olderThan: t(1_700_003_000), limit: 100).count
        // Shrinkage = 4 absorbed. The vague item is also excluded (bit-20).
        // Remaining = 6 - 4 (absorbed) = 2 eligible.
        #expect(afterCount == 2)
        #expect(beforeCount - afterCount == 4,
                "shrinkage must equal the count of absorbed constituents (AC-2)")
    }

    // MARK: - constituentIDsForVagueItem round-trip

    @Test("constituentIDsForVagueItem returns empty for non-vague item (no tunnels)")
    func constituentIDs_emptyForNonVague() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = episodicDrawer(id: "nv-1")
        try await store.addDrawer(d)
        let ids = try await store.constituentIDsForVagueItem(vagueDrawerID: d.id)
        #expect(ids.isEmpty)
    }

    @Test("constituentIDsForVagueItem returns correct IDs after consolidation")
    func constituentIDs_roundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d1 = episodicDrawer(id: "rt-c1")
        let d2 = episodicDrawer(id: "rt-c2")
        let d3 = episodicDrawer(id: "rt-c3")
        let d4 = episodicDrawer(id: "rt-c4")
        try await store.addDrawer(d1)
        try await store.addDrawer(d2)
        try await store.addDrawer(d3)
        try await store.addDrawer(d4)
        let vague = vagueDrawer(id: "rt-v1")
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [d1.id, d2.id, d3.id, d4.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )
        let ids = try await store.constituentIDsForVagueItem(vagueDrawerID: vague.id)
        #expect(ids.count == 4)
        #expect(Set(ids) == Set([d1.id, d2.id, d3.id, d4.id]))
    }

    // MARK: - foldIn (§5.1)

    @Test("foldIn sets representedByVague on new constituent and creates tunnel")
    func foldIn_setsBit21OnConstituent() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d1 = episodicDrawer(id: "fi-c1")
        let d2 = episodicDrawer(id: "fi-c2")
        let d3 = episodicDrawer(id: "fi-c3")
        let d4 = episodicDrawer(id: "fi-c4")
        try await store.addDrawer(d1)
        try await store.addDrawer(d2)
        try await store.addDrawer(d3)
        try await store.addDrawer(d4)
        let vague = vagueDrawer(id: "fi-v1")
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [d1.id, d2.id, d3.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )
        // Fold in a 4th constituent.
        try await store.foldIn(
            constituentID: d4.id,
            intoVagueDrawerID: vague.id,
            addedBy: "newton",
            now: t(1_700_003_000)
        )
        let loaded = try await store.getDrawer(id: d4.id)
        #expect(loaded?.representedByVague == true,
                "folded-in constituent must have bit-21 set")
        let ids = try await store.constituentIDsForVagueItem(vagueDrawerID: vague.id)
        #expect(ids.count == 4)
        #expect(Set(ids).contains(d4.id), "foldIn must create a _consolidated_from tunnel")
    }

    @Test("foldIn rejects target that is not a vague item (bit 20 not set)")
    func foldIn_rejectsNonVagueTarget() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d1 = episodicDrawer(id: "fir-c1")
        let d2 = episodicDrawer(id: "fir-c2")
        try await store.addDrawer(d1)
        try await store.addDrawer(d2)
        await #expect(throws: (any Error).self) {
            try await store.foldIn(
                constituentID: d2.id,
                intoVagueDrawerID: d1.id, // not a vague item
                addedBy: "newton",
                now: t(1_700_002_000)
            )
        }
    }

    @Test("foldIn rejects when vague item is already at level 2 (§5.4 level cap)")
    func foldIn_rejectsLevelCap() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        // Build a level-2 vague item by constructing one with bits 22-23 set.
        let constituents = (1...5).map { episodicDrawer(id: "lc-c\($0)") }
        for c in constituents { try await store.addDrawer(c) }
        let extra = episodicDrawer(id: "lc-extra")
        try await store.addDrawer(extra)
        // vague_level = 2 → bits 22-23: (2 << 22) = 0x800000.
        let level2VagueOpBitmap = DrawerFeatureFlags.isVague.rawValue | Int64(2 << 22)
        let level2Vague = Drawer(
            id: TestStorage.tid("lc-v1"),
            content: "level-2 vague",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: t(1_700_001_000),
            embeddingModelID: "test-model-v1",
            operationalBitmap: level2VagueOpBitmap
        )
        try await store.consolidateTransactionally(
            vagueDrawer: level2Vague,
            constituentIDs: constituents.map { $0.id },
            addedBy: "newton",
            now: t(1_700_002_000)
        )
        // Attempt to fold in an extra constituent into the level-2 vague item.
        await #expect(throws: (any Error).self) {
            try await store.foldIn(
                constituentID: extra.id,
                intoVagueDrawerID: level2Vague.id,
                addedBy: "newton",
                now: t(1_700_003_000)
            )
        }
    }
}
