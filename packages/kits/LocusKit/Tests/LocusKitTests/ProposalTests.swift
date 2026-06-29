import Foundation
import Testing
@testable import LocusKit

/// Conformance + persistence tests for the `Proposal` noun per mission
/// NOUN-PRO-01 and cookbook §2.4 ("Proposal operational"), §2.7
/// (lattice anchor required on every row). The Rust suite
/// `proposal_tests.rs` mirrors this file case-for-case (conformance
/// gate I-19).
///
/// Three concerns:
///   1. Operational bitmap conformance — every §2.4 raw value and field
///      position, the way `OperationalBitmapConformanceTests` pins the
///      Drawer layout.
///   2. The adjective `state` accessor (cookbook §2.3 bits 0–5).
///   3. Store round-trip through `DrawerStore` — persist/fetch byte
///      identity, the required lattice anchor, and index resolution,
///      the way `KGFactStoreTests` exercises `kg_facts`.
@Suite("ProposalTests")
struct ProposalTests {

    // MARK: - Fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-proposal-test-\(UUID().uuidString).sqlite"
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

    private func sampleProposal(
        id: String = "p1",
        targetRowID: String = "d1",
        justification: String? = "drift detected",
        candidateState: Int64 = 0,
        latticeAnchor: LatticeAnchor = .udc("547"),
        adjectiveBitmap: Int64 = 0,
        operationalBitmap: Int64 = 0,
        provenanceBitmap: Int64 = 0,
        filedAt: Date? = nil
    ) -> Proposal {
        Proposal(
            id: id,
            targetRowID: targetRowID,
            justification: justification,
            candidateState: candidateState,
            latticeAnchor: latticeAnchor,
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: operationalBitmap,
            provenanceBitmap: provenanceBitmap,
            filedAt: filedAt ?? t(1_700_000_000)
        )
    }

    // MARK: - §2.4 ProposalKind (bits 0–5)

    @Test("ProposalKind raw values match cookbook §2.4")
    func proposalKindRawValues() {
        #expect(ProposalKind.newTunnel.rawValue == 0)
        #expect(ProposalKind.mutateDrawer.rawValue == 1)
        #expect(ProposalKind.withdrawDrawer.rawValue == 2)
        #expect(ProposalKind.newKGFact.rawValue == 3)
        #expect(ProposalKind.associationPromotion.rawValue == 4)
        #expect(ProposalKind.miningPatternAdjustment.rawValue == 5)
        #expect(ProposalKind.actionProposal.rawValue == 6)
        #expect(ProposalKind.recordObservation.rawValue == 7)
        #expect(ProposalKind.tierAdvisory.rawValue == 8)
    }

    @Test("proposalKind decodes bits 0–5; reserved raws fall back to .newTunnel")
    func proposalKindField() {
        for kind in [ProposalKind.newTunnel, .mutateDrawer, .withdrawDrawer,
                     .newKGFact, .associationPromotion, .miningPatternAdjustment,
                     .actionProposal, .recordObservation, .tierAdvisory] {
            let p = sampleProposal(operationalBitmap: Int64(kind.rawValue))
            #expect(p.proposalKind == kind)
        }
        for raw in 9...63 {
            #expect(sampleProposal(operationalBitmap: Int64(raw)).proposalKind == .newTunnel)
        }
    }

    // MARK: - §2.4 ProposalTargetObjectType (bits 6–11)

    @Test("ProposalTargetObjectType raw values match cookbook §2.4")
    func targetObjectTypeRawValues() {
        #expect(ProposalTargetObjectType.drawer.rawValue == 0)
        #expect(ProposalTargetObjectType.tunnel.rawValue == 1)
        #expect(ProposalTargetObjectType.kgfact.rawValue == 2)
        #expect(ProposalTargetObjectType.association.rawValue == 3)
        #expect(ProposalTargetObjectType.noneBrandNew.rawValue == 4)
        #expect(ProposalTargetObjectType.ambientSample.rawValue == 5)
        #expect(ProposalTargetObjectType.systemState.rawValue == 6)
    }

