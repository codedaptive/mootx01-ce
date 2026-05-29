import Foundation
import Testing
@testable import LocusKit

@Suite("TunnelTests")
struct TunnelTests {

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    @Test("designated init sets every field")
    func designatedInit() {
        let now = t(1_700_000_000)
        let tunnel = Tunnel(
            id: "t1",
            sourceWing: "src-wing", sourceRoom: "src-room",
            sourceDrawerId: "d-src",
            targetWing: "tgt-wing", targetRoom: "tgt-room",
            targetDrawerId: "d-tgt",
            label: "supports",
            addedBy: "bilby", filedAt: now
        )
        #expect(tunnel.id == "t1")
        #expect(tunnel.sourceWing == "src-wing")
        #expect(tunnel.sourceRoom == "src-room")
        #expect(tunnel.sourceDrawerId == "d-src")
        #expect(tunnel.targetWing == "tgt-wing")
        #expect(tunnel.targetRoom == "tgt-room")
        #expect(tunnel.targetDrawerId == "d-tgt")
        #expect(tunnel.label == "supports")
        #expect(tunnel.addedBy == "bilby")
        #expect(tunnel.filedAt == now)
        #expect(tunnel.tombstonedAt == nil)
        #expect(tunnel.removedByBatch == nil)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let now = t(1_700_000_000)
        let original = Tunnel(
            id: "t1",
            sourceWing: "src-wing", sourceRoom: "src-room",
            targetWing: "tgt-wing", targetRoom: "tgt-room",
            label: "supports",
            addedBy: "bilby", filedAt: now,
            tombstonedAt: t(1_700_000_500),
            removedByBatch: "batch-9"
        )
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(Tunnel.self, from: data)
        #expect(back == original)
    }

    @Test("Codable round-trip preserves nil optionals")
    func codableNilOptionals() throws {
        let now = t(1_700_000_000)
        let original = Tunnel(
            id: "t2",
            sourceWing: "w1", sourceRoom: "r1",
            targetWing: "w2", targetRoom: "r2",
            label: "links",
            addedBy: "b", filedAt: now
        )
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(Tunnel.self, from: data)
        #expect(back == original)
        #expect(back.sourceDrawerId == nil)
        #expect(back.targetDrawerId == nil)
        #expect(back.tombstonedAt == nil)
        #expect(back.removedByBatch == nil)
    }

    @Test("Equatable contract")
    func equatable() {
        let now = t(1_700_000_000)
        let a = Tunnel(id: "x", sourceWing: "w", sourceRoom: "r",
                       targetWing: "w2", targetRoom: "r2",
                       label: "l", addedBy: "b", filedAt: now)
        let b = Tunnel(id: "x", sourceWing: "w", sourceRoom: "r",
                       targetWing: "w2", targetRoom: "r2",
                       label: "l", addedBy: "b", filedAt: now)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("differing label makes tunnels unequal")
    func notEqualOnLabel() {
        let now = t(1_700_000_000)
        let a = Tunnel(id: "x", sourceWing: "w", sourceRoom: "r",
                       targetWing: "w2", targetRoom: "r2",
                       label: "l1", addedBy: "b", filedAt: now)
        let b = Tunnel(id: "x", sourceWing: "w", sourceRoom: "r",
                       targetWing: "w2", targetRoom: "r2",
                       label: "l2", addedBy: "b", filedAt: now)
        #expect(a != b)
    }
}
