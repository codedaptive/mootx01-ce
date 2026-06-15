// NMFDoubleFrobeniusSquared.swift
//
// Double-precision NMF with Frobenius-squared (||O - WH||_F^2) convergence
// criterion and floored initialization.
//
// !! PRODUCTION GATE — NOT FOR PRODUCTION USE !!
//
// This variant is preserved in the substrate for honest benchmarking against
// the canonical f32/RMS `NMFAlternatingLeastSquares`. It captures the exact
// algorithm that existed in GeniusLocusKit prior to the 2026-06-13 delegation
// to the canonical substrate primitive (Bob's ruling 2026-06-13).
//
// DO NOT WIRE ANY PRODUCTION CONSUMER TO THIS VARIANT.
// It must pass `docs/validation/substrate_math_performance/` benchmarking
// (iteration count to convergence, wall-time, memory, recall-quality impact)
// against `NMFAlternatingLeastSquares` before any consumer may use it.
//
// The pending benchmark task is tracked in the substrate math performance
// backlog. Any SIMD, Metal, or BLAS acceleration for this f64 variant also
// carries FMA-divergence risk and is itself subject to perf-eval-before-
// production (the scalar cross-port is the gated floor; do NOT ship
// vectorised paths for this variant without separate benchmarking).
//
// CORRECTNESS CONFORMANCE: Despite the production gate, this implementation
// is conformance-gated: the scalar Swift path and the scalar Rust path must
// produce bit-identical output given identical inputs. Cross-port
// conformance vector: `nmf_double_frobenius_squared.json` (canonical seed
// 0xCAFEBABEDEADBEEF, but note this variant uses its own seed default
// 0xC0FFEE_BABE_BEEF per the original GLK definition).
//
// Algorithm:
//   Multiplicative Lee-Seung updates, f64 arithmetic.
//   Convergence: |lastError - err| < tolerance (Frobenius² delta, not RMS).
//   Init: SplitMix64 with floor `max(raw, 1e-3)` on every cell.
//   ε: 1e-9 added to denominators.
//
// Spec cross-reference: SUBSTRATEML_SPEC.md § 5.4b
//
// Used by: nobody in production — see gate above.

import Foundation

// MARK: - Result

/// Output of one `NMFDoubleFrobeniusSquared` factorization pass.
///
/// All factor matrices are `Double` precision, matching the
/// double-precision algorithm. The reconstruction error is the
/// raw Frobenius² value `||O - W·H||_F^2`, NOT the normalized RMS.
///
/// NOTE: This is the parked f64 variant. For production use, see
/// `NMFFactorization` (the result type of `NMFAlternatingLeastSquares`)
/// which uses `Float32` and RMS error.
public struct NMFDoubleFrobeniusSquaredFactorization: Sendable, Equatable, Codable {

    /// W matrix in row-major dense layout. Shape: `rows × rank`.
    /// `Double` precision — this is the f64 variant.
    public let w: [Double]

    /// H matrix in row-major dense layout. Shape: `rank × cols`.
    /// `Double` precision — this is the f64 variant.
    public let h: [Double]

    public let rows: Int
    public let cols: Int
    public let rank: Int

    /// Reconstruction error `||O - W·H||_F^2` (raw Frobenius squared).
    /// This is NOT the normalized RMS used by `NMFAlternatingLeastSquares`.
    public let reconstructionError: Double

    /// Number of multiplicative-update iterations executed.
    public let iterations: Int

    public init(w: [Double],
                h: [Double],
                rows: Int,
                cols: Int,
                rank: Int,
                reconstructionError: Double,
                iterations: Int) {
        self.w = w
        self.h = h
        self.rows = rows
        self.cols = cols
        self.rank = rank
        self.reconstructionError = reconstructionError
        self.iterations = iterations
    }

    /// Loading for one row: the rank-dimensional latent factor vector.
    /// Returns the row of W corresponding to `row`.
    public func loadings(forRow row: Int) -> [Double] {
        precondition((0..<rows).contains(row), "row out of range")
        return (0..<rank).map { j in w[row * rank + j] }
    }
}

// MARK: - Engine

/// Double-precision NMF using Frobenius-squared convergence criterion.
///
/// !! PRODUCTION GATE — NOT FOR PRODUCTION USE !!
///
/// This is the parked f64/Frobenius² variant lifted verbatim from
/// GeniusLocusKit's prior `MatrixNMF` implementation (present before the
/// 2026-06-13 delegation to the canonical substrate f32 NMF per Bob's ruling).
/// It is preserved here so a future benchmark can compare the two approaches
/// honestly: the REAL f64 Frobenius² algorithm versus the canonical f32 RMS
/// algorithm. Benchmark before using in production.
///
/// For all production use, call `NMFAlternatingLeastSquares.factorize` instead.
public enum NMFDoubleFrobeniusSquared {

