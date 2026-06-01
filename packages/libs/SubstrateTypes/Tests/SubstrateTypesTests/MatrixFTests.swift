// MatrixFTests.swift
//
// Per-type suite for MatrixF (field-presence matrix). Mirrors the Rust
// `matrix_f.rs` inline #[test] set: fresh_matrix_zero,
// apply_row_all_set_capture, apply_row_inverse, never_set_is_noop,
// wire_round_trip.
//
// Signature note: the Swift applyRow takes a BitVector216 (Phase 5,
// §6.5) where the Rust port takes an (field,bit)->bool closure. The
// behaviors asserted are the same; the Swift suite drives them through
// the typed bit-vector view.

import Testing
@testable import SubstrateTypes

@Suite("MatrixF field-presence matrix")
struct MatrixFTests {

    /// A RowBitmaps with all six bits of field 0 set (value 0x3F),
    /// everything else clear → exactly 6 set cells.
    private var sixBitVector: BitVector216 {
        RowBitmaps(adjective: 0x3F, operational: 0, provenance: 0).bitVector()
    }

    @Test("fresh matrix is all zeros with the canonical cell count")
    func freshMatrixZero() {
        let m = MatrixF()
        #expect(m.totalCount == 0)
        #expect(m.cells.count == MatrixF.cellCount)
        #expect(MatrixF.cellCount == 216)
    }

    @Test("applyRow(+1) on capture raises exactly the set cells")
    func applyRowCaptureRaisesSetCells() {
        var m = MatrixF()
        m.applyRow(delta: 1, bitVector: sixBitVector)
        // field 0, bits 0..5 each incremented once → total 6.
        #expect(m.totalCount == 6)
        for bit in 0..<6 { #expect(m[0, bit] == 1) }
        #expect(m[1, 0] == 0)
    }

    @Test("applyRow(+1) with a fully-set bit-vector raises every one of the 216 cells")
    func applyRowAllSetCapture() {
        // Mirrors the Rust `apply_row_all_set_capture` (closure `always_set`):
        // an all-ones RowBitmaps yields a BitVector216 with all 216 bits set
        // (every field reads 0x3F), so capture increments every cell to 1.
        var m = MatrixF()
        let full = RowBitmaps(adjective: -1, operational: -1, provenance: -1).bitVector()
        m.applyRow(delta: 1, bitVector: full)
        #expect(m.totalCount == Int64(MatrixF.cellCount))   // 216
        for c in m.cells { #expect(c == 1) }
    }

    @Test("applyRow(+1) then applyRow(-1) restores zero")
    func applyRowInverse() {
        var m = MatrixF()
        let v = sixBitVector
        m.applyRow(delta: 1, bitVector: v)
        m.applyRow(delta: -1, bitVector: v)
        #expect(m.totalCount == 0)
    }

    @Test("applyRow with an empty bit-vector (or delta 0) is a no-op")
    func neverSetIsNoop() {
        var m = MatrixF()
        m.applyRow(delta: 1, bitVector: RowBitmaps.zero.bitVector())
        #expect(m.totalCount == 0)
        m.applyRow(delta: 0, bitVector: sixBitVector)
        #expect(m.totalCount == 0)
    }

    @Test("wire encoding round-trips, including negative and large cells")
    func wireRoundTrip() throws {
        var m = MatrixF()
        m[0, 0] = 42
        m[35, 5] = -7
        m[17, 3] = 1_000_000
        var bytes = [UInt8]()
        m.writeWire(into: &bytes)
        #expect(bytes.count == MatrixF.wireBytes)
        let back = try #require(MatrixF.readWire(bytes))
        #expect(back == m)
    }
}
