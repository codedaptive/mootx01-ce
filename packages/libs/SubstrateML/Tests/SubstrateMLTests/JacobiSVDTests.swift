// JacobiSVDTests.swift
//
// Conformance and correctness tests for JacobiSVD.
//
// ## What is tested
//
//   1. Structural: dimensions, non-negativity of singular values,
//      non-increasing order, unit norms for U columns and Vt rows.
//   2. Reconstruction fidelity: A ≈ U diag(Σ) Vt within Float32 tolerance.
//   3. Determinism: same input → same output every call.
//   4. Sign convention: largest-magnitude component of each U column
//      is positive.
//   5. Cross-port canonical vectors: the same 4×3 input with rank=3,
//      sweeps=30 must produce bit-identical f32 values on BOTH Swift
//      (this test) and Rust (substrate-ml crate svd.rs tests).
//
// ## Cross-port conformance protocol
//
//   Rust is run first to emit canonical bit patterns via
//   `emit_canonical_svd_values`. Those patterns are pasted as UInt32
//   hex constants. When this test passes, Swift agrees with Rust
//   bit-for-bit on the 4×3 canonical matrix.

import Testing
@testable import SubstrateML

// MARK: - Canonical fixture

/// The canonical 4×3 input matrix. Both ports use this input.
/// Any change invalidates the cross-port conformance pins below.
let svdCanonicalA: [[Float]] = [
    [1.0, 2.0, 3.0],
    [4.0, 5.0, 6.0],
    [7.0, 8.0, 9.0],
    [2.0, 0.0, 1.0],
]

// MARK: - JacobiSVD Tests

@Suite("JacobiSVD")
struct JacobiSVDTests {

    // MARK: - Structural tests

    @Test("output dimensions are correct")
    func dimensionsCorrect() {
        let result = JacobiSVD.decompose(A: svdCanonicalA, rank: 2)
        // U: m×k = 4×2
        #expect(result.U.count == 4)
        #expect(result.U[0].count == 2)
        // singular values: k = 2
        #expect(result.singularValues.count == 2)
        // Vt: k×n = 2×3
        #expect(result.Vt.count == 2)
        #expect(result.Vt[0].count == 3)
        #expect(result.rank == 2)
    }

    @Test("singular values are non-negative")
    func singularValuesNonNegative() {
        let result = JacobiSVD.decompose(A: svdCanonicalA, rank: 3)
        for sv in result.singularValues {
            #expect(sv >= 0, "singular value must be >= 0")
        }
    }

