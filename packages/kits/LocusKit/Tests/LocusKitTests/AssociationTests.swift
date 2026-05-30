import Foundation
import Testing
@testable import LocusKit

/// Conformance + persistence tests for the `Association` noun per mission
/// NOUN-ASC-01 and cookbook §2.4 ("Association operational"), §2.7
/// (lattice anchor required on every row). The Rust suite
/// `association_tests.rs` mirrors the store section of this file
/// case-for-case (conformance gate I-19); the §2.4 operational conformance
/// lives inline in `association_operational.rs` on the Rust side.
///
/// Three concerns:
///   1. Operational bitmap conformance — the §2.4 signal-sources-seen
///      bitset, decay class, and arity, the way `ProposalTests` pins the
///      Proposal layout.
///   2. Store round-trip through `DrawerStore` — persist/fetch byte
///      identity, the required lattice anchor, and edge-index resolution,
///      the way `TunnelTests` / `ProposalTests` exercise their tables.
@Suite("AssociationTests")
struct AssociationTests {

    // MARK: - Fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-association-test-\(UUID().uuidString).sqlite"
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

    private func sampleAssociation(
        id: String = "a1",
        sourceWing: String = "wing-a",
        sourceRoom: String = "room-a",
        sourceDrawerId: String? = nil,
        targetWing: String = "wing-b",
        targetRoom: String = "room-b",
        targetDrawerId: String? = nil,
        label: String = "co-recalled",
        latticeAnchor: LatticeAnchor = .udc("547"),
        adjectiveBitmap: Int64 = 0,
        operationalBitmap: Int64 = 0,
        provenanceBitmap: Int64 = 0,
        addedBy: String = "dreaming",
        filedAt: Date? = nil
    ) -> Association {
        Association(
            id: id,
            sourceWing: sourceWing,
            sourceRoom: sourceRoom,
            sourceDrawerId: sourceDrawerId,
            targetWing: targetWing,
            targetRoom: targetRoom,
            targetDrawerId: targetDrawerId,
            label: label,
            latticeAnchor: latticeAnchor,
            adjectiveBitmap: adjectiveBitmap,
            operationalBitmap: operationalBitmap,
            provenanceBitmap: provenanceBitmap,
            addedBy: addedBy,
            filedAt: filedAt ?? t(1_700_000_000)
        )
    }

    // MARK: - §2.4 signal_sources_seen (bits 0–11, bitset)

    @Test("AssociationSignalSources bit values match cookbook §2.4")
    func signalSourcesBitValues() {
        #expect(AssociationSignalSources.coRecall.rawValue == 1 << 0)
        #expect(AssociationSignalSources.coConfirmed.rawValue == 1 << 1)
        #expect(AssociationSignalSources.dreamPairing.rawValue == 1 << 2)
        #expect(AssociationSignalSources.vectorSimilarity.rawValue == 1 << 3)
        #expect(AssociationSignalSources.sharedEntity.rawValue == 1 << 4)
        #expect(AssociationSignalSources.explicitHuman.rawValue == 1 << 5)
        #expect(AssociationSignalSources.fingerprintSimilarity.rawValue == 1 << 6)
        #expect(AssociationSignalSources.crossEstate.rawValue == 1 << 7)
        #expect(AssociationSignalSources.crossTier.rawValue == 1 << 8)
        #expect(AssociationSignalSources.actionOutcome.rawValue == 1 << 9)
    }

    @Test("signalSourcesSeen decodes each individual bit")
    func signalSourcesEachBit() {
        let members: [AssociationSignalSources] = [
            .coRecall, .coConfirmed, .dreamPairing, .vectorSimilarity,
            .sharedEntity, .explicitHuman, .fingerprintSimilarity,
            .crossEstate, .crossTier, .actionOutcome
        ]
        for member in members {
            let a = sampleAssociation(operationalBitmap: member.rawValue)
            #expect(a.signalSourcesSeen.contains(member))
        }
    }

