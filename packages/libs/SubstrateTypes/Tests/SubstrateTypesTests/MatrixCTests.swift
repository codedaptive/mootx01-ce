// MatrixCTests.swift
//
// Per-type suite for MatrixC (correlation matrix, marginals derived
// from F). Mirrors the Rust `matrix_c.rs` inline #[test] set:
// zero_rows_gives_zero_matrix, derive_marginal_half,
// derive_marginal_one_third (Float32 bit-identity anchor), wire_round_trip.

import Testing
@testable import SubstrateTypes

@Suite("MatrixC correlation matrix")
struct MatrixCTests {

    @Test("derive with zero rows yields the zero matrix regardless of F")
    func zeroRowsGivesZeroMatrix() {
        var f = MatrixF()
        f[3, 2] = 100
        f[10, 5] = 999
        let c = MatrixC.derive(from: f, nRows: 0)
        for v in c.cells { #expect(v == 0.0) }
    }

    @Test("a 50/100 cell derives to marginal 0.5")
    func deriveMarginalHalf() {
        var f = MatrixF()
        f[0, 0] = 50
        let c = MatrixC.derive(from: f, nRows: 100)
        #expect(abs(c[0, 0] - 0.5) < 1e-7)
    }

    @Test("1/3 derives to the canonical Float32 bit pattern 0x3eaaaaab")
    func deriveMarginalOneThird() {
        // 1/3 has a non-terminating binary expansion; the Int64→Double→
        // Float32 cast must produce the same f32 bits in Swift and Rust.
        var f = MatrixF()
        f[0, 0] = 1
        let c = MatrixC.derive(from: f, nRows: 3)
        #expect(c[0, 0].bitPattern == 0x3eaa_aaab)
    }

    @Test("wire encoding round-trips Float32 cells (including negatives)")
    func wireRoundTrip() throws {
        var c = MatrixC()
        c[0, 0] = 0.5
        c[35, 5] = 0.123_456
        c[17, 3] = -1.0   // exotic but representable
        var bytes = [UInt8]()
        c.writeWire(into: &bytes)
        #expect(bytes.count == MatrixC.wireBytes)
        let back = try #require(MatrixC.readWire(bytes))
        #expect(back == c)
    }
}
