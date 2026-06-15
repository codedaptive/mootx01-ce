// matrix/calibration.rs — per-model LLM calibration curves.
//
// Cookbook §6.6. Twenty equal-width buckets over [0, 1) record count
// and rolling success rate; `calibrate` deflates a claimed confidence
// to the bucket's empirical rate.
//
// Decay (math treatise §8, dormant-surfaces mission Part 4):
//   Observations lose influence over time via a 30-day half-life.
//   Decay is lazy — applied at write time via `apply_decay` on
//   `MatrixCalibrationCurve`, then `record_with_decay` on
//   `MatrixCalibrationRegistry`. `update_timestamps` stores the
//   last-record time per model so elapsed days can be computed.

use std::collections::HashMap;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct MatrixCalibrationBucket {
    pub count: i32,
    pub success_rate: f32,
}

impl MatrixCalibrationBucket {
    /// Apply multiplicative decay to this bucket's observation count.
    ///
    /// `factor` is `0.5^(elapsed_days / half_life_days)`. Reduces the
    /// influence of past observations without changing `success_rate`
    /// (a rate — not a sum; it does not change under decay).
    pub fn apply_decay(&mut self, factor: f64) {
        let decayed = (self.count as f64 * factor).round().max(0.0) as i32;
        self.count = decayed;
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum MatrixCalibrationOutcome {
    Success,
    Failure,
}

/// Per-model calibration curve. 20 buckets per cookbook §6.6.
#[derive(Clone, Debug, PartialEq)]
pub struct MatrixCalibrationCurve {
    pub buckets: Vec<MatrixCalibrationBucket>,
}

impl MatrixCalibrationCurve {
    pub const BUCKET_COUNT: usize = 20;

    pub fn new() -> Self {
        Self {
            buckets: vec![MatrixCalibrationBucket::default(); Self::BUCKET_COUNT],
        }
    }

    pub fn record(&mut self, claimed_confidence: f32, outcome: MatrixCalibrationOutcome) {
        let clamped = claimed_confidence.clamp(0.0, 0.99999);
        let idx = ((clamped * Self::BUCKET_COUNT as f32) as usize).min(Self::BUCKET_COUNT - 1);
        let bucket = &mut self.buckets[idx];
        let old_count = bucket.count as f32;
        bucket.count = bucket.count.saturating_add(1);
        let outcome_bit: f32 = match outcome {
            MatrixCalibrationOutcome::Success => 1.0,
            MatrixCalibrationOutcome::Failure => 0.0,
        };
        // Running mean: new = (old * (n-1) + outcome) / n.
        bucket.success_rate = (bucket.success_rate * old_count + outcome_bit) / bucket.count as f32;
    }

    pub fn calibrate(&self, claimed_confidence: f32) -> f32 {
        let clamped = claimed_confidence.clamp(0.0, 0.99999);
        let idx = ((clamped * Self::BUCKET_COUNT as f32) as usize).min(Self::BUCKET_COUNT - 1);
        let bucket = &self.buckets[idx];
        if bucket.count > 0 {
            bucket.success_rate
        } else {
            claimed_confidence
        }
    }

    /// Apply multiplicative decay to all buckets.
    ///
    /// `elapsed_days` is time since last update. Decay is skipped for
    /// sub-day intervals to avoid floating-point noise. `half_life_days`
    /// defaults to 30 per math treatise §8.
    pub fn apply_decay(&mut self, elapsed_days: f64, half_life_days: f64) {
        if elapsed_days < 1.0 {
            return;
        }
        let factor = 0.5_f64.powf(elapsed_days / half_life_days);
        for bucket in &mut self.buckets {
            bucket.apply_decay(factor);
        }
    }
}

impl Default for MatrixCalibrationCurve {
    fn default() -> Self {
        Self::new()
    }
}

/// Per-model registry. Keyed by stable model id.
///
/// `update_timestamps` stores the last-record time per model as seconds
/// since Unix epoch, used by `record_with_decay` to compute elapsed days
/// for the lazy decay pass.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MatrixCalibrationRegistry {
    pub curves: HashMap<String, MatrixCalibrationCurve>,
    pub update_timestamps: HashMap<String, f64>,
}

impl MatrixCalibrationRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn record(
        &mut self,
        model_id: &str,
        claimed_confidence: f32,
        outcome: MatrixCalibrationOutcome,
    ) {
        let curve = self.curves.entry(model_id.to_string()).or_default();
        curve.record(claimed_confidence, outcome);
    }

    pub fn calibrate(&self, model_id: &str, claimed_confidence: f32) -> f32 {
        match self.curves.get(model_id) {
            Some(curve) => curve.calibrate(claimed_confidence),
            None => claimed_confidence,
        }
    }

    /// Apply 30-day-half-life decay then record one observation.
    ///
    /// Decay is computed from the last-recorded timestamp for `model_id`
    /// and the supplied `now_unix_secs`. If this is the first observation
    /// for the model, no decay is applied. After recording, `update_timestamps`
    /// is advanced to `now_unix_secs` so the next call's decay window starts here.
    pub fn record_with_decay(
        &mut self,
        model_id: &str,
        claimed_confidence: f32,
        outcome: MatrixCalibrationOutcome,
        now_unix_secs: f64,
        half_life_days: f64,
    ) {
        let curve = self.curves.entry(model_id.to_string()).or_default();

        // Apply decay proportional to elapsed time since last update.
        if let Some(&last_ts) = self.update_timestamps.get(model_id) {
            let elapsed_days = (now_unix_secs - last_ts) / 86_400.0;
            curve.apply_decay(elapsed_days, half_life_days);
        }

        curve.record(claimed_confidence, outcome);
        self.update_timestamps.insert(model_id.to_string(), now_unix_secs);
    }
}
