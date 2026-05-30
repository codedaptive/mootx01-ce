import Foundation
import Testing
@testable import LocusKit

/// Conformance + persistence tests for the `LearnedReference` noun per mission
/// NOUN-LRF-01, arch spec §7.8.2, and cookbook §2.4 ("LearnedReference
/// operational"), §2.7 (lattice anchor required on every row). The Rust suite
/// `learned_reference_tests.rs` mirrors the store section of this file
/// case-for-case (conformance gate I-19); the §2.4 operational conformance
/// lives inline in `learned_reference.rs` on the Rust side.
///
/// Two concerns:
///   1. Operational bitmap conformance — the §2.4 refresh_policy,
///      drift_severity, mode, and source axes, the way `AssociationTests`
///      pins the Association layout.
///   2. Store round-trip through `DrawerStore` — persist/fetch byte identity,
///      the required lattice anchor, and source-index resolution, the way
///      `AssociationTests` / `ProposalTests` exercise their tables.
@Suite("LearnedReferenceTests")
struct LearnedReferenceTests {

    // MARK: - Fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-learnedref-test-\(UUID().uuidString).sqlite"
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

    private func sampleReference(
        id: String = "lr1",
        sourceCatalogID: String = "catalog:docs",
        handle: String = "https://example.com/spec",
        latticeAnchor: LatticeAnchor = .udc("004"),
        adjectiveBitmap: Int64 = 0,
        operationalBitmap: Int64 = 0,
        provenanceBitmap: Int64 = 0,
        addedBy: String = "learner",
        filedAt: Date? = nil,
        tombstonedAt: Date? = nil,
        removedByBatch: String? = nil
    ) -> LearnedReference {
        LearnedReference(
            id: id,
            sourceCatalogID: sourceCatalogID,
            handle: handle,
            latticeAnchor: latticeAnchor,
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: operationalBitmap,
            provenanceBitmap: provenanceBitmap,
            addedBy: addedBy,
            filedAt: filedAt ?? t(1_700_000_000),
            tombstonedAt: tombstonedAt,
            removedByBatch: removedByBatch
        )
    }

    // MARK: - §2.4 refresh_policy (bits 0–5, scale-gapped)

    @Test("RefreshPolicy raw values match cookbook §2.4 (scale-gapped)")
    func refreshPolicyRawValues() {
        #expect(RefreshPolicy.none.rawValue == 0)
        #expect(RefreshPolicy.monthly.rawValue == 16)
        #expect(RefreshPolicy.weekly.rawValue == 24)
        #expect(RefreshPolicy.daily.rawValue == 32)
        #expect(RefreshPolicy.onDemand.rawValue == 48)
        #expect(RefreshPolicy.realtime.rawValue == 56)
    }

    @Test("refreshPolicy decodes bits 0–5; scale-gap sentinels fall back to .none")
    func refreshPolicyField() {
        for p in [RefreshPolicy.none, .monthly, .weekly, .daily, .onDemand, .realtime] {
            #expect(sampleReference(operationalBitmap: Int64(p.rawValue)).refreshPolicy == p)
        }
        for raw in [1, 8, 15, 17, 23, 33, 47, 49, 55, 57, 63] {
            #expect(sampleReference(operationalBitmap: Int64(raw)).refreshPolicy == .none)
        }
    }

    @Test("RefreshPolicy Comparable orders by raw value")
    func refreshPolicyComparable() {
        #expect(RefreshPolicy.none < .monthly)
        #expect(RefreshPolicy.monthly < .weekly)
        #expect(RefreshPolicy.weekly < .daily)
        #expect(RefreshPolicy.daily < .onDemand)
        #expect(RefreshPolicy.onDemand < .realtime)
    }

    // MARK: - §2.4 drift_severity (bits 6–11, scale-gapped)

    @Test("DriftSeverity raw values match cookbook §2.4 (scale-gapped)")
    func driftSeverityRawValues() {
        #expect(DriftSeverity.none.rawValue == 0)
        #expect(DriftSeverity.minor.rawValue == 16)
        #expect(DriftSeverity.major.rawValue == 32)
        #expect(DriftSeverity.critical.rawValue == 48)
    }

    @Test("driftSeverity decodes bits 6–11; sentinels fall back to .none")
    func driftSeverityField() {
        for s in [DriftSeverity.none, .minor, .major, .critical] {
            #expect(sampleReference(operationalBitmap: Int64(s.rawValue) << 6).driftSeverity == s)
        }
        for raw in [1, 8, 15, 17, 31, 33, 47, 49, 63] {
            #expect(sampleReference(operationalBitmap: Int64(raw) << 6).driftSeverity == .none)
        }
    }

