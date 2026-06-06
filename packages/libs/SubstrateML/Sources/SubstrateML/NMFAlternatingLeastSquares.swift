// NMFAlternatingLeastSquares.swift
//
// Non-negative matrix factorization via alternating least squares
// per cookbook § 6.9 and § 8.9.
//
//   V ≈ W × H,  V ∈ R+^{m×n},  W ∈ R+^{m×k},  H ∈ R+^{k×n}
//
// All three matrices are constrained non-negative. The rank k is
// chosen by the caller (typical estate: k ∈ {4, 8, 16}). The
// substrate uses NMF on the F matrix (cookbook § 6.2) to surface
// latent "themes" and on the O matrix (§ 6.3) to surface
// co-occurrence factors.
//
// We use the Lee-Seung multiplicative update rules, which preserve
// non-negativity automatically without explicit projection:
//
//   H_{kj} ← H_{kj}  ·  (Wᵀ V)_{kj}  /  (Wᵀ W H + ε)_{kj}
//   W_{ik} ← W_{ik}  ·  (V Hᵀ)_{ik}  /  (W H Hᵀ + ε)_{ik}
//
// Initialization: uniform random in [0, 1) from SplitMix64 seeded
// by the caller. Bit-identical across cells because SplitMix64 is
// the substrate's canonical PRNG.
//
// Convergence: iterate until reconstruction error change drops
// below tolerance, or maxIterations reached. The error is RMS:
//   err = sqrt(Σ (V - WH)^2 / (m·n))
//
// Input preconditions (enforced at entry; violations trigger precondition):
//   - V is rectangular: every row has the same column count.
//   - All entries of V are finite (no NaN, no Inf).
//   - All entries of V are ≥ 0 (the Lee-Seung theorem requires V ≥ 0;
//     negative input violates the non-negativity theorem and produces
//     undefined output).
//
// Used by:
//   § 6.9    NMF definition (this file)
//   § 8.9    NMF over F matrix (latent themes)
//   § 11.11  recall_by_latent_factor primitive
//   § 11.12  recall_loading_on_factor primitive
//   § 15     Dreaming daemon rule 4 (monthly NMF rerun)

import Foundation
import IntellectusLib

public struct NMFFactorization: Sendable {
    public let W: [[Float32]]      // m × k
    public let H: [[Float32]]      // k × n
    public let rank: Int
    public let iterations: Int
    public let finalError: Float32

    public init(W: [[Float32]], H: [[Float32]],
                rank: Int, iterations: Int, finalError: Float32) {
        self.W = W
        self.H = H
        self.rank = rank
        self.iterations = iterations
        self.finalError = finalError
    }
}

public enum NMFAlternatingLeastSquares {

