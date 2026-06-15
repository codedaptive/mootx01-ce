// LatentFactors.swift
//
// GLK matrix-tier NMF — delegates to the canonical substrate primitive
// `NMFAlternatingLeastSquares` (SubstrateML). The substrate owns the
// algorithm; GLK owns the estate-tier wiring.
//
// Mathematical reference: substrate mathematics §8 and cookbook §6.9.
// O is decomposed into W (rows × K) and H (K × rows) with W, H ≥ 0
// such that O ≈ W·H. The multiplicative-update rule is:
//
//   H ← H ⊙ (Wᵀ·V) / (Wᵀ·W·H + ε)
//   W ← W ⊙ (V·Hᵀ) / (W·H·Hᵀ + ε)
//
// The substrate runs Lee-Seung multiplicative updates over Float32 and
// reports RMS reconstruction error `sqrt(||V - W·H||² / (m·n))`.
//
// Latent-factor recomputation is the out-of-band part of the matrix
// pipeline: the GLK-07 training daemon's per-tick fold updates F / O
// incrementally, and a periodic refactorize pass (cookbook §6.9 calls
// for weekly) re-derives W and H. Callers reach refactorize through
// `EnrichmentPipeline.refactorize(oDense:rows:cols:k:seed:)`.
//
// Type note: `MatrixNMFFactorization` holds Float32 factors (from the
// substrate f32 canonical path). The public `factorize` entry point
// accepts `[Double]` for backward compatibility with existing callers
// (e.g. NeuronKit.latentThemes), converting internally. Callers that
// inspect numeric results will observe f32-precision values.

import Foundation
import SubstrateML

// MARK: - Result

/// Output of one NMF factorization pass over the GLK co-occurrence matrix.
///
/// Factor matrices hold Float32 values, which is the precision of the
/// substrate canonical `NMFAlternatingLeastSquares`. Reconstruction error
/// is the RMS metric: `sqrt(||O - W·H||² / (m·n))`.
public struct MatrixNMFFactorization: Sendable, Equatable, Codable {

    /// W matrix in row-major dense layout. Shape: `rows × k`. Float32.
    public let w: [Float32]

    /// H matrix in row-major dense layout. Shape: `k × cols`. Float32.
    public let h: [Float32]

    public let rows: Int
    public let cols: Int
    public let k: Int

    /// Final RMS reconstruction error `sqrt(||O - W·H||² / (rows·cols))`.
    /// This is the substrate canonical error metric (normalized RMS), distinct
    /// from the raw Frobenius² metric of the parked f64 variant.
    public let reconstructionError: Float32

    public init(w: [Float32],
                h: [Float32],
                rows: Int,
                cols: Int,
                k: Int,
                reconstructionError: Float32) {
        self.w = w
        self.h = h
        self.rows = rows
        self.cols = cols
        self.k = k
        self.reconstructionError = reconstructionError
    }

    /// Loading for one row: the K-dimensional latent factor vector (Float32).
    public func loadings(forRow row: Int) -> [Float32] {
        precondition((0..<rows).contains(row), "row out of range")
        return (0..<k).map { j in w[row * k + j] }
    }
}

// MARK: - NMF

public enum MatrixNMF {

    /// Default convergence iteration cap. Matches the substrate canonical default.
    public static let defaultMaxIterations: Int = 100

    /// Default convergence tolerance on RMS reconstruction error delta.
    /// Matches the substrate canonical default (1e-4 RMS delta).
    public static let defaultTolerance: Float32 = 1e-4

    /// Run the canonical substrate NMF (Float32, RMS error) over a dense
    /// `rows × cols` row-major matrix `o`. `k` is the number of latent factors.
    ///
    /// `o` is accepted as `[Double]` for compatibility with callers that build
    /// the co-occurrence matrix in f64 precision (e.g. NeuronKit label
    /// co-occurrence). Values are converted to Float32 before factorization.
    ///
    /// `seed` controls the deterministic SplitMix64 initial fill in the
    /// substrate. Two replicas running on the same input produce bit-identical
    /// factorizations.
    ///
    /// The substrate uses `NMFAlternatingLeastSquares` (f32, RMS error,
    /// cookbook §6.9 / §8.9). The parked f64/Frobenius² algorithm is available
    /// in SubstrateML as `NMFDoubleFrobeniusSquared` (NOT for production; see
    /// its spec entry § 5.4b for the performance-gate contract).
    public static func factorize(
        o: [Double],
        rows: Int,
        cols: Int,
        k: Int,
        seed: UInt64 = 0xDEADBEEFCAFEBABE,
        maxIterations: Int = defaultMaxIterations,
        tolerance: Float32 = defaultTolerance
    ) -> MatrixNMFFactorization {
        precondition(o.count == rows * cols, "o shape mismatch")
        precondition(k > 0, "k must be positive")

        // Convert flat [Double] row-major to [[Float32]] for the substrate.
        // The substrate entry point takes nested rows; we build them here.
        let V: [[Float32]] = (0..<rows).map { row in
            (0..<cols).map { col in Float32(o[row * cols + col]) }
        }

        let result = NMFAlternatingLeastSquares.factorize(
            V: V,
            rank: k,
            maxIterations: maxIterations,
            tolerance: tolerance,
            seed: seed
        )

        // Flatten substrate's nested-array W and H to flat row-major.
        let wFlat = result.W.flatMap { $0 }
        let hFlat = result.H.flatMap { $0 }

        return MatrixNMFFactorization(
            w: wFlat,
            h: hFlat,
            rows: rows,
            cols: cols,
            k: k,
            reconstructionError: result.finalError
        )
    }
}
