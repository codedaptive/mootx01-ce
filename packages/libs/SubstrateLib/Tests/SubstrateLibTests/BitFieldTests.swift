import Foundation
import XCTest
@testable import SubstrateLib

/// Conformance tests for `BitField` — the parametric bit-field
/// primitives that kits consume (F18 atomic-centralization cascade).
///
/// Mirror of `rust/glref-rust-bit_field.rs` test module. Every test
/// here has a Rust counterpart with identical semantics; the two
/// suites guarantee Swift + Rust parity at the bit-math level.
final class BitFieldTests: XCTestCase {

    // MARK: - extractField

    func testExtractFieldLSB6Bits() {
        // Cookbook §2.3 state at bits 0–5.
        XCTAssertEqual(BitField.extractField(0b101010, shift: 0, width: 6), 0b101010)
        XCTAssertEqual(BitField.extractField(33, shift: 0, width: 6), 33) // tombstoned
    }

    func testExtractFieldMiddleField6Bits() {
        // Cookbook §2.3 trust at bits 18–23. Trust=canonical=3.
        let adj: Int64 = 3 << 18
        XCTAssertEqual(BitField.extractField(adj, shift: 18, width: 6), 3)
        // Lower bits don't leak into the extraction.
        let adj2: Int64 = (3 << 18) | 0x3F
        XCTAssertEqual(BitField.extractField(adj2, shift: 18, width: 6), 3)
    }

    func testExtractFieldHighBitsDontPollute() {
        // Cookbook §2.5 enrichment_status at bits 36–41.
        let prov: Int64 = 2 << 36
        XCTAssertEqual(BitField.extractField(prov, shift: 36, width: 6), 2)
    }

    // MARK: - writeField

    func testWriteFieldPreservesOtherFields() {
        // Adjective: state=active(0) at bits 0–5, trust=canonical(3) at 18–23.
        let prior: Int64 = 3 << 18
        let next = BitField.writeField(33, into: prior, shift: 0, width: 6)
        XCTAssertEqual(BitField.extractField(next, shift: 0, width: 6), 33)
        XCTAssertEqual(BitField.extractField(next, shift: 18, width: 6), 3)
    }

    func testWriteFieldOverwritesCleanly() {
        let prior: Int64 = 0x3F << 18 // trust=63 (all bits in trust field)
        let next = BitField.writeField(3, into: prior, shift: 18, width: 6)
        XCTAssertEqual(BitField.extractField(next, shift: 18, width: 6), 3)
    }

    func testWriteFieldTruncatesOversizeValue() {
        // value=0x7F (7 bits) into a 6-bit field truncates to 0x3F.
        let next = BitField.writeField(0x7F, into: 0, shift: 0, width: 6)
        XCTAssertEqual(BitField.extractField(next, shift: 0, width: 6), 0x3F)
    }

    // MARK: - extractFlag / writeFlag

    func testExtractFlagReturnsBool() {
        XCTAssertFalse(BitField.extractFlag(0, bit: 26))
        XCTAssertTrue(BitField.extractFlag(Int64(1) << 26, bit: 26))
        // Bit 27 set doesn't bleed into bit 26's read.
        XCTAssertFalse(BitField.extractFlag(Int64(1) << 27, bit: 26))
    }

    func testWriteFlagPreservesOtherBits() {
        let prior: Int64 = (1 << 24) | (1 << 25)
        let next = BitField.writeFlag(true, into: prior, bit: 26)
        XCTAssertTrue(BitField.extractFlag(next, bit: 24))
        XCTAssertTrue(BitField.extractFlag(next, bit: 25))
        XCTAssertTrue(BitField.extractFlag(next, bit: 26))
    }

    func testWriteFlagCanClear() {
        let prior: Int64 = 0xFF
        let next = BitField.writeFlag(false, into: prior, bit: 3)
        XCTAssertEqual(next, 0xF7) // bit 3 cleared
    }

    // MARK: - popcount / hammingDistance / xorFold

    func testPopcountMatchesSetBits() {
        XCTAssertEqual(BitField.popcount(0), 0)
        XCTAssertEqual(BitField.popcount(1), 1)
        XCTAssertEqual(BitField.popcount(0xFF), 8)
        XCTAssertEqual(BitField.popcount(-1), 64) // all bits set in two's complement
    }

    func testHammingDistanceSymmetric() {
        XCTAssertEqual(BitField.hammingDistance(0b1100, 0b0011), 4)
        XCTAssertEqual(BitField.hammingDistance(0b0011, 0b1100), 4)
        XCTAssertEqual(BitField.hammingDistance(42, 42), 0)
    }

    func testXorFoldEmptyIsZero() {
        let empty: [Int64] = []
        XCTAssertEqual(BitField.xorFold(empty), 0)
    }

    func testXorFoldSelfCancels() {
        // a ^ a = 0; pair of identical values cancels.
        XCTAssertEqual(BitField.xorFold([Int64(0x1234_5678), Int64(0x1234_5678)]), 0)
        // a ^ b ^ a = b.
        XCTAssertEqual(BitField.xorFold([Int64(0xAA), Int64(0xBB), Int64(0xAA)]), 0xBB)
    }

    // MARK: - Round-trip across cookbook §2.3 layout

    func testRoundTripCookbook23Layout() {
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

        XCTAssertEqual(BitField.extractField(adj, shift: 0, width: 6), 2)
        XCTAssertEqual(BitField.extractField(adj, shift: 6, width: 6), 16)
        XCTAssertEqual(BitField.extractField(adj, shift: 12, width: 6), 0)
        XCTAssertEqual(BitField.extractField(adj, shift: 18, width: 6), 3)
        XCTAssertTrue(BitField.extractFlag(adj, bit: 24))
        XCTAssertFalse(BitField.extractFlag(adj, bit: 25))
        XCTAssertTrue(BitField.extractFlag(adj, bit: 26))
    }
}
