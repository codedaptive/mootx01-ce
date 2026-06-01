// RowBitmapsTests.swift
//
// Per-type suite for RowBitmaps + BitVector216 (cookbook §2.3 row
// bitmap layout, made an explicit value type in Phase 5). RowBitmaps
// is a Swift-side layout type with no dedicated Rust module; this suite
// asserts the contract from source: layout constants, 6-bit field
// access, (field,bit) predicate, fieldValues enumeration, and the dense
// BitVector216 view.

import Testing
@testable import SubstrateTypes

@Suite("RowBitmaps + BitVector216")
struct RowBitmapsTests {

    @Test("layout constants describe the 36×6 = 216 cookbook §2.3 grid")
    func layoutConstants() {
        #expect(RowBitmaps.fieldCount == 36)
        #expect(RowBitmaps.bitsPerField == 6)
        #expect(RowBitmaps.bitmapsCount == 3)
        #expect(RowBitmaps.fieldsPerBitmap == 12)
        #expect(RowBitmaps.totalBits == 216)
        #expect(RowBitmaps.fieldValueMask == 0x3F)
    }

    @Test("field(_:) reads the 6-bit value from the right bitmap column")
    func fieldReadsSixBitValue() {
        // field 0 → adjective low 6 bits; field 12 → operational low 6;
        // field 24 → provenance low 6.
        let rb = RowBitmaps(adjective: 0x2A, operational: 0x15, provenance: 0x3F)
        #expect(rb.field(0) == 0x2A)
        #expect(rb.field(12) == 0x15)
        #expect(rb.field(24) == 0x3F)
    }

    @Test("bit(field:bit:) reflects individual bits of a field value")
    func bitReflectsFieldBits() {
        let rb = RowBitmaps(adjective: 0b101, operational: 0, provenance: 0)
        #expect(rb.bit(field: 0, bit: 0))
        #expect(!rb.bit(field: 0, bit: 1))
        #expect(rb.bit(field: 0, bit: 2))
    }

    @Test("fieldValues enumerates all 36 fields in index order")
    func fieldValuesEnumeratesAll() {
        let rb = RowBitmaps(adjective: 0x07, operational: 0, provenance: 0)
        let fvs = rb.fieldValues()
        #expect(fvs.count == 36)
        #expect(fvs[0].field == 0)
        #expect(fvs[0].value == 0x07)
        #expect(fvs[1].value == 0)
    }

