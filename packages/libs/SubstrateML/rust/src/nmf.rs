// nmf.rs
//
// Non-negative matrix factorization via alternating least squares
// per cookbook § 6.9 / § 8.9. Mirror of
// NMFAlternatingLeastSquares.swift.
//
// V ≈ W × H, all three non-negative. Lee-Seung multiplicative
// update rules preserve non-negativity without explicit projection.
//
// Input preconditions (enforced at entry; violations panic):
//   - V is rectangular: every row has the same column count.
//   - All entries of V are finite (no NaN, no Inf).
//   - All entries of V are >= 0 (Lee-Seung theorem requires V >= 0).

use crate::random_walks::SplitMix64;
use intellectus_lib::{StatSample, report};
use crate::viz_graph_signals::VizGraphSignals;

#[derive(Debug, Clone)]
pub struct NMFFactorization {
    pub w: Vec<Vec<f32>>,    // m × k
    pub h: Vec<Vec<f32>>,    // k × n
    pub rank: usize,
    pub iterations: usize,
    pub final_error: f32,
}

pub struct NMFAlternatingLeastSquares;

impl NMFAlternatingLeastSquares {
    /// VizGraph telemetry: when monitoring is enabled, emits
    /// `VizGraphSignals::NMF_FACTOR` with the final reconstruction error,
    /// tagged by estate, matrix dimensions, and rank.
    /// Off-path is a single AtomicBool load + branch — no allocation.
    ///
    /// # Parameters
    /// - `estate`: Estate identifier tag for VizGraph telemetry.
    /// - `ts`: Caller-supplied epoch seconds. Never read a clock here.
    pub fn factorize(v: &[Vec<f32>],
                     rank: usize,
                     max_iterations: usize,
                     tolerance: f32,
                     seed: u64,
                     estate: &str,
                     ts: f64) -> NMFFactorization {
        assert!(!v.is_empty(), "V must have at least one row");
        let m = v.len();
        let n = v[0].len();
        assert!(n > 0, "V must have at least one column");
        assert!(rank > 0 && rank <= m.min(n), "rank out of range");

        // Domain preconditions: rectangular, finite, non-negative.
        for (i, row) in v.iter().enumerate() {
            assert!(row.len() == n,
                "V is not rectangular: row 0 has {} columns but row {} has {}",
                n, i, row.len());
            for (j, &val) in row.iter().enumerate() {
                assert!(val.is_finite(),
                    "V[{}][{}] is not finite ({})", i, j, val);
                assert!(val >= 0.0,
                    "V[{}][{}] is negative ({}): NMF requires V >= 0", i, j, val);
            }
        }

        let mut rng = SplitMix64::new(seed);
        let mut w: Vec<Vec<f32>> = (0..m).map(|_|
            (0..rank).map(|_| (rng.next() & 0xFFFF) as f32 / 0xFFFF as f32).collect()
        ).collect();
        let mut h: Vec<Vec<f32>> = (0..rank).map(|_|
            (0..n).map(|_| (rng.next() & 0xFFFF) as f32 / 0xFFFF as f32).collect()
        ).collect();

        let mut prev_error = f32::INFINITY;
        let mut iterations = 0;
        let eps: f32 = 1e-9;

        for it in 0..max_iterations {
            iterations = it + 1;

            // H update: H *= (Wᵀ V) / (Wᵀ W H + eps)
            let wt_v = Self::mat_mul_atb(&w, v);
            let wt_w = Self::mat_mul_atb(&w, &w);
            let wt_wh = Self::mat_mul(&wt_w, &h);
            for k in 0..rank {
                for j in 0..n {
                    let num = wt_v[k][j];
                    let den = wt_wh[k][j] + eps;
                    let mut new_v = h[k][j] * num / den;
                    if new_v < 0.0 { new_v = 0.0; }
                    h[k][j] = new_v;
                }
            }

            // W update: W *= (V Hᵀ) / (W H Hᵀ + eps)
            let v_ht = Self::mat_mul_abt(v, &h);
            let h_ht = Self::mat_mul_abt(&h, &h);
            let w_hht = Self::mat_mul(&w, &h_ht);
            for i in 0..m {
                for k in 0..rank {
                    let num = v_ht[i][k];
                    let den = w_hht[i][k] + eps;
                    let mut new_v = w[i][k] * num / den;
                    if new_v < 0.0 { new_v = 0.0; }
                    w[i][k] = new_v;
                }
            }

            let err = Self::reconstruction_error(v, &w, &h);
            if (prev_error - err).abs() < tolerance { break; }
            prev_error = err;
        }

        let final_error = Self::reconstruction_error(v, &w, &h);
        let result = NMFFactorization { w, h, rank, iterations, final_error };

        // VizGraph emit: nmf.factor — factorisation complete.
        // Value = final reconstruction error (how well V ≈ W × H).
        // The Topology theme-overlay layer uses W and H to assign
        // latent-theme colours to nodes; this signal fires once the
        // matrices are ready for that rendering pass.
        //
        // Off-path when monitoring is disabled: single AtomicBool load
        // + branch. Closure is NEVER evaluated when monitoring is off.
        let m_str = m.to_string();
        let n_str = n.to_string();
        let rank_str = rank.to_string();
        let final_err_val = result.final_error as f64;
        report!({
            let mut tags = std::collections::HashMap::new();
            tags.insert("estate".to_string(), estate.to_string());
            tags.insert("rows".to_string(), m_str.clone());
            tags.insert("cols".to_string(), n_str.clone());
            tags.insert("rank".to_string(), rank_str.clone());
            StatSample::metric(
                VizGraphSignals::NMF_FACTOR.to_string(),
                final_err_val,
                tags,
                ts,
            )
        });

        result
    }

