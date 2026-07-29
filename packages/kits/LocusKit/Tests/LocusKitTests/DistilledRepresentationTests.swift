import Foundation
import PersistenceKit
import SubstrateTypes
import Testing
@testable import LocusKit

/// Distilled-representation columns on the drawer row per
/// SPEC_DISTILLATION_STORAGE §4 (Wave 1, W1_DISTILL).
///
/// A distilled representation is a VIEW of one item — four nullable columns
/// (`distilled`, `distilled_pipeline_version`, `distilled_token_count`,
/// `distilled_at`) plus bit 19 (`hasCurrentRepresentation`) in
/// `operationalBitmap` — all written or cleared in one atomic UPDATE.
/// The §4 invariant: the bit and the four columns are ALWAYS in agreement;
/// they travel together in every statement. No Bool stored property.
///
/// The Rust suite `distilled_representation_tests` mirrors this file
/// case-for-case (twin-parity gate).
@Suite("DistilledRepresentationTests")
struct DistilledRepresentationTests {

    // MARK: - Fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-distilled-test-\(UUID().uuidString).sqlite"
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

    private func sampleDrawer(id: String = "d1") -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "The quarterly planning meeting moved to Thursday. "
                + "Sarah sends updated invites Monday. Update travel plans.",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
    }

    // MARK: - Entity defaults and Codable

    @Test("Drawer representation fields default to nil")
    func drawerRepresentationFieldsDefaultNil() {
        let d = sampleDrawer()
        #expect(d.distilled == nil)
        #expect(d.distilledPipelineVersion == nil)
        #expect(d.distilledTokenCount == nil)
        #expect(d.distilledAt == nil)
    }

    @Test("Drawer Codable round-trips the four representation fields")
    func drawerCodableRoundTripsRepresentation() throws {
        let d = Drawer(
            id: TestStorage.tid("dcodable"),
            content: "content",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6",
            distilled: "Quarterly meeting moved Thursday.",
            distilledPipelineVersion: "p1",
            distilledTokenCount: 6,
            distilledAt: t(1_700_000_100)
        )
        let decoded = try JSONDecoder().decode(
            Drawer.self, from: JSONEncoder().encode(d))
        #expect(decoded.distilled == d.distilled)
        #expect(decoded.distilledPipelineVersion == "p1")
        #expect(decoded.distilledTokenCount == 6)
        #expect(decoded.distilledAt == d.distilledAt)
        #expect(decoded == d)
    }

    // MARK: - Store round-trip

    @Test("fresh row: all four representation columns read back NULL")
    func freshRowReadsNilRepresentation() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        let loaded = try await store.getDrawer(id: d.id)
        #expect(loaded?.distilled == nil)
        #expect(loaded?.distilledPipelineVersion == nil)
        #expect(loaded?.distilledTokenCount == nil)
        #expect(loaded?.distilledAt == nil)
        // §4 invariant: bit 19 matches column presence.
        #expect(loaded?.hasCurrentRepresentation == false)
    }

    @Test("setDistilledRepresentation populates all four columns atomically")
    func setRepresentationPopulatesAllFour() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)

        let updated = try await store.setDistilledRepresentation(
            drawerId: d.id,
            distilled: "Quarterly planning meeting moved Thursday; Sarah sends invites Monday.",
            pipelineVersion: "p1",
            tokenCount: 12,
            at: t(1_700_000_200)
        )
        #expect(updated == 1)

        let loaded = try await store.getDrawer(id: d.id)
        #expect(loaded?.distilled
            == "Quarterly planning meeting moved Thursday; Sarah sends invites Monday.")
        #expect(loaded?.distilledPipelineVersion == "p1")
        #expect(loaded?.distilledTokenCount == 12)
        #expect(loaded?.distilledAt == t(1_700_000_200))
        // §4 invariant: bit 19 set alongside the four populated columns.
        #expect(loaded?.hasCurrentRepresentation == true)
        // Content and lifecycle fields are untouched by a representation write.
        #expect(loaded?.content == d.content)
        #expect(loaded?.tombstonedAt == nil)
    }

    @Test("setDistilledRepresentation replaces a prior representation")
    func setRepresentationReplaces() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        _ = try await store.setDistilledRepresentation(
            drawerId: d.id, distilled: "first", pipelineVersion: "p1",
            tokenCount: 1, at: t(1_700_000_200))
        _ = try await store.setDistilledRepresentation(
            drawerId: d.id, distilled: "second rendering", pipelineVersion: "p1",
            tokenCount: 2, at: t(1_700_000_300))
        let loaded = try await store.getDrawer(id: d.id)
        #expect(loaded?.distilled == "second rendering")
        #expect(loaded?.distilledTokenCount == 2)
        #expect(loaded?.distilledAt == t(1_700_000_300))
    }

    @Test("setDistilledRepresentation on an unknown id updates zero rows")
    func setRepresentationUnknownID() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let updated = try await store.setDistilledRepresentation(
            drawerId: "99999999-9999-4999-8999-999999999999",
            distilled: "x", pipelineVersion: "p1", tokenCount: 1,
            at: t(1_700_000_200))
        #expect(updated == 0)
    }

    // MARK: - NULL-on-content-write (§7.3 + §2 erasure scrub)

    @Test("expungeGated clears the representation columns with the content")
    func expungeClearsRepresentation() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        _ = try await store.setDistilledRepresentation(
            drawerId: d.id, distilled: "derived text", pipelineVersion: "p1",
            tokenCount: 2, at: t(1_700_000_200))

        _ = try await store.expungeGated(
            drawerId: d.id, changedBy: "test",
            reason: "erasure scrub covers derived representation",
            now: t(1_700_000_500))

        let after = try await store.getDrawer(id: d.id)
        #expect(after?.content == "")
        // The representation is content-derived text: it must not outlive
        // the erased content (SPEC §2 at-rest / destruction contract).
        #expect(after?.distilled == nil)
        #expect(after?.distilledPipelineVersion == nil)
        #expect(after?.distilledTokenCount == nil)
        #expect(after?.distilledAt == nil)
        // §4 invariant: bit 19 cleared alongside the four NULL columns.
        #expect(after?.hasCurrentRepresentation == false)
    }

    @Test("expungeGated scrubs representation on lineage siblings too")
    func expungeClearsSiblingRepresentation() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        // Two drawers in one lineage: v1 superseded by v2.
        let lineage = UUID()
        let v1 = Drawer(
            id: TestStorage.tid("v1"),
            content: "version one content",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_700_000_000),
            embeddingModelID: "minilm-v6",
            lineageID: lineage)
        let v2 = Drawer(
            id: TestStorage.tid("v2"),
            content: "version two content",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_700_000_100),
            embeddingModelID: "minilm-v6",
            lineageID: lineage)
        try await store.addDrawer(v1)
        try await store.addDrawer(v2)
        _ = try await store.setDistilledRepresentation(
            drawerId: v1.id, distilled: "v1 derived", pipelineVersion: "p1",
            tokenCount: 2, at: t(1_700_000_200))
        _ = try await store.setDistilledRepresentation(
            drawerId: v2.id, distilled: "v2 derived", pipelineVersion: "p1",
            tokenCount: 2, at: t(1_700_000_200))

        _ = try await store.expungeGated(
            drawerId: v2.id, changedBy: "test", reason: nil,
            now: t(1_700_000_500))

        for id in [v1.id, v2.id] {
            let row = try await store.getDrawer(id: id)
            #expect(row?.content == "")
            #expect(row?.distilled == nil)
            #expect(row?.distilledPipelineVersion == nil)
            #expect(row?.distilledTokenCount == nil)
            #expect(row?.distilledAt == nil)
            // §4 invariant: bit 19 cleared on every sibling.
            #expect(row?.hasCurrentRepresentation == false)
        }
    }

    @Test("updateDatasetContent clears the representation columns (§7.3 edit trigger)")
    func datasetContentUpdateClearsRepresentation() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        _ = try await store.setDistilledRepresentation(
            drawerId: d.id, distilled: "stale rendering", pipelineVersion: "p1",
            tokenCount: 2, at: t(1_700_000_200))

        _ = try await store.updateDatasetContent(
            drawerId: d.id, content: "{\"patched\":true}")

        let after = try await store.getDrawer(id: d.id)
        #expect(after?.content == "{\"patched\":true}")
        // Content changed in place → representation is stale → NULL is the
        // regeneration trigger (no staleness flag, no Bool).
        #expect(after?.distilled == nil)
        #expect(after?.distilledPipelineVersion == nil)
        #expect(after?.distilledTokenCount == nil)
        #expect(after?.distilledAt == nil)
        // §4 invariant: bit 19 cleared alongside the four NULL columns.
        #expect(after?.hasCurrentRepresentation == false)
    }

    // MARK: - has_current_representation bit 19 — §4 invariant (cookbook §2.4.1)

    @Test("bit 19 tracks the distillation lifecycle: set → clear → set on re-distillation")
    func bit19LifecycleSetClearReset() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)

        // Step 1: fresh row — bit clear.
        let fresh = try await store.getDrawer(id: d.id)
        #expect(fresh?.hasCurrentRepresentation == false)

        // Step 2: distillation — bit set alongside columns.
        _ = try await store.setDistilledRepresentation(
            drawerId: d.id, distilled: "rendering one", pipelineVersion: "p1",
            tokenCount: 2, at: t(1_700_000_200))
        let distilled = try await store.getDrawer(id: d.id)
        #expect(distilled?.hasCurrentRepresentation == true)
        #expect(distilled?.distilled != nil)

        // Step 3: expunge clears bit alongside columns.
        _ = try await store.expungeGated(
            drawerId: d.id, changedBy: "test", reason: nil, now: t(1_700_000_500))
        let expunged = try await store.getDrawer(id: d.id)
        #expect(expunged?.hasCurrentRepresentation == false)
        #expect(expunged?.distilled == nil)
    }

    @Test("bit 19 clear and set never skew from the four columns")
    func bit19NeverSkewsFromColumns() async throws {
        // The §4 invariant: bit and columns always in the same state.
        // Verified through every mutation path.
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)

        func check(_ drawer: Drawer?, bitExpected: Bool, columnsExpected: Bool) {
            let hasRep = drawer?.hasCurrentRepresentation ?? !bitExpected
            let hasColumns = drawer?.distilled != nil
            #expect(hasRep == bitExpected, "bit 19 should be \(bitExpected)")
            #expect(hasColumns == columnsExpected, "distilled column should be \(columnsExpected ? "populated" : "nil")")
            // Core invariant: bit and column MUST agree.
            #expect(hasRep == hasColumns, "§4 invariant: bit and column must agree")
        }

        // After add: both clear.
        let afterAdd = try await store.getDrawer(id: d.id)
        check(afterAdd, bitExpected: false, columnsExpected: false)

        // After setDistilledRepresentation: both set.
        _ = try await store.setDistilledRepresentation(
            drawerId: d.id, distilled: "some rendering", pipelineVersion: "p1",
            tokenCount: 3, at: t(1_700_000_200))
        let afterSet = try await store.getDrawer(id: d.id)
        check(afterSet, bitExpected: true, columnsExpected: true)

        // After re-distillation with new version: still both set.
        _ = try await store.setDistilledRepresentation(
            drawerId: d.id, distilled: "updated rendering", pipelineVersion: "p2",
            tokenCount: 4, at: t(1_700_000_300))
        let afterReDistill = try await store.getDrawer(id: d.id)
        check(afterReDistill, bitExpected: true, columnsExpected: true)

        // After updateDatasetContent: both clear.
        _ = try await store.updateDatasetContent(drawerId: d.id, content: "{\"v\":2}")
        let afterPatch = try await store.getDrawer(id: d.id)
        check(afterPatch, bitExpected: false, columnsExpected: false)

        // Re-distill again: both set once more.
        _ = try await store.setDistilledRepresentation(
            drawerId: d.id, distilled: "final rendering", pipelineVersion: "p2",
            tokenCount: 5, at: t(1_700_000_400))
        let afterFinal = try await store.getDrawer(id: d.id)
        check(afterFinal, bitExpected: true, columnsExpected: true)
    }

    @Test("countUndistilled uses bit 19 — equivalent to isNull(distilled) on same fixture")
    func countUndistilledBitmapEquivalence() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        // Add 3 drawers: 2 undistilled, 1 distilled.
        let d1 = sampleDrawer(id: "d1")
        let d2 = sampleDrawer(id: "d2")
        let d3 = sampleDrawer(id: "d3")
        for d in [d1, d2, d3] { try await store.addDrawer(d) }
        _ = try await store.setDistilledRepresentation(
            drawerId: d3.id, distilled: "distilled d3", pipelineVersion: "p1",
            tokenCount: 2, at: t(1_700_000_200))

        // countUndistilled now uses bitmaskNone(bit19) predicate.
        let count = try await store.countUndistilled(pipelineVersion: "p1")
        // d1 and d2 have bit 19 clear → counted as undistilled.
        // d3 has bit 19 set and matches pipelineVersion → not counted.
        #expect(count == 2)

        // After distilling d1: only d2 undistilled.
        _ = try await store.setDistilledRepresentation(
            drawerId: d1.id, distilled: "distilled d1", pipelineVersion: "p1",
            tokenCount: 1, at: t(1_700_000_300))
        let countAfter = try await store.countUndistilled(pipelineVersion: "p1")
        #expect(countAfter == 1)

        // Version mismatch: d3 is distilled under p1 but p2 is asked for —
        // d3 should now count as needing redistillation.
        let countV2 = try await store.countUndistilled(pipelineVersion: "p2")
        // d1 matches p1 but not p2 (so counted), d2 has no rep (counted),
        // d3 matches p1 but not p2 (counted) → 3 undistilled for p2.
        #expect(countV2 == 3)
    }
}
