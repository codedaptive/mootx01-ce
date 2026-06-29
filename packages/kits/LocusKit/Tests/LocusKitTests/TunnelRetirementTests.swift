import Foundation
import PersistenceKit
import Testing
@testable import LocusKit

/// Tunnel retirement and active-tunnel reads (T13 / ADR-021 Phase 7).
///
/// Verifies Part A of the T13 mission:
///  • `isRetired` / `isDreamed` accessor correctness (unit level)
///  • `DrawerStore.retireTunnel` / `unretireTunnel` bitmap persistence
///  • `DrawerStore.allActiveTunnels` excludes retired tunnels
///  • `allTunnels` still returns retired tunnels (full-history view)
///  • declared tunnels (isDreamed == false) are never touched by OMEGA
///    predicate logic (provenance guard)
///
/// Each test uses a per-test temp directory for SQLite isolation.
@Suite("TunnelRetirementTests")
struct TunnelRetirementTests {

    // MARK: - Helpers

    private func makeEstate() async throws -> Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lk-retire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        return try await Estate.create(
            storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
    }

    /// Construct a raw Tunnel with both isDreamed and isRetired unset (declared).
    private func declaredTunnel(id: String = UUID().uuidString,
                                sourceWing: String = "src", targetWing: String = "tgt") -> Tunnel {
        Tunnel(
            id: id,
            sourceWing: sourceWing, sourceRoom: "r1", sourceDrawerId: nil,
            targetWing: targetWing, targetRoom: "r2", targetDrawerId: nil,
            label: "edge-\(id)", kind: .references,
            addedBy: "bilby", filedAt: Date(timeIntervalSinceReferenceDate: 0),
            orderKey: nil
        )
    }

    /// Construct a raw Tunnel with isDreamed stamped (dreamed provenance).
    private func dreamedTunnel(id: String = UUID().uuidString,
                               sourceWing: String = "src", targetWing: String = "tgt") -> Tunnel {
        declaredTunnel(id: id, sourceWing: sourceWing, targetWing: targetWing)
            .withDreamedProvenance()
    }

    // MARK: - Bit-level unit tests (no DB)

    @Test("isRetired is false for a freshly constructed tunnel")
    func isRetiredDefaultsToFalse() {
        let t = declaredTunnel()
        #expect(!t.isRetired, "operationalBitmap = 0, bit 13 must be unset")
    }

    @Test("isDreamed is false for a declared tunnel")
    func isDreamedDefaultsToFalse() {
        let t = declaredTunnel()
        #expect(!t.isDreamed, "provenanceBitmap = 0, bit 0 must be unset")
    }

    @Test("withRetired sets bit 13 of operationalBitmap")
    func withRetiredSetsBit13() {
        let t = declaredTunnel()
        let retired = t.withRetired()
        #expect(retired.isRetired)
        #expect(retired.operationalBitmap & (1 << 13) != 0)
    }

    @Test("withUnretired clears bit 13 of operationalBitmap")
    func withUnretiredClearsBit13() {
        let t = declaredTunnel().withRetired()
        #expect(t.isRetired)
        let active = t.withUnretired()
        #expect(!active.isRetired)
        #expect(active.operationalBitmap & (1 << 13) == 0)
    }

    @Test("withDreamedProvenance sets bit 0 of provenanceBitmap")
    func withDreamedProvenanceSetsBit0() {
        let t = declaredTunnel()
        let dreamed = t.withDreamedProvenance()
        #expect(dreamed.isDreamed)
        #expect(dreamed.provenanceBitmap & 1 != 0)
    }

    @Test("retire→unretire round-trip preserves original operationalBitmap")
    func retireUnretireRoundTrip() {
        // Set some bits other than 13 so we verify they survive the round-trip.
        // bit 0 = direction bidirectional (raw 1 in bits 0-2), bit 6 = originClass derived (raw 1 in bits 6-8).
        let t = Tunnel(
            id: "rt",
            sourceWing: "s", sourceRoom: "r", sourceDrawerId: nil,
            targetWing: "t", targetRoom: "r", targetDrawerId: nil,
            label: "l", kind: .references,
            adjectiveBitmap: 0,
            operationalBitmap: 1 | (1 << 6), // bidirectional direction, derived origin
            provenanceBitmap: 0,
            addedBy: "bilby", filedAt: Date(timeIntervalSinceReferenceDate: 0),
            tombstonedAt: nil, removedByBatch: nil, orderKey: nil
        )
        let original = t.operationalBitmap
        let restored = t.withRetired().withUnretired().operationalBitmap
        #expect(original == restored, "bitmap must be identical after retire→unretire")
    }