    @Test("signalSourcesSeen is a bitset — multiple sources coexist")
    func signalSourcesBitset() {
        let raw = AssociationSignalSources.coRecall.rawValue
            | AssociationSignalSources.vectorSimilarity.rawValue
            | AssociationSignalSources.explicitHuman.rawValue
        let a = sampleAssociation(operationalBitmap: raw)
        #expect(a.signalSourcesSeen.contains(.coRecall))
        #expect(a.signalSourcesSeen.contains(.vectorSimilarity))
        #expect(a.signalSourcesSeen.contains(.explicitHuman))
        #expect(!a.signalSourcesSeen.contains(.crossTier))
    }

    @Test("signalSourcesSeen masks off the decay/arity axes (bits 12+)")
    func signalSourcesMasksHigherAxes() {
        // decay_class=Normal(32)<<12 and arity=NAry(1)<<18 must not leak
        // into the signal set.
        let raw = (Int64(32) << 12) | (Int64(1) << 18) | AssociationSignalSources.coRecall.rawValue
        let a = sampleAssociation(operationalBitmap: raw)
        #expect(a.signalSourcesSeen == .coRecall)
    }

    // MARK: - §2.4 decay_class (bits 12–17, scale-gapped)

    @Test("AssociationDecayClass raw values match cookbook §2.4 (scale-gapped)")
    func decayClassRawValues() {
        #expect(AssociationDecayClass.pinned.rawValue == 0)
        #expect(AssociationDecayClass.slow.rawValue == 16)
        #expect(AssociationDecayClass.normal.rawValue == 32)
        #expect(AssociationDecayClass.fast.rawValue == 48)
    }

    @Test("decayClass decodes bits 12–17; scale-gap sentinels fall back to .pinned")
    func decayClassField() {
        for cls in [AssociationDecayClass.pinned, .slow, .normal, .fast] {
            let a = sampleAssociation(operationalBitmap: Int64(cls.rawValue) << 12)
            #expect(a.decayClass == cls)
        }
        for raw in [1, 8, 15, 17, 31, 33, 47, 49, 63] {
            #expect(sampleAssociation(operationalBitmap: Int64(raw) << 12).decayClass == .pinned)
        }
    }

    @Test("decayClass Comparable orders by raw value (increasing decay speed)")
    func decayClassComparable() {
        #expect(AssociationDecayClass.pinned < .slow)
        #expect(AssociationDecayClass.slow < .normal)
        #expect(AssociationDecayClass.normal < .fast)
    }

    // MARK: - §2.4 arity (bits 18–19, contiguous)

    @Test("arity decodes bits 18–19; reserved raws fall back to .binary")
    func arityField() {
        #expect(AssociationArity.binary.rawValue == 0)
        #expect(AssociationArity.nAry.rawValue == 1)
        #expect(sampleAssociation(operationalBitmap: Int64(0) << 18).arity == .binary)
        #expect(sampleAssociation(operationalBitmap: Int64(1) << 18).arity == .nAry)
        #expect(sampleAssociation(operationalBitmap: Int64(2) << 18).arity == .binary)
        #expect(sampleAssociation(operationalBitmap: Int64(3) << 18).arity == .binary)
    }

    // MARK: - Composite operational round-trip (all three axes at once)

    /// signals = co_recall | shared_entity (bits 0,4) | decay=normal(32)<<12
    /// | arity=nAry(1)<<18. Each axis must decode independently with no
    /// bleed across the field boundaries.
    @Test("composite operational bitmap round-trips through all three §2.4 axes")
    func compositeOperational() {
        let raw: Int64 =
            AssociationSignalSources.coRecall.rawValue
            | AssociationSignalSources.sharedEntity.rawValue
            | (Int64(AssociationDecayClass.normal.rawValue) << 12)
            | (Int64(AssociationArity.nAry.rawValue) << 18)
        let a = sampleAssociation(operationalBitmap: raw)
        #expect(a.signalSourcesSeen.contains(.coRecall))
        #expect(a.signalSourcesSeen.contains(.sharedEntity))
        #expect(!a.signalSourcesSeen.contains(.coConfirmed))
        #expect(a.decayClass == .normal)
        #expect(a.arity == .nAry)
    }

