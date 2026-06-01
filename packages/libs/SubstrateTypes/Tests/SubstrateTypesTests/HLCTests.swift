// HLCTests.swift
//
// Per-type suite for HLC (Hybrid Logical Clock) + HLCGenerator.
// Mirrors the Rust `hlc.rs` inline #[test] set:
//   monotonic_within_same_millisecond, physical_advance_resets_logical,
//   receive_advances_past_remote, total_order_uses_node_id_as_tiebreaker,
//   wire_round_trip, causality_preserved_across_replicas.
// Adds the packed 8-byte round-trip (Swift §12.3 surface).

import Testing
@testable import SubstrateTypes

@Suite("HLC — clock + generator")
struct HLCTests {

    @Test("send is monotonic within the same millisecond")
    func monotonicWithinSameMillisecond() {
        var g = HLCGenerator(nodeID: 7)
        let a = g.send(now: 1000)
        let b = g.send(now: 1000)
        let c = g.send(now: 1000)
        #expect(a < b)
        #expect(b < c)
        #expect(a.physicalTime == 1000)
        #expect(b.physicalTime == 1000)
        #expect(c.physicalTime == 1000)
        #expect(a.logicalCount == 0)
        #expect(b.logicalCount == 1)
        #expect(c.logicalCount == 2)
    }

    @Test("physical advance resets the logical counter")
    func physicalAdvanceResetsLogical() {
        var g = HLCGenerator(nodeID: 7)
        _ = g.send(now: 1000)
        _ = g.send(now: 1000)
        let c = g.send(now: 2000)
        #expect(c.physicalTime == 2000)
        #expect(c.logicalCount == 0)
    }

    @Test("receive advances past a higher remote timestamp")
    func receiveAdvancesPastRemote() {
        var g = HLCGenerator(nodeID: 7)
        _ = g.send(now: 1000)
        let remote = HLC(physicalTime: 5000, logicalCount: 10, nodeID: 99)
        let t = g.receive(remote: remote, now: 500)
        // Local wall (500) is behind both ours (1000) and remote (5000),
        // so maxPhysical = remote.physicalTime = 5000, logical = remote+1.
        #expect(t.physicalTime == 5000)
        #expect(t.logicalCount == 11)
        #expect(t.nodeID == 7)
    }

    @Test("total order uses nodeID as the final tiebreaker")
    func totalOrderUsesNodeIDAsTiebreaker() {
        let a = HLC(physicalTime: 1000, logicalCount: 5, nodeID: 1)
        let b = HLC(physicalTime: 1000, logicalCount: 5, nodeID: 2)
        #expect(a < b)
    }

    @Test("wireBytes round-trips through init(wireBytes:)")
    func wireRoundTrip() throws {
        let t = HLC(physicalTime: 0x1234_5678_9ABC, logicalCount: 42, nodeID: 7)
        let wire = t.wireBytes
        let back = try HLC(wireBytes: wire)
        #expect(t == back)
    }

    @Test("init(wireBytes:) rejects a wrong-length buffer")
    func wireBytesWrongLengthThrows() {
        #expect(throws: HLCError.invalidWireLength(15)) {
            _ = try HLC(wireBytes: [UInt8](repeating: 0, count: 15))
        }
    }

    @Test("causality is preserved across replicas (X → Y)")
    func causalityPreservedAcrossReplicas() {
        // Replica A sends X; replica B receives X then sends Y; HLC(X) < HLC(Y).
        var a = HLCGenerator(nodeID: 1)
        var b = HLCGenerator(nodeID: 2)
        let x = a.send(now: 1000)
        _ = b.receive(remote: x, now: 900)   // B's clock is slightly behind
        let y = b.send(now: 900)
        #expect(x < y)
    }

    @Test("packed 8-byte form round-trips (low bits, federation surface)")
    func packedRoundTrip() {
        // packed is lossy: nodeID low 8 bits, logical low 16, physical low 40.
        let t = HLC(physicalTime: 0x12_3456_789A, logicalCount: 0x0042, nodeID: 0x7F)
        let back = HLC(packed: t.packed)
        #expect(back.physicalTime == 0x12_3456_789A)
        #expect(back.logicalCount == 0x0042)
        #expect(back.nodeID == 0x7F)
    }

    @Test("advanced() bumps logical and preserves physical + node")
    func advancedBumpsLogical() {
        let t = HLC(physicalTime: 1000, logicalCount: 4, nodeID: 3)
        let n = t.advanced()
        #expect(n.physicalTime == 1000)
        #expect(n.logicalCount == 5)
        #expect(n.nodeID == 3)
    }
}
