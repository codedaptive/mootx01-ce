// Fingerprint256CombinatorsTests.swift
//
// Per-type suite for Fingerprint256. Covers the core value type
// (wire encoding, bit access, zero) and the Phase 1 combinator layer
// (zip4 / reduce4 / map4 / popcount + batch siblings).
//
// Mirrors the Rust `fingerprint256.rs` inline #[test] set:
//   zero_wire_bytes_all_zero, bit_zero_in_block_zero,
//   bit_zero_in_block_one, round_trip_wire_bytes, plus the
//   combinator tests (zip4/reduce4/map4/popcount/batch).
//
// swift-testing (import Testing) only.

import Testing
@testable import SubstrateTypes

@Suite("Fingerprint256 — core + combinators")
struct Fingerprint256CombinatorsTests {

    let a = Fingerprint256(block0: 0xFF00, block1: 0x0F00,
                           block2: 0x00FF, block3: 0xF0F0)
    let b = Fingerprint256(block0: 0x0FF0, block1: 0xFF00,
                           block2: 0x0FF0, block3: 0x0F0F)

    // MARK: - Core value type (mirrors Rust core tests)

    @Test("zero fingerprint encodes to 32 zero bytes")
    func zeroWireBytesAllZero() {
        #expect(Fingerprint256.zero.wireBytes == [UInt8](repeating: 0, count: 32))
    }

    @Test("bit 0 lives in block 0")
    func bitZeroInBlockZero() {
        let fp = Fingerprint256(block0: 1, block1: 0, block2: 0, block3: 0)
        #expect(fp.bit(at: 0))
        #expect(!fp.bit(at: 1))
    }

    @Test("bit 64 lives in block 1")
    func bitZeroInBlockOne() {
        let fp = Fingerprint256(block0: 0, block1: 1, block2: 0, block3: 0)
        #expect(fp.bit(at: 64))
        #expect(!fp.bit(at: 63))
    }

    @Test("wireBytes round-trips through init(wireBytes:)")
    func roundTripWireBytes() throws {
        let fp = Fingerprint256(block0: 0xDEAD_BEEF, block1: 0xCAFE_F00D,
                                block2: 0x1234, block3: 0x5678)
        let wire = fp.wireBytes
        let back = try Fingerprint256(wireBytes: wire)
        #expect(fp == back)
    }

    @Test("init(wireBytes:) rejects a wrong-length buffer")
    func wireBytesWrongLengthThrows() {
        #expect(throws: Fingerprint256Error.self) {
            _ = try Fingerprint256(wireBytes: [UInt8](repeating: 0, count: 31))
        }
    }

    @Test("fromBytes returns nil on invalid length (non-throwing adapter)")
    func fromBytesNilOnInvalidLength() {
        #expect(Fingerprint256.fromBytes([0, 1, 2]) == nil)
        #expect(Fingerprint256.fromBytes(a.toBytes()) == a)
    }

    // MARK: - zip4

    @Test("zip4 with | equals union")
    func zip4OrMatchesUnion() {
        #expect(a.zip4(b, |) == a.union(b))
    }

    @Test("zip4 with ^ is blockwise XOR")
    func zip4XorIsBlockwiseXOR() {
        let r = a.zip4(b, ^)
        #expect(r.block0 == a.block0 ^ b.block0)
        #expect(r.block1 == a.block1 ^ b.block1)
        #expect(r.block2 == a.block2 ^ b.block2)
        #expect(r.block3 == a.block3 ^ b.block3)
    }

    @Test("zip4 with & is blockwise AND")
    func zip4AndIsBlockwiseAND() {
        let r = a.zip4(b, &)
        #expect(r.block0 == a.block0 & b.block0)
        #expect(r.block1 == a.block1 & b.block1)
        #expect(r.block2 == a.block2 & b.block2)
        #expect(r.block3 == a.block3 & b.block3)
    }

    // MARK: - reduce4

    @Test("reduce4 of empty with | is zero")
    func reduce4OrEmptyIsZero() {
        #expect(Fingerprint256.reduce4([], |) == .zero)
    }

    @Test("reduce4 of many with | is blockwise OR")
    func reduce4OrMultipleIsBlockwiseOR() {
        let c = Fingerprint256(block0: 1, block1: 2, block2: 4, block3: 8)
        let r = Fingerprint256.reduce4([a, b, c], |)
        #expect(r.block0 == a.block0 | b.block0 | c.block0)
        #expect(r.block1 == a.block1 | b.block1 | c.block1)
        #expect(r.block2 == a.block2 | b.block2 | c.block2)
        #expect(r.block3 == a.block3 | b.block3 | c.block3)
    }

    // MARK: - map4

    @Test("map4 with ~ inverts all blocks")
    func map4ComplementInvertsAllBlocks() {
        let r = a.map4(~)
        #expect(r.block0 == ~a.block0)
        #expect(r.block1 == ~a.block1)
        #expect(r.block2 == ~a.block2)
        #expect(r.block3 == ~a.block3)
    }

    // MARK: - popcount

    @Test("popcount of zero is zero")
    func popcountZeroIsZero() {
        #expect(Fingerprint256.zero.popcount() == 0)
    }

    @Test("popcount of all ones is 256")
    func popcountAllOnesIs256() {
        let allOnes = Fingerprint256(block0: .max, block1: .max,
                                     block2: .max, block3: .max)
        #expect(allOnes.popcount() == 256)
    }

    @Test("popcount sums across blocks")
    func popcountSumsAcrossBlocks() {
        #expect(a.popcount() ==
            a.block0.nonzeroBitCount
            + a.block1.nonzeroBitCount
            + a.block2.nonzeroBitCount
            + a.block3.nonzeroBitCount)
    }

    @Test("hamming via zip4(^).popcount() equals the direct sum")
    func hammingViaZip4Popcount() {
        let viaCombinators = a.zip4(b, ^).popcount()
        let direct =
            (a.block0 ^ b.block0).nonzeroBitCount
          + (a.block1 ^ b.block1).nonzeroBitCount
          + (a.block2 ^ b.block2).nonzeroBitCount
          + (a.block3 ^ b.block3).nonzeroBitCount
        #expect(viaCombinators == direct)
    }

    // MARK: - batch siblings

    @Test("zip4Batch maps pairwise across equal-length arrays")
    func zip4BatchPairwise() {
        let out = Fingerprint256.zip4Batch([a, b], [b, a], |)
        #expect(out.count == 2)
        #expect(out[0] == a.zip4(b, |))
        #expect(out[1] == b.zip4(a, |))
    }

    @Test("map4Batch applies the op per element")
    func map4BatchAppliesPerElement() {
        let out = Fingerprint256.map4Batch([a, b], ~)
        #expect(out.count == 2)
        #expect(out[0] == a.map4(~))
        #expect(out[1] == b.map4(~))
    }
}