    // MARK: - Store round-trip

    /// Persist + fetch every field, including non-zero bitmaps and both
    /// optional drawer ids, through SQLite without truncation.
    @Test("addAssociation + getAssociation round-trip every field")
    func addGetRoundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let a = sampleAssociation(
            sourceDrawerId: "d-src",
            targetDrawerId: "d-tgt",
            adjectiveBitmap: 0x0001,
            operationalBitmap: 0x4_3211,
            provenanceBitmap: 0xABCD
        )
        try await store.addAssociation(a)
        let loaded = try await store.getAssociation(id: a.id)
        #expect(loaded == a)
    }

    /// All three Int64 bitmap columns round-trip non-zero values
    /// byte-identically, with distinct bit regions per column so a swap in
    /// `associationFromRow` surfaces immediately.
    @Test("all bitmap columns round-trip byte-identically at non-zero values")
    func bitmapsByteIdentical() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let a = sampleAssociation(
            adjectiveBitmap: 0x0021,
            operationalBitmap: 0x5_8001,
            provenanceBitmap: 0xABCD
        )
        try await store.addAssociation(a)
        let loaded = try await store.getAssociation(id: a.id)
        #expect(loaded?.adjectiveBitmap == 0x0021)
        #expect(loaded?.operationalBitmap == 0x5_8001)
        #expect(loaded?.provenanceBitmap == 0xABCD)
    }

    /// The full lattice anchor (udcCode + optional enrichment) survives the
    /// round-trip.
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
        let a = sampleAssociation(latticeAnchor: anchor)
        try await store.addAssociation(a)
        let loaded = try await store.getAssociation(id: a.id)
        #expect(loaded?.latticeAnchor == anchor)
    }

    // MARK: - Lattice anchor required (absent → error)

    /// An association with an empty `udcCode` is rejected before insert
    /// with `LocusKitError.invalidContent` — the cookbook §2.7 (I-16)
    /// every-row-has-an-anchor requirement, enforced at the store.
    @Test("addAssociation rejects an empty lattice anchor (cookbook §2.7)")
    func latticeAnchorRequired() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let a = sampleAssociation(latticeAnchor: LatticeAnchor(udcCode: ""))
        await #expect(throws: LocusKitError.self) {
            try await store.addAssociation(a)
        }
        // The rejected association must not have landed.
        #expect(try await store.getAssociation(id: a.id) == nil)
    }

    // MARK: - Edge index resolution (associationsFrom / associationsTo)

    /// `associationsFrom(wing:room:)` filters to the requested source
    /// endpoint and orders by `filedAt` ascending, resolving through
    /// `idx_associations_source`. This is the source-endpoint resolution.
    @Test("associationsFrom(wing:room:) filters by source and orders by filedAt ASC")
    func associationsFromSource() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addAssociation(sampleAssociation(id: "a-late", sourceWing: "w", sourceRoom: "r", filedAt: t(300)))
        try await store.addAssociation(sampleAssociation(id: "a-early", sourceWing: "w", sourceRoom: "r", filedAt: t(100)))
        try await store.addAssociation(sampleAssociation(id: "a-mid", sourceWing: "w", sourceRoom: "r", filedAt: t(200)))
        try await store.addAssociation(sampleAssociation(id: "a-other", sourceWing: "w", sourceRoom: "other", filedAt: t(150)))

        let here = try await store.associationsFrom(wing: "w", room: "r")
        let other = try await store.associationsFrom(wing: "w", room: "other")
        #expect(here.map(\.id) == ["a-early", "a-mid", "a-late"])
        #expect(other.map(\.id) == ["a-other"])
    }

    /// `associationsTo(wing:room:)` resolves the target endpoint through
    /// `idx_associations_target`. This is the target-endpoint resolution.
    @Test("associationsTo(wing:room:) filters by target endpoint")
    func associationsToTarget() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addAssociation(sampleAssociation(id: "a1", targetWing: "tw", targetRoom: "tr", filedAt: t(100)))
        try await store.addAssociation(sampleAssociation(id: "a2", targetWing: "tw", targetRoom: "tr", filedAt: t(200)))
        try await store.addAssociation(sampleAssociation(id: "a3", targetWing: "tw", targetRoom: "elsewhere", filedAt: t(150)))

        let toTr = try await store.associationsTo(wing: "tw", room: "tr")
        #expect(toTr.map(\.id) == ["a1", "a2"])
        #expect(try await store.associationsTo(wing: "tw", room: "elsewhere").map(\.id) == ["a3"])
    }

    /// A tombstoned association is excluded from the edge-lookup queries
    /// (they filter `tombstonedAt IS NULL`), but is still fetchable by id.
    @Test("edge lookups exclude tombstoned rows; getAssociation still finds them")
    func tombstonedExcludedFromEdgeLookups() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let live = sampleAssociation(id: "a-live", sourceWing: "w", sourceRoom: "r", filedAt: t(100))
        let dead = sampleAssociation(id: "a-dead", sourceWing: "w", sourceRoom: "r", filedAt: t(200))
        let tombstoned = Association(
            id: dead.id, sourceWing: dead.sourceWing, sourceRoom: dead.sourceRoom,
            targetWing: dead.targetWing, targetRoom: dead.targetRoom,
            label: dead.label, latticeAnchor: dead.latticeAnchor,
            addedBy: dead.addedBy, filedAt: dead.filedAt,
            tombstonedAt: t(250), removedByBatch: "batch-1"
        )
        try await store.addAssociation(live)
        try await store.addAssociation(tombstoned)
        #expect(try await store.associationsFrom(wing: "w", room: "r").map(\.id) == ["a-live"])
        // Fetchable by id regardless of tombstone.
        #expect(try await store.getAssociation(id: "a-dead") == tombstoned)
    }

    // MARK: - Miss

    @Test("getAssociation returns nil for a missing id")
    func getMiss() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        #expect(try await store.getAssociation(id: "no-such-association") == nil)
    }

    // MARK: - Table isolation

    /// Association writes live in their own table; adding an association
    /// must not affect the drawers or tunnels surfaces, and vice versa.
    @Test("Association ops do not affect drawers or tunnels")
    func tableIsolation() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }

        let tunnel = Tunnel(
            id: "t-1",
            sourceWing: "wing-a", sourceRoom: "room-a",
            targetWing: "wing-b", targetRoom: "room-b",
            label: "references",
            addedBy: "bilby",
            filedAt: t(1_000)
        )
        try await store.addTunnel(tunnel)
        try await store.addAssociation(sampleAssociation(id: "a-iso", sourceWing: "wing-a", sourceRoom: "room-a"))

        // Tunnel surface unaffected by the association write.
        #expect(try await store.getTunnel(id: "t-1") == tunnel)
        #expect(try await store.tunnelsFrom(wing: "wing-a", room: "room-a").count == 1)
        #expect(try await store.associationsFrom(wing: "wing-a", room: "room-a").count == 1)
        // The association did not leak into the tunnel fetch.
        #expect(try await store.getTunnel(id: "a-iso") == nil)
    }

    // MARK: - Persistence across re-open

    /// Closing the store and re-opening the same database file preserves
    /// previously-written associations.
    @Test("idempotent re-open preserves previously-written associations")
    func idempotentReopen() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let a = sampleAssociation(id: "a-persist", operationalBitmap: 0x4_3211)
        do {
            let store1 = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await store1.addAssociation(a)
            _ = store1
        }
        let store2 = try await DrawerStore(storage: TestStorage.sqlite(url))
        let loaded = try await store2.getAssociation(id: a.id)
        #expect(loaded == a)
    }
}
