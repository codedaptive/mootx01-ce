import Foundation
import Testing
@testable import LocusKit

/// AC-6 (SPEC_CONSOLIDATION_VAGUE_RECALL §7): `insertDefaults` injects the tier
/// default only when no caller filter constrains the tier axis. Classifier
/// suppression is verified with explicit tier filters, `.all`/`.any`/`.not`
/// nesting included (mirrors the existing sensitivity-default parity contract).
///
/// Tests verify the evaluator's end-to-end behavior by calling
/// `BitmapEvaluator.evaluate` directly with crafted drawers whose operational
/// bitmaps exercise the four RecallTier cases.
///
/// Two classes of drawers:
///   - `ordinary`: both bits 20/21 clear → passes all tier filters
///   - `absorbed`: bit 21 set (representedByVague) → excluded by default
///   - `vague`: bit 20 set (isVague) → included in currentAndVague, excluded
///              from currentOnly
@Suite("RecallTierFilterTests — AC-6 default injection parity")
struct RecallTierFilterTests {

    // MARK: - Store fixture

    private func makeStore() async throws -> (DrawerStore, URL) {
        let name = "locuskit-tier-test-\(UUID().uuidString).sqlite"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    // MARK: - Drawer factories

    /// Ordinary pre-Wave-2 drawer: both bits 20/21 clear.
    private func ordinaryDrawer(id: String = "ord-1") -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "ordinary content \(id)",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: Date(timeIntervalSince1970: 1_000_000),
            embeddingModelID: "test-model-v1",
            adjectiveBitmap: 0,
            operationalBitmap: 0
        )
    }

    /// Absorbed constituent: bit 21 (representedByVague) set.
    private func absorbedDrawer(id: String = "abs-1") -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "absorbed content \(id)",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: Date(timeIntervalSince1970: 1_000_001),
            embeddingModelID: "test-model-v1",
            adjectiveBitmap: 0,
            operationalBitmap: DrawerFeatureFlags.representedByVague.rawValue
        )
    }

    /// Vague item: bit 20 (isVague) set, bit 21 clear.
    private func vagueItemDrawer(id: String = "vague-1") -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "vague content \(id)",
            parentNodeId: "test-parent",
            addedBy: "newton",
            filedAt: Date(timeIntervalSince1970: 1_000_002),
            embeddingModelID: "test-model-v1",
            adjectiveBitmap: 0,
            operationalBitmap: DrawerFeatureFlags.isVague.rawValue
        )
    }

    // MARK: - AC-6: default injection

    @Test("AC-6: no tier filter in chain → .currentAndVague injected → absorbed drawer excluded")
    func noTierFilter_absorbedExcluded() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let drawers = [ordinaryDrawer(id: "ord-1"), absorbedDrawer(id: "abs-1")]
        // Use explicit state/trust/sensitivity filters to suppress those defaults,
        // leaving the recallTier slot empty so `.currentAndVague` is injected.
        // The ordinary drawer (bit-21=0) passes; the absorbed one (bit-21=1) fails.
        let frame = RecallFrame(filterChain: [
            .currentlyBelieve,
            .trustworthy,
            .sensitivityAtMost(.elevated),
        ])
        let result = try await BitmapEvaluator.evaluate(
            frame: frame, drawers: drawers, store: store)
        #expect(result.count == 1, "absorbed drawer must be excluded by injected default")
        #expect(result.first?.id == TestStorage.tid("ord-1"),
                "only the ordinary drawer passes")
    }

    @Test("AC-6: explicit .recallTier(.all) suppresses default injection → absorbed included")
    func explicitRecallTierAll_absorbedIncluded() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let drawers = [ordinaryDrawer(id: "ord-2"), absorbedDrawer(id: "abs-2")]
        // Explicit .recallTier(.all) → no default injected → absorbed passes.
        let frame = RecallFrame(filterChain: [.recallTier(.all)])
        let result = try await BitmapEvaluator.evaluate(
            frame: frame, drawers: drawers, store: store)
        #expect(result.count == 2,
                "absorbed drawer must be included when .recallTier(.all) is explicit")
    }

    @Test("AC-6: .recallTier(.vagueOnly) restricts to vague items only")
    func vagueOnly_onlyVagueItemsPass() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let drawers = [
            ordinaryDrawer(id: "ord-3"),
            absorbedDrawer(id: "abs-3"),
            vagueItemDrawer(id: "vague-3"),
        ]
        let frame = RecallFrame(filterChain: [.recallTier(.vagueOnly)])
        let result = try await BitmapEvaluator.evaluate(
            frame: frame, drawers: drawers, store: store)
        #expect(result.count == 1)
        #expect(result.first?.id == TestStorage.tid("vague-3"),
                ".vagueOnly passes only is_vague drawers")
    }

    @Test("AC-6: .recallTier(.currentOnly) excludes vague items and absorbed constituents")
    func currentOnly_excludesVagueAndAbsorbed() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let drawers = [
            ordinaryDrawer(id: "ord-4"),
            absorbedDrawer(id: "abs-4"),
            vagueItemDrawer(id: "vague-4"),
        ]
        let frame = RecallFrame(filterChain: [.recallTier(.currentOnly)])
        let result = try await BitmapEvaluator.evaluate(
            frame: frame, drawers: drawers, store: store)
        #expect(result.count == 1)
        #expect(result.first?.id == TestStorage.tid("ord-4"),
                ".currentOnly passes only drawers with bits 20/21 both clear")
    }

    @Test("AC-6: .recallTier(.currentAndVague) includes ordinary and vague, excludes absorbed")
    func currentAndVague_includesVagueExcludesAbsorbed() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let drawers = [
            ordinaryDrawer(id: "ord-5"),
            absorbedDrawer(id: "abs-5"),
            vagueItemDrawer(id: "vague-5"),
        ]
        let frame = RecallFrame(filterChain: [.recallTier(.currentAndVague)])
        let result = try await BitmapEvaluator.evaluate(
            frame: frame, drawers: drawers, store: store)
        let ids = Set(result.map { $0.id })
        #expect(result.count == 2)
        #expect(ids.contains(TestStorage.tid("ord-5")))
        #expect(ids.contains(TestStorage.tid("vague-5")))
        #expect(!ids.contains(TestStorage.tid("abs-5")),
                ".currentAndVague must exclude absorbed constituent")
    }

    // MARK: - AC-6: nesting suppresses default (parity with sensitivity-default tests)

    @Test("AC-6: .all([.recallTier(...)]) suppresses default injection")
    func nestedInAll_suppressesDefault() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let drawers = [ordinaryDrawer(id: "ord-6"), absorbedDrawer(id: "abs-6")]
        // .all wrapping a recallTier → suppresses default injection.
        let frame = RecallFrame(filterChain: [.all([.recallTier(.all)])])
        let result = try await BitmapEvaluator.evaluate(
            frame: frame, drawers: drawers, store: store)
        #expect(result.count == 2,
                ".all([.recallTier(.all)]) must suppress default injection, allowing absorbed")
    }

    @Test("AC-6: .any([.recallTier(...)]) suppresses default injection")
    func nestedInAny_suppressesDefault() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let drawers = [ordinaryDrawer(id: "ord-7"), absorbedDrawer(id: "abs-7")]
        // .any wrapping a recallTier → suppresses default injection.
        let frame = RecallFrame(filterChain: [.any([.recallTier(.all)])])
        let result = try await BitmapEvaluator.evaluate(
            frame: frame, drawers: drawers, store: store)
        #expect(result.count == 2,
                ".any([.recallTier(.all)]) must suppress default injection, allowing absorbed")
    }

    @Test("AC-6: .not(.recallTier(...)) suppresses default injection")
    func nestedInNot_suppressesDefault() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let drawers = [ordinaryDrawer(id: "ord-8"), absorbedDrawer(id: "abs-8")]
        // .not wrapping a recallTier → suppresses default injection.
        // .not(.recallTier(.currentOnly)) = accept everything that isn't currentOnly,
        // which for the absorbed drawer means: passes the NOT gate (absorbed fails
        // .currentOnly, so NOT(.currentOnly) = true for absorbed).
        let frame = RecallFrame(filterChain: [.not(.recallTier(.currentOnly))])
        let result = try await BitmapEvaluator.evaluate(
            frame: frame, drawers: drawers, store: store)
        // NOT(.currentOnly) passes items that have bit 20 or 21 set.
        // The absorbed drawer has bit 21 → fails currentOnly → NOT → passes.
        // The ordinary drawer has neither bit set → passes currentOnly → NOT → fails.
        #expect(result.count == 1)
        #expect(result.first?.id == TestStorage.tid("abs-8"),
                ".not(.recallTier(.currentOnly)) must suppress default and pass absorbed")
    }
}