    @Test("singular values are in non-increasing order")
    func singularValuesNonIncreasing() {
        let result = JacobiSVD.decompose(A: svdCanonicalA, rank: 3)
        for i in 1..<result.singularValues.count {
            #expect(result.singularValues[i - 1] >= result.singularValues[i],
                    "singular values must be non-increasing")
        }
    }

    @Test("U columns are unit vectors")
    func uColumnsAreUnitVectors() {
        let result = JacobiSVD.decompose(A: svdCanonicalA, rank: 3)
        let m = svdCanonicalA.count
        let tol: Float = 1e-5
        for col in 0..<result.rank {
            var norm2: Float = 0
            for row in 0..<m { let v = result.U[row][col]; norm2 += v * v }
            #expect(abs(norm2.squareRoot() - 1) < tol, "U column norm must be 1")
        }
    }

    @Test("Vt rows are unit vectors")
    func vtRowsAreUnitVectors() {
        let result = JacobiSVD.decompose(A: svdCanonicalA, rank: 3)
        let tol: Float = 1e-5
        for row in 0..<result.rank {
            let norm2 = result.Vt[row].reduce(Float(0)) { $0 + $1 * $1 }
            #expect(abs(norm2.squareRoot() - 1) < tol, "Vt row norm must be 1")
        }
    }

    @Test("reconstruction fidelity: A ≈ U diag(Σ) Vt")
    func reconstructionFidelity() {
        let result = JacobiSVD.decompose(A: svdCanonicalA, rank: 3)
        let m = svdCanonicalA.count
        let n = svdCanonicalA[0].count
        let tol: Float = 1e-4
        for i in 0..<m {
            for j in 0..<n {
                var approx: Float = 0
                for r in 0..<result.rank {
                    approx += result.U[i][r] * result.singularValues[r] * result.Vt[r][j]
                }
                #expect(abs(approx - svdCanonicalA[i][j]) < tol,
                        "reconstruction error exceeds tolerance")
            }
        }
    }

    @Test("determinism: same input → identical output")
    func determinism() {
        let r1 = JacobiSVD.decompose(A: svdCanonicalA, rank: 3)
        let r2 = JacobiSVD.decompose(A: svdCanonicalA, rank: 3)
        #expect(r1.singularValues == r2.singularValues)
        #expect(r1.U == r2.U)
        #expect(r1.Vt == r2.Vt)
    }

    @Test("sign convention: largest-magnitude U component is positive")
    func signConventionLargestComponentPositive() {
        let result = JacobiSVD.decompose(A: svdCanonicalA, rank: 3)
        let m = svdCanonicalA.count
        for col in 0..<result.rank {
            var maxAbs: Float = 0
            var maxIdx: Int = 0
            for row in 0..<m {
                let absVal = abs(result.U[row][col])
                if absVal > maxAbs { maxAbs = absVal; maxIdx = row }
            }
            #expect(result.U[maxIdx][col] >= 0,
                    "largest-magnitude U component must be positive")
        }
    }

    @Test("rank-1 matrix has one dominant singular value (σ₁ = 14.0)")
    func rank1MatrixExact() {
        // A = u·uᵀ where u=[1,2,3]; σ₁ = ||u||² = 14.0.
        let a: [[Float]] = [[1, 2, 3], [2, 4, 6], [3, 6, 9]]
        let result = JacobiSVD.decompose(A: a, rank: 3)
        let tol: Float = 1e-3
        #expect(abs(result.singularValues[0] - 14.0) < tol, "σ₁ must be 14.0")
        #expect(result.singularValues[1] < 1e-3, "σ₂ must be ~0 for rank-1 matrix")
    }

    // MARK: - Cross-port canonical conformance

    /// Cross-port bit-identity gate: the same 4×3 input with rank=3,
    /// sweeps=30 must produce EXACTLY these f32 bit patterns on BOTH
    /// ports. These values were generated by running the Rust port:
    ///
    ///   cargo test emit_canonical_svd_values -- --nocapture
    ///
    /// If this test fails, the Swift arithmetic has diverged from Rust.
    /// Regenerate from Rust, paste here, re-verify both ports pass.
    @Test("canonical conformance vectors match Rust port bit-for-bit")
    func canonicalConformanceVectors() {
        let result = JacobiSVD.decompose(A: svdCanonicalA, rank: 3, sweeps: 30)

        // ── Singular values (bits from Rust emit_canonical_svd_values) ──
        // sv[0] = 16.92688  sv[1] = 1.7014122  sv[2] = 0.7654766
        #expect(result.singularValues[0].bitPattern == 0x41876A40, "sv[0] bit-identity with Rust")
        #expect(result.singularValues[1].bitPattern == 0x3FD9C7E0, "sv[1] bit-identity with Rust")
        #expect(result.singularValues[2].bitPattern == 0x3F43F646, "sv[2] bit-identity with Rust")

        // ── U row 0: [0.21353085, -0.45331436, 0.76304907] ──
        #expect(result.U[0][0].bitPattern == 0x3E5AA7D5, "U[0][0] bit-identity with Rust")
        #expect(result.U[0][1].bitPattern == 0xBEE818D2, "U[0][1] bit-identity with Rust")
        #expect(result.U[0][2].bitPattern == 0x3F43572F, "U[0][2] bit-identity with Rust")

        // ── U row 1: [0.51806062, -0.16642670, 0.19299927] ──
        #expect(result.U[1][0].bitPattern == 0x3F049F9F, "U[1][0] bit-identity with Rust")
        #expect(result.U[1][1].bitPattern == 0xBE2A6BC3, "U[1][1] bit-identity with Rust")
        #expect(result.U[1][2].bitPattern == 0x3E45A19A, "U[1][2] bit-identity with Rust")

        // ── U row 2: [0.82259047, 0.12046091, -0.37705109] ──
        #expect(result.U[2][0].bitPattern == 0x3F52954A, "U[2][0] bit-identity with Rust")
        #expect(result.U[2][1].bitPattern == 0x3DF6B436, "U[2][1] bit-identity with Rust")
        #expect(result.U[2][2].bitPattern == 0xBEC10CD7, "U[2][2] bit-identity with Rust")

        // ── U row 3: [0.09676100, 0.86735082, 0.48820063] ──
        #expect(result.U[3][0].bitPattern == 0x3DC62AA1, "U[3][0] bit-identity with Rust")
        #expect(result.U[3][1].bitPattern == 0x3F5E0AB4, "U[3][1] bit-identity with Rust")
        #expect(result.U[3][2].bitPattern == 0x3EF9F56F, "U[3][2] bit-identity with Rust")

        // ── Vt row 0: [0.48664778, 0.56703234, 0.66456622] ──
        #expect(result.Vt[0][0].bitPattern == 0x3EF929E6, "Vt[0][0] bit-identity with Rust")
        #expect(result.Vt[0][1].bitPattern == 0x3F112908, "Vt[0][1] bit-identity with Rust")
        #expect(result.Vt[0][2].bitPattern == 0x3F2A2103, "Vt[0][2] bit-identity with Rust")

        // ── Vt row 1: [0.85746837, -0.45554805, -0.23921554] ──
        #expect(result.Vt[1][0].bitPattern == 0x3F5B830C, "Vt[1][0] bit-identity with Rust")
        #expect(result.Vt[1][1].bitPattern == 0xBEE93D98, "Vt[1][1] bit-identity with Rust")
        #expect(result.Vt[1][2].bitPattern == 0xBE74F4EB, "Vt[1][2] bit-identity with Rust")

        // ── Vt row 2: [-0.16709879, -0.68625814, 0.70790368] ──
        #expect(result.Vt[2][0].bitPattern == 0xBE2B1BF2, "Vt[2][0] bit-identity with Rust")
        #expect(result.Vt[2][1].bitPattern == 0xBF2FAE9D, "Vt[2][1] bit-identity with Rust")
        #expect(result.Vt[2][2].bitPattern == 0x3F35392D, "Vt[2][2] bit-identity with Rust")
    }
}
