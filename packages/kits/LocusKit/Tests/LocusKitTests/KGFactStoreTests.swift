import Foundation
import SQLite3
import Testing
import SubstrateTypes
@testable import LocusKit

/// Persistence tests for `KGFact` in `DrawerStore` per mission
/// LOCI_V035_06B and spec `GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md`
/// § 4.1. Mirrors the structure of `DrawerStoreTests` and the
/// `addTunnel`/`getTunnel`/`tunnelsFrom` pattern.
@Suite("KGFactStoreTests")
struct KGFactStoreTests {

    // MARK: - Fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-kgfact-test-\(UUID().uuidString).sqlite"
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

    private func sampleFact(
        id: String = "f1",
        subject: String = "drawer-42",
        predicate: String = "is_about",
        object: String = "organic_chemistry",
        sourceDrawerID: String = "d1",
        adjectiveBitmap: Int64 = 0,
        operationalBitmap: Int64 = 0,
        provenanceBitmap: Int64 = 0,
        filedAt: Date? = nil
    ) -> KGFact {
        KGFact(
            id: id,
            subject: subject,
            predicate: predicate,
            object: object,
            sourceDrawerID: TestStorage.tid(sourceDrawerID),
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: operationalBitmap,
            provenanceBitmap: provenanceBitmap,
            filedAt: filedAt ?? t(1_700_000_000)
        )
    }

    // MARK: - Round-trip

