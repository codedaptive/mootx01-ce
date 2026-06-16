// nmf_double_frobenius_squared.rs
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
// backlog. Any SIMD, BLAS, or NEON acceleration for this f64 variant also
// carries FMA-divergence risk and is itself subject to perf-eval-before-
// production (the scalar cross-port is the gated floor; do NOT ship
// vectorised paths for this variant without separate benchmarking).
//
// CORRECTNESS CONFORMANCE: Despite the production gate, this implementation
// is conformance-gated: the scalar Swift path and this scalar Rust path must
// produce bit-identical output given identical inputs. Cross-port conformance
// vector: `nmf_double_frobenius_squared.json`.
//
// Algorithm:
//   Multiplicative Lee-Seung updates, f64 arithmetic.
//   Convergence: |last_error - err| < tolerance (Frobenius² delta, not RMS).
//   Init: SplitMix64 top-53-bit draw, floored to 1e-3 on every cell.
//   ε: 1e-9 added to denominators.
//
// Spec cross-reference: SUBSTRATEML_SPEC.md § 5.4b
//
// Used by: nobody in production — see gate above.

const EPSILON: f64 = 1e-9;

/// Output of one `NMFDoubleFrobeniusSquared::factorize` pass.
///
/// All factor matrices are f64, matching the double-precision algorithm.
/// The reconstruction error is the raw Frobenius² value `||O - W·H||_F^2`,
/// NOT the normalized RMS.
///
/// NOTE: This is the parked f64 variant. For production use, see
/// `NMFFactorization` (the result type of `NMFAlternatingLeastSquares`)
/// which uses f32 and RMS error.
#[derive(Clone, Debug, PartialEq)]
pub struct NMFDoubleFrobeniusSquaredFactorization {
    /// W matrix, row-major, shape `rows × rank`. f64 — parked variant.
    pub w: Vec<f64>,
    /// H matrix, row-major, shape `rank × cols`. f64 — parked variant.
    pub h: Vec<f64>,
    pub rows: usize,
    pub cols: usize,
    pub rank: usize,
    /// Reconstruction error `||O - W·H||_F^2` (raw Frobenius squared, NOT RMS).
    pub reconstruction_error: f64,
    /// Number of multiplicative-update iterations executed.
    pub iterations: usize,
}

impl NMFDoubleFrobeniusSquaredFactorization {
    /// Loading for one row: the rank-dimensional latent factor vector (row of W).
    pub fn loadings_for_row(&self, row: usize) -> Vec<f64> {
        assert!(row < self.rows, "row out of range");
        (0..self.rank).map(|j| self.w[row * self.rank + j]).collect()
    }
}

/// Double-precision NMF using Frobenius-squared convergence criterion.
///
/// !! PRODUCTION GATE — NOT FOR PRODUCTION USE !!
///
/// This is the parked f64/Frobenius² variant lifted verbatim from
/// GeniusLocusKit's prior `MatrixNMF` implementation (present before the
/// 2026-06-13 delegation to the canonical substrate f32 NMF per Bob's ruling).
/// It is preserved here so a future benchmark can compare the two approaches
/// honestly. Benchmark before using in production.
///
/// For all production use, call `NMFAlternatingLeastSquares::factorize` instead.
pub struct NMFDoubleFrobeniusSquared;

impl NMFDoubleFrobeniusSquared {
    /// Default convergence iteration cap. Matches the original GLK default.
    pub const DEFAULT_MAX_ITERATIONS: usize = 100;

    /// Convergence tolerance on the Frobenius² delta `|last_error - err|`.
    /// Note: this is NOT the same criterion as `NMFAlternatingLeastSquares`,
    /// which converges on RMS error delta.
    pub const DEFAULT_TOLERANCE: f64 = 1e-6;

