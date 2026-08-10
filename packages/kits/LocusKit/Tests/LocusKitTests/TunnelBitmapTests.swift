import Foundation
import Testing
@testable import LocusKit

/// Persistence and accessor coverage for the LOCI_V035_05B tunnel
/// bitmap columns (`kind_id`, `adjectiveBitmap`, `operationalBitmap`,
/// `provenanceBitmap`).
///
/// SQLite-backed tests exercise the round-trip path through
/// `DrawerStore.addTunnel` / `getTunnel`; in-memory accessor tests
/// exercise the decoded value types from `TunnelOperational.swift`
/// without paying the SQLite open/insert cost on every assertion.
///
/// Bit layout under test (per spec § 5.6, contiguous unless noted):
///   bits 0–2   direction        (3 bits, contiguous, 4 cases)
///   bits 3–5   tunnel_lifecycle (3 bits, contiguous, 4 cases)
///   bits 6–8   origin_class     (3 bits, contiguous, 5 cases)
///   bits 9–11  strength         (3 bits, scale-gapped 0/2/4/6)
///   bit  12    has_inverse      (1 bit, exclusive)
@Suite("TunnelBitmapTests")
struct TunnelBitmapTests {

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func freshStoreURL() -> URL {
        // tmpDir / UUID / store.sqlite — each test gets a virgin
        // database. Mirrors the pattern used in DrawerStoreTests.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return base.appendingPathComponent("store.sqlite")
    }

    // MARK: - SQLite round-trips

    @Test("addTunnel + getTunnel round-trips kind_id .supersedes")
    func kindSupersedesRoundTrip() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let original = Tunnel(
            id: "t-supersedes",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "supersedes",
            kind: .supersedes,
            addedBy: "bilby", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(original)
        let loaded = try #require(try await store.getTunnel(id: original.id))
        #expect(loaded.kind == .supersedes)
    }

    @Test("addTunnel + getTunnel round-trips default kind_id .references")
    func kindDefaultsRoundTrip() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let original = Tunnel(
            id: "t-default",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "any",
            addedBy: "bilby", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(original)
        let loaded = try #require(try await store.getTunnel(id: original.id))
        #expect(loaded.kind == .references)
    }

    @Test("addTunnel + getTunnel round-trips adjectiveBitmap 0x3000")
    func adjectiveBitmapRoundTrip() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let original = Tunnel(
            id: "t-adj",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "x",
            adjectiveBitmap: 0x3000,
            addedBy: "bilby", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(original)
        let loaded = try #require(try await store.getTunnel(id: original.id))
        #expect(loaded.adjectiveBitmap == 0x3000)
    }