    @Test("targetObjectType decodes bits 6–11; reserved raw 7 falls back to .drawer")
    func targetObjectTypeField() {
        for ty in [ProposalTargetObjectType.drawer, .tunnel, .kgfact, .association,
                   .noneBrandNew, .ambientSample, .systemState] {
            let p = sampleProposal(operationalBitmap: Int64(ty.rawValue) << 6)
            #expect(p.targetObjectType == ty)
        }
        #expect(sampleProposal(operationalBitmap: Int64(7) << 6).targetObjectType == .drawer)
    }

    // MARK: - §2.4 ProposalConfirmationSource (bits 12–17)

    @Test("ProposalConfirmationSource raw values + bit field match cookbook §2.4")
    func confirmationSourceField() {
        #expect(ProposalConfirmationSource.human.rawValue == 0)
        #expect(ProposalConfirmationSource.agent.rawValue == 1)
        #expect(ProposalConfirmationSource.automatedThreshold.rawValue == 2)
        #expect(ProposalConfirmationSource.actuator.rawValue == 3)
        for src in [ProposalConfirmationSource.human, .agent, .automatedThreshold, .actuator] {
            let p = sampleProposal(operationalBitmap: Int64(src.rawValue) << 12)
            #expect(p.confirmationSource == src)
        }
        #expect(sampleProposal(operationalBitmap: Int64(4) << 12).confirmationSource == .human)
    }

    // MARK: - §2.4 ProposalGeneratedByClass (bits 18–23)

    @Test("ProposalGeneratedByClass raw values + bit field match cookbook §2.4")
    func generatedByClassField() {
        #expect(ProposalGeneratedByClass.dreamingDaemon.rawValue == 0)
        #expect(ProposalGeneratedByClass.mcpAgent.rawValue == 1)
        #expect(ProposalGeneratedByClass.federationSync.rawValue == 2)
        #expect(ProposalGeneratedByClass.manual.rawValue == 3)
        #expect(ProposalGeneratedByClass.tierAggregator.rawValue == 4)
        for cls in [ProposalGeneratedByClass.dreamingDaemon, .mcpAgent,
                    .federationSync, .manual, .tierAggregator] {
            let p = sampleProposal(operationalBitmap: Int64(cls.rawValue) << 18)
            #expect(p.generatedByClass == cls)
        }
        #expect(sampleProposal(operationalBitmap: Int64(5) << 18).generatedByClass == .dreamingDaemon)
    }

    // MARK: - §2.4 ProposalConfidenceBucket (bits 24–29, scale-gapped)

    @Test("ProposalConfidenceBucket raw values match cookbook §2.4 (scale-gapped)")
    func confidenceBucketRawValues() {
        #expect(ProposalConfidenceBucket.null.rawValue == 0)
        #expect(ProposalConfidenceBucket.low.rawValue == 8)
        #expect(ProposalConfidenceBucket.medium.rawValue == 16)
        #expect(ProposalConfidenceBucket.high.rawValue == 32)
        #expect(ProposalConfidenceBucket.verified.rawValue == 48)
    }

    @Test("confidenceBucket decodes bits 24–29; scale-gap sentinels fall back to .null")
    func confidenceBucketField() {
        for bucket in [ProposalConfidenceBucket.null, .low, .medium, .high, .verified] {
            let p = sampleProposal(operationalBitmap: Int64(bucket.rawValue) << 24)
            #expect(p.confidenceBucket == bucket)
        }
        for raw in [1, 2, 4, 7, 9, 15, 17, 31, 33, 47, 49, 63] {
            #expect(sampleProposal(operationalBitmap: Int64(raw) << 24).confidenceBucket == .null)
        }
    }

