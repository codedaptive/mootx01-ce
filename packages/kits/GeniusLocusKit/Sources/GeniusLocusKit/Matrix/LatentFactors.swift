// LatentFactors.swift
//
// Mission GLK-06 — NMF (non-negative matrix factorization) over the
// co-occurrence matrix O.
//
// Mathematical reference: substrate mathematics §8 and cookbook §6.9.
// O is decomposed into W (rows × K) and H (K × rows) with W, H ≥ 0
// such that O ≈ W·H. The multiplicative-update rule is:
//
//   H ← H ⊙ (Wᵀ·O) / (Wᵀ·W·H + ε)
//   W ← W ⊙ (O·Hᵀ) / (W·H·Hᵀ + ε)
//
// Latent-factor recomputation is the out-of-band part of the matrix
// pipeline: the GLK-07 training daemon's per-tick fold updates F / O
// incrementally, and a periodic refactorize pass (cookbook §6.9 calls
// for weekly) re-derives W and H. Callers reach refactorize through
// `EnrichmentPipeline.refactorize(oDense:rows:cols:k:seed:)`. We cache
// only the loadings for the rows the substrate flags as interesting
// (top-scoring per latent factor).
//
// Implementation note. The cookbook describes O over (field-i, value-i,
// field-j, value-j); the factorization works on the indexed sparse
// matrix view. Here we accept any explicit dense or sparse input shape
// and run the multiplicative updates over Double-precision dense
// scratch buffers — the matrices are small (≤ a few thousand cells in
// practice), and the dense scratch is faster than a sparse multiply
// for K ≤ 20. The conformance-test vectors compare against the same
// dense reference in the Rust port.

import Foundation

// MARK: - Result

/// Output of one NMF factorization pass.
public struct MatrixNMFFactorization: Sendable, Equatable, Codable {
    /// W matrix in row-major dense layout. Shape: `rows × k`.
    public let w: [Double]
    /// H matrix in row-major dense layout. Shape: `k × cols`.
    public let h: [Double]
    public let rows: Int
    public let cols: Int
    public let k: Int

    /// Final reconstruction error `||O - W·H||²` (Frobenius²).
    public let reconstructionError: Double

    public init(w: [Double],
                h: [Double],
                rows: Int,
                cols: Int,
                k: Int,
                reconstructionError: Double) {
        self.w = w
        self.h = h
        self.rows = rows
        self.cols = cols
        self.k = k
        self.reconstructionError = reconstructionError
    }

    /// Loading for one row: the K-dimensional latent factor vector.
    public func loadings(forRow row: Int) -> [Double] {
        precondition((0..<rows).contains(row), "row out of range")
        var out = [Double](repeating: 0, count: k)
        for j in 0..<k {
            out[j] = w[row * k + j]
        }
        return out
    }
}

// MARK: - NMF

public enum MatrixNMF {

    /// Default convergence iteration cap. Cookbook §6.9 says "until
    /// reconstruction error < tol"; the cap keeps the worst case
    /// bounded.
    public static let defaultMaxIterations: Int = 100

    /// Default convergence tolerance on `||O - W·H||²`.
    public static let defaultTolerance: Double = 1e-6

    /// Numeric epsilon to keep the multiplicative updates non-singular
    /// when a denominator approaches zero. The cookbook's ε.
    private static let epsilon: Double = 1e-9

    /// Run the multiplicative-update NMF on a dense `rows × cols`
    /// row-major matrix `o`. `k` is the number of latent factors.
    /// `seed` controls the deterministic initial fill so two replicas
    /// running on the same input matrix produce bit-identical
    /// factorizations.
    public static func factorize(
        o: [Double],
        rows: Int,
        cols: Int,
        k: Int,
        seed: UInt64 = 0xC0FFEE_BABE_BEEF,
        maxIterations: Int = defaultMaxIterations,
        tolerance: Double = defaultTolerance
    ) -> MatrixNMFFactorization {
        precondition(o.count == rows * cols, "o shape mismatch")
        precondition(k > 0, "k must be positive")

        var rng = SplitMix64(state: seed)
        var w = [Double](repeating: 0, count: rows * k)
        var h = [Double](repeating: 0, count: k * cols)
        for i in 0..<w.count {
            w[i] = rng.nextUnitNonNeg()
        }
        for i in 0..<h.count {
            h[i] = rng.nextUnitNonNeg()
        }

        var lastError = Double.infinity

        for _ in 0..<maxIterations {
            // H ← H ⊙ (Wᵀ·O) / (Wᵀ·W·H + ε)
            let wT_o = matMulTransposeLeft(w, rows, k, o, rows, cols)        // k × cols
            let wT_w = matMulTransposeLeft(w, rows, k, w, rows, k)            // k × k
            let wT_w_h = matMul(wT_w, k, k, h, k, cols)                       // k × cols
            for i in 0..<h.count {
                h[i] = h[i] * wT_o[i] / (wT_w_h[i] + epsilon)
            }

            // W ← W ⊙ (O·Hᵀ) / (W·H·Hᵀ + ε)
            let o_hT = matMulTransposeRight(o, rows, cols, h, k, cols)        // rows × k
            let h_hT = matMulTransposeRight(h, k, cols, h, k, cols)           // k × k
            let w_h_hT = matMul(w, rows, k, h_hT, k, k)                       // rows × k
            for i in 0..<w.count {
                w[i] = w[i] * o_hT[i] / (w_h_hT[i] + epsilon)
            }

            let err = frobeniusErrorSquared(
                o: o, rows: rows, cols: cols,
                w: w, h: h, k: k
            )
            if abs(lastError - err) < tolerance { lastError = err; break }
            lastError = err
        }

        return MatrixNMFFactorization(
            w: w, h: h,
            rows: rows, cols: cols, k: k,
            reconstructionError: lastError
        )
    }

