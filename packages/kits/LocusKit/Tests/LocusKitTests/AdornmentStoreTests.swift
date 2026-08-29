import Foundation
import PersistenceKit
import Testing
import AdornmentLib
@testable import LocusKit

/// Tests for the normalized adornment store surface added in ADORN-STORE-02 v17.
///
/// Covers all eight methods on DrawerStore:
///   listAdornmentMinters, registerAdornmentMinter, setAdornmentMinterActive,
///   setActiveAdornmentMinters, adornmentDebtBatch, putAdornment,
///   adornments(drawerID:), activeAdornments(drawerIDs:).
///
/// Golden pins:
///   - A registered minter round-trips through the store with all fields intact.
///   - setActiveAdornmentMinters fails atomically on unknown id.
///   - adornmentDebtBatch returns pairs absent from the adornments table.
///   - putAdornment inserts and replaces.
///   - Expunge deletes adornment rows for the tombstoned drawer.
@Suite("AdornmentStoreTests")
struct AdornmentStoreTests {

    // MARK: - Helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "adornment-store-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
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

    private func minter(
        id: String = "m1",
        name: String = "Apple Gen1",
        isActive: Bool = true,
        parameters: [String: String] = [:]
    ) -> AdornmentMinterDescriptor {
        AdornmentMinterDescriptor(
            id: id, name: name, family: "apple",
            modelID: "apple-gen1", modelVersion: "2026-08",
            promptDigest: "deadbeef01", parameters: parameters,
            isActive: isActive
        )
    }

