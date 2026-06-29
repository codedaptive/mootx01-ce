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

    @Test("applyRow(+1) with a directly-constructed all-set bit-vector raises every one of the 216 cells")
    func applyRowAllSetCapture() {
        // Mirrors the Rust `apply_row_all_set_capture` (closure `always_set`).
        // The all-216-bits-set vector is constructed directly via
        // BitVector216(presenceBytes:) — NOT via RowBitmaps(-1,-1,-1).bitVector().
        //
        // Reason: RowBitmaps stores three Int64 fields; each covers only 64 bits.
        // Fields 10 and 11 (local shift = 60 and 66 in each bitmap column) fall
        // partially or entirely outside the 64-bit range:
        //   field(10): bits 60-65 → only bits 60-63 can be set (4 bits, not 6)
        //   field(11): bits 66-71 → entirely outside; correctly reads 0
        // RowBitmaps(-1,-1,-1).bitVector() therefore sets 192 cells, not 216.
        //
        // To test applyRow with a genuine all-216-set vector, use presenceBytes.
        var m = MatrixF()
        let full = BitVector216(presenceBytes: Array(repeating: 0xFF, count: 27))
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