    /// Factorize V ≈ W × H with rank k via Lee-Seung multiplicative
    /// updates. SplitMix64-seeded initialization yields bit-identical
    /// results across cells given identical inputs.
    ///
    /// VizGraph telemetry: when monitoring is enabled, emits
    /// `VizGraphSignals.nmfFactor` with the final reconstruction error,
    /// tagged by estate, matrix dimensions, and rank. The emit is a
    /// no-op (single atomic-bool load) when monitoring is off.
    ///
    /// - Parameters:
    ///   - V: The input non-negative matrix (m × n).
    ///   - rank: Target latent rank k.
    ///   - maxIterations: Lee-Seung iteration cap.
    ///   - tolerance: Convergence tolerance on reconstruction error.
    ///   - seed: SplitMix64 seed for W/H initialisation.
    ///   - estate: Estate identifier for VizGraph telemetry.
    ///   - ts: Caller-supplied epoch seconds for telemetry.
    public static func factorize(V: [[Float32]],
                                 rank: Int,
                                 maxIterations: Int = 100,
                                 tolerance: Float32 = 1e-4,
                                 seed: UInt64 = 0xDEADBEEFCAFEBABE,
                                 estate: String = "",
                                 ts: Double = 0)
                                -> NMFFactorization {
        precondition(!V.isEmpty, "V must have at least one row")
        let m = V.count
        let n = V[0].count
        precondition(n > 0, "V must have at least one column")
        precondition(rank > 0 && rank <= min(m, n),
                     "rank must be positive and at most min(m, n)")

        // Domain preconditions: rectangular, finite, non-negative.
        // Negative or non-finite input violates the Lee-Seung theorem;
        // ragged rows corrupt the flat-storage index arithmetic below.
        for i in 0..<m {
            precondition(V[i].count == n,
                         "V is not rectangular: row 0 has \(n) columns but row \(i) has \(V[i].count)")
            for j in 0..<n {
                let v = V[i][j]
                precondition(v.isFinite, "V[\(i)][\(j)] is not finite (\(v))")
                precondition(v >= 0, "V[\(i)][\(j)] is negative (\(v)): NMF requires V ≥ 0")
            }
        }

        // Convert nested-array input V to flat [Float32] for the
        // hot loops. The matMul helpers below all operate on flat
        // row-major storage with explicit (rows, cols) dimensions;
        // this eliminates the inner-loop double bounds-check +
        // double pointer-deref that nested arrays force per cell
        // access. Loop nest order and reduction order are preserved
        // exactly so NMF conformance vector CRC 0x300bf633 remains
        // byte-identical.
        var Vflat = [Float32](repeating: 0, count: m * n)
        for i in 0..<m {
            let row = V[i]
            for j in 0..<n { Vflat[i * n + j] = row[j] }
        }

        var rng = SplitMix64(seed: seed)
        var Wflat = [Float32](repeating: 0, count: m * rank)
        for i in 0..<(m * rank) {
            Wflat[i] = Float32(rng.next() & 0xFFFF) / Float32(0xFFFF)
        }
        var Hflat = [Float32](repeating: 0, count: rank * n)
        for i in 0..<(rank * n) {
            Hflat[i] = Float32(rng.next() & 0xFFFF) / Float32(0xFFFF)
        }

        var prevError: Float32 = .greatestFiniteMagnitude
        var iterations = 0
        let eps: Float32 = 1e-9

        for it in 0..<maxIterations {
            iterations = it + 1

            // H update: H *= (Wᵀ V) / (Wᵀ W H + eps)
            let WtV  = matMulAtBFlat(Wflat, m: m, k: rank, B: Vflat, n: n)
            let WtW  = matMulAtBFlat(Wflat, m: m, k: rank, B: Wflat, n: rank)
            let WtWH = matMulFlat(WtW,  m: rank, k: rank, B: Hflat, n: n)
            for kk in 0..<rank {
                for j in 0..<n {
                    let idx = kk * n + j
                    let num = WtV[idx]
                    let den = WtWH[idx] + eps
                    var v = Hflat[idx] * num / den
                    if v < 0 { v = 0 }
                    Hflat[idx] = v
                }
            }

            // W update: W *= (V Hᵀ) / (W H Hᵀ + eps)
            let VHt  = matMulABtFlat(Vflat, m: m, k: n, B: Hflat, n: rank)
            let HHt  = matMulABtFlat(Hflat, m: rank, k: n, B: Hflat, n: rank)
            let WHHt = matMulFlat(Wflat, m: m, k: rank, B: HHt, n: rank)
            for i in 0..<m {
                for kk in 0..<rank {
                    let idx = i * rank + kk
                    let num = VHt[idx]
                    let den = WHHt[idx] + eps
                    var v = Wflat[idx] * num / den
                    if v < 0 { v = 0 }
                    Wflat[idx] = v
                }
            }

            // Convergence check
            let err = reconstructionErrorFlat(V: Vflat, W: Wflat, H: Hflat, m: m, n: n, rank: rank)
            if abs(prevError - err) < tolerance { break }
            prevError = err
        }

        let finalError = reconstructionErrorFlat(V: Vflat, W: Wflat, H: Hflat, m: m, n: n, rank: rank)

        // Convert flat back to nested for the public API.
        var W = [[Float32]](repeating: [], count: m)
        for i in 0..<m {
            var row = [Float32](repeating: 0, count: rank)
            for kk in 0..<rank { row[kk] = Wflat[i * rank + kk] }
            W[i] = row
        }
        var H = [[Float32]](repeating: [], count: rank)
        for kk in 0..<rank {
            var row = [Float32](repeating: 0, count: n)
            for j in 0..<n { row[j] = Hflat[kk * n + j] }
            H[kk] = row
        }

        let result = NMFFactorization(W: W, H: H, rank: rank,
                                      iterations: iterations, finalError: finalError)

        // VizGraph emit: nmf.factor — factorisation complete.
        // Value = final reconstruction error (how well V ≈ W × H).
        // The Topology theme-overlay layer uses the factor matrices W and H
        // to assign latent-theme colours to nodes; this signal fires once
        // the matrices are ready for that rendering pass.
        //
        // Off-path when monitoring is disabled: single Atomic<Bool> load
        // + branch. No arithmetic in the autoclosure unless monitoring is on.
        Intellectus.report(.metric(
            name: VizGraphSignals.nmfFactor,
            value: Double(result.finalError),
            tags: [
                "estate": estate,
                "rows": "\(m)",
                "cols": "\(n)",
                "rank": "\(rank)",
            ],
            ts: ts
        ))

        return result
    }

    /// Public reconstruction-error API on nested arrays. Keeps the
    /// existing callsite signature; converts to flat internally.
    public static func reconstructionError(V: [[Float32]],
                                           W: [[Float32]],
                                           H: [[Float32]]) -> Float32 {
        let m = V.count
        let n = V[0].count
        let rank = W[0].count
        var Vflat = [Float32](repeating: 0, count: m * n)
        for i in 0..<m {
            let row = V[i]
            for j in 0..<n { Vflat[i * n + j] = row[j] }
        }
        var Wflat = [Float32](repeating: 0, count: m * rank)
        for i in 0..<m {
            let row = W[i]
            for kk in 0..<rank { Wflat[i * rank + kk] = row[kk] }
        }
        var Hflat = [Float32](repeating: 0, count: rank * n)
        for kk in 0..<rank {
            let row = H[kk]
            for j in 0..<n { Hflat[kk * n + j] = row[j] }
        }
        return reconstructionErrorFlat(V: Vflat, W: Wflat, H: Hflat, m: m, n: n, rank: rank)
    }

