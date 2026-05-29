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
// Used by:
//   § 6.9    NMF definition (this file)
//   § 8.9    NMF over F matrix (latent themes)
//   § 11.11  recall_by_latent_factor primitive
//   § 11.12  recall_loading_on_factor primitive
//   § 15     Dreaming daemon rule 4 (monthly NMF rerun)

import Foundation

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
    public static func factorize(V: [[Float32]],
                                 rank: Int,
                                 maxIterations: Int = 100,
                                 tolerance: Float32 = 1e-4,
                                 seed: UInt64 = 0xDEADBEEFCAFEBABE)
                                -> NMFFactorization {
        precondition(!V.isEmpty, "V must have at least one row")
        let m = V.count
        let n = V[0].count
        precondition(n > 0, "V must have at least one column")
        precondition(rank > 0 && rank <= min(m, n),
                     "rank must be positive and at most min(m, n)")

        var rng = SplitMix64(seed: seed)
        var W = (0..<m).map { _ in
            (0..<rank).map { _ -> Float32 in
                Float32(rng.next() & 0xFFFF) / Float32(0xFFFF)
            }
        }
        var H = (0..<rank).map { _ in
            (0..<n).map { _ -> Float32 in
                Float32(rng.next() & 0xFFFF) / Float32(0xFFFF)
            }
        }

        var prevError: Float32 = .greatestFiniteMagnitude
        var iterations = 0
        let eps: Float32 = 1e-9

        for it in 0..<maxIterations {
            iterations = it + 1

            // H update: H *= (Wᵀ V) / (Wᵀ W H + eps)
            let WtV = matMulAtB(W, V)
            let WtW = matMulAtB(W, W)
            let WtWH = matMul(WtW, H)
            for k in 0..<rank {
                for j in 0..<n {
                    let num = WtV[k][j]
                    let den = WtWH[k][j] + eps
                    var v = H[k][j] * num / den
                    if v < 0 { v = 0 }
                    H[k][j] = v
                }
            }

            // W update: W *= (V Hᵀ) / (W H Hᵀ + eps)
            let VHt = matMulABt(V, H)
            let HHt = matMulABt(H, H)
            let WHHt = matMul(W, HHt)
            for i in 0..<m {
                for k in 0..<rank {
                    let num = VHt[i][k]
                    let den = WHHt[i][k] + eps
                    var v = W[i][k] * num / den
                    if v < 0 { v = 0 }
                    W[i][k] = v
                }
            }

            // Convergence check
            let err = reconstructionError(V: V, W: W, H: H)
            if abs(prevError - err) < tolerance { break }
            prevError = err
        }

        let finalError = reconstructionError(V: V, W: W, H: H)
        return NMFFactorization(W: W, H: H, rank: rank,
                                iterations: iterations, finalError: finalError)
    }

    public static func reconstructionError(V: [[Float32]],
                                           W: [[Float32]],
                                           H: [[Float32]]) -> Float32 {
        let m = V.count
        let n = V[0].count
        let R = matMul(W, H)
        var err: Float32 = 0
        for i in 0..<m {
            for j in 0..<n {
                let d = V[i][j] - R[i][j]
                err += d * d
            }
        }
        return (err / Float32(m * n)).squareRoot()
    }

    // ----- Dense matrix helpers (m×k × k×n etc.) -----

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
