// BitFieldTests.swift
//
// Swift library-test peer suite for `BitField` (BitField.swift).
// Mirrors the behavior set asserted by the Rust `bit_field.rs`
// `#[test]` module (14 tests) so the two legs prove the same
// semantics: parametric field extract/write, single-bit flags,
// popcount / Hamming-distance / XOR-fold atomics, and the cookbook
// §2.3 packed-row round-trip.
//
// One Swift-only addition (maskedEquals): the Swift `BitField` exposes
// `maskedEquals`, a public primitive the Rust port also ships but does
// not unit-test. Proving the shipped Swift API is in scope, so the
// Swift leg asserts it; this expands coverage beyond the Rust set
// without narrowing it.
//
// Bitmaps are Int64 to match the production signatures.

import Testing
@testable import SubstrateKernel

@Suite("BitField")
struct BitFieldTests {

    // MARK: - Field extract

    @Test("extract_field: LSB 6-bit field")
    func extractFieldLSB6Bits() {
        // Cookbook §2.3 state at bits 0–5.
        #expect(BitField.extractField(0b101010, shift: 0, width: 6) == 0b101010)
        #expect(BitField.extractField(33, shift: 0, width: 6) == 33) // tombstoned
    }

    @Test("extract_field: middle 6-bit field, lower bits don't leak")
    func extractFieldMiddleField6Bits() {
        // Cookbook §2.3 trust at bits 18–23. Trust = canonical = 3.
        let adj: Int64 = 3 << 18
        #expect(BitField.extractField(adj, shift: 18, width: 6) == 3)
        // Lower bits don't leak into the extraction.
        let adj2: Int64 = (3 << 18) | 0x3F
        #expect(BitField.extractField(adj2, shift: 18, width: 6) == 3)
    }

    @Test("extract_field: high bits don't pollute")
    func extractFieldHighBitsDontPollute() {
        // Cookbook §2.5 enrichment_status at bits 36–41.
        let prov: Int64 = 2 << 36
        #expect(BitField.extractField(prov, shift: 36, width: 6) == 2)
    }

    // MARK: - Field write

    @Test("write_field preserves other fields")
    func writeFieldPreservesOtherFields() {
        // Adjective: state=active(0) at bits 0–5, trust=canonical(3) at 18–23.
        let prior: Int64 = 3 << 18 // trust=canonical, state=active
        let next = BitField.writeField(33, into: prior, shift: 0, width: 6) // state -> tombstoned
        #expect(BitField.extractField(next, shift: 0, width: 6) == 33)
        #expect(BitField.extractField(next, shift: 18, width: 6) == 3) // trust preserved
    }

    @Test("write_field overwrites field cleanly")
    func writeFieldOverwritesFieldCleanly() {
        let prior: Int64 = 0x3F << 18 // trust=63 (all bits set in trust field)
        let next = BitField.writeField(3, into: prior, shift: 18, width: 6) // overwrite with canonical
        #expect(BitField.extractField(next, shift: 18, width: 6) == 3)
    }

    @Test("write_field truncates oversize value to field width")
    func writeFieldTruncatesOversizeValue() {
        // value=0x7F (7 bits) into a 6-bit field truncates to 0x3F.
        let next = BitField.writeField(0x7F, into: 0, shift: 0, width: 6)
        #expect(BitField.extractField(next, shift: 0, width: 6) == 0x3F)
    }

    // MARK: - Flag extract/write

    @Test("extract_flag returns the single-bit value")
    func extractFlagReturnsBool() {
        #expect(BitField.extractFlag(0, bit: 26) == false)
        #expect(BitField.extractFlag(Int64(1) << 26, bit: 26) == true)
        // Bit 27 set doesn't bleed into bit 26's read.
        #expect(BitField.extractFlag(Int64(1) << 27, bit: 26) == false)
    }

    @Test("write_flag preserves other bits")
    func writeFlagPreservesOtherBits() {
        let prior: Int64 = (1 << 24) | (1 << 25) // state_extension + lineage_clustering
        let next = BitField.writeFlag(true, into: prior, bit: 26) // set dreaming_recalc_required
        #expect(BitField.extractFlag(next, bit: 24) == true)
        #expect(BitField.extractFlag(next, bit: 25) == true)
        #expect(BitField.extractFlag(next, bit: 26) == true)
    }

