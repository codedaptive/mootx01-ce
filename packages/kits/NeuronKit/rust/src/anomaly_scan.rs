//! Anomaly scan — z-score outlier detection (Lens 5, Surprise): the NeuronKit
//! reasoning surface over SubstrateML's `AnomalyDetection`. Given a value
//! series, flag the entries that stand out from the rest — the substrate of
//! the "Contradiction / odd-one-out" lens (a memory whose cohesion with its
//! peers is anomalously low doesn't fit; the estate notices the tension).
//!
//! Layer B-1: the z-score math lives in SubstrateML; this shapes a series into
//! flagged outliers. CognitionKit sequences it (derive the series from the
//! estate, then call this).

use substrate_ml::anomaly::AnomalyDetection;

/// One flagged entry: its index in the input series and its z-score (signed —
/// negative = below the mean, e.g. a low-cohesion outlier).
#[derive(Clone, Debug, PartialEq)]
pub struct Anomaly {
    pub index: usize,
    pub z_score: f32,
}

/// Flag series entries whose z-score magnitude meets `threshold`. The mean and
/// standard deviation are computed over the whole series; a series with (near)
/// zero spread has no outliers (guarded — avoids a divide-by-zero z-score).
pub fn anomalies(values: &[f32], threshold: f32) -> Vec<Anomaly> {
    let n = values.len();
    if n == 0 {
        return Vec::new();
    }
    let mean = values.iter().sum::<f32>() / n as f32;
    let var = values.iter().map(|v| (v - mean).powi(2)).sum::<f32>() / n as f32;
    let std = var.sqrt();
    if std < 1e-6 {
        return Vec::new(); // no spread ⇒ nothing stands out
    }
    let mut out = Vec::new();
    for (i, &v) in values.iter().enumerate() {
        let z = AnomalyDetection::z_score(v, mean, std);
        if AnomalyDetection::is_anomalous(z, threshold) {
            out.push(Anomaly { index: i, z_score: z });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // AN-1: a single spike in a flat series is flagged (high positive z).
    #[test]
    fn an1_spike_is_flagged() {
        let v = [10.0_f32, 10.0, 10.0, 10.0, 100.0];
        let a = anomalies(&v, 1.5);
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].index, 4);
        assert!(a[0].z_score > 0.0, "the spike is above the mean");
    }

    // AN-2: a low outlier is flagged with a NEGATIVE z (the "doesn't fit"
    // signal the contradiction lens uses).
    #[test]
    fn an2_low_outlier_is_negative_z() {
        let v = [9.0_f32, 10.0, 9.0, 10.0, 0.0];
        let a = anomalies(&v, 1.5);
        assert!(a.iter().any(|x| x.index == 4 && x.z_score < 0.0), "the low outlier is below the mean");
    }

    // AN-3: a flat series has no outliers (guarded zero-spread).
    #[test]
    fn an3_flat_series_no_anomalies() {
        assert!(anomalies(&[5.0_f32, 5.0, 5.0], 1.0).is_empty());
        assert!(anomalies(&[], 1.0).is_empty());
    }
}