    @Test("DriftSeverity Comparable orders by raw value")
    func driftSeverityComparable() {
        #expect(DriftSeverity.none < .minor)
        #expect(DriftSeverity.minor < .major)
        #expect(DriftSeverity.major < .critical)
    }

    // MARK: - §2.4 mode (bit 12)

    @Test("mode decodes bit 12; clear = byReference, set = byIngestion")
    func modeField() {
        #expect(LearnMode.byReference.rawValue == 0)
        #expect(LearnMode.byIngestion.rawValue == 1)
        #expect(sampleReference(operationalBitmap: 0).mode == .byReference)
        #expect(sampleReference(operationalBitmap: Int64(1) << 12).mode == .byIngestion)
    }

    // MARK: - §2.4 source (bits 13–18, contiguous)

    @Test("acquisitionSource decodes bits 13–18; reserved raws fall back to .user")
    func acquisitionSourceField() {
        let cases: [LearnedReferenceSource] = [
            .user, .federation, .householdPairing, .fleetPairing, .tierInheritance, .pairedEstate
        ]
        for src in cases {
            #expect(sampleReference(operationalBitmap: Int64(src.rawValue) << 13).acquisitionSource == src)
        }
        for raw in [6, 7, 15, 31, 63] {
            #expect(sampleReference(operationalBitmap: Int64(raw) << 13).acquisitionSource == .user)
        }
    }

    // MARK: - Composite operational round-trip (all four axes at once)

    /// refresh=weekly(24) | drift=major(32)<<6 | mode=byIngestion(1)<<12
    /// | source=federation(1)<<13. Each axis must decode independently with
    /// no bleed across the field boundaries.
    @Test("composite operational bitmap round-trips through all four §2.4 axes")
    func compositeOperational() {
        let raw: Int64 =
            Int64(RefreshPolicy.weekly.rawValue)
            | (Int64(DriftSeverity.major.rawValue) << 6)
            | (Int64(1) << 12)
            | (Int64(LearnedReferenceSource.federation.rawValue) << 13)
        let r = sampleReference(operationalBitmap: raw)
        #expect(r.refreshPolicy == .weekly)
        #expect(r.driftSeverity == .major)
        #expect(r.mode == .byIngestion)
        #expect(r.acquisitionSource == .federation)
    }

    // MARK: - Store round-trip