    /// Round-trip every field including a non-zero
    /// `operationalBitmap` of `0x3211` — `KGExtractorClass.rulesBased`
    /// (raw 3) in bits 0–3, `KGAssertionKind.asserted` (raw 0) cleared
    /// in bits 4–6 with the higher-bit pattern set, exercising the
    /// full Int64 round-trip through SQLite without truncation.
    @Test("addKGFact + getKGFact round-trip every field including operationalBitmap 0x3211")
    func addGetKGFactRoundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let f = sampleFact(operationalBitmap: 0x3211)
        try await store.addKGFact(f)
        let loaded = try await store.getKGFact(id: f.id)
        #expect(loaded == f)
    }

    // MARK: - Per-drawer query

    /// `kgFacts(forDrawerID:)` filters to the requested source and
    /// returns only facts in the RowState Cluster-A (active) set —
    /// `(adjectiveBitmap & 0x3F) < RowState.activeClusterUpperBoundRaw`.
    @Test("kgFacts(forDrawerID:) returns only facts for the requested drawer")
    func kgFactsForDrawerFilters() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addKGFact(sampleFact(id: "f-a", sourceDrawerID: "d1", filedAt: t(1)))
        try await store.addKGFact(sampleFact(id: "f-b", sourceDrawerID: "d1", filedAt: t(2)))
        try await store.addKGFact(sampleFact(id: "f-c", sourceDrawerID: "d2", filedAt: t(3)))
        let d1 = try await store.kgFacts(forDrawerID: TestStorage.tid("d1"))
        let d2 = try await store.kgFacts(forDrawerID: TestStorage.tid("d2"))
        #expect(d1.count == 2)
        #expect(d2.count == 1)
        #expect(Set(d1.map(\.id)) == ["f-a", "f-b"])
        #expect(d2.map(\.id) == ["f-c"])
    }

    // MARK: - Ordering

    /// Results from `kgFacts(forDrawerID:)` are sorted by `filedAt`
    /// ascending — the retrieval layer threads them chronologically
    /// into rung 1.5 readers, so the order is part of the contract.
    @Test("kgFacts(forDrawerID:) orders results by filedAt ASC")
    func kgFactsOrderedAsc() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addKGFact(sampleFact(id: "f-late", filedAt: t(300)))
        try await store.addKGFact(sampleFact(id: "f-early", filedAt: t(100)))
        try await store.addKGFact(sampleFact(id: "f-mid", filedAt: t(200)))
        let result = try await store.kgFacts(forDrawerID: TestStorage.tid("d1"))
        #expect(result.map(\.id) == ["f-early", "f-mid", "f-late"])
    }

    // MARK: - Miss

    /// `getKGFact` returns nil for an absent id — a routine query
    /// miss, not an error, mirroring `getDrawer` and `getTunnel`.
    @Test("getKGFact returns nil for missing id")
    func getKGFactMiss() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        #expect(try await store.getKGFact(id: "no-such-fact") == nil)
    }

    // MARK: - Bitmap fidelity

    /// All three Int64 bitmap columns round-trip non-zero values
    /// without sign extension or truncation. The values are picked to
    /// exercise distinct bit regions per column so a swap or off-by-
    /// one in `kgFactFromRow` would surface immediately.
    @Test("all three bitmaps round-trip at non-zero values")
    func bitmapsRoundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let f = sampleFact(
            adjectiveBitmap: 0x1234,
            operationalBitmap: 0x3211,
            provenanceBitmap: 0xABCD
        )
        try await store.addKGFact(f)
        let loaded = try await store.getKGFact(id: f.id)
        #expect(loaded?.adjectiveBitmap == 0x1234)
        #expect(loaded?.operationalBitmap == 0x3211)
        #expect(loaded?.provenanceBitmap == 0xABCD)
    }

    // MARK: - Table isolation

    /// KGFact writes live in their own table; adding a fact must not
    /// affect the `drawers` or `tunnels` surfaces and vice versa.
    @Test("KGFact ops do not affect drawers or tunnels")
    func tableIsolation() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let drawer = Drawer(
            id: TestStorage.tid("drawer-1"),
            content: "hello",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: t(1_000),
            embeddingModelID: "minilm-v6"
        )
        try await store.addDrawer(drawer)

        let tunnel = Tunnel(
            id: "tunnel-1",
            sourceWing: "wing-a",
            sourceRoom: "room-a",
            targetWing: "wing-b",
            targetRoom: "room-b",
            label: "references",
            addedBy: "bilby",
            filedAt: t(2_000)
        )
        try await store.addTunnel(tunnel)

        try await store.addKGFact(sampleFact(id: "f-iso"))

        #expect(try await store.getDrawer(id: TestStorage.tid("drawer-1")) == drawer)
        #expect(try await store.getTunnel(id: "tunnel-1") == tunnel)
        #expect(try await store.allDrawers().count == 1)
        #expect(try await store.tunnelsFrom(wing: "wing-a").count == 1)
        #expect(try await store.kgFacts(forDrawerID: TestStorage.tid("d1")).count == 1)
    }

    // MARK: - Persistence across re-open

    /// Closing the store and re-opening the same database file
    /// preserves previously-written facts. `CREATE TABLE IF NOT
    /// EXISTS` is the idempotency guard; this test pins the
    /// behaviour so a future migration cannot regress it.
    @Test("idempotent re-open preserves previously-written facts")
    func idempotentReopen() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let f = sampleFact(id: "f-persist", operationalBitmap: 0x3211)
        do {
            let store1 = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store1.addKGFact(f)
            _ = store1   // keep alive until end of scope
        }
        let store2 = try await DrawerStore(storage: TestStorage.sqlite(url))
        let loaded = try await store2.getKGFact(id: f.id)
        #expect(loaded == f)
    }

    // MARK: - allKGFactsIncludingRetired (FINDING-3 parity gate)
    //
    // Swift DrawerStore is a concrete actor — there is no protocol-extension
    // default that could silently return empty. These tests serve as the parity
    // gate to the Rust fail-loud gate (FINDING-3) and confirm the Swift
    // implementation returns correct results.

    /// Empty estate returns empty array — a genuinely-empty estate is valid.
    @Test("allKGFactsIncludingRetired — empty estate returns empty")
    func allKGFactsIncludingRetiredEmptyEstate() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let result = try await store.allKGFactsIncludingRetired()
        #expect(result.isEmpty)
    }

    /// Active facts (RowState Cluster A) appear in the timeline.
    @Test("allKGFactsIncludingRetired — active facts are visible")
    func allKGFactsIncludingRetiredIncludesActiveFacts() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addKGFact(sampleFact(id: "f-active", subject: "alice"))
        let result = try await store.allKGFactsIncludingRetired()
        #expect(result.count == 1)
        #expect(result[0].subject == "alice")
    }

    /// Retired (withdrawn) facts appear in the timeline but NOT in the
    /// active-only `allKGFacts()`. This is the core contract of the
    /// timeline path: it must include every lifecycle state.
    @Test("allKGFactsIncludingRetired — includes retired facts excluded from allKGFacts")
    func allKGFactsIncludingRetiredIncludesRetiredFacts() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addKGFact(sampleFact(id: "f-retired", subject: "bob"))
        try await store.withdrawKGFact(id: "f-retired")

        // Active-only scan must exclude the withdrawn fact.
        let active = try await store.allKGFacts()
        #expect(active.isEmpty, "withdrawn fact must not appear in active-only scan")

        // Full timeline must include it.
        let timeline = try await store.allKGFactsIncludingRetired()
        #expect(timeline.count == 1)
        #expect(timeline[0].subject == "bob")
    }

    /// Mixed estate (one active + one retired) returns both rows ordered
    /// by filedAt ascending.
    @Test("allKGFactsIncludingRetired — mixed estate returns both, filedAt ASC")
    func allKGFactsIncludingRetiredMixedEstate() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addKGFact(sampleFact(id: "f-a", subject: "carol", filedAt: t(1_700_000_000)))
        try await store.addKGFact(sampleFact(id: "f-r", subject: "eve", filedAt: t(1_700_000_001)))
        try await store.withdrawKGFact(id: "f-r")

        let timeline = try await store.allKGFactsIncludingRetired()
        #expect(timeline.count == 2)
        // filedAt ascending: carol (earlier) before eve (later).
        #expect(timeline[0].subject == "carol")
        #expect(timeline[1].subject == "eve")
    }

    // MARK: - KG-active filter == RowState Cluster-A (single-source-of-truth gate)
    //
    // The KG-fact "active" filter (allKGFacts / kgFacts(forDrawerID:)) must
    // derive "active" from the canonical RowState Cluster-A boundary
    // (RowState.activeClusterUpperBoundRaw == 16), NOT a hand-rolled `< 7`.
    // These run against the SQLite-backed store, so they exercise the real
    // SQL/storage predicate path — proving the persisted filter and the
    // automaton agree.

    /// File one fact in every defined RowState and assert the active set
    /// returned by `allKGFacts()` is EXACTLY the RowState Cluster-A states
    /// {active, pending, contested, accepted} — behavior-preserving over the
    /// prior `< 7` gate (every defined active raw is < 7 AND < 16, so the set
    /// is unchanged), while every retired B/C state is excluded.
    @Test("allKGFacts active set == RowState Cluster-A across all ten defined states")
    func allKGFactsActiveSetEqualsClusterA() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        // One fact per defined state; bits 0–5 of adjectiveBitmap carry the raw.
        for state in RowState.allCases {
            try await store.addKGFact(sampleFact(
                id: "f-\(state.rawValue)",
                subject: "s-\(state.rawValue)",
                adjectiveBitmap: Int64(state.rawValue),
                filedAt: t(1_700_000_000 + Double(state.rawValue))))
        }

        let activeIDs = Set(try await store.allKGFacts().map(\.id))
        let expected = Set(RowState.allCases
            .filter { $0.isActiveCluster }
            .map { "f-\($0.rawValue)" })

        // Behavior-preserving active set.
        #expect(activeIDs == expected)
        #expect(activeIDs == ["f-0", "f-1", "f-2", "f-3"])
        // The four Cluster-A states are present; every retired state absent.
        for state in RowState.allCases {
            let present = activeIDs.contains("f-\(state.rawValue)")
            #expect(present == state.isActiveCluster,
                    "state \(state) (raw \(state.rawValue)) active-membership must match Cluster-A")
        }
    }

    /// The per-drawer active filter agrees with the estate-wide active
    /// filter on the same data: both derive from RowState Cluster-A, so
    /// `kgFacts(forDrawerID:)` and `allKGFacts()` return the same active
    /// rows for a single-drawer estate.
    @Test("kgFacts(forDrawerID:) and allKGFacts agree on the active set")
    func perDrawerAndEstateActiveFiltersAgree() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        for state in RowState.allCases {
            try await store.addKGFact(sampleFact(
                id: "f-\(state.rawValue)",
                sourceDrawerID: "d1",
                adjectiveBitmap: Int64(state.rawValue),
                filedAt: t(1_700_000_000 + Double(state.rawValue))))
        }

        let perDrawer = Set(try await store.kgFacts(forDrawerID: TestStorage.tid("d1")).map(\.id))
        let estate = Set(try await store.allKGFacts().map(\.id))
        #expect(perDrawer == estate)
        #expect(perDrawer == ["f-0", "f-1", "f-2", "f-3"])
    }
}