    @Test("withRetired does not affect provenanceBitmap")
    func withRetiredPreservesProvenanceBitmap() {
        let dreamed = dreamedTunnel()
        let retiredDreamed = dreamed.withRetired()
        #expect(retiredDreamed.isDreamed, "provenanceBitmap must be unchanged by retirement")
        #expect(retiredDreamed.isRetired)
    }

    @Test("isRetiredBit constant equals 8192 (1 << 13) — parity with Rust")
    func isRetiredBitConstant() {
        #expect(Tunnel.isRetiredBit == 8192)
    }

    @Test("isDreamedBit constant equals 1 (1 << 0) — parity with Rust")
    func isDreamedBitConstant() {
        #expect(Tunnel.isDreamedBit == 1)
    }

    // MARK: - DrawerStore persistence tests

    @Test("retireTunnel persists bit 13 to SQLite")
    func retireTunnelPersistsBit() async throws {
        let estate = try await makeEstate()
        let tunnel = dreamedTunnel(id: "t-dreamed-1")
        try await estate.store.addTunnel(tunnel)

        let now = Date()
        try await estate.store.retireTunnel(id: "t-dreamed-1", changedBy: "bilby", now: now)

        let fetched = try await estate.store.getTunnel(id: "t-dreamed-1")
        #expect(fetched?.isRetired == true, "retirement bit must survive round-trip through SQLite")
    }

    @Test("unretireTunnel clears bit 13 in SQLite")
    func unretireTunnelClearsBit() async throws {
        let estate = try await makeEstate()
        let tunnel = dreamedTunnel(id: "t-dreamed-2")
        try await estate.store.addTunnel(tunnel)

        let now = Date()
        try await estate.store.retireTunnel(id: "t-dreamed-2", changedBy: "bilby", now: now)
        try await estate.store.unretireTunnel(id: "t-dreamed-2", changedBy: "bilby", now: now)

        let fetched = try await estate.store.getTunnel(id: "t-dreamed-2")
        #expect(fetched?.isRetired == false, "un-retirement must clear bit 13 in SQLite")
    }

