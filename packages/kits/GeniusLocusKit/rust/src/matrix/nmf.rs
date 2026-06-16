// matrix/nmf.rs — GLK matrix-tier NMF, delegates to canonical substrate primitive.
//
// Cookbook §6.9 / substrate-mathematics §8. Delegates to
// `substrate_ml::nmf::NMFAlternatingLeastSquares` (f32, RMS error). The
// substrate owns the algorithm; GLK owns the estate-tier wiring.
//
// Input: flat row-major f64 matrix (for backward compatibility with callers
// that build the co-occurrence matrix in f64, e.g. NeuronKit label
// co-occurrence). Conversion to f32 happens here before delegation.
//
// Output: `MatrixNMFFactorization` with f32 factors and RMS reconstruction
// error. Callers that inspect numeric values observe f32-precision results.
//
// The parked f64/Frobenius² algorithm is preserved in the substrate as
// `substrate_ml::nmf_double_frobenius_squared::NMFDoubleFrobeniusSquared`
// (NOT for production; see SUBSTRATEML_SPEC.md § 5.4b).

use substrate_ml::nmf::NMFAlternatingLeastSquares;

/// Output of one GLK NMF factorization pass.
///
/// Factor matrices hold f32 values from the canonical substrate
/// `NMFAlternatingLeastSquares`. Reconstruction error is the RMS metric:
/// `sqrt(||O - W·H||² / (m·n))`.
#[derive(Clone, Debug, PartialEq)]
pub struct MatrixNMFFactorization {
    /// W matrix, row-major, shape `rows × rank`. f32.
    pub w: Vec<f32>,
    /// H matrix, row-major, shape `rank × cols`. f32.
    pub h: Vec<f32>,
    pub rows: usize,
    pub cols: usize,
    pub k: usize,
    /// RMS reconstruction error `sqrt(||O - W·H||² / (rows·cols))`.
    /// Normalized RMS (the substrate canonical metric), distinct from the
    /// raw Frobenius² of the parked f64 variant.
    pub reconstruction_error: f32,
}

impl MatrixNMFFactorization {
    /// Loading for one row: the k-dimensional latent factor vector (f32).
    pub fn loadings_for_row(&self, row: usize) -> Vec<f32> {
        assert!(row < self.rows, "row out of range");
        (0..self.k).map(|j| self.w[row * self.k + j]).collect()
    }
}

pub struct MatrixNMF;

impl MatrixNMF {
    pub const DEFAULT_MAX_ITERATIONS: usize = 100;
    /// Tolerance on the RMS reconstruction error delta (substrate canonical).
    pub const DEFAULT_TOLERANCE: f32 = 1e-4;

    /// Factorize a flat row-major f64 matrix `o` (shape `rows × cols`)
    /// into W and H factors via the canonical substrate f32 NMF.
    ///
    /// The input `o` is accepted as f64 for compatibility with callers that
    /// build co-occurrence matrices in f64 precision. Values are converted to
    /// f32 before delegation to `NMFAlternatingLeastSquares`.
    ///
    /// The parked f64/Frobenius² algorithm is available in the substrate as
    /// `NMFDoubleFrobeniusSquared` (NOT for production).
    pub fn factorize(
        o: &[f64],
        rows: usize,
        cols: usize,
        k: usize,
        seed: u64,
        max_iterations: usize,
        tolerance: f32,
    ) -> MatrixNMFFactorization {
        assert_eq!(o.len(), rows * cols, "o shape mismatch");
        assert!(k > 0, "k must be positive");

        // Convert flat f64 row-major to nested Vec<Vec<f32>> for the substrate.
        let v: Vec<Vec<f32>> = (0..rows)
            .map(|row| {
                (0..cols)
                    .map(|col| o[row * cols + col] as f32)
                    .collect()
            })
            .collect();

        let result = NMFAlternatingLeastSquares::factorize(
            &v,
            k,
            max_iterations,
            tolerance,
            seed,
            "",    // estate tag — GLK matrix-tier calls do not emit telemetry from this layer
            0.0,
        );

        // Flatten substrate nested W and H to flat row-major f32.
        let w: Vec<f32> = result.w.iter().flat_map(|row| row.iter().copied()).collect();
        let h: Vec<f32> = result.h.iter().flat_map(|row| row.iter().copied()).collect();

        MatrixNMFFactorization {
            w,
            h,
            rows,
            cols,
            k,
            reconstruction_error: result.final_error,
        }
    }
}
