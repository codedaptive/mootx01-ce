// NMFDoubleFrobeniusSquaredTests.swift
//
// Conformance and behavior tests for NMFDoubleFrobeniusSquared — the parked
// f64/Frobenius² NMF variant.
//
// NOT FOR PRODUCTION — see NMFDoubleFrobeniusSquared.swift and
// SUBSTRATEML_SPEC.md § 5.4b for the production-gate contract.
//
// These tests pin the bit-exact output of the Swift scalar path against the
// canonical conformance vectors in:
//   docs/engineering/substrate_reference/test-harness/vectors/
//     nmf_double_frobenius_squared.json
//
// Cross-port bit-identity (Swift scalar ↔ Rust scalar) is the correctness
// gate; the Rust side pins the same bit patterns in
// nmf_double_frobenius_squared.rs #[test] blocks.

import Testing
@testable import SubstrateML

@Suite("NMFDoubleFrobeniusSquared (parked f64 variant)")
struct NMFDoubleFrobeniusSquaredTests {

    // MARK: - Conformance vector nmf-dfs-001

    @Test("nmf-dfs-001: 2×2 k=1 canonical seed bit-exact W, H, err, iters")
    func conformance2x2K1CanonicalSeed() {
        // Vector: nmf_double_frobenius_squared.json case nmf-dfs-001
        // o = [4, 1, 1, 5], rows=2, cols=2, rank=1, seed=0xC0FFEE_BABE_BEEF
        let o = [4.0, 1.0, 1.0, 5.0]
        let f = NMFDoubleFrobeniusSquared.factorize(
            o: o, rows: 2, cols: 2, rank: 1,
            seed: 0xC0FFEE_BABE_BEEF,
            maxIterations: 100, tolerance: 1e-6
        )
        // Bit-exact conformance against nmf-dfs-001 expected values.
        #expect(f.w[0].bitPattern == 4603661257158336504, "W[0] bit mismatch")
        #expect(f.w[1].bitPattern == 4607051107372252721, "W[1] bit mismatch")
        #expect(f.h[0].bitPattern == 4612924100901497531, "H[0] bit mismatch")
        #expect(f.h[1].bitPattern == 4616330521827979722, "H[1] bit mismatch")
        #expect(f.reconstructionError.bitPattern == 4622628467456029591, "err bit mismatch")
        #expect(f.iterations == 8, "iteration count mismatch")
    }

    // MARK: - Conformance vector nmf-dfs-002

    @Test("nmf-dfs-002: 3×3 rank-1 canonical seed — bit-exact W, H; err < 1e-6")
    func conformance3x3Rank1CanonicalSeed() {
        // Vector: nmf-dfs-002
        let o = [1.0, 2.0, 3.0, 2.0, 4.0, 6.0, 3.0, 6.0, 9.0]
        let f = NMFDoubleFrobeniusSquared.factorize(
            o: o, rows: 3, cols: 3, rank: 1,
            seed: 0xC0FFEE_BABE_BEEF,
            maxIterations: 200, tolerance: 1e-9
        )
        #expect(f.w[0].bitPattern == 4601193815539350904, "W[0] bit mismatch")
        #expect(f.w[1].bitPattern == 4605697415166833578, "W[1] bit mismatch")
        #expect(f.w[2].bitPattern == 4608320465888842828, "W[2] bit mismatch")
        #expect(f.h[0].bitPattern == 4612575102165826494, "H[0] bit mismatch")
        #expect(f.h[1].bitPattern == 4617078701793658225, "H[1] bit mismatch")
        #expect(f.h[2].bitPattern == 4619775043477024004, "H[2] bit mismatch")
        #expect(f.reconstructionError.bitPattern == 4327796906586673664, "err bit mismatch")
        // Frobenius² of a perfect rank-1 matrix should be near zero.
        #expect(f.reconstructionError < 1e-6, "expected low Frobenius² error for rank-1 input")
        #expect(f.iterations == 2)
    }

    // MARK: - Conformance vector nmf-dfs-003