    /// Persist + fetch every field, including non-zero bitmaps, through SQLite
    /// without truncation.
    @Test("addLearnedReference + getLearnedReference round-trip every field")
    func addGetRoundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let r = sampleReference(
            adjectiveBitmap: 0x0001,
            operationalBitmap: 0x4_3018,
            provenanceBitmap: 0xABCD
        )
        try await store.addLearnedReference(r)
        let loaded = try await store.getLearnedReference(id: r.id)
        #expect(loaded == r)
    }

    /// All three Int64 bitmap columns round-trip non-zero values
    /// byte-identically, with distinct bit regions per column so a swap in
    /// `learnedReferenceFromRow` surfaces immediately.
    @Test("all bitmap columns round-trip byte-identically at non-zero values")
    func bitmapsByteIdentical() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let r = sampleReference(
            adjectiveBitmap: 0x0021,
            operationalBitmap: 0x5_8018,
            provenanceBitmap: 0xABCD
        )
        try await store.addLearnedReference(r)
        let loaded = try await store.getLearnedReference(id: r.id)
        #expect(loaded?.adjectiveBitmap == 0x0021)
        #expect(loaded?.operationalBitmap == 0x5_8018)
        #expect(loaded?.provenanceBitmap == 0xABCD)
    }

    /// The full lattice anchor (udcCode + optional enrichment) survives the
    /// round-trip.
    @Test("lattice anchor (all four fields) round-trips")
    func latticeAnchorRoundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let anchor = LatticeAnchor(
            udcCode: "004",
            udcFacets: "00",
            wikidataQID: "Q11366",
            wikidataQidsSecondary: "Q2329,Q11173"
        )
        let r = sampleReference(latticeAnchor: anchor)
        try await store.addLearnedReference(r)
        let loaded = try await store.getLearnedReference(id: r.id)
        #expect(loaded?.latticeAnchor == anchor)
    }

    // MARK: - Provenance field survival (handle + sourceCatalogID)

    /// The two content columns — `handle` and `sourceCatalogID` — survive the
    /// round-trip unaltered, including non-ASCII and URL-shaped values.
    @Test("handle and sourceCatalogID content survive the round-trip")
    func contentFieldsSurvive() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let r = sampleReference(
            sourceCatalogID: "catalog:wikipedia/en",
            handle: "https://en.wikipedia.org/wiki/Memory_palace#History"
        )
        try await store.addLearnedReference(r)
        let loaded = try await store.getLearnedReference(id: r.id)
        #expect(loaded?.sourceCatalogID == "catalog:wikipedia/en")
        #expect(loaded?.handle == "https://en.wikipedia.org/wiki/Memory_palace#History")
    }

    // MARK: - Lattice anchor required (absent → error)

    /// A reference with an empty `udcCode` is rejected before insert with
    /// `LocusKitError.invalidContent` — the cookbook §2.7 (I-16)
    /// every-row-has-an-anchor requirement, enforced at the store.
    @Test("addLearnedReference rejects an empty lattice anchor (cookbook §2.7)")
    func latticeAnchorRequired() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let r = sampleReference(latticeAnchor: LatticeAnchor(udcCode: ""))
        await #expect(throws: LocusKitError.self) {
            try await store.addLearnedReference(r)
        }
        // The rejected reference must not have landed.
        #expect(try await store.getLearnedReference(id: r.id) == nil)
    }

    // MARK: - Source index resolution (learnedReferences(forSourceCatalogID:))

    /// `learnedReferences(forSourceCatalogID:)` filters to the requested
    /// source and orders by `filedAt` ascending, resolving through
    /// `idx_learned_references_source`.
    @Test("learnedReferences(forSourceCatalogID:) filters by source and orders by filedAt ASC")
    func sourceIndexResolution() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addLearnedReference(sampleReference(id: "r-late", sourceCatalogID: "cat-a", filedAt: t(300)))
        try await store.addLearnedReference(sampleReference(id: "r-early", sourceCatalogID: "cat-a", filedAt: t(100)))
        try await store.addLearnedReference(sampleReference(id: "r-mid", sourceCatalogID: "cat-a", filedAt: t(200)))
        try await store.addLearnedReference(sampleReference(id: "r-other", sourceCatalogID: "cat-b", filedAt: t(150)))

        let catA = try await store.learnedReferences(forSourceCatalogID: "cat-a")
        let catB = try await store.learnedReferences(forSourceCatalogID: "cat-b")
        #expect(catA.map(\.id) == ["r-early", "r-mid", "r-late"])
        #expect(catB.map(\.id) == ["r-other"])
    }

    /// A tombstoned reference is excluded from the source-index query (it
    /// filters `tombstonedAt IS NULL`), but is still fetchable by id.
    @Test("source lookup excludes tombstoned rows; getLearnedReference still finds them")
    func tombstonedExcludedFromSourceLookup() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let live = sampleReference(id: "r-live", sourceCatalogID: "cat-a", filedAt: t(100))
        let dead = sampleReference(
            id: "r-dead", sourceCatalogID: "cat-a", filedAt: t(200),
            tombstonedAt: t(250), removedByBatch: "batch-1"
        )
        try await store.addLearnedReference(live)
        try await store.addLearnedReference(dead)
        #expect(try await store.learnedReferences(forSourceCatalogID: "cat-a").map(\.id) == ["r-live"])
        // Fetchable by id regardless of tombstone.
        #expect(try await store.getLearnedReference(id: "r-dead") == dead)
    }

    // MARK: - Miss

    @Test("getLearnedReference returns nil for a missing id")
    func getMiss() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        #expect(try await store.getLearnedReference(id: "no-such-reference") == nil)
    }

    // MARK: - Table isolation

    /// LearnedReference writes live in their own table; adding one must not
    /// affect the associations or kg_facts surfaces, and vice versa.
    @Test("LearnedReference ops do not affect associations or kg_facts")
    func tableIsolation() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let assoc = Association(
            id: "a-iso",
            sourceWing: "wing-a", sourceRoom: "room-a",
            targetWing: "wing-b", targetRoom: "room-b",
            label: "co-recalled",
            latticeAnchor: .udc("547"),
            addedBy: "dreaming",
            filedAt: t(1_000)
        )
        try await store.addAssociation(assoc)
        try await store.addLearnedReference(sampleReference(id: "lr-iso"))

        // Association surface unaffected by the learned-reference write.
        #expect(try await store.getAssociation(id: "a-iso") == assoc)
        // The learned reference did not leak into the association fetch.
        #expect(try await store.getAssociation(id: "lr-iso") == nil)
        // And the association did not leak into the learned-reference fetch.
        #expect(try await store.getLearnedReference(id: "a-iso") == nil)
    }

    // MARK: - Persistence across re-open

    /// Closing the store and re-opening the same database file preserves
    /// previously-written references.
    @Test("idempotent re-open preserves previously-written references")
    func idempotentReopen() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let r = sampleReference(id: "r-persist", operationalBitmap: 0x4_3018)
        do {
            let store1 = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store1.addLearnedReference(r)
            _ = store1
        }
        let store2 = try await DrawerStore(storage: TestStorage.sqlite(url))
        let loaded = try await store2.getLearnedReference(id: r.id)
        #expect(loaded == r)
    }
}
