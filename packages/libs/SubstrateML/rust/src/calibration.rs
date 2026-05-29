// calibration.rs
//
// LLM calibration curve per cookbook § 6.6. Mirror of
// glref-swift-LLMCalibrationCurve.swift.

#[derive(Debug, Clone)]
pub struct LLMCalibrationCurve {
    pub bins: Vec<(u32, u32)>,    // (predicted, hit) per bucket
    pub sample_count: u64,
}

impl LLMCalibrationCurve {
    pub const BIN_COUNT: usize = 20;
    pub const BIN_WIDTH: f32 = 0.05;

    pub fn new() -> Self {
        Self {
            bins: vec![(0, 0); Self::BIN_COUNT],
            sample_count: 0,
        }
    }

    pub fn observe(&mut self, claimed_confidence: f32, actual_outcome: bool) {
        assert!(claimed_confidence.is_finite(), "claimed_confidence must be finite");
        let clamped = claimed_confidence.max(0.0).min(0.999_999);
        let bucket = ((clamped * Self::BIN_COUNT as f32) as usize).min(Self::BIN_COUNT - 1);
        self.bins[bucket].0 = self.bins[bucket].0.wrapping_add(1);
        if actual_outcome {
            self.bins[bucket].1 = self.bins[bucket].1.wrapping_add(1);
        }
        self.sample_count = self.sample_count.wrapping_add(1);
    }

    pub fn actual_rate(&self, bucket: usize) -> Option<f32> {
        assert!(bucket < Self::BIN_COUNT, "bucket out of range");
        let (predicted, hit) = self.bins[bucket];
        if predicted == 0 { None } else {
            Some(hit as f32 / predicted as f32)
        }
    }

    pub fn midpoint(bucket: usize) -> f32 {
        (bucket as f32 + 0.5) * Self::BIN_WIDTH
    }

    /// Expected calibration error.
    pub fn expected_calibration_error(&self) -> f32 {
        let mut weighted = 0.0_f32;
        let mut total = 0.0_f32;
        for (i, &(predicted, hit)) in self.bins.iter().enumerate() {
            if predicted == 0 { continue; }
            let actual = hit as f32 / predicted as f32;
            let weight = predicted as f32;
            weighted += weight * (actual - Self::midpoint(i)).abs();
            total += weight;
        }
        if total > 0.0 { weighted / total } else { 0.0 }
    }

    /// Brier score.
    pub fn brier_score(&self) -> f32 {
        let mut sum = 0.0_f32;
        let mut total = 0.0_f32;
        for (i, &(predicted, hit)) in self.bins.iter().enumerate() {
            if predicted == 0 { continue; }
            let actual = hit as f32 / predicted as f32;
            let weight = predicted as f32;
            let d = actual - Self::midpoint(i);
            sum += weight * d * d;
            total += weight;
        }
        if total > 0.0 { sum / total } else { 0.0 }
    }

    /// Apply fractional decay to all bins.
    pub fn decay(&mut self, factor: f32) {
        assert!((0.0..=1.0).contains(&factor), "decay factor must be in [0,1]");
        for bin in &mut self.bins {
            bin.0 = (bin.0 as f32 * factor) as u32;
            bin.1 = (bin.1 as f32 * factor) as u32;
        }
        self.sample_count = (self.sample_count as f32 * factor) as u64;
    }
}

impl Default for LLMCalibrationCurve {
    fn default() -> Self { Self::new() }
}