    /// Default convergence iteration cap. Matches the original GLK default.
    public static let defaultMaxIterations: Int = 100

    /// Convergence tolerance on the Frobenius² delta `|lastError - err|`.
    /// Note: this is NOT the same convergence criterion as `NMFAlternatingLeastSquares`,
    /// which converges on RMS error delta. The different criterion is part of
    /// what the benchmark must evaluate.
    public static let defaultTolerance: Double = 1e-6

    /// Numeric epsilon added to multiplicative-update denominators to
    /// prevent division by zero when a denominator approaches zero.
    private static let epsilon: Double = 1e-9

    /// Run the double-precision multiplicative-update NMF.
    ///
    /// !! PRODUCTION GATE — NOT FOR PRODUCTION USE !!
    ///
    /// Factorize a dense `rows × cols` row-major non-negative matrix `o`
    /// into W (`rows × rank`) and H (`rank × cols`) such that `o ≈ W·H`,
    /// `W ≥ 0`, `H ≥ 0`.
    ///
    /// The `seed` controls the deterministic SplitMix64 initial fill; two
    /// replicas running on the same input with the same seed produce
    /// bit-identical factorizations.
    ///
    /// The canonical production variant is `NMFAlternatingLeastSquares.factorize`.
    /// Do not use this variant in production until it has passed substrate
    /// math performance benchmarking.
    ///
    /// - Parameters:
    ///   - o: The input non-negative matrix, dense row-major, `rows × cols`.
    ///   - rows: Row count of `o`.
    ///   - cols: Column count of `o`.
    ///   - rank: Target latent rank k.
    ///   - seed: SplitMix64 seed for deterministic W/H initialization.
    ///     Default is `0xC0FFEE_BABE_BEEF` — the original GLK seed.
    ///   - maxIterations: Multiplicative-update iteration cap.
    ///   - tolerance: Convergence threshold on `|lastError - err|` (Frobenius²).
    public static func factorize(
        o: [Double],
        rows: Int,
        cols: Int,
        rank: Int,
        seed: UInt64 = 0xC0FFEE_BABE_BEEF,
        maxIterations: Int = defaultMaxIterations,
        tolerance: Double = defaultTolerance
    ) -> NMFDoubleFrobeniusSquaredFactorization {
        precondition(o.count == rows * cols, "o shape mismatch: expected \(rows * cols) elements, got \(o.count)")
        precondition(rank > 0, "rank must be positive")
        precondition(rows > 0, "rows must be positive")
        precondition(cols > 0, "cols must be positive")

        // SplitMix64 with floored init: max(raw, 1e-3). The floor prevents
        // exact-zero initial cells from sticking at zero under the
        // multiplicative update. This is the original GLK initialization —
        // distinct from NMFAlternatingLeastSquares (which uses the 16-low-bit
        // PRNG with no floor). The floor is part of what makes this variant
        // algorithmically distinct from the canonical f32 path.
        var rng = NMFDoubleFrobeniusSquaredRNG(state: seed)
        var w = (0..<rows * rank).map { _ in rng.nextUnitNonNeg() }
        var h = (0..<rank * cols).map { _ in rng.nextUnitNonNeg() }

        var lastError = Double.infinity
        var iterations = 0

        for it in 0..<maxIterations {
            iterations = it + 1

            // H ← H ⊙ (Wᵀ·O) / (Wᵀ·W·H + ε)
            let wtO   = matMulTransposeLeft(w, rows, rank, o,   rows, cols)   // rank × cols
            let wtW   = matMulTransposeLeft(w, rows, rank, w,   rows, rank)   // rank × rank
            let wtWH  = matMul(wtW, rank, rank, h, rank, cols)                 // rank × cols
            for i in 0..<h.count {
                h[i] = h[i] * wtO[i] / (wtWH[i] + epsilon)
            }

            // W ← W ⊙ (O·Hᵀ) / (W·H·Hᵀ + ε)
            let oHt   = matMulTransposeRight(o, rows, cols, h, rank, cols)    // rows × rank
            let hHt   = matMulTransposeRight(h, rank, cols, h, rank, cols)    // rank × rank
            let wHHt  = matMul(w, rows, rank, hHt, rank, rank)                // rows × rank
            for i in 0..<w.count {
                w[i] = w[i] * oHt[i] / (wHHt[i] + epsilon)
            }

            // Convergence check: Frobenius² delta (NOT RMS).
            let err = frobeniusSquared(o: o, rows: rows, cols: cols, w: w, h: h, rank: rank)
            if abs(lastError - err) < tolerance { lastError = err; break }
            lastError = err
        }

        return NMFDoubleFrobeniusSquaredFactorization(
            w: w, h: h,
            rows: rows, cols: cols, rank: rank,
            reconstructionError: lastError,
            iterations: iterations
        )
    }