    @Test("nmf-dfs-003: 2×3 rank-2 canonical seed — bit-exact W, H, err")
    func conformance2x3Rank2CanonicalSeed() {
        // Vector: nmf-dfs-003
        let o = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        let f = NMFDoubleFrobeniusSquared.factorize(
            o: o, rows: 2, cols: 3, rank: 2,
            seed: 0xC0FFEE_BABE_BEEF,
            maxIterations: 100, tolerance: 1e-6
        )
        let expectedW: [UInt64] = [4602465361513043642, 4593766770366977732,
                                    4605722911112632657, 4612419604414596566]
        let expectedH: [UInt64] = [4610627333865788969, 4615981999002032526,
                                    4618482759899252455, 4607560704718651574,
                                    4604853887617463912, 4600969095618859142]
        for (i, bp) in expectedW.enumerated() {
            #expect(f.w[i].bitPattern == bp, "W[\(i)] bit mismatch")
        }
        for (i, bp) in expectedH.enumerated() {
            #expect(f.h[i].bitPattern == bp, "H[\(i)] bit mismatch")
        }
        #expect(f.reconstructionError.bitPattern == 4531103906867295372, "err bit mismatch")
        #expect(f.iterations == 75)
    }

    // MARK: - Determinism (nmf-dfs-004)

    @Test("nmf-dfs-004: determinism — same seed, same inputs produce bit-identical output")
    func deterministicAcrossCallsSameSeed() {
        let o = [4.0, 1.0, 1.0, 5.0]
        let a = NMFDoubleFrobeniusSquared.factorize(
            o: o, rows: 2, cols: 2, rank: 1,
            seed: 0xDEADBEEF_CAFEBABE,
            maxIterations: 100, tolerance: 1e-6
        )
        let b = NMFDoubleFrobeniusSquared.factorize(
            o: o, rows: 2, cols: 2, rank: 1,
            seed: 0xDEADBEEF_CAFEBABE,
            maxIterations: 100, tolerance: 1e-6
        )
        #expect(a.w == b.w)
        #expect(a.h == b.h)
        #expect(a.reconstructionError == b.reconstructionError)
        #expect(a.iterations == b.iterations)
    }

    // MARK: - Behavior invariants

    @Test("result type carries correct shape metadata")
    func resultCarriesCorrectShape() {
        let o = [4.0, 1.0, 1.0, 5.0]
        let f = NMFDoubleFrobeniusSquared.factorize(
            o: o, rows: 2, cols: 2, rank: 1
        )
        #expect(f.rows == 2)
        #expect(f.cols == 2)
        #expect(f.rank == 1)
        #expect(f.w.count == 2 * 1)
        #expect(f.h.count == 1 * 2)
    }

    @Test("loadings(forRow:) returns the correct W row")
    func loadingsForRowReturnsWRow() {
        let o = [4.0, 1.0, 1.0, 5.0]
        let f = NMFDoubleFrobeniusSquared.factorize(
            o: o, rows: 2, cols: 2, rank: 1,
            seed: 0xC0FFEE_BABE_BEEF
        )
        let l0 = f.loadings(forRow: 0)
        let l1 = f.loadings(forRow: 1)
        #expect(l0.count == 1)
        #expect(l1.count == 1)
        // loadings must match the W matrix entries exactly.
        #expect(l0[0].bitPattern == f.w[0].bitPattern)
        #expect(l1[0].bitPattern == f.w[1].bitPattern)
    }

    @Test("all W and H entries are non-negative after convergence")
    func nonNegativityInvariant() {
        let o = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        let f = NMFDoubleFrobeniusSquared.factorize(
            o: o, rows: 2, cols: 3, rank: 2
        )
        for v in f.w { #expect(v >= 0, "W entry negative: \(v)") }
        for v in f.h { #expect(v >= 0, "H entry negative: \(v)") }
    }

    @Test("different seeds produce different factorizations")
    func differentSeedsDifferentOutput() {
        let o = [4.0, 1.0, 1.0, 5.0]
        let a = NMFDoubleFrobeniusSquared.factorize(
            o: o, rows: 2, cols: 2, rank: 1, seed: 1
        )
        let b = NMFDoubleFrobeniusSquared.factorize(
            o: o, rows: 2, cols: 2, rank: 1, seed: 2
        )
        // Different seeds should (with overwhelming probability) produce different W.
        #expect(a.w != b.w || a.h != b.h)
    }
}
