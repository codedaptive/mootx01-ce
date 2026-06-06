// anomaly.rs
//
// Anomaly detection per cookbook § 8.13. Mirror of
// glref-swift-AnomalyDetection.swift.

use intellectus_lib::{StatSample, report};
use crate::viz_graph_signals::VizGraphSignals;

pub struct AnomalyDetection;

impl AnomalyDetection {
    /// Classic z-score. Returns 0 when stddev is zero.
    pub fn z_score(value: f32, mean: f32, stddev: f32) -> f32 {
        if stddev <= 0.0 { 0.0 } else { (value - mean) / stddev }
    }

    /// Rolling-window z-score using the supplied window as baseline.
    ///
    /// VizGraph telemetry: when monitoring is enabled, emits
    /// `VizGraphSignals::ANOMALY_FLAG` with the absolute z-score,
    /// tagged by estate, method ("z_score"), and window size.
    /// Off-path is a single AtomicBool load + branch — no allocation.
    ///
    /// # Parameters
    /// - `estate`: Estate identifier tag for VizGraph telemetry.
    /// - `ts`: Caller-supplied epoch seconds. Never read a clock here.
    pub fn rolling_z_score(window: &[f32], current: f32,
                           estate: &str, ts: f64) -> f32 {
        if window.is_empty() { return 0.0; }
        let n = window.len() as f32;
        let mean = window.iter().sum::<f32>() / n;
        let variance = window.iter()
            .map(|x| (x - mean) * (x - mean))
            .sum::<f32>() / n;
        let stddev = variance.sqrt();
        let score = Self::z_score(current, mean, stddev);

        // VizGraph emit: anomaly.flag — rolling z-score computation complete.
        // The Topology view uses abs(z) to decide whether to mark this
        // node or edge as anomalous (red highlight). The "z_score" method
        // tag distinguishes this from the modified variant.
        let abs_score = (score.abs()) as f64;
        let ws_str = window.len().to_string();
        report!({
            let mut tags = std::collections::HashMap::new();
            tags.insert("estate".to_string(), estate.to_string());
            tags.insert("method".to_string(), "z_score".to_string());
            tags.insert("window_size".to_string(), ws_str.clone());
            StatSample::metric(
                VizGraphSignals::ANOMALY_FLAG.to_string(),
                abs_score,
                tags,
                ts,
            )
        });

        score
    }

    /// Modified z-score using median absolute deviation.
    /// The 0.6745 factor makes the score consistent with the
    /// classic z-score on normal data.
    pub fn modified_z_score(value: f32, median: f32, mad: f32) -> f32 {
        if mad <= 0.0 { 0.0 } else { 0.6745 * (value - median) / mad }
    }

    /// Rolling modified z-score. Computes median and MAD in-place.
    ///
    /// VizGraph telemetry: when monitoring is enabled, emits
    /// `VizGraphSignals::ANOMALY_FLAG` with the absolute modified z-score,
    /// tagged by estate, method ("modified_z_score"), and window size.
    /// Off-path is a single AtomicBool load + branch.
    ///
    /// # Parameters
    /// - `estate`: Estate identifier tag for VizGraph telemetry.
    /// - `ts`: Caller-supplied epoch seconds. Never read a clock here.
    pub fn rolling_modified_z_score(window: &[f32], current: f32,
                                     estate: &str, ts: f64) -> f32 {
        if window.is_empty() { return 0.0; }
        let mut sorted = window.to_vec();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let median = sorted[sorted.len() / 2];
        let mut deviations: Vec<f32> = window.iter()
            .map(|x| (x - median).abs())
            .collect();
        deviations.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let mad = deviations[deviations.len() / 2];
        let score = Self::modified_z_score(current, median, mad);

        // VizGraph emit: anomaly.flag — modified z-score computation complete.
        // Method tag "modified_z_score" distinguishes this from the classic
        // z-score path; the Topology view can apply different highlighting
        // rules for heavy-tailed distributions.
        let abs_score = (score.abs()) as f64;
        let ws_str = window.len().to_string();
        report!({
            let mut tags = std::collections::HashMap::new();
            tags.insert("estate".to_string(), estate.to_string());
            tags.insert("method".to_string(), "modified_z_score".to_string());
            tags.insert("window_size".to_string(), ws_str.clone());
            StatSample::metric(
                VizGraphSignals::ANOMALY_FLAG.to_string(),
                abs_score,
                tags,
                ts,
            )
        });

        score
    }

    pub fn is_anomalous(z_score: f32, threshold: f32) -> bool {
        z_score.abs() >= threshold
    }
}