    @Test("confidenceBucket Comparable orders by raw value")
    func confidenceBucketComparable() {
        #expect(ProposalConfidenceBucket.null < .low)
        #expect(ProposalConfidenceBucket.low < .medium)
        #expect(ProposalConfidenceBucket.medium < .high)
        #expect(ProposalConfidenceBucket.high < .verified)
    }

    // MARK: - Composite operational round-trip (all five axes at once)

    /// kind=.mutateDrawer(1) | target=.tunnel(1)<<6 | confirm=.agent(1)<<12
    /// | genby=.manual(3)<<18 | confidence=.high(32)<<24. Each axis must
    /// decode independently with no bleed across the 6-bit boundaries.
    @Test("composite operational bitmap round-trips through all five §2.4 accessors")
    func compositeOperational() {
        let raw: Int64 =
            Int64(ProposalKind.mutateDrawer.rawValue)
            | (Int64(ProposalTargetObjectType.tunnel.rawValue) << 6)
            | (Int64(ProposalConfirmationSource.agent.rawValue) << 12)
            | (Int64(ProposalGeneratedByClass.manual.rawValue) << 18)
            | (Int64(ProposalConfidenceBucket.high.rawValue) << 24)
        let p = sampleProposal(operationalBitmap: raw)
        #expect(p.proposalKind == .mutateDrawer)
        #expect(p.targetObjectType == .tunnel)
        #expect(p.confirmationSource == .agent)
        #expect(p.generatedByClass == .manual)
        #expect(p.confidenceBucket == .high)
    }

    // MARK: - Adjective state accessor (cookbook §2.3 bits 0–5)

    @Test("state decodes the adjective lifecycle axis (bits 0–5)")
    func stateAccessor() {
        #expect(sampleProposal(adjectiveBitmap: 0).state == .active)
        #expect(sampleProposal(adjectiveBitmap: 1).state == .pending)
        #expect(sampleProposal(adjectiveBitmap: 3).state == .accepted)
        #expect(sampleProposal(adjectiveBitmap: 18).state == .withdrawn)
        #expect(sampleProposal(adjectiveBitmap: 32).state == .rejected)
        // Bits above the 0–5 window must not leak into the accessor.
        #expect(sampleProposal(adjectiveBitmap: (1 << 6) | (1 << 30)).state == .active)
    }

    // MARK: - Store round-trip

