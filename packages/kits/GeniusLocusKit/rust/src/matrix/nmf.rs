// matrix/nmf.rs — multiplicative-update NMF over O.
//
// Cookbook §6.9 / substrate-mathematics §8. Mirrors the Swift
// `MatrixNMF` reference dense-matrix implementation; deterministic
// SplitMix64 seeding keeps the initial W and H fills bit-identical
// across replicas.

#[derive(Clone, Debug, PartialEq)]
pub struct MatrixNMFFactorization {
    pub w: Vec<f64>,
    pub h: Vec<f64>,
    pub rows: usize,
    pub cols: usize,
    pub k: usize,
    pub reconstruction_error: f64,
}

impl MatrixNMFFactorization {
    pub fn loadings_for_row(&self, row: usize) -> Vec<f64> {
        assert!(row < self.rows, "row out of range");
        let mut out = vec![0.0; self.k];
        for j in 0..self.k {
            out[j] = self.w[row * self.k + j];
        }
        out
    }
}

pub struct MatrixNMF;

impl MatrixNMF {
    pub const DEFAULT_MAX_ITERATIONS: usize = 100;
    pub const DEFAULT_TOLERANCE: f64 = 1e-6;
    const EPSILON: f64 = 1e-9;

    pub fn factorize(
        o: &[f64],
        rows: usize,
        cols: usize,
        k: usize,
        seed: u64,
        max_iterations: usize,
        tolerance: f64,
    ) -> MatrixNMFFactorization {
        assert_eq!(o.len(), rows * cols, "o shape mismatch");
        assert!(k > 0, "k must be positive");

        let mut rng = SplitMix64 { state: seed };
        let mut w = vec![0.0_f64; rows * k];
        let mut h = vec![0.0_f64; k * cols];
        for i in 0..w.len() {
            w[i] = rng.next_unit_nonneg();
        }
        for i in 0..h.len() {
            h[i] = rng.next_unit_nonneg();
        }

        let mut last_error = f64::INFINITY;

        for _ in 0..max_iterations {
            // H ← H ⊙ (Wᵀ·O) / (Wᵀ·W·H + ε)
            let wt_o = mat_mul_transpose_left(&w, rows, k, o, rows, cols);
            let wt_w = mat_mul_transpose_left(&w, rows, k, &w, rows, k);
            let wt_w_h = mat_mul(&wt_w, k, k, &h, k, cols);
            for i in 0..h.len() {
                h[i] = h[i] * wt_o[i] / (wt_w_h[i] + Self::EPSILON);
            }

            // W ← W ⊙ (O·Hᵀ) / (W·H·Hᵀ + ε)
            let o_ht = mat_mul_transpose_right(o, rows, cols, &h, k, cols);
            let h_ht = mat_mul_transpose_right(&h, k, cols, &h, k, cols);
            let w_h_ht = mat_mul(&w, rows, k, &h_ht, k, k);
            for i in 0..w.len() {
                w[i] = w[i] * o_ht[i] / (w_h_ht[i] + Self::EPSILON);
            }

            let err = frobenius_squared(o, rows, cols, &w, &h, k);
            if (last_error - err).abs() < tolerance {
                last_error = err;
                break;
            }
            last_error = err;
        }

        MatrixNMFFactorization {
            w,
            h,
            rows,
            cols,
            k,
            reconstruction_error: last_error,
        }
    }
}

// MARK: - Dense linear-algebra helpers

fn mat_mul_transpose_left(
    a: &[f64], arows: usize, acols: usize,
    b: &[f64], brows: usize, bcols: usize,
) -> Vec<f64> {
    assert_eq!(arows, brows, "mat_mul_transpose_left inner-dim mismatch");
    let mut out = vec![0.0; acols * bcols];
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

fn mat_mul_transpose_right(
    a: &[f64], arows: usize, acols: usize,
    b: &[f64], brows: usize, bcols: usize,
) -> Vec<f64> {
    assert_eq!(acols, bcols, "mat_mul_transpose_right inner-dim mismatch");
    let mut out = vec![0.0; arows * brows];
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

fn mat_mul(
    a: &[f64], arows: usize, acols: usize,
    b: &[f64], brows: usize, bcols: usize,
) -> Vec<f64> {
    assert_eq!(acols, brows, "mat_mul inner-dim mismatch");
    let mut out = vec![0.0; arows * bcols];
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

fn frobenius_squared(
    o: &[f64], rows: usize, cols: usize,
    w: &[f64], h: &[f64], k: usize,
) -> f64 {
    let mut err = 0.0;
    for i in 0..rows {
        for j in 0..cols {
            let mut prod = 0.0;
            for kk in 0..k {
                prod += w[i * k + kk] * h[kk * cols + j];
            }
            let d = o[i * cols + j] - prod;
            err += d * d;
        }
    }
    err
}

// MARK: - SplitMix64

/// Deterministic seedable PRNG. Same constants as the Swift reference
/// so two replicas starting from the same seed produce identical
/// initial W and H fills.
struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    fn next_unit_nonneg(&mut self) -> f64 {
        let bits = self.next_u64() >> 11;
        let raw = bits as f64 / (1u64 << 53) as f64;
        raw.max(1e-3)
    }
}