    @Test("addTunnel + getTunnel round-trips operationalBitmap 0x0801")
    func operationalBitmapRoundTrip() async throws {
        // 0x0801 = bit 11 set (strength=.strong rawValue 4 stored in
        // bits 9–11) + bit 0 set (direction=.bidirectional rawValue 1).
        // Mission specifies the value 0x0401 with strength=.strong; that
        // would require strength's raw value 4 at bits 9–11 to be stored
        // as bit 10 alone (= raw value 2 = .normal), so we use the
        // spec-correct value here. See completion report deviations.
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let original = Tunnel(
            id: "t-op",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "x",
            operationalBitmap: 0x0801,
            addedBy: "bilby", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(original)
        let loaded = try #require(try await store.getTunnel(id: original.id))
        #expect(loaded.operationalBitmap == 0x0801)
    }

    @Test("addTunnel + getTunnel round-trips provenanceBitmap 0x14")
    func provenanceBitmapRoundTrip() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let original = Tunnel(
            id: "t-prov",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "x",
            provenanceBitmap: 0x14,
            addedBy: "bilby", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(original)
        let loaded = try #require(try await store.getTunnel(id: original.id))
        #expect(loaded.provenanceBitmap == 0x14)
    }

    @Test("addTunnel + getTunnel defaults all three bitmaps to 0")
    func defaultZeroBitmaps() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let original = Tunnel(
            id: "t-zero",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "x",
            addedBy: "bilby", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(original)
        let loaded = try #require(try await store.getTunnel(id: original.id))
        #expect(loaded.adjectiveBitmap == 0)
        #expect(loaded.operationalBitmap == 0)
        #expect(loaded.provenanceBitmap == 0)
    }

    @Test("addTunnel persists kind, adjective, operational, provenance together")
    func allFourFieldsTogether() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let original = Tunnel(
            id: "t-all",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "x",
            kind: .validates,
            adjectiveBitmap: 0x3000,
            operationalBitmap: 0x0801,
            provenanceBitmap: 0x14,
            addedBy: "bilby", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(original)
        let loaded = try #require(try await store.getTunnel(id: original.id))
        #expect(loaded.kind == .validates)
        #expect(loaded.adjectiveBitmap == 0x3000)
        #expect(loaded.operationalBitmap == 0x0801)
        #expect(loaded.provenanceBitmap == 0x14)
    }

    // MARK: - Operational accessor decoding (no SQLite)

    private func tunnel(operational: Int64) -> Tunnel {
        Tunnel(
            id: "t",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "x",
            operationalBitmap: operational,
            addedBy: "bilby", filedAt: t(1_700_000_000)
        )
    }

    @Test("operationalBitmap = 0x0801 decodes direction=.bidirectional, strength=.strong, lifecycle=.active, originClass=.userExplicit, hasInverse=false")
    func accessorsDecodeStrongBidirectional() {
        let tn = tunnel(operational: 0x0801)
        #expect(tn.direction == .bidirectional)
        #expect(tn.lifecycle == .active)
        #expect(tn.originClass == .userExplicit)
        #expect(tn.strength == .strong)
        #expect(tn.hasInverse == false)
    }

    @Test("operationalBitmap = 0 decodes to all-zero defaults")
    func accessorsDecodeAllZero() {
        let tn = tunnel(operational: 0)
        #expect(tn.direction == .directional)
        #expect(tn.lifecycle == .active)
        #expect(tn.originClass == .userExplicit)
        #expect(tn.strength == .weak)
        #expect(tn.hasInverse == false)
    }

    @Test("hasInverse decodes from bit 12")
    func hasInverseBit() {
        // bit 12 = 0x1000
        let tn = tunnel(operational: 0x1000)
        #expect(tn.hasInverse == true)
    }

    @Test("lifecycle decodes from bits 3–5")
    func lifecycleField() {
        // 3 << 3 = 0x18 → lifecycle = .withdrawn (raw 3)
        let tn = tunnel(operational: 0x18)
        #expect(tn.lifecycle == .withdrawn)
    }

    @Test("originClass decodes from bits 6–8")
    func originClassField() {
        // 4 << 6 = 0x100 → originClass = .migration (raw 4)
        let tn = tunnel(operational: 0x100)
        #expect(tn.originClass == .migration)
    }

    @Test("strength scale-gap sentinel raw=1 falls back to .weak")
    func strengthSentinelFallback() {
        // (1 << 9) = 0x200 → strength raw=1 → nil → fallback .weak
        let tn = tunnel(operational: 0x200)
        #expect(tn.strength == .weak)
    }

    // MARK: - Review-ladder bits 14/15 + ext (MXE-CT3 P2.5)

    @Test("endorsed defaults false; withEndorsed sets exactly bit 14")
    func endorsedDefaultAndSet() {
        let fresh = tunnel(operational: 0)
        #expect(!fresh.isEndorsed)
        #expect(Tunnel.isEndorsedBit == 1 << 14)
        let endorsed = fresh.withEndorsed()
        #expect(endorsed.isEndorsed)
        #expect(endorsed.operationalBitmap & (1 << 14) == 1 << 14)
        // Endorsed is NOT a lifecycle case — lifecycle bits untouched.
        #expect(endorsed.lifecycle == fresh.lifecycle)
    }

    @Test("contested defaults false; withContested sets exactly bit 15")
    func contestedDefaultAndSet() {
        let fresh = tunnel(operational: 0)
        #expect(!fresh.isContested)
        #expect(Tunnel.isContestedBit == 1 << 15)
        let contested = fresh.withContested()
        #expect(contested.isContested)
        #expect(contested.operationalBitmap & (1 << 15) == 1 << 15)
    }

    @Test("endorsed/contested set and clear do not disturb other bits")
    func reviewBitsPreserveNeighbours() {
        // direction=bidirectional, lifecycle=proposed, retired set.
        let bits: Int64 = 1 | (1 << 3) | (1 << 13)
        let both = tunnel(operational: bits).withEndorsed().withContested()
        #expect(both.direction == .bidirectional)
        #expect(both.lifecycle == .proposed)
        #expect(both.isRetired)
        #expect(both.isEndorsed && both.isContested)
        // Clear leg of the quad: dropping bit 14 leaves bit 15 and the
        // original bits exactly intact.
        let cleared = tunnel(operational: both.operationalBitmap & ~Tunnel.isEndorsedBit)
        #expect(!cleared.isEndorsed)
        #expect(cleared.isContested)
        #expect(cleared.operationalBitmap & bits == bits)
    }

    @Test("review bits + ext persist and reload through SQLite")
    func reviewStateSQLiteRoundTrip() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let proposed = Tunnel(
            id: "t-review",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "tier2:word_exclusion@1 score=0.8",
            kind: .contradicts,
            operationalBitmap: Int64(TunnelLifecycle.proposed.rawValue) << 3,
            addedBy: "conflict-projection", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(proposed)

        var ledger = TunnelReviewLedger()
        ledger.recordEndorsement(by: "claude", atISO: "2026-08-07T12:00:00Z", tier: 2)
        let stamped = proposed.withEndorsed()
        try await store.stampTunnelReview(
            id: proposed.id,
            operationalBitmap: stamped.operationalBitmap,
            ext: ledger.serialized())

        let loaded = try #require(try await store.getTunnel(id: proposed.id))
        #expect(loaded.isEndorsed)
        #expect(!loaded.isContested)
        #expect(loaded.lifecycle == .proposed)
        // Reopen after reload: the reparsed ledger continues accepting
        // votes — persistence did not flatten it.
        var reparsed = try TunnelReviewLedger.parse(loaded.ext)
        #expect(reparsed.distinctEndorserCount == 1)
        #expect(reparsed.endorsements.first?.by == "claude")
        let addedSecond = reparsed.recordEndorsement(
            by: "apple-onboard", atISO: "2026-08-07T13:00:00Z", tier: 2)
        #expect(addedSecond)
        #expect(reparsed.distinctEndorserCount == 2)
    }

    @Test("respondToTunnel records reviewer identity on both transitions")
    func respondRecordsReviewerIdentity() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let base = Tunnel(
            id: "t-reject",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "dcp: rule@1 result=x",
            kind: .contradicts,
            operationalBitmap: Int64(TunnelLifecycle.proposed.rawValue) << 3,
            addedBy: "conflict-projection", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(base)
        try await store.respondToTunnel(
            id: base.id, accept: false, changedBy: "bob", now: t(1_700_000_100))
        let rejected = try #require(try await store.getTunnel(id: base.id))
        #expect(rejected.lifecycle == .withdrawn)
        let rejectLedger = try TunnelReviewLedger.parse(rejected.ext)
        #expect(rejectLedger.reviewedBy == "bob")
        // User rejection carries NO objection entry — that entry is the
        // model-rejection marker (reopenability distinction).
        #expect(rejectLedger.objections.isEmpty)

        let accepting = Tunnel(
            id: "t-accept",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "dcp: rule@1 result=y",
            kind: .contradicts,
            operationalBitmap: Int64(TunnelLifecycle.proposed.rawValue) << 3,
            addedBy: "conflict-projection", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(accepting)
        try await store.respondToTunnel(
            id: accepting.id, accept: true, changedBy: "bob", now: t(1_700_000_100))
        let accepted = try #require(try await store.getTunnel(id: accepting.id))
        #expect(accepted.lifecycle == .active)
        #expect(try TunnelReviewLedger.parse(accepted.ext).reviewedBy == "bob")
    }

    @Test("respondToTunnel preserves unknown ext tenants and fails loud on corrupt ext")
    func respondExtTolerance() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        let base = Tunnel(
            id: "t-tenant",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "dcp: rule@1 result=z",
            kind: .contradicts,
            operationalBitmap: Int64(TunnelLifecycle.proposed.rawValue) << 3,
            addedBy: "conflict-projection", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(base)
        try await store.stampTunnelReview(
            id: base.id, operationalBitmap: base.operationalBitmap,
            ext: "{\"zFuture\":{\"keep\":true}}")
        try await store.respondToTunnel(
            id: base.id, accept: false, changedBy: "bob", now: t(1_700_000_100))
        let loaded = try #require(try await store.getTunnel(id: base.id))
        #expect(loaded.ext == "{\"reviewedBy\":\"bob\",\"zFuture\":{\"keep\":true}}")

        // Corrupt ext: structured error, nothing overwritten.
        let corrupt = Tunnel(
            id: "t-corrupt",
            sourceWing: "w", sourceRoom: "r",
            targetWing: "w2", targetRoom: "r2",
            label: "dcp: rule@1 result=w",
            kind: .contradicts,
            operationalBitmap: Int64(TunnelLifecycle.proposed.rawValue) << 3,
            addedBy: "conflict-projection", filedAt: t(1_700_000_000)
        )
        try await store.addTunnel(corrupt)
        try await store.stampTunnelReview(
            id: corrupt.id, operationalBitmap: corrupt.operationalBitmap, ext: "not json {")
        await #expect(throws: LocusKitError.self) {
            try await store.respondToTunnel(
                id: corrupt.id, accept: false, changedBy: "bob", now: t(1_700_000_100))
        }
        let untouched = try #require(try await store.getTunnel(id: corrupt.id))
        #expect(untouched.ext == "not json {")
        #expect(untouched.lifecycle == .proposed)
    }

    @Test("stampTunnelReview on a missing tunnel throws tunnelNotFound")
    func stampUnknownTunnelThrows() async throws {
        let store = try await DrawerStore(storage: TestStorage.sqlite(freshStoreURL()))
        await #expect(throws: LocusKitError.self) {
            try await store.stampTunnelReview(
                id: "no-such-tunnel", operationalBitmap: 0, ext: nil)
        }
    }
}