    /// Reconstruction error against flat-storage W and H, computing
    /// R = W × H on the fly. Loop nest matches the original nested-
    /// array implementation; reduction order is preserved.
    static func reconstructionErrorFlat(V: [Float32], W: [Float32], H: [Float32],
                                        m: Int, n: Int, rank: Int) -> Float32 {
        let R = matMulFlat(W, m: m, k: rank, B: H, n: n)
        var err: Float32 = 0
        for i in 0..<m {
            for j in 0..<n {
                let idx = i * n + j
                let d = V[idx] - R[idx]
                err += d * d
            }
        }
        return (err / Float32(m * n)).squareRoot()
    }

    // ----- Flat-storage matrix helpers. -----
    //
    // All three helpers preserve the EXACT loop nest order of the
    // original nested-array versions so per-cell accumulation order
    // matches, and Float32 lowest-bit rounding stays identical.
    // The change is purely the storage layout: flat [Float32]
    // with explicit (rows × cols) instead of [[Float32]].

    /// C = A × B; A is m×k, B is k×n, result is m×n (flat row-major).
    static func matMulFlat(_ A: [Float32], m: Int, k: Int, B: [Float32], n: Int) -> [Float32] {
        var C = [Float32](repeating: 0, count: m * n)
        for i in 0..<m {
            for kk in 0..<k {
                let aik = A[i * k + kk]
                for j in 0..<n {
                    C[i * n + j] += aik * B[kk * n + j]
                }
            }
        }
        return C
    }

    /// C = Aᵀ × B; A is m×k stored row-major, B is m×n stored row-major,
    /// result C is k×n stored row-major.
    static func matMulAtBFlat(_ A: [Float32], m: Int, k: Int, B: [Float32], n: Int) -> [Float32] {
        var C = [Float32](repeating: 0, count: k * n)
        for i in 0..<m {
            for kk in 0..<k {
                let aik = A[i * k + kk]
                for j in 0..<n {
                    C[kk * n + j] += aik * B[i * n + j]
                }
            }
        }
        return C
    }

    /// C = A × Bᵀ; A is m×k, B is n×k (both row-major), result C is m×n.
    static func matMulABtFlat(_ A: [Float32], m: Int, k: Int, B: [Float32], n: Int) -> [Float32] {
        var C = [Float32](repeating: 0, count: m * n)
        for i in 0..<m {
            for j in 0..<n {
                var sum: Float32 = 0
                for kk in 0..<k {
                    sum += A[i * k + kk] * B[j * k + kk]
                }
                C[i * n + j] = sum
            }
        }
        return C
    }

    // ----- Original nested-array helpers (preserved for callers
    //       outside factorize() that still use [[Float32]]). -----

    /// C = A × B; A is m×k, B is k×n, result is m×n.
    static func matMul(_ A: [[Float32]], _ B: [[Float32]]) -> [[Float32]] {
        let m = A.count
        let kDim = A[0].count
        let n = B[0].count
        var C = Array(repeating: Array(repeating: Float32(0), count: n), count: m)
        for i in 0..<m {
            for k in 0..<kDim {
                let aik = A[i][k]
                for j in 0..<n {
                    C[i][j] += aik * B[k][j]
                }
            }
        }
        return C
    }

    /// C = Aᵀ × B; A is m×k, B is m×n, result is k×n.
    static func matMulAtB(_ A: [[Float32]], _ B: [[Float32]]) -> [[Float32]] {
        let m = A.count
        let kDim = A[0].count
        let n = B[0].count
        precondition(B.count == m)
        var C = Array(repeating: Array(repeating: Float32(0), count: n), count: kDim)
        for i in 0..<m {
            for k in 0..<kDim {
                let aik = A[i][k]
                for j in 0..<n {
                    C[k][j] += aik * B[i][j]
                }
            }
        }
        return C
    }

    /// C = A × Bᵀ; A is m×k, B is n×k, result is m×n.
    static func matMulABt(_ A: [[Float32]], _ B: [[Float32]]) -> [[Float32]] {
        let m = A.count
        let kDim = A[0].count
        let n = B.count
        precondition(B[0].count == kDim)
        var C = Array(repeating: Array(repeating: Float32(0), count: n), count: m)
        for i in 0..<m {
            for j in 0..<n {
                var sum: Float32 = 0
                for k in 0..<kDim {
                    sum += A[i][k] * B[j][k]
                }
                C[i][j] = sum
            }
        }
        return C
    }
}