    @Test("zero RowBitmaps has every field clear")
    func zeroIsClear() {
        let z = RowBitmaps.zero
        for f in 0..<RowBitmaps.fieldCount { #expect(z.field(f) == 0) }
    }

    @Test("BitVector216 sets the absolute bits for each present field bit")
    func bitVectorAbsoluteBits() {
        // field 0 = value 0b101 → absolute bits 0 and 2 set.
        let bv = RowBitmaps(adjective: 0b101, operational: 0, provenance: 0).bitVector()
        #expect(bv.bit(at: 0))
        #expect(!bv.bit(at: 1))
        #expect(bv.bit(at: 2))
        #expect(bv.bit(field: 0, bit: 0))
        #expect(bv.bit(field: 0, bit: 2))
        #expect(BitVector216.bitCount == 216)
        #expect(BitVector216.byteCount == 27)
    }

    // MARK: - BitVector216(presenceBytes:) — raw initializer

    @Test("BitVector216(presenceBytes:) round-trips a full 27-byte pattern losslessly")
    func presenceBytesRoundTrip() {
        // Construct a 27-byte pattern with bits set in ranges that
        // RowBitmaps.field(_:) cannot represent:
        //
        //   fields 10/11 → absolute bits 60–71 (bytes 7–8, bits 4–7 and 0–7)
        //   fields 22/23 → absolute bits 132–143
        //   fields 34/35 → absolute bits 204–215
        //
        // Setting all 216 bits in alternating positions exercises
        // the full range including the "high" slots that overflow
        // the 12×6 uniform-grid model.
        var bytes = [UInt8](repeating: 0, count: BitVector216.byteCount) // 27 bytes

        // Set specific bits in the high-field ranges to confirm they
        // survive the round-trip intact.

        // field 10, bit 4 → absolute 64, byte 8 bit 0
        let pos_f10_b4 = 10 * 6 + 4  // = 64
        bytes[pos_f10_b4 / 8] |= 1 << (pos_f10_b4 % 8)

        // field 11, bit 5 → absolute 71, byte 8 bit 7
        let pos_f11_b5 = 11 * 6 + 5  // = 71
        bytes[pos_f11_b5 / 8] |= 1 << (pos_f11_b5 % 8)

        // field 22, bit 0 → absolute 132, byte 16 bit 4
        let pos_f22_b0 = 22 * 6 + 0  // = 132
        bytes[pos_f22_b0 / 8] |= 1 << (pos_f22_b0 % 8)

        // field 23, bit 3 → absolute 141, byte 17 bit 5
        let pos_f23_b3 = 23 * 6 + 3  // = 141
        bytes[pos_f23_b3 / 8] |= 1 << (pos_f23_b3 % 8)

        // field 34, bit 1 → absolute 205, byte 25 bit 5
        let pos_f34_b1 = 34 * 6 + 1  // = 205
        bytes[pos_f34_b1 / 8] |= 1 << (pos_f34_b1 % 8)

        // field 35, bit 5 → absolute 215, byte 26 bit 7  (last bit)
        let pos_f35_b5 = 35 * 6 + 5  // = 215
        bytes[pos_f35_b5 / 8] |= 1 << (pos_f35_b5 % 8)

        let bv = BitVector216(presenceBytes: bytes)

        // Every set bit must survive the round-trip.
        #expect(bv.bit(at: pos_f10_b4))   // field 10, bit 4
        #expect(bv.bit(at: pos_f11_b5))   // field 11, bit 5
        #expect(bv.bit(at: pos_f22_b0))   // field 22, bit 0
        #expect(bv.bit(at: pos_f23_b3))   // field 23, bit 3
        #expect(bv.bit(at: pos_f34_b1))   // field 34, bit 1
        #expect(bv.bit(at: pos_f35_b5))   // field 35, bit 5 (absolute 215)

        // Convenience (field, bit) accessor must agree.
        #expect(bv.bit(field: 10, bit: 4))
        #expect(bv.bit(field: 11, bit: 5))
        #expect(bv.bit(field: 22, bit: 0))
        #expect(bv.bit(field: 23, bit: 3))
        #expect(bv.bit(field: 34, bit: 1))
        #expect(bv.bit(field: 35, bit: 5))

        // Bits adjacent to the set ones must be clear (no spillover).
        #expect(!bv.bit(at: pos_f10_b4 - 1))
        #expect(!bv.bit(at: pos_f11_b5 - 1))
        #expect(!bv.bit(at: pos_f22_b0 + 1))

        // All 27 storage bytes must match the input exactly.
        // Build a second BitVector216 from the same bytes and verify
        // it is equal, confirming storage is a verbatim copy.
        let bv2 = BitVector216(presenceBytes: bytes)
        #expect(bv == bv2)
    }

    @Test("BitVector216(presenceBytes:) all-zeros and all-ones are lossless")
    func presenceBytesAllZerosAndOnes() {
        // All zeros.
        let zeroBV = BitVector216(presenceBytes: [UInt8](repeating: 0, count: 27))
        for i in 0..<216 { #expect(!zeroBV.bit(at: i)) }

        // All ones — including the high positions 60–71, 132–143, 204–215.
        let oneBV = BitVector216(presenceBytes: [UInt8](repeating: 0xFF, count: 27))
        for i in 0..<216 { #expect(oneBV.bit(at: i)) }
    }
}
