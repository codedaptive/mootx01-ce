import Foundation
import Testing
@testable import SubstrateLib
import SubstrateML
import SubstrateKernel
import SubstrateTypes

/// Conformance tests for `BitField` — the parametric bit-field
/// primitives that kits consume (F18 atomic-centralization cascade).
///
/// Mirror of the Rust bit-field tests in
/// `packages/libs/SubstrateKernel/rust/src/bit_field.rs`. Every test
/// here has a Rust counterpart with identical semantics; the two
/// suites guarantee Swift + Rust parity at the bit-math level.
@Suite("BitField bit-math primitives")
struct BitFieldTests {

    // MARK: - extractField

    @Test func testExtractFieldLSB6Bits() {
        // Cookbook §2.3 state at bits 0–5.
        #expect(BitField.extractField(0b101010, shift: 0, width: 6) == 0b101010)
        #expect(BitField.extractField(33, shift: 0, width: 6) == 33) // tombstoned
    }

    @Test func testExtractFieldMiddleField6Bits() {
        // Cookbook §2.3 trust at bits 18–23. Trust=canonical=3.
        let adj: Int64 = 3 << 18
        #expect(BitField.extractField(adj, shift: 18, width: 6) == 3)
        // Lower bits don't leak into the extraction.
        let adj2: Int64 = (3 << 18) | 0x3F
        #expect(BitField.extractField(adj2, shift: 18, width: 6) == 3)
    }

    @Test func testExtractFieldHighBitsDontPollute() {
        // Cookbook §2.5 enrichment_status at bits 36–41.
        let prov: Int64 = 2 << 36
        #expect(BitField.extractField(prov, shift: 36, width: 6) == 2)
    }

    // MARK: - writeField

    @Test func testWriteFieldPreservesOtherFields() {
        // Adjective: state=active(0) at bits 0–5, trust=canonical(3) at 18–23.
        let prior: Int64 = 3 << 18
        let next = BitField.writeField(33, into: prior, shift: 0, width: 6)
        #expect(BitField.extractField(next, shift: 0, width: 6) == 33)
        #expect(BitField.extractField(next, shift: 18, width: 6) == 3)
    }

    @Test func testWriteFieldOverwritesCleanly() {
        let prior: Int64 = 0x3F << 18 // trust=63 (all bits in trust field)
        let next = BitField.writeField(3, into: prior, shift: 18, width: 6)
        #expect(BitField.extractField(next, shift: 18, width: 6) == 3)
    }

    @Test func testWriteFieldTruncatesOversizeValue() {
        // value=0x7F (7 bits) into a 6-bit field truncates to 0x3F.
        let next = BitField.writeField(0x7F, into: 0, shift: 0, width: 6)
        #expect(BitField.extractField(next, shift: 0, width: 6) == 0x3F)
    }

    // MARK: - extractFlag / writeFlag

    @Test func testExtractFlagReturnsBool() {
        #expect(!BitField.extractFlag(0, bit: 26))
        #expect(BitField.extractFlag(Int64(1) << 26, bit: 26))
        // Bit 27 set doesn't bleed into bit 26's read.
        #expect(!BitField.extractFlag(Int64(1) << 27, bit: 26))
    }

    @Test func testWriteFlagPreservesOtherBits() {
        let prior: Int64 = (1 << 24) | (1 << 25)
        let next = BitField.writeFlag(true, into: prior, bit: 26)
        #expect(BitField.extractFlag(next, bit: 24))
        #expect(BitField.extractFlag(next, bit: 25))
        #expect(BitField.extractFlag(next, bit: 26))
    }

    @Test func testWriteFlagCanClear() {
        let prior: Int64 = 0xFF
        let next = BitField.writeFlag(false, into: prior, bit: 3)
        #expect(next == 0xF7) // bit 3 cleared
    }

    // MARK: - popcount / hammingDistance / xorFold

    @Test func testPopcountMatchesSetBits() {
        #expect(BitField.popcount(0) == 0)
        #expect(BitField.popcount(1) == 1)
        #expect(BitField.popcount(0xFF) == 8)
        #expect(BitField.popcount(-1) == 64) // all bits set in two's complement
    }

    @Test func testHammingDistanceSymmetric() {
        #expect(BitField.hammingDistance(0b1100, 0b0011) == 4)
        #expect(BitField.hammingDistance(0b0011, 0b1100) == 4)
        #expect(BitField.hammingDistance(42, 42) == 0)
    }

    @Test func testXorFoldEmptyIsZero() {
        let empty: [Int64] = []
        #expect(BitField.xorFold(empty) == 0)
    }

    @Test func testXorFoldSelfCancels() {
        // a ^ a = 0; pair of identical values cancels.
        #expect(BitField.xorFold([Int64(0x1234_5678), Int64(0x1234_5678)]) == 0)
        // a ^ b ^ a = b.
        #expect(BitField.xorFold([Int64(0xAA), Int64(0xBB), Int64(0xAA)]) == 0xBB)
    }

    // MARK: - Round-trip across cookbook §2.3 layout

    @Test func testRoundTripCookbook23Layout() {
        // Build cookbook §2.3 layout from scratch: state, sensitivity,
        // exportability, trust, three flags. Round-trip every field.
        var adj: Int64 = 0
        adj = BitField.writeField(2, into: adj, shift: 0, width: 6)   // state=contested
        adj = BitField.writeField(16, into: adj, shift: 6, width: 6)  // sensitivity=elevated
        adj = BitField.writeField(0, into: adj, shift: 12, width: 6)  // exportability=private
        adj = BitField.writeField(3, into: adj, shift: 18, width: 6)  // trust=canonical
        adj = BitField.writeFlag(true, into: adj, bit: 24)             // state_extension
        adj = BitField.writeFlag(false, into: adj, bit: 25)            // lineage_clustering
        adj = BitField.writeFlag(true, into: adj, bit: 26)             // dreaming_recalc_required

        #expect(BitField.extractField(adj, shift: 0, width: 6) == 2)
        #expect(BitField.extractField(adj, shift: 6, width: 6) == 16)
        #expect(BitField.extractField(adj, shift: 12, width: 6) == 0)
        #expect(BitField.extractField(adj, shift: 18, width: 6) == 3)
        #expect(BitField.extractFlag(adj, bit: 24))
        #expect(!BitField.extractFlag(adj, bit: 25))
        #expect(BitField.extractFlag(adj, bit: 26))
    }
}