    /// Factorize a dense `rows × cols` row-major non-negative matrix `o`
    /// into W (`rows × rank`) and H (`rank × cols`) with W, H ≥ 0.
    ///
    /// !! PRODUCTION GATE — NOT FOR PRODUCTION USE !!
    ///
    /// The `seed` controls the deterministic SplitMix64 initial fill; two
    /// replicas running on the same input with the same seed produce
    /// bit-identical factorizations (cross-port: Swift and Rust agree).
    ///
    /// The canonical production variant is
    /// `NMFAlternatingLeastSquares::factorize`.
    pub fn factorize(
        o: &[f64],
        rows: usize,
        cols: usize,
        rank: usize,
        seed: u64,
        max_iterations: usize,
        tolerance: f64,
    ) -> NMFDoubleFrobeniusSquaredFactorization {
        assert_eq!(o.len(), rows * cols, "o shape mismatch");
        assert!(rank > 0, "rank must be positive");
        assert!(rows > 0, "rows must be positive");
        assert!(cols > 0, "cols must be positive");

        // SplitMix64 with floored init: max(raw, 1e-3). The floor prevents
        // exact-zero initial cells from sticking at zero under the
        // multiplicative update. This is the original GLK initialization —
        // distinct from NMFAlternatingLeastSquares (which uses 16 low bits,
        // no floor). The floor and the 53-high-bit draw are what make this
        // variant's initialization bit-distinct from the canonical path.
        let mut rng = Rng { state: seed };
        let mut w: Vec<f64> = (0..rows * rank).map(|_| rng.next_unit_nonneg()).collect();
        let mut h: Vec<f64> = (0..rank * cols).map(|_| rng.next_unit_nonneg()).collect();

        let mut last_error = f64::INFINITY;
        let mut iterations = 0usize;

        for it in 0..max_iterations {
            iterations = it + 1;

            // H ← H ⊙ (Wᵀ·O) / (Wᵀ·W·H + ε)
            let wt_o = mat_mul_transpose_left(&w, rows, rank, o, rows, cols);  // rank × cols
            let wt_w = mat_mul_transpose_left(&w, rows, rank, &w, rows, rank); // rank × rank
            let wt_w_h = mat_mul(&wt_w, rank, rank, &h, rank, cols);           // rank × cols
            for i in 0..h.len() {
                h[i] = h[i] * wt_o[i] / (wt_w_h[i] + EPSILON);
            }

            // W ← W ⊙ (O·Hᵀ) / (W·H·Hᵀ + ε)
            let o_ht = mat_mul_transpose_right(o, rows, cols, &h, rank, cols); // rows × rank
            let h_ht = mat_mul_transpose_right(&h, rank, cols, &h, rank, cols); // rank × rank
            let w_h_ht = mat_mul(&w, rows, rank, &h_ht, rank, rank);           // rows × rank
            for i in 0..w.len() {
                w[i] = w[i] * o_ht[i] / (w_h_ht[i] + EPSILON);
            }

            // Convergence check: Frobenius² delta (NOT RMS).
            let err = frobenius_squared(o, rows, cols, &w, &h, rank);
            if (last_error - err).abs() < tolerance {
                last_error = err;
                break;
            }
            last_error = err;
        }

        NMFDoubleFrobeniusSquaredFactorization {
            w,
            h,
            rows,
            cols,
            rank,
            reconstruction_error: last_error,
            iterations,
        }
    }
}

// MARK: - Dense linear-algebra helpers (scalar f64)

/// C = Aᵀ · B; A is `arows × acols`, B is `arows × bcols`. Result is `acols × bcols`.
fn mat_mul_transpose_left(
    a: &[f64],
    arows: usize,
    acols: usize,
    b: &[f64],
    brows: usize,
    bcols: usize,
) -> Vec<f64> {
    assert_eq!(arows, brows, "mat_mul_transpose_left: inner-dim mismatch");
    let mut out = vec![0.0f64; acols * bcols];
    for i in 0..acols {
        for j in 0..bcols {
            let mut sum = 0.0;
            for r in 0..arows {
                sum += a[r * acols + i] * b[r * bcols + j];
            }
            out[i * bcols + j] = sum;
        }
    }
    out
}

/// C = A · Bᵀ; A is `arows × acols`, B is `brows × bcols` (= `brows × acols`). Result is `arows × brows`.
fn mat_mul_transpose_right(
    a: &[f64],
    arows: usize,
    acols: usize,
    b: &[f64],
    brows: usize,
    bcols: usize,
) -> Vec<f64> {
    assert_eq!(acols, bcols, "mat_mul_transpose_right: inner-dim mismatch");
    let mut out = vec![0.0f64; arows * brows];
    for i in 0..arows {
        for j in 0..brows {
            let mut sum = 0.0;
            for c in 0..acols {
                sum += a[i * acols + c] * b[j * bcols + c];
            }
            out[i * brows + j] = sum;
        }
    }
    out
}

/// C = A · B; A is `arows × acols`, B is `brows × bcols`. `acols` must equal `brows`.
fn mat_mul(
    a: &[f64],
    arows: usize,
    acols: usize,
    b: &[f64],
    brows: usize,
    bcols: usize,
) -> Vec<f64> {
    assert_eq!(acols, brows, "mat_mul: inner-dim mismatch");
    let mut out = vec![0.0f64; arows * bcols];
    for i in 0..arows {
        for j in 0..bcols {
            let mut sum = 0.0;
            for c in 0..acols {
                sum += a[i * acols + c] * b[c * bcols + j];
            }
            out[i * bcols + j] = sum;
        }
    }
    out
}

