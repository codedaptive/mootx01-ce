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
        // The value 0x0401 with strength=.strong would require strength's
        // raw value 4 at bits 9–11 to be stored as bit 10 alone (= raw
        // value 2 = .normal), so the spec-correct value is used here.
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
}
