// anomaly.rs
//
// Anomaly detection per cookbook § 8.13. Mirror of
// glref-swift-AnomalyDetection.swift.

pub struct AnomalyDetection;

impl AnomalyDetection {
    /// Classic z-score. Returns 0 when stddev is zero.
    pub fn z_score(value: f32, mean: f32, stddev: f32) -> f32 {
        if stddev <= 0.0 { 0.0 } else { (value - mean) / stddev }
    }

    /// Rolling-window z-score using the supplied window as baseline.
    pub fn rolling_z_score(window: &[f32], current: f32) -> f32 {
        if window.is_empty() { return 0.0; }
        let n = window.len() as f32;
        let mean = window.iter().sum::<f32>() / n;
        let variance = window.iter()
            .map(|x| (x - mean) * (x - mean))
            .sum::<f32>() / n;
        let stddev = variance.sqrt();
        Self::z_score(current, mean, stddev)
    }

    /// Modified z-score using median absolute deviation.
    /// The 0.6745 factor makes the score consistent with the
    /// classic z-score on normal data.
    pub fn modified_z_score(value: f32, median: f32, mad: f32) -> f32 {
        if mad <= 0.0 { 0.0 } else { 0.6745 * (value - median) / mad }
    }

    /// Rolling modified z-score. Computes median and MAD in-place.
    pub fn rolling_modified_z_score(window: &[f32], current: f32) -> f32 {
        if window.is_empty() { return 0.0; }
        let mut sorted = window.to_vec();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let median = sorted[sorted.len() / 2];
        let mut deviations: Vec<f32> = window.iter()
            .map(|x| (x - median).abs())
            .collect();
        deviations.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let mad = deviations[deviations.len() / 2];
        Self::modified_z_score(current, median, mad)
    }

    pub fn is_anomalous(z_score: f32, threshold: f32) -> bool {
        z_score.abs() >= threshold
    }
}
