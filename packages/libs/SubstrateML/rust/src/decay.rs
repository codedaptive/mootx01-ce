// decay.rs
//
// Exponential matrix decay per cookbook § 8.13 / § 6.8.
//
// Every matrix in the substrate's matrix tier (F, C, O, T,
// ActionOutcomes, calibration, w_ranking) carries a half-life
// τ that determines how quickly past evidence loses weight.
// The decay step replaces each cell `m_ij` with:
//
//   m_ij(t + Δt) = m_ij(t) * exp(-Δt * ln(2) / τ)
//
// for elapsed time Δt since the last decay step. Decay runs as
// part of the dreaming daemon (§ 15), typically every 24h on a
// background queue.
//
// Per-matrix half-lives (cookbook § 6.8 table):
//
//   F matrix         (field-presence):      τ =  90 days
//   C matrix         (correlation):         τ = 180 days
//   O matrix         (co-activation):       τ =  60 days
//   T matrix         (temporal causality):  τ =  30 days
//   ActionOutcomes:                         τ = 365 days
//   calibration:                            τ = 730 days  (slow)
//   w_ranking:                              τ =  90 days
//
// CONSTITUTIONAL: decay is monotonic non-increasing. It cannot
// add new evidence; it can only forget. The substrate adds new
// evidence ONLY through verb operations (cookbook § 10).

use intellectus_lib::{StatSample, report};
use crate::viz_graph_signals::VizGraphSignals;

/// A rectangular floating-point matrix. The reference
/// implementation uses a flat row-major `Vec<f64>` for
/// transparency; the production NeuronKit Rust port uses
/// ndarray or wide-SIMD and must produce bit-equivalent results
/// (within IEEE-754 rounding, since exp is not exact).
#[derive(Debug, Clone)]
pub struct DecayingMatrix {
    pub rows: usize,
    pub cols: usize,
    pub values: Vec<f64>,
    /// Half-life in seconds.
    pub half_life_seconds: f64,
    /// HLC physical_time (in seconds) of the last decay step.
    pub last_decay_time_seconds: i64,
}

impl DecayingMatrix {
    pub fn new(rows: usize, cols: usize,
               half_life_seconds: f64,
               last_decay_time_seconds: i64) -> Self {
        assert!(rows > 0 && cols > 0, "matrix dimensions must be positive");
        assert!(half_life_seconds > 0.0, "half-life must be positive");
        Self {
            rows,
            cols,
            values: vec![0.0; rows * cols],
            half_life_seconds,
            last_decay_time_seconds,
        }
    }

    #[inline]
    pub fn get(&self, row: usize, col: usize) -> f64 {
        self.values[row * self.cols + col]
    }

    #[inline]
    pub fn set(&mut self, row: usize, col: usize, value: f64) {
        self.values[row * self.cols + col] = value;
    }

    #[inline]
    pub fn add(&mut self, row: usize, col: usize, increment: f64) {
        self.values[row * self.cols + col] += increment;
    }
}

/// Apply exponential decay to every cell. `now_seconds` is the
/// current HLC physical_time (in seconds). If `now_seconds <=
/// matrix.last_decay_time_seconds` this is a no-op (decay never
/// goes backward).
///
/// VizGraph telemetry: when monitoring is enabled, emits
/// `VizGraphSignals::EDGE_DECAYED_WEIGHT` with the applied decay factor
/// (1.0 when no-op). Tagged by estate, matrix dimensions, and elapsed
/// seconds. Off-path is a single AtomicBool load + branch.
///
/// # Parameters
/// - `estate`: Estate identifier tag for VizGraph telemetry.
/// - `ts`: Caller-supplied epoch seconds. Never read a clock here.
pub fn apply(matrix: &mut DecayingMatrix, now_seconds: i64,
             estate: &str, ts: f64) {
    let dt = (now_seconds - matrix.last_decay_time_seconds) as f64;
    if dt <= 0.0 {
        // No-op: elapsed time is zero or negative. Emit factor = 1.0 so
        // the Topology view knows a decay check ran but nothing changed.
        let rows_str = matrix.rows.to_string();
        let cols_str = matrix.cols.to_string();
        report!({
            let mut tags = std::collections::HashMap::new();
            tags.insert("estate".to_string(), estate.to_string());
            tags.insert("matrix_rows".to_string(), rows_str.clone());
            tags.insert("matrix_cols".to_string(), cols_str.clone());
            tags.insert("elapsed_seconds".to_string(), "0".to_string());
            StatSample::metric(
                VizGraphSignals::EDGE_DECAYED_WEIGHT.to_string(),
                1.0,
                tags,
                ts,
            )
        });
        return;
    }
    let factor = (-dt * std::f64::consts::LN_2 / matrix.half_life_seconds).exp();
    for v in matrix.values.iter_mut() {
        *v *= factor;
    }
    matrix.last_decay_time_seconds = now_seconds;

    // VizGraph emit: edge.decayed_weight — decay pass complete.
    // Value = the multiplicative factor applied to every cell
    // (0 < factor ≤ 1.0). The Topology view refreshes edge-weight
    // rendering when the factor deviates significantly from 1.0.
    let rows_str = matrix.rows.to_string();
    let cols_str = matrix.cols.to_string();
    let elapsed_str = (dt as i64).to_string();
    report!({
        let mut tags = std::collections::HashMap::new();
        tags.insert("estate".to_string(), estate.to_string());
        tags.insert("matrix_rows".to_string(), rows_str.clone());
        tags.insert("matrix_cols".to_string(), cols_str.clone());
        tags.insert("elapsed_seconds".to_string(), elapsed_str.clone());
        StatSample::metric(
            VizGraphSignals::EDGE_DECAYED_WEIGHT.to_string(),
            factor,
            tags,
            ts,
        )
    });
}