    // MARK: - Dense linear-algebra helpers (scalar f64)

    /// C = Aᵀ · B; A is `arows × acols`, B is `arows × bcols`. Result is `acols × bcols`.
    private static func matMulTransposeLeft(
        _ a: [Double], _ arows: Int, _ acols: Int,
        _ b: [Double], _ brows: Int, _ bcols: Int
    ) -> [Double] {
        precondition(arows == brows, "matMulTransposeLeft: inner-dim mismatch")
        var out = [Double](repeating: 0, count: acols * bcols)
        for i in 0..<acols {
            for j in 0..<bcols {
                var sum = 0.0
                for r in 0..<arows { sum += a[r * acols + i] * b[r * bcols + j] }
                out[i * bcols + j] = sum
            }
        }
        return out
    }

    /// C = A · Bᵀ; A is `arows × acols`, B is `brows × acols`. Result is `arows × brows`.
    private static func matMulTransposeRight(
        _ a: [Double], _ arows: Int, _ acols: Int,
        _ b: [Double], _ brows: Int, _ bcols: Int
    ) -> [Double] {
        precondition(acols == bcols, "matMulTransposeRight: inner-dim mismatch")
        var out = [Double](repeating: 0, count: arows * brows)
        for i in 0..<arows {
            for j in 0..<brows {
                var sum = 0.0
                for c in 0..<acols { sum += a[i * acols + c] * b[j * bcols + c] }
                out[i * brows + j] = sum
            }
        }
        return out
    }

    /// C = A · B; A is `arows × acols`, B is `brows × bcols`. `acols` must equal `brows`.
    private static func matMul(
        _ a: [Double], _ arows: Int, _ acols: Int,
        _ b: [Double], _ brows: Int, _ bcols: Int
    ) -> [Double] {
        precondition(acols == brows, "matMul: inner-dim mismatch")
        var out = [Double](repeating: 0, count: arows * bcols)
        for i in 0..<arows {
            for j in 0..<bcols {
                var sum = 0.0
                for c in 0..<acols { sum += a[i * acols + c] * b[c * bcols + j] }
                out[i * bcols + j] = sum
            }
        }
        return out
    }

    /// Frobenius² reconstruction error `Σ (o_ij - (W·H)_ij)²`.
    ///
    /// This is the RAW Frobenius squared, not normalized by m·n and not
    /// square-rooted. It is the convergence criterion for this variant.
    /// `NMFAlternatingLeastSquares` uses `sqrt(Σ d² / (m·n))` (RMS) instead.
    static func frobeniusSquared(
        o: [Double], rows: Int, cols: Int,
        w: [Double], h: [Double], rank: Int
    ) -> Double {
        var err = 0.0
        for i in 0..<rows {
            for j in 0..<cols {
                var prod = 0.0
                for k in 0..<rank { prod += w[i * rank + k] * h[k * cols + j] }
                let d = o[i * cols + j] - prod
                err += d * d
            }
        }
        return err
    }
}

// MARK: - Deterministic RNG

/// SplitMix64 seeded PRNG for `NMFDoubleFrobeniusSquared`.
///
/// This is the initialization RNG of the original GLK f64 NMF: the 53
/// high bits of each SplitMix64 output are divided by 2^53, then floored
/// to 1e-3 so no initial cell is exactly zero (multiplicative updates
/// cannot recover from a zero cell). This is algorithmically different
/// from the substrate canonical `SplitMix64` used by
/// `NMFAlternatingLeastSquares` (which uses 16 low bits and no floor).
///
/// The PRNG constants are identical to SubstrateML's `RandomWalks.SplitMix64`
/// — only the output transformation differs. Cross-port bit-identity with the
/// Rust `NMFDoubleFrobeniusSquaredRNG` is enforced by the conformance harness.
struct NMFDoubleFrobeniusSquaredRNG {
    var state: UInt64

    /// Advance the PRNG and return the next u64.
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Next non-negative double in `[1e-3, 1)`. Uses top 53 bits of the
    /// SplitMix64 output, scaled to [0, 1), then floored to 1e-3.
    /// The floor prevents exact-zero initial cells from sticking at zero
    /// under the multiplicative update.
    mutating func nextUnitNonNeg() -> Double {
        let bits = next() >> 11                        // top 53 bits
        let raw = Double(bits) / Double(1 << 53)
        return max(raw, 1e-3)
    }
}