    @Test("write_flag can clear a bit")
    func writeFlagCanClear() {
        let prior: Int64 = 0xFF
        let next = BitField.writeFlag(false, into: prior, bit: 3)
        #expect(next == 0xF7) // bit 3 cleared
    }

    // MARK: - Masked equality (Swift-only coverage — public API the Rust port ships untested)

    @Test("masked_equals: (bitmap & mask) == expected")
    func maskedEquals() {
        // Cookbook §2.8: state field at bits 0–3 (4-bit field), test state == 3.
        #expect(BitField.maskedEquals(3, mask: 0xF, expected: 3))
        #expect(BitField.maskedEquals(0x13, mask: 0xF, expected: 3)) // high bits outside mask ignored
        #expect(BitField.maskedEquals(2, mask: 0xF, expected: 3) == false)
        // expected with bits outside mask never matches.
        #expect(BitField.maskedEquals(0xFF, mask: 0xF, expected: 0x1F) == false)
    }

    // MARK: - Bulk-friendly atomics

    @Test("popcount matches the set-bit count")
    func popcountMatchesSetBits() {
        #expect(BitField.popcount(0) == 0)
        #expect(BitField.popcount(1) == 1)
        #expect(BitField.popcount(0xFF) == 8)
        #expect(BitField.popcount(-1) == 64) // all bits set in two's complement
    }

    @Test("hamming_distance is symmetric and zero on equal inputs")
    func hammingDistanceSymmetric() {
        #expect(BitField.hammingDistance(0b1100, 0b0011) == 4)
        #expect(BitField.hammingDistance(0b0011, 0b1100) == 4)
        #expect(BitField.hammingDistance(42, 42) == 0)
    }

    @Test("xor_fold of an empty sequence is zero")
    func xorFoldEmptyIsZero() {
        let empty: [Int64] = []
        #expect(BitField.xorFold(empty) == 0)
    }

    @Test("xor_fold self-cancels (a^a=0, a^b^a=b)")
    func xorFoldSelfCancels() {
        // a ^ a = 0; pair of identical values cancels.
        #expect(BitField.xorFold([0x1234_5678 as Int64, 0x1234_5678]) == 0)
        // a ^ b ^ a = b.
        #expect(BitField.xorFold([0xAA as Int64, 0xBB, 0xAA]) == 0xBB)
    }

    // MARK: - Round-trip

    @Test("round-trip the full cookbook §2.3 packed-row layout")
    func roundTripCookbook23Layout() {
        // Build cookbook §2.3 layout from scratch: state, sensitivity,
        // exportability, trust, three flags. Round-trip every field.
        var adj: Int64 = 0
        adj = BitField.writeField(2, into: adj, shift: 0, width: 6)   // state=contested
        adj = BitField.writeField(16, into: adj, shift: 6, width: 6)  // sensitivity=elevated
        adj = BitField.writeField(0, into: adj, shift: 12, width: 6)  // exportability=private
        adj = BitField.writeField(3, into: adj, shift: 18, width: 6)  // trust=canonical
        adj = BitField.writeFlag(true, into: adj, bit: 24)            // state_extension
        adj = BitField.writeFlag(false, into: adj, bit: 25)           // lineage_clustering
        adj = BitField.writeFlag(true, into: adj, bit: 26)            // dreaming_recalc_required

        #expect(BitField.extractField(adj, shift: 0, width: 6) == 2)
        #expect(BitField.extractField(adj, shift: 6, width: 6) == 16)
        #expect(BitField.extractField(adj, shift: 12, width: 6) == 0)
        #expect(BitField.extractField(adj, shift: 18, width: 6) == 3)
        #expect(BitField.extractFlag(adj, bit: 24) == true)
        #expect(BitField.extractFlag(adj, bit: 25) == false)
        #expect(BitField.extractFlag(adj, bit: 26) == true)
    }
}
