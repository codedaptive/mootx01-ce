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
}
