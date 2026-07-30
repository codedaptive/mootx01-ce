import Foundation
import Testing
@testable import LocusKit

/// AC-4 (SPEC_CONSOLIDATION_VAGUE_RECALL §7): deleting a vague item restores every
/// constituent to Fast Recall visibility in the same transaction.
///
/// The deletion cascade (§5.3 / DrawerStore.expungeGated) must:
///   1. Tombstone the vague item (existing expunge behavior).
///   2. Clear representedByVague (bit 21) on every constituent — same transaction.
///   3. After clearing, constituents appear in drawersEligibleForConsolidation.
///
/// AC-4 "vague-of-vague death reverts exactly one level" is tested as
/// a level boundary check: deleting a level-1 vague item clears bit-21 on
/// its constituents but does NOT recurse into grandchildren (no second level
/// of cascade in one deletion event).
@Suite("VagueDeletionCascadeTests — AC-4 un-consolidation")
struct VagueDeletionCascadeTests {

    // MARK: - Fixtures

    private func makeTempURL() -> URL {
        let name = "locuskit-del-cascade-\(UUID().uuidString).sqlite"
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

    private func episodicDrawer(id: String) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "episodic \(id)",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: t(1_700_000_000),
            embeddingModelID: "test-model-v1"
        )
    }

    private func vagueDrawer(id: String, level: Int = 0) -> Drawer {
        let levelBits: Int64 = (level > 0) ? Int64(min(level, 2)) << 22 : 0
        return Drawer(
            id: TestStorage.tid(id),
            content: "vague summary \(id)",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: t(1_700_001_000),
            embeddingModelID: "test-model-v1",
            operationalBitmap: DrawerFeatureFlags.isVague.rawValue | levelBits
        )
    }

    // MARK: - AC-4: core un-consolidation

    @Test("AC-4: expungeGated on vague item clears bit-21 on all constituents")
    func expunge_clearsBit21OnConstituents() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let c1 = episodicDrawer(id: "uc-c1")
        let c2 = episodicDrawer(id: "uc-c2")
        let c3 = episodicDrawer(id: "uc-c3")
        try await store.addDrawer(c1)
        try await store.addDrawer(c2)
        try await store.addDrawer(c3)
        let vague = vagueDrawer(id: "uc-v1")
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [c1.id, c2.id, c3.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )
        // Verify bit-21 is set before expunge.
        for cid in [c1.id, c2.id, c3.id] {
            let loaded = try await store.getDrawer(id: cid)
            #expect(loaded?.representedByVague == true,
                    "constituent must have bit-21 set before expunge")
        }
        // Expunge the vague item.
        try await store.expungeGated(
            drawerId: vague.id,
            changedBy: "newton",
            reason: "AC-4 test",
            now: t(1_700_003_000),
            sealAudit: true
        )
        // After expunge, bit-21 must be cleared on all constituents.
        for cid in [c1.id, c2.id, c3.id] {
            let loaded = try await store.getDrawer(id: cid)
            #expect(loaded?.representedByVague == false,
                    "constituent \(cid) must have bit-21 cleared after vague expunge")
        }
    }

    @Test("AC-4: after expunge, ex-constituents appear in drawersEligibleForConsolidation")
    func expunge_constituentsBeEligibleAfterCascade() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let c1 = episodicDrawer(id: "ue-c1")
        let c2 = episodicDrawer(id: "ue-c2")
        let c3 = episodicDrawer(id: "ue-c3")
        try await store.addDrawer(c1)
        try await store.addDrawer(c2)
        try await store.addDrawer(c3)
        let vague = vagueDrawer(id: "ue-v1")
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [c1.id, c2.id, c3.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )
        // Before expunge: no constituents are eligible (bit-21 set).
        let beforeEligible = try await store.drawersEligibleForConsolidation(
            olderThan: t(1_700_005_000), limit: 100)
        #expect(beforeEligible.isEmpty,
                "all drawers are absorbed or vague — none eligible before expunge")
        // Expunge the vague item.
        try await store.expungeGated(
            drawerId: vague.id,
            changedBy: "newton",
            reason: "AC-4 eligibility test",
            now: t(1_700_003_000),
            sealAudit: true
        )
        // After expunge: ex-constituents are eligible again (bit-21 cleared).
        // The vague item itself is tombstoned, so it won't appear.
        let afterEligible = try await store.drawersEligibleForConsolidation(
            olderThan: t(1_700_005_000), limit: 100)
        #expect(afterEligible.count == 3,
                "ex-constituents must be eligible after vague item is expunged")
        let eligibleIds = Set(afterEligible.map { $0.id })
        #expect(eligibleIds.contains(c1.id))
        #expect(eligibleIds.contains(c2.id))
        #expect(eligibleIds.contains(c3.id))
    }

    @Test("AC-4: expunging a non-vague item does NOT affect other drawers' bitmaps")
    func expunge_nonVague_noConstituentEffect() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d1 = episodicDrawer(id: "nv-d1")
        let d2 = episodicDrawer(id: "nv-d2")
        try await store.addDrawer(d1)
        try await store.addDrawer(d2)
        let before = try await store.getDrawer(id: d2.id)
        let beforeOp = before?.operationalBitmap ?? -1
        // Expunge d1 (non-vague).
        try await store.expungeGated(
            drawerId: d1.id,
            changedBy: "newton",
            reason: "non-vague expunge test",
            now: t(1_700_002_000),
            sealAudit: true
        )
        // d2 must be completely unaffected.
        let after = try await store.getDrawer(id: d2.id)
        #expect(after?.operationalBitmap == beforeOp,
                "non-vague expunge must not touch other drawers")
    }

    @Test("AC-4: vague item itself is tombstoned correctly by expungeGated")
    func expunge_vagueItemTombstoned() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let c1 = episodicDrawer(id: "vt-c1")
        let c2 = episodicDrawer(id: "vt-c2")
        let c3 = episodicDrawer(id: "vt-c3")
        try await store.addDrawer(c1)
        try await store.addDrawer(c2)
        try await store.addDrawer(c3)
        let vague = vagueDrawer(id: "vt-v1")
        try await store.consolidateTransactionally(
            vagueDrawer: vague,
            constituentIDs: [c1.id, c2.id, c3.id],
            addedBy: "newton",
            now: t(1_700_002_000)
        )
        try await store.expungeGated(
            drawerId: vague.id,
            changedBy: "newton",
            reason: "vague tombstone test",
            now: t(1_700_003_000),
            sealAudit: true
        )
        // Vague item must be tombstoned.
        let loaded = try await store.getDrawer(id: vague.id)
        #expect(loaded?.tombstonedAt != nil,
                "vague item must be tombstoned after expunge")
    }
}