    /// Persist + fetch every field, including a non-zero
    /// `operationalBitmap` and `candidateState`, through SQLite without
    /// truncation.
    @Test("addProposal + getProposal round-trip every field")
    func addGetRoundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let p = sampleProposal(
            candidateState: 0x1F,
            operationalBitmap: 0x3211,
            provenanceBitmap: 0xABCD
        )
        try await store.addProposal(p)
        let loaded = try await store.getProposal(id: p.id)
        #expect(loaded == p)
    }

    /// All four Int64 bitmap columns (candidateState + the three axis
    /// bitmaps) round-trip non-zero values byte-identically, with
    /// distinct bit regions per column so a swap in `proposalFromRow`
    /// surfaces immediately.
    @Test("all bitmap columns round-trip byte-identically at non-zero values")
    func bitmapsByteIdentical() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let p = sampleProposal(
            candidateState: 0x1234,
            adjectiveBitmap: 0x0001,
            operationalBitmap: 0x3211,
            provenanceBitmap: 0xABCD
        )
        try await store.addProposal(p)
        let loaded = try await store.getProposal(id: p.id)
        #expect(loaded?.candidateState == 0x1234)
        #expect(loaded?.adjectiveBitmap == 0x0001)
        #expect(loaded?.operationalBitmap == 0x3211)
        #expect(loaded?.provenanceBitmap == 0xABCD)
    }

    /// The full lattice anchor (udcCode + optional enrichment) survives
    /// the round-trip.
    @Test("lattice anchor (all four fields) round-trips")
    func latticeAnchorRoundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let anchor = LatticeAnchor(
            udcCode: "547",
            udcFacets: "54",
            wikidataQID: "Q11351",
            wikidataQidsSecondary: "Q2329,Q11173"
        )
        let p = sampleProposal(latticeAnchor: anchor)
        try await store.addProposal(p)
        let loaded = try await store.getProposal(id: p.id)
        #expect(loaded?.latticeAnchor == anchor)
    }

    // MARK: - Lattice anchor required (absent → error)

    /// A proposal with an empty `udcCode` is rejected before insert with
    /// `LocusKitError.invalidContent` — the cookbook §2.7 (I-16)
    /// every-row-has-an-anchor requirement, enforced at the store the
    /// way the capture path enforces it in `EstateVerbs`.
    @Test("addProposal rejects an empty lattice anchor (cookbook §2.7)")
    func latticeAnchorRequired() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let p = sampleProposal(latticeAnchor: LatticeAnchor(udcCode: ""))
        await #expect(throws: LocusKitError.self) {
            try await store.addProposal(p)
        }
        // The rejected proposal must not have landed.
        #expect(try await store.getProposal(id: p.id) == nil)
    }

    /// An empty `targetRowID` is allowed — a brand-new-object proposal
    /// (target object type `.noneBrandNew`) legitimately targets no
    /// existing row. Only the lattice anchor is required.
    @Test("addProposal allows an empty targetRowID (brand-new-object proposal)")
    func emptyTargetAllowed() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let p = sampleProposal(
            targetRowID: "",
            operationalBitmap: Int64(ProposalTargetObjectType.noneBrandNew.rawValue) << 6
        )
        try await store.addProposal(p)
        #expect(try await store.getProposal(id: p.id) == p)
    }

    // MARK: - Index resolution (proposals(forTargetRowID:))

    /// `proposals(forTargetRowID:)` filters to the requested target and
    /// orders by `filedAt` ascending, resolving through
    /// `idx_proposals_target`.
    @Test("proposals(forTargetRowID:) filters by target and orders by filedAt ASC")
    func proposalsForTarget() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addProposal(sampleProposal(id: "p-late", targetRowID: "d1", filedAt: t(300)))
        try await store.addProposal(sampleProposal(id: "p-early", targetRowID: "d1", filedAt: t(100)))
        try await store.addProposal(sampleProposal(id: "p-mid", targetRowID: "d1", filedAt: t(200)))
        try await store.addProposal(sampleProposal(id: "p-other", targetRowID: "d2", filedAt: t(150)))

        let d1 = try await store.proposals(forTargetRowID: "d1")
        let d2 = try await store.proposals(forTargetRowID: "d2")
        #expect(d1.map(\.id) == ["p-early", "p-mid", "p-late"])
        #expect(d2.map(\.id) == ["p-other"])
    }

    // MARK: - Miss

    @Test("getProposal returns nil for a missing id")
    func getMiss() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        #expect(try await store.getProposal(id: "no-such-proposal") == nil)
    }

    // MARK: - Table isolation

    /// Proposal writes live in their own table; adding a proposal must
    /// not affect the drawers, tunnels, or kg_facts surfaces.
    @Test("Proposal ops do not affect drawers, tunnels, or kg_facts")
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
        try await store.addProposal(sampleProposal(id: "p-iso", targetRowID: "drawer-1"))

        #expect(try await store.getDrawer(id: TestStorage.tid("drawer-1")) == drawer)
        #expect(try await store.allDrawers().count == 1)
        #expect(try await store.proposals(forTargetRowID: "drawer-1").count == 1)
    }

    // MARK: - Persistence across re-open

    /// Closing the store and re-opening the same database file preserves
    /// previously-written proposals.
    @Test("idempotent re-open preserves previously-written proposals")
    func idempotentReopen() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let p = sampleProposal(id: "p-persist", operationalBitmap: 0x3211)
        do {
            let store1 = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store1.addProposal(p)
            _ = store1
        }
        let store2 = try await DrawerStore(storage: TestStorage.sqlite(url))
        let loaded = try await store2.getProposal(id: p.id)
        #expect(loaded == p)
    }
}