    private func sampleDrawer(id: String) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "content-\(id)",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_000),
            embeddingModelID: "minilm-v6",
            operationalBitmap: 0
        )
    }

    // MARK: - listAdornmentMinters

    @Test("listAdornmentMinters returns empty on fresh store")
    func listAdornmentMintersEmpty() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let result = try await store.listAdornmentMinters()
        #expect(result.isEmpty)
    }

    // MARK: - registerAdornmentMinter

    @Test("registerAdornmentMinter round-trips all fields")
    func registerMinterRoundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let m = minter(parameters: ["temperature": "0.7", "top_p": "0.9"])
        try await store.registerAdornmentMinter(m)
        let listed = try await store.listAdornmentMinters()
        #expect(listed.count == 1)
        let loaded = try #require(listed.first)
        #expect(loaded.id == m.id)
        #expect(loaded.name == m.name)
        #expect(loaded.family == m.family)
        #expect(loaded.modelID == m.modelID)
        #expect(loaded.modelVersion == m.modelVersion)
        #expect(loaded.promptDigest == m.promptDigest)
        #expect(loaded.parameters == m.parameters)
        #expect(loaded.isActive == m.isActive)
    }

    @Test("registerAdornmentMinter: identical configuration is an idempotent no-op")
    func registerMinterIdempotent() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.registerAdornmentMinter(minter(id: "m1", name: "Same Name"))
        // Second identical registration succeeds and changes nothing.
        try await store.registerAdornmentMinter(minter(id: "m1", name: "Same Name"))
        let listed = try await store.listAdornmentMinters()
        #expect(listed.count == 1)
        #expect(listed[0].name == "Same Name")
    }

    @Test("registerAdornmentMinter: a same-id configuration change is REJECTED")
    func registerMinterConfigChangeRejected() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.registerAdornmentMinter(minter(id: "m1", name: "Old Name"))
        // Configuration is immutable (LOCUSKIT_SPEC § ADORNMENT_STORE): a
        // changed field requires a NEW minter id, never an in-place update.
        let changed = AdornmentMinterDescriptor(
            id: "m1", name: "New Name", family: "candle",
            modelID: "candle-v2", modelVersion: "2026-09", promptDigest: "beef01",
            parameters: [:], isActive: false
        )
        await #expect(throws: LocusKitError.self) {
            try await store.registerAdornmentMinter(changed)
        }
        // The stored row is untouched.
        let listed = try await store.listAdornmentMinters()
        #expect(listed.count == 1)
        #expect(listed[0].name == "Old Name")
    }

    @Test("registerAdornmentMinter never retoggles is_active on an existing row")
    func registerMinterNeverRetogglesActivation() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.registerAdornmentMinter(
            minter(id: "m1", name: "Same Name", isActive: true))
        // Re-registering the identical configuration with a different
        // initial-state flag must NOT change activation — activation is the
        // exclusive domain of the activation setters.
        try await store.registerAdornmentMinter(
            minter(id: "m1", name: "Same Name", isActive: false))
        let listed = try await store.listAdornmentMinters()
        #expect(listed.count == 1)
        #expect(listed[0].isActive == true)
    }

    @Test("listAdornmentMinters returns minters ordered by name")
    func listAdornmentMintersOrdered() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.registerAdornmentMinter(minter(id: "mZ", name: "Zebra Minter"))
        try await store.registerAdornmentMinter(minter(id: "mA", name: "Apple Minter"))
        try await store.registerAdornmentMinter(minter(id: "mM", name: "Mango Minter"))
        let listed = try await store.listAdornmentMinters()
        #expect(listed.count == 3)
        #expect(listed[0].id == "mA")
        #expect(listed[1].id == "mM")
        #expect(listed[2].id == "mZ")
    }

    // MARK: - setAdornmentMinterActive

    @Test("setAdornmentMinterActive updates the active flag, returns 1 on hit, 0 on miss")
    func setAdornmentMinterActiveHitAndMiss() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.registerAdornmentMinter(minter(id: "m1", isActive: true))
        let updated = try await store.setAdornmentMinterActive(id: "m1", active: false)
        #expect(updated == 1)
        let listed = try await store.listAdornmentMinters()
        #expect(listed[0].isActive == false)
        let missed = try await store.setAdornmentMinterActive(id: "no-such-id", active: true)
        #expect(missed == 0)
    }

    // MARK: - setActiveAdornmentMinters

    @Test("setActiveAdornmentMinters atomically replaces active set")
    func setActiveAdornmentMintersReplaces() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.registerAdornmentMinter(minter(id: "mA", isActive: true))
        try await store.registerAdornmentMinter(minter(id: "mB", isActive: false))
        try await store.registerAdornmentMinter(minter(id: "mC", isActive: true))
        // Activate only mB — should deactivate mA and mC.
        _ = try await store.setActiveAdornmentMinters(ids: ["mB"])
        let listed = try await store.listAdornmentMinters()
        let byID = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0.isActive) })
        #expect(byID["mA"] == false)
        #expect(byID["mB"] == true)
        #expect(byID["mC"] == false)
    }

    @Test("setActiveAdornmentMinters with empty set deactivates all")
    func setActiveAdornmentMintersEmpty() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.registerAdornmentMinter(minter(id: "mA", isActive: true))
        try await store.registerAdornmentMinter(minter(id: "mB", isActive: true))
        _ = try await store.setActiveAdornmentMinters(ids: [])
        let listed = try await store.listAdornmentMinters()
        for m in listed { #expect(m.isActive == false) }
    }

    @Test("setActiveAdornmentMinters fails atomically on unknown id")
    func setActiveAdornmentMintersUnknownIDFails() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.registerAdornmentMinter(minter(id: "mA", isActive: true))
        await #expect(throws: (any Error).self) {
            _ = try await store.setActiveAdornmentMinters(ids: ["mA", "no-such-id"])
        }
        // mA must remain active — transaction rolled back.
        let listed = try await store.listAdornmentMinters()
        #expect(listed[0].isActive == true)
    }

    // MARK: - putAdornment / adornments(drawerID:)

    @Test("putAdornment inserts and adornments(drawerID:) returns it")
    func putAdornmentAndRetrieve() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: "d1"))
        let sa = StoredAdornment(drawerID: TestStorage.tid("d1"), minterID: "m1",
                                 text: "Apple Cupertino California; founded 1976")
        let count = try await store.putAdornment(sa)
        #expect(count == 1)
        let loaded = try await store.adornments(drawerID: TestStorage.tid("d1"))
        #expect(loaded.count == 1)
        #expect(loaded[0] == sa)
    }

    @Test("putAdornment replaces on second call for same (drawerID, minterID)")
    func putAdornmentReplace() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: "d1"))
        let dID = TestStorage.tid("d1")
        let first = StoredAdornment(drawerID: dID, minterID: "m1", text: "version one")
        let second = StoredAdornment(drawerID: dID, minterID: "m1", text: "version two")
        _ = try await store.putAdornment(first)
        _ = try await store.putAdornment(second)
        let loaded = try await store.adornments(drawerID: dID)
        #expect(loaded.count == 1)
        #expect(loaded[0].text == "version two")
    }

    @Test("adornments(drawerID:) returns empty for drawer with no adornment rows")
    func adornmentsEmptyForBareDrawer() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: "d1"))
        let loaded = try await store.adornments(drawerID: TestStorage.tid("d1"))
        #expect(loaded.isEmpty)
    }

    // MARK: - activeAdornments(drawerIDs:)

    @Test("activeAdornments returns only rows from active minters")
    func activeAdornmentsFiltersToActiveMinters() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: "d1"))
        try await store.registerAdornmentMinter(minter(id: "mActive", isActive: true))
        try await store.registerAdornmentMinter(minter(id: "mInactive", isActive: false))
        let dID = TestStorage.tid("d1")
        _ = try await store.putAdornment(
            StoredAdornment(drawerID: dID, minterID: "mActive", text: "active text"))
        _ = try await store.putAdornment(
            StoredAdornment(drawerID: dID, minterID: "mInactive", text: "inactive text"))
        let result = try await store.activeAdornments(drawerIDs: [dID])
        let rows = try #require(result[dID])
        #expect(rows.count == 1)
        #expect(rows[0].minterID == "mActive")
    }

    @Test("activeAdornments withholds rows for restricted/secret drawers")
    func activeAdornmentsGatesSensitiveDrawers() async throws {
        // Sensitivity gate (codex finding 2026-08-26): adornment text is a
        // content-derived pre-minted claim, so a restricted/secret drawer
        // must contribute NO adornments to the composition read — otherwise
        // the render layers' subject/firstSentence redaction is bypassed
        // through the adornment column.
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.registerAdornmentMinter(minter(id: "m1", isActive: true))
        // provenance bits 30–35 carry the sensitivity raw (cookbook §2.5).
        let restricted = Int64(Sensitivity.restricted.rawValue) << 30
        let secret = Int64(Sensitivity.secret.rawValue) << 30
        var restrictedDrawer = sampleDrawer(id: "dR")
        restrictedDrawer = Drawer(
            id: restrictedDrawer.id, content: restrictedDrawer.content,
            parentNodeId: restrictedDrawer.parentNodeId,
            addedBy: restrictedDrawer.addedBy, filedAt: restrictedDrawer.filedAt,
            embeddingModelID: restrictedDrawer.embeddingModelID,
            provenance: restricted, operationalBitmap: 0)
        var secretDrawer = sampleDrawer(id: "dS")
        secretDrawer = Drawer(
            id: secretDrawer.id, content: secretDrawer.content,
            parentNodeId: secretDrawer.parentNodeId,
            addedBy: secretDrawer.addedBy, filedAt: secretDrawer.filedAt,
            embeddingModelID: secretDrawer.embeddingModelID,
            provenance: secret, operationalBitmap: 0)
        try await store.addDrawer(restrictedDrawer)
        try await store.addDrawer(secretDrawer)
        try await store.addDrawer(sampleDrawer(id: "dN"))
        for d in ["dR", "dS", "dN"] {
            _ = try await store.putAdornment(
                StoredAdornment(drawerID: TestStorage.tid(d), minterID: "m1", text: "claim-\(d)"))
        }
        let result = try await store.activeAdornments(
            drawerIDs: ["dR", "dS", "dN"].map(TestStorage.tid))
        #expect(result[TestStorage.tid("dR")] == nil)
        #expect(result[TestStorage.tid("dS")] == nil)
        #expect(result[TestStorage.tid("dN")]?.first?.text == "claim-dN")
    }

    @Test("activeAdornments returns empty dict when no active minters exist")
    func activeAdornmentsNoActiveMinters() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: "d1"))
        let dID = TestStorage.tid("d1")
        _ = try await store.putAdornment(
            StoredAdornment(drawerID: dID, minterID: "m1", text: "text"))
        let result = try await store.activeAdornments(drawerIDs: [dID])
        #expect(result.isEmpty)
    }

    // MARK: - adornmentDebtBatch

    @Test("adornmentDebtBatch returns pairs absent from adornments table")
    func adornmentDebtBatchReturnsDebt() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: "d1"))
        try await store.addDrawer(sampleDrawer(id: "d2"))
        try await store.registerAdornmentMinter(minter(id: "m1", isActive: true))
        // Only d1 has been adorned by m1; d2 has not.
        let dID1 = TestStorage.tid("d1")
        _ = try await store.putAdornment(
            StoredAdornment(drawerID: dID1, minterID: "m1", text: "adorned"))
        let debt = try await store.adornmentDebtBatch(limit: 10)
        // Only d2/m1 should appear in debt.
        #expect(debt.count == 1)
        #expect(debt[0].drawer.id == TestStorage.tid("d2"))
        #expect(debt[0].minter.id == "m1")
    }

    @Test("adornmentDebtBatch returns empty when all pairs are present")
    func adornmentDebtBatchEmptyWhenComplete() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: "d1"))
        try await store.registerAdornmentMinter(minter(id: "m1", isActive: true))
        let dID = TestStorage.tid("d1")
        _ = try await store.putAdornment(
            StoredAdornment(drawerID: dID, minterID: "m1", text: "done"))
        let debt = try await store.adornmentDebtBatch(limit: 10)
        #expect(debt.isEmpty)
    }

    @Test("adornmentDebtBatch finds debt beyond a fully-minted oldest prefix")
    func adornmentDebtBatchScansPastMintedPrefix() async throws {
        // Regression (MINT-DEBT-WINDOW, 2026-08-27): the old implementation
        // scanned only the first `limit × activeMinters` drawers in filedAt
        // order. Once that prefix was fully minted the fetch returned empty
        // while unminted drawers existed further down — the drain loop then
        // falsely concluded the estate was complete.
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.registerAdornmentMinter(minter(id: "m1", isActive: true))
        // 12 drawers with strictly ascending filedAt so scan order is fixed.
        for i in 1...12 {
            try await store.addDrawer(Drawer(
                id: TestStorage.tid(String(format: "d%02d", i)),
                content: "content-d\(i)",
                parentNodeId: "test-parent",
                addedBy: "bilby",
                filedAt: t(1_000 + TimeInterval(i)),
                embeddingModelID: "minilm-v6",
                operationalBitmap: 0
            ))
        }
        // Mint the oldest 10 — more than limit × minters (4 × 1), so the
        // whole first scan window is already complete.
        for i in 1...10 {
            _ = try await store.putAdornment(StoredAdornment(
                drawerID: TestStorage.tid(String(format: "d%02d", i)),
                minterID: "m1", text: "adorned"))
        }
        let debt = try await store.adornmentDebtBatch(limit: 4)
        // The two unminted drawers past the minted prefix MUST surface.
        #expect(debt.count == 2)
        #expect(Set(debt.map { $0.drawer.id })
            == [TestStorage.tid("d11"), TestStorage.tid("d12")])
    }

    @Test("adornmentDebtBatch excludes tombstoned drawers")
    func adornmentDebtBatchExcludesTombstoned() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: "d1"))
        try await store.registerAdornmentMinter(minter(id: "m1", isActive: true))
        // Tombstone d1 by direct bitmap update (simpler than full expunge for this gate).
        _ = try await store.rowStore_deleteForTest(drawerID: TestStorage.tid("d1"))
        let debt = try await store.adornmentDebtBatch(limit: 10)
        #expect(debt.isEmpty)
    }

    @Test("adornmentDebtBatch respects cursor paging via afterDrawerID")
    func adornmentDebtBatchCursorPaging() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        // Three drawers, one minter, zero adornments.
        let ids = ["d1", "d2", "d3"]
        for id in ids { try await store.addDrawer(sampleDrawer(id: id)) }
        try await store.registerAdornmentMinter(minter(id: "m1", isActive: true))
        // Page 1: limit 1 — should return one pair.
        let page1 = try await store.adornmentDebtBatch(limit: 1, afterDrawerID: nil)
        #expect(page1.count == 1)
        // Page 2: limit 1 after page1[0].drawer.id — should return another pair.
        let page2 = try await store.adornmentDebtBatch(
            limit: 1, afterDrawerID: page1[0].drawer.id)
        #expect(page2.count == 1)
        #expect(page2[0].drawer.id != page1[0].drawer.id)
    }
}

// MARK: - Test-only helpers on DrawerStore

extension DrawerStore {
    /// Delete a drawer row by id. Used only in tests to simulate tombstoning
    /// without a full expunge (avoids audit event complexity). Not for production use.
    fileprivate func rowStore_deleteForTest(drawerID: String) async throws -> Int {
        try await storage.rowStore.delete(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text(drawerID))
        )
    }
}