/// Compute the decay factor that would be applied for a given
/// elapsed time and half-life. Useful for projecting "what will
/// this matrix look like in 30 days" without mutating.
pub fn decay_factor(elapsed_seconds: f64, half_life_seconds: f64) -> f64 {
    if elapsed_seconds <= 0.0 {
        return 1.0;
    }
    (-elapsed_seconds * std::f64::consts::LN_2 / half_life_seconds).exp()
}

/// Apply decay AND add new evidence atomically. Decay first (to
/// current time), then add. This is the canonical pattern for
/// online updates from the verb layer.
///
/// Forwards empty estate and ts=0 to `apply`; callers that want
/// VizGraph telemetry should call `apply` directly with their estate
/// and ts values, then add separately.
pub fn decay_and_add(matrix: &mut DecayingMatrix,
                     now_seconds: i64,
                     row: usize, col: usize,
                     increment: f64) {
    // Empty estate and ts=0: no-op emit (monitoring off by default).
    apply(matrix, now_seconds, "", 0.0);
    matrix.add(row, col, increment);
}

// Recommended half-lives (cookbook § 6.8 table)
//
// These constants are illustrative; the actual half-lives live
// in the manifest under `decay_half_lives.<matrix_name>` and can
// be tuned per-estate via dreaming-daemon rule 11 (cookbook § 15.11).

pub mod half_lives {
    const DAY: f64 = 86_400.0;

    pub const FIELD_PRESENCE_SECONDS:     f64 =  90.0 * DAY;
    pub const CORRELATION_SECONDS:        f64 = 180.0 * DAY;
    pub const CO_ACTIVATION_SECONDS:      f64 =  60.0 * DAY;
    pub const TEMPORAL_CAUSALITY_SECONDS: f64 =  30.0 * DAY;
    pub const ACTION_OUTCOMES_SECONDS:    f64 = 365.0 * DAY;
    pub const CALIBRATION_SECONDS:        f64 = 730.0 * DAY;
    pub const W_RANKING_SECONDS:          f64 =  90.0 * DAY;
}

// Properties
//
//   monotonic non-increasing: |m_ij(t+Δt)| ≤ |m_ij(t)| for Δt > 0.
//   half-life:                m_ij decays to half its value after
//                             exactly τ seconds.
//   commutes with addition:   decay(m + n) = decay(m) + decay(n)
//                             where decay is applied with same Δt.
//   idempotent at Δt=0:       apply(m, t) where t == last_decay_time
//                             leaves m unchanged.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decay_halves_at_one_half_life() {
        let mut m = DecayingMatrix::new(1, 1, 100.0, 0);
        m.set(0, 0, 1.0);
        apply(&mut m, 100, "", 0.0);
        // After exactly one half-life, value should be 0.5.
        assert!((m.get(0, 0) - 0.5).abs() < 1e-12);
    }

    #[test]
    fn decay_is_noop_when_no_time_elapsed() {
        let mut m = DecayingMatrix::new(1, 1, 100.0, 50);
        m.set(0, 0, 0.7);
        apply(&mut m, 50, "", 0.0);
        assert_eq!(m.get(0, 0), 0.7);
    }

    #[test]
    fn decay_does_not_go_backward() {
        let mut m = DecayingMatrix::new(1, 1, 100.0, 100);
        m.set(0, 0, 0.7);
        apply(&mut m, 50, "", 0.0);  // earlier than last_decay_time
        assert_eq!(m.get(0, 0), 0.7);
        assert_eq!(m.last_decay_time_seconds, 100);
    }

    #[test]
    fn decay_quarters_at_two_half_lives() {
        let mut m = DecayingMatrix::new(1, 1, 100.0, 0);
        m.set(0, 0, 1.0);
        apply(&mut m, 200, "", 0.0);
        assert!((m.get(0, 0) - 0.25).abs() < 1e-12);
    }

    #[test]
    fn decay_and_add_round_trip() {
        let mut m = DecayingMatrix::new(1, 1, 100.0, 0);
        m.set(0, 0, 1.0);
        decay_and_add(&mut m, 100, 0, 0, 0.5);
        // After one half-life: 1.0 → 0.5, then +0.5 → 1.0.
        assert!((m.get(0, 0) - 1.0).abs() < 1e-12);
    }

    #[test]
    fn decay_factor_for_zero_elapsed_is_one() {
        let f = decay_factor(0.0, 100.0);
        assert_eq!(f, 1.0);
    }

    #[test]
    fn decay_factor_at_one_half_life_is_half() {
        let f = decay_factor(100.0, 100.0);
        assert!((f - 0.5).abs() < 1e-12);
    }
}
