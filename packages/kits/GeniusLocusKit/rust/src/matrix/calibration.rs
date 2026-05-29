// matrix/calibration.rs — per-model LLM calibration curves.
//
// Cookbook §6.6. Twenty equal-width buckets over [0, 1) record count
// and rolling success rate; `calibrate` deflates a claimed confidence
// to the bucket's empirical rate.

use std::collections::HashMap;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct MatrixCalibrationBucket {
    pub count: i32,
    pub success_rate: f32,
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

    pub fn record(
        &mut self,
        claimed_confidence: f32,
        outcome: MatrixCalibrationOutcome,
    ) {
        let clamped = claimed_confidence.clamp(0.0, 0.99999);
        let idx = ((clamped * Self::BUCKET_COUNT as f32) as usize)
            .min(Self::BUCKET_COUNT - 1);
        let bucket = &mut self.buckets[idx];
        let old_count = bucket.count as f32;
        bucket.count = bucket.count.saturating_add(1);
        let outcome_bit: f32 = match outcome {
            MatrixCalibrationOutcome::Success => 1.0,
            MatrixCalibrationOutcome::Failure => 0.0,
        };
        // Running mean: new = (old * (n-1) + outcome) / n.
        bucket.success_rate =
            (bucket.success_rate * old_count + outcome_bit) / bucket.count as f32;
    }

    pub fn calibrate(&self, claimed_confidence: f32) -> f32 {
        let clamped = claimed_confidence.clamp(0.0, 0.99999);
        let idx = ((clamped * Self::BUCKET_COUNT as f32) as usize)
            .min(Self::BUCKET_COUNT - 1);
        let bucket = &self.buckets[idx];
        if bucket.count > 0 {
            bucket.success_rate
        } else {
            claimed_confidence
        }
    }
}

impl Default for MatrixCalibrationCurve {
    fn default() -> Self {
        Self::new()
    }
}

/// Per-model registry. Keyed by stable model id.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MatrixCalibrationRegistry {
    pub curves: HashMap<String, MatrixCalibrationCurve>,
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
        let curve = self
            .curves
            .entry(model_id.to_string())
            .or_insert_with(MatrixCalibrationCurve::new);
        curve.record(claimed_confidence, outcome);
    }

    pub fn calibrate(&self, model_id: &str, claimed_confidence: f32) -> f32 {
        match self.curves.get(model_id) {
            Some(curve) => curve.calibrate(claimed_confidence),
            None => claimed_confidence,
        }
    }
}
