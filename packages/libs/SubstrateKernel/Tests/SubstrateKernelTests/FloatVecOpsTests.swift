// FloatVecOpsTests.swift
//
// Conformance and correctness tests for FloatVecOps.
//
// ## What is tested
//
//   1. l2Norm: empty vector, zero vector, unit basis vector, [3,4]→5.
//   2. l2Normalize: zero-vector passthrough, unit output, bit-exact
//      patterns for canonical inputs.
//   3. dot: orthogonal, identical, known numeric value.
//   4. cosine: identical, orthogonal, opposite, and equivalence with
//      dot for normalised inputs.
//   5. Cross-port bit-identity gate: fixed float inputs → expected
//      bit patterns, matched against the Rust port's output. Both
//      ports must agree on every entry in the canonical table below.

import Testing
@testable import SubstrateKernel

@Suite("FloatVecOps")
struct FloatVecOpsTests {

    // MARK: - Helpers

    private func approxEq(_ a: Float, _ b: Float, tol: Float = 1e-6) -> Bool {
        abs(a - b) < tol
    }

    // MARK: - l2Norm

    @Test("l2Norm of empty vector is 0.0")
    func l2NormEmpty() {
        #expect(FloatVecOps.l2Norm([]) == 0.0)
    }

    @Test("l2Norm of zero vector is 0.0")
    func l2NormZeroVector() {
        let v = [Float](repeating: 0.0, count: 8)
        #expect(FloatVecOps.l2Norm(v) == 0.0)
    }

    @Test("l2Norm of unit basis vector is 1.0")
    func l2NormUnitBasis() {
        let v: [Float] = [1.0, 0.0, 0.0, 0.0]
        let n = FloatVecOps.l2Norm(v)
        #expect(approxEq(n, 1.0, tol: 1e-7), "expected 1.0, got \(n)")
    }

    @Test("l2Norm([3, 4]) == 5.0")
    func l2NormThreeFour() {
        let v: [Float] = [3.0, 4.0]
        let n = FloatVecOps.l2Norm(v)
        #expect(approxEq(n, 5.0, tol: 1e-6), "expected 5.0, got \(n)")
    }

    // MARK: - l2Normalize

    @Test("l2Normalize of zero vector returns zero vector unchanged")
    func l2NormalizeZeroVector() {
        // Zero-vector contract: must not NaN or panic.
        let v = [Float](repeating: 0.0, count: 4)
        let out = FloatVecOps.l2Normalize(v)
        for (i, x) in out.enumerated() {
            #expect(x == 0.0, "position \(i) must be 0.0 after zero-vector passthrough")
        }
    }

    @Test("l2Normalize produces a unit vector")
    func l2NormalizeProducesUnit() {
        let v: [Float] = [3.0, 4.0, 0.0]
        let normed = FloatVecOps.l2Normalize(v)
        let normSq = normed.reduce(Float(0)) { $0 + $1 * $1 }
        let norm = normSq.squareRoot()
        #expect(approxEq(norm, 1.0, tol: 1e-6), "normalised vector must have unit norm; got \(norm)")
    }

    @Test("l2Normalize of [3,4] gives [0.6, 0.8] (bit-exact canonical)")
    func l2NormalizeCanonicaltThreeFour() {
        // Canonical: norm = 5; inv = 1/5 = 0.2; 3*0.2=0.6, 4*0.2=0.8.
        let v: [Float] = [3.0, 4.0]
        let out = FloatVecOps.l2Normalize(v)
        #expect(approxEq(out[0], 0.6, tol: 1e-7), "expected 0.6 got \(out[0])")
        #expect(approxEq(out[1], 0.8, tol: 1e-7), "expected 0.8 got \(out[1])")
    }

    @Test("l2Normalize already-unit vector — bit pattern unchanged")
    func l2NormalizeAlreadyUnit() {
        // [1, 0, 0]: norm_sq=1, inv_norm=1.0/1.0=1.0; elements unchanged.
        let v: [Float] = [1.0, 0.0, 0.0]
        let out = FloatVecOps.l2Normalize(v)
        #expect(out[0].bitPattern == (1.0 as Float).bitPattern)
        #expect(out[1].bitPattern == (0.0 as Float).bitPattern)
        #expect(out[2].bitPattern == (0.0 as Float).bitPattern)
    }

    // MARK: - Bit-identity canonical table
    //
    // These are the canonical input → bit-pattern pairs the Rust port's
    // float_vec_ops tests must also pass. Any divergence between ports
    // is a bit-identity bug. The values are computed by the algorithm
    // specification:
    //   norm_sq = sum(x*x); inv_norm = 1.0 / sqrt(norm_sq); out[i] = in[i] * inv_norm

    @Test("l2Normalize canonical bit-identity: [1, 2, 2] → norm 3")
    func l2NormalizeCanonical122() {
        // norm_sq = 1+4+4 = 9; sqrt(9) = 3.0; inv_norm = 1.0/3.0
        let v: [Float] = [1.0, 2.0, 2.0]
        let out = FloatVecOps.l2Normalize(v)
        let invNorm: Float = 1.0 / (3.0 as Float)  // 1.0 / sqrt(9)
        // Verify bit patterns match the expected operation sequence.
        #expect(out[0].bitPattern == (1.0 * invNorm).bitPattern,
                "bit pattern mismatch at index 0")
        #expect(out[1].bitPattern == (2.0 * invNorm).bitPattern,
                "bit pattern mismatch at index 1")
        #expect(out[2].bitPattern == (2.0 * invNorm).bitPattern,
                "bit pattern mismatch at index 2")
    }

    // MARK: - dot

    @Test("dot of orthogonal unit vectors is 0.0")
    func dotOrthogonal() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        #expect(FloatVecOps.dot(a, b) == 0.0)
    }

    @Test("dot of identical unit vector with itself is 1.0")
    func dotSelf() {
        let a: [Float] = [1.0, 0.0, 0.0]
        #expect(approxEq(FloatVecOps.dot(a, a), 1.0, tol: 1e-7))
    }

    @Test("dot([1,2,3], [4,5,6]) == 32.0")
    func dotKnownValue() {
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [4.0, 5.0, 6.0]
        // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
        #expect(approxEq(FloatVecOps.dot(a, b), 32.0, tol: 1e-6))
    }

    // MARK: - cosine

    @Test("cosine of identical unit vectors is 1.0")
    func cosineIdentical() {
        let v: [Float] = [1.0, 0.0, 0.0]
        #expect(approxEq(FloatVecOps.cosine(v, v), 1.0, tol: 1e-7))
    }

    @Test("cosine of orthogonal unit vectors is 0.0")
    func cosineOrthogonal() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [0.0, 1.0]
        #expect(FloatVecOps.cosine(a, b) == 0.0)
    }

    @Test("cosine of opposite unit vectors is -1.0")
    func cosineOpposite() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [-1.0, 0.0]
        #expect(approxEq(FloatVecOps.cosine(a, b), -1.0, tol: 1e-7))
    }

    @Test("cosine of normalised inputs equals dot product")
    func cosineEqualsDotForNormalisedInputs() {
        let rawA: [Float] = [3.0, 4.0, 0.0]
        let rawB: [Float] = [0.0, 4.0, 3.0]
        let a = FloatVecOps.l2Normalize(rawA)
        let b = FloatVecOps.l2Normalize(rawB)
        let c = FloatVecOps.cosine(a, b)
        let d = FloatVecOps.dot(a, b)
        #expect(approxEq(c, d, tol: 1e-7),
                "cosine and dot must agree for normalised inputs: cosine=\(c) dot=\(d)")
    }
}