    // MARK: - Dense linear-algebra helpers

    /// Multiply: `(aT)·b` where `a` is `arows × acols` row-major and
    /// `b` is `arows × bcols` row-major. Result is `acols × bcols`.
    private static func matMulTransposeLeft(
        _ a: [Double], _ arows: Int, _ acols: Int,
        _ b: [Double], _ brows: Int, _ bcols: Int
    ) -> [Double] {
        precondition(arows == brows, "matMulTransposeLeft inner-dim mismatch")
        var out = [Double](repeating: 0, count: acols * bcols)
        for i in 0..<acols {
            for j in 0..<bcols {
                var sum = 0.0
                for r in 0..<arows {
                    sum += a[r * acols + i] * b[r * bcols + j]
                }
                out[i * bcols + j] = sum
            }
        }
        return out
    }

    /// Multiply: `a·(bT)` where `a` is `arows × acols` row-major and
    /// `b` is `brows × acols` row-major. Result is `arows × brows`.
    private static func matMulTransposeRight(
        _ a: [Double], _ arows: Int, _ acols: Int,
        _ b: [Double], _ brows: Int, _ bcols: Int
    ) -> [Double] {
        precondition(acols == bcols, "matMulTransposeRight inner-dim mismatch")
        var out = [Double](repeating: 0, count: arows * brows)
        for i in 0..<arows {
            for j in 0..<brows {
                var sum = 0.0
                for c in 0..<acols {
                    sum += a[i * acols + c] * b[j * bcols + c]
                }
                out[i * brows + j] = sum
            }
        }
        return out
    }

    /// Multiply: `a·b`. `a` is `arows × acols`; `b` is `brows × bcols`.
    /// `acols` must equal `brows`. Result is `arows × bcols`.
    private static func matMul(
        _ a: [Double], _ arows: Int, _ acols: Int,
        _ b: [Double], _ brows: Int, _ bcols: Int
    ) -> [Double] {
        precondition(acols == brows, "matMul inner-dim mismatch")
        var out = [Double](repeating: 0, count: arows * bcols)
        for i in 0..<arows {
            for j in 0..<bcols {
                var sum = 0.0
                for c in 0..<acols {
                    sum += a[i * acols + c] * b[c * bcols + j]
                }
                out[i * bcols + j] = sum
            }
        }
        return out
    }

    /// Frobenius² reconstruction error `Σ(o - w·h)²`.
    private static func frobeniusErrorSquared(
        o: [Double], rows: Int, cols: Int,
        w: [Double], h: [Double], k: Int
    ) -> Double {
        var err = 0.0
        for i in 0..<rows {
            for j in 0..<cols {
                var prod = 0.0
                for kk in 0..<k {
                    prod += w[i * k + kk] * h[kk * cols + j]
                }
                let d = o[i * cols + j] - prod
                err += d * d
            }
        }
        return err
    }
}

// MARK: - Deterministic seedable RNG

/// SplitMix64 — a small fast deterministic PRNG used to seed NMF.
/// Pure value type so two replicas with the same seed produce
/// identical W and H initial fills, which keeps the factorization
/// bit-identical across the Swift / Rust conformance gate.
fileprivate struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Next non-negative double in `[ε, 1)`. The lower clamp prevents
    /// an exact-zero initial cell from sticking at zero under the
    /// multiplicative update.
    mutating func nextUnitNonNeg() -> Double {
        let bits = next() >> 11                       // top 53 bits
        let raw = Double(bits) / Double(1 << 53)
        // Floor to a small positive ε so multiplicative updates can
        // climb away from zero.
        return max(raw, 1e-3)
    }
}