    pub fn reconstruction_error(v: &[Vec<f32>], w: &[Vec<f32>], h: &[Vec<f32>]) -> f32 {
        let m = v.len();
        let n = v[0].len();
        let r = Self::mat_mul(w, h);
        let mut err = 0.0_f32;
        for i in 0..m {
            for j in 0..n {
                let d = v[i][j] - r[i][j];
                err += d * d;
            }
        }
        (err / (m * n) as f32).sqrt()
    }

    /// C = A × B
    pub fn mat_mul(a: &[Vec<f32>], b: &[Vec<f32>]) -> Vec<Vec<f32>> {
        let m = a.len();
        let k_dim = a[0].len();
        let n = b[0].len();
        let mut c = vec![vec![0.0_f32; n]; m];
        for i in 0..m {
            for k in 0..k_dim {
                let a_ik = a[i][k];
                for j in 0..n {
                    c[i][j] += a_ik * b[k][j];
                }
            }
        }
        c
    }

    /// C = Aᵀ × B (A is m×k, B is m×n)
    pub fn mat_mul_atb(a: &[Vec<f32>], b: &[Vec<f32>]) -> Vec<Vec<f32>> {
        let m = a.len();
        let k_dim = a[0].len();
        let n = b[0].len();
        assert_eq!(b.len(), m);
        let mut c = vec![vec![0.0_f32; n]; k_dim];
        for i in 0..m {
            for k in 0..k_dim {
                let a_ik = a[i][k];
                for j in 0..n {
                    c[k][j] += a_ik * b[i][j];
                }
            }
        }
        c
    }

    /// C = A × Bᵀ (A is m×k, B is n×k)
    pub fn mat_mul_abt(a: &[Vec<f32>], b: &[Vec<f32>]) -> Vec<Vec<f32>> {
        let m = a.len();
        let k_dim = a[0].len();
        let n = b.len();
        assert_eq!(b[0].len(), k_dim);
        let mut c = vec![vec![0.0_f32; n]; m];
        for i in 0..m {
            for j in 0..n {
                let mut sum = 0.0_f32;
                for k in 0..k_dim {
                    sum += a[i][k] * b[j][k];
                }
                c[i][j] = sum;
            }
        }
        c
    }
}