/// Frobenius² reconstruction error `Σ (o_ij - (W·H)_ij)²`.
///
/// Raw Frobenius squared, NOT normalized by m·n and NOT square-rooted.
/// This is the convergence criterion for this variant.
/// `NMFAlternatingLeastSquares` uses `sqrt(Σ d² / (m·n))` (RMS) instead.
pub(crate) fn frobenius_squared(
    o: &[f64],
    rows: usize,
    cols: usize,
    w: &[f64],
    h: &[f64],
    rank: usize,
) -> f64 {
    let mut err = 0.0;
    for i in 0..rows {
        for j in 0..cols {
            let mut prod = 0.0;
            for k in 0..rank {
                prod += w[i * rank + k] * h[k * cols + j];
            }
            let d = o[i * cols + j] - prod;
            err += d * d;
        }
    }
    err
}

// MARK: - Deterministic RNG

/// SplitMix64 seeded PRNG for `NMFDoubleFrobeniusSquared`.
///
/// Uses the standard SplitMix64 constants (same as
/// `RandomWalks::SplitMix64`), but the output transformation is different:
/// top-53-bit draw scaled to [0,1), then floored to 1e-3. This matches the
/// original GLK `SplitMix64::next_unit_nonneg` exactly.
struct Rng {
    state: u64,
}

impl Rng {
    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    fn next_unit_nonneg(&mut self) -> f64 {
        let bits = self.next_u64() >> 11;              // top 53 bits
        let raw = bits as f64 / (1u64 << 53) as f64;
        raw.max(1e-3)
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    /// Verify that the canonical 2×2 k=1 factorization matches the
    /// pinned conformance vector (nmf_double_frobenius_squared.json case 1).
    /// Bit-identical to the Swift scalar reference.
    #[test]
    fn conformance_2x2_k1_canonical_seed() {
        // nmf_double_frobenius_squared.json vector 1
        // seed = 0xC0FFEE_BABE_BEEF, o = [4,1,1,5], rows=2, cols=2, rank=1
        let o = [4.0f64, 1.0, 1.0, 5.0];
        let f = NMFDoubleFrobeniusSquared::factorize(
            &o, 2, 2, 1, 0xC0FFEE_BABE_BEEF, 100, 1e-6,
        );
        // W bits pinned from Swift scalar reference.
        assert_eq!(f.w[0].to_bits(), 4603661257158336504, "W[0] bit mismatch");
        assert_eq!(f.w[1].to_bits(), 4607051107372252721, "W[1] bit mismatch");
        // H bits pinned.
        assert_eq!(f.h[0].to_bits(), 4612924100901497531, "H[0] bit mismatch");
        assert_eq!(f.h[1].to_bits(), 4616330521827979722, "H[1] bit mismatch");
        // Reconstruction error bit-pinned.
        assert_eq!(
            f.reconstruction_error.to_bits(),
            4622628467456029591,
            "err bit mismatch"
        );
        assert_eq!(f.iterations, 8);
    }

    /// Determinism: same seed produces identical W and H.
    #[test]
    fn deterministic_across_calls_same_seed() {
        let o = [1.0f64, 2.0, 3.0, 4.0];
        let a = NMFDoubleFrobeniusSquared::factorize(&o, 2, 2, 2, 42, 20, 1e-6);
        let b = NMFDoubleFrobeniusSquared::factorize(&o, 2, 2, 2, 42, 20, 1e-6);
        assert_eq!(a.w, b.w);
        assert_eq!(a.h, b.h);
        assert_eq!(a.reconstruction_error, b.reconstruction_error);
    }

    /// Rank-1 factorization of a rank-1 matrix converges to low error.
    #[test]
    fn rank1_matrix_low_reconstruction_error() {
        // Perfect rank-1 matrix: o = [1,2,3; 2,4,6; 3,6,9]
        let o = [1.0f64, 2.0, 3.0, 2.0, 4.0, 6.0, 3.0, 6.0, 9.0];
        let f = NMFDoubleFrobeniusSquared::factorize(&o, 3, 3, 1, 0xC0FFEE_BABE_BEEF, 200, 1e-9);
        // Frobenius² error should be very small for a perfect rank-1 input.
        assert!(
            f.reconstruction_error < 1e-6,
            "expected low error for rank-1 input, got {}",
            f.reconstruction_error
        );
        assert_eq!(f.loadings_for_row(0).len(), 1);
    }

    /// Loadings-for-row returns the correct W row.
    #[test]
    fn loadings_for_row_returns_w_row() {
        let o = [4.0f64, 1.0, 1.0, 5.0];
        let f = NMFDoubleFrobeniusSquared::factorize(
            &o, 2, 2, 1, 0xC0FFEE_BABE_BEEF, 100, 1e-6,
        );
        let l = f.loadings_for_row(0);
        assert_eq!(l.len(), 1);
        assert_eq!(l[0].to_bits(), f.w[0].to_bits());
    }
}