    @Test("retireTunnel throws tunnelNotFound for unknown id")
    func retireTunnelThrowsForUnknownId() async throws {
        let estate = try await makeEstate()
        let now = Date()
        await #expect(throws: LocusKitError.tunnelNotFound(id: "no-such-tunnel")) {
            try await estate.store.retireTunnel(id: "no-such-tunnel", changedBy: "bilby", now: now)
        }
    }

    @Test("unretireTunnel throws tunnelNotFound for unknown id")
    func unretireTunnelThrowsForUnknownId() async throws {
        let estate = try await makeEstate()
        let now = Date()
        await #expect(throws: LocusKitError.tunnelNotFound(id: "no-such-tunnel")) {
            try await estate.store.unretireTunnel(id: "no-such-tunnel", changedBy: "bilby", now: now)
        }
    }

    // MARK: - allActiveTunnels visibility tests

    @Test("allActiveTunnels excludes retired tunnels")
    func allActiveTunnelsExcludesRetired() async throws {
        let estate = try await makeEstate()
        let dreamed = dreamedTunnel(id: "t-d1", sourceWing: "a", targetWing: "b")
        let declared = declaredTunnel(id: "t-c1", sourceWing: "c", targetWing: "d")
        try await estate.store.addTunnel(dreamed)
        try await estate.store.addTunnel(declared)

        // Retire the dreamed tunnel.
        try await estate.store.retireTunnel(id: "t-d1", changedBy: "bilby", now: Date())

        let active = try await estate.store.allActiveTunnels()
        #expect(active.count == 1, "retired tunnel must be excluded from allActiveTunnels")
        #expect(active.first?.id == "t-c1")
    }

    @Test("allActiveTunnels returns all tunnels when none are retired")
    func allActiveTunnelsReturnsAllWhenNoneRetired() async throws {
        let estate = try await makeEstate()
        try await estate.store.addTunnel(dreamedTunnel(id: "d1"))
        try await estate.store.addTunnel(declaredTunnel(id: "d2"))

        let active = try await estate.store.allActiveTunnels()
        #expect(active.count == 2)
    }

    @Test("allActiveTunnels returns empty when all tunnels are retired")
    func allActiveTunnelsEmptyWhenAllRetired() async throws {
        let estate = try await makeEstate()
        try await estate.store.addTunnel(dreamedTunnel(id: "d1"))
        try await estate.store.retireTunnel(id: "d1", changedBy: "bilby", now: Date())

        let active = try await estate.store.allActiveTunnels()
        #expect(active.isEmpty)
    }

    @Test("allTunnels returns retired tunnels (full-history view)")
    func allTunnelsIncludesRetired() async throws {
        let estate = try await makeEstate()
        try await estate.store.addTunnel(dreamedTunnel(id: "t-r1"))
        try await estate.store.retireTunnel(id: "t-r1", changedBy: "bilby", now: Date())

        let all = try await estate.store.allTunnels()
        #expect(all.count == 1, "allTunnels must include retired tunnels for audit access")
        #expect(all.first?.isRetired == true)
    }

    @Test("un-retire restores tunnel to allActiveTunnels")
    func unretireRestoresToActive() async throws {
        let estate = try await makeEstate()
        try await estate.store.addTunnel(dreamedTunnel(id: "t-rev1"))
        let now = Date()
        try await estate.store.retireTunnel(id: "t-rev1", changedBy: "bilby", now: now)
        #expect((try await estate.store.allActiveTunnels()).isEmpty)

        try await estate.store.unretireTunnel(id: "t-rev1", changedBy: "bilby", now: now)
        let active = try await estate.store.allActiveTunnels()
        #expect(active.count == 1, "unretired tunnel must re-appear in allActiveTunnels")
    }

    @Test("retirement does not disturb other operational bitmap bits")
    func retirementPreservesOtherBits() async throws {
        let estate = try await makeEstate()
        // Encode direction=bidirectional (raw 1, lives in bits 0-2) and
        // lifecycle=proposed (raw 1, lives in bits 3-5 → 1 << 3 = 8).
        // operationalBitmap = 0b001 (direction) | 0b001_000 (lifecycle) = 0b001001 = 9.
        let bidirectionalBits: Int64 = 1         // bits 0-2 = 1 → TunnelDirection.bidirectional
        let proposedBits: Int64 = 1 << 3         // bits 3-5 = 1 → TunnelLifecycle.proposed
        let t = Tunnel(
            id: "t-bits-test",
            sourceWing: "s", sourceRoom: "r", sourceDrawerId: nil,
            targetWing: "t", targetRoom: "r", targetDrawerId: nil,
            label: "bits", kind: .references,
            adjectiveBitmap: 0,
            operationalBitmap: bidirectionalBits | proposedBits,
            provenanceBitmap: 0,
            addedBy: "bilby", filedAt: Date(timeIntervalSinceReferenceDate: 0),
            tombstonedAt: nil, removedByBatch: nil, orderKey: nil
        )
        try await estate.store.addTunnel(t)

        let now = Date()
        try await estate.store.retireTunnel(id: "t-bits-test", changedBy: "bilby", now: now)
        let fetched = try await estate.store.getTunnel(id: "t-bits-test")!

        // bit 13 should now be set; existing direction/lifecycle bits must be preserved.
        #expect(fetched.isRetired)
        #expect(fetched.direction == .bidirectional, "direction bits must be preserved by retirement")
        #expect(fetched.lifecycle == .proposed, "lifecycle bits must be preserved by retirement")
    }

    // MARK: - OMEGA predicate guard (declared tunnels are never retired by OMEGA)

    @Test("declared tunnel has isDreamed = false (OMEGA must skip it)")
    func declaredTunnelIsNotDreamed() async throws {
        let estate = try await makeEstate()
        // Insert a declared tunnel via the estate's capture verb — no provenanceBitmap slot,
        // so provenanceBitmap remains 0, isDreamed = false.
        _ = try await estate.capture(TunnelCaptureFrame(
            sourceWing: "alpha", sourceRoom: "r1",
            targetWing: "beta",  targetRoom: "r2",
            label: "declared-edge", addedBy: "bilby"
        ))
        let tunnels = try await estate.store.allTunnels()
        #expect(tunnels.count == 1)
        #expect(tunnels.first?.isDreamed == false,
                "capture-path tunnel must have isDreamed = false (declared provenance)")
    }

    @Test("dreamed tunnel has isDreamed = true (OMEGA may retire it)")
    func dreamedTunnelIsDreamed() async throws {
        let estate = try await makeEstate()
        let t = dreamedTunnel(id: "t-dreamed-check")
        try await estate.store.addTunnel(t)

        let fetched = try await estate.store.getTunnel(id: "t-dreamed-check")!
        #expect(fetched.isDreamed == true,
                "dreamed tunnel must have isDreamed = true after provenanceBitmap round-trip")
    }
}
