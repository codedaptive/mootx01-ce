// rhythm.rs
//
// Rhythm lens — finds top-K dominant periodic signals in a boolean activity
// series (NEURONKIT_SPEC.md § 8.2, Lens 2 Prediction+Time).
//
// Converts booleans to f64, zero-pads to next power of two (required by
// substrate_ml::fft::forward), extracts positive-frequency bins 1..N/2,
// normalises magnitudes by total AC energy, and returns top-K periods
// sorted by relative magnitude descending. Owns no math (I-17). Pure,
// stateless, no estate access (I-18, B-5). Total over edge inputs (B-8, C-16).

use substrate_ml::fft;

/// One dominant periodic component extracted from the activity series.
#[derive(Debug, Clone, PartialEq)]
pub struct DominantPeriod {
    /// Duration of the dominant cycle in seconds.
    pub period_seconds: f64,
    /// Fraction of total AC spectral energy in this period (0.0–1.0).
    pub relative_magnitude: f64,
}

/// Finds the top-K dominant periodic components in a boolean activity series.
///
/// Returns empty for series shorter than 4 buckets, all-constant series,
/// non-positive `bucket_duration_seconds`, or `top_k` == 0 (B-8).
pub fn rhythm(buckets: &[bool], bucket_duration_seconds: f64, top_k: usize) -> Vec<DominantPeriod> {
    if top_k == 0 || bucket_duration_seconds <= 0.0 || buckets.len() < 4 {
        return vec![];
    }
    let real: Vec<f64> = buckets.iter().map(|&b| if b { 1.0 } else { 0.0 }).collect();

    // All-constant series carries no frequency information.
    if real[1..].iter().all(|&v| v == real[0]) {
        return vec![];
    }

    // Zero-pad to next power of two as required by fft::forward.
    let mut n_padded = 1usize;
    while n_padded < real.len() {
        n_padded <<= 1;
    }
    let mut padded = real.clone();
    padded.resize(n_padded, 0.0);

    let spectrum = fft::forward(&padded);

    // Positive-frequency bins 1..n_padded/2 (skip DC at 0, skip conjugate mirror).
    let n2 = n_padded / 2;
    let mut bins: Vec<(f64, f64)> = Vec::with_capacity(n2);
    for i in 1..=n2 {
        let c = &spectrum[i];
        let mag = (c.real * c.real + c.imag * c.imag).sqrt();
        let period = (n_padded as f64) / (i as f64) * bucket_duration_seconds;
        bins.push((period, mag));
    }

    let total_ac: f64 = bins.iter().map(|b| b.1).sum();
    if total_ac == 0.0 {
        return vec![];
    }

    let mut result: Vec<DominantPeriod> = bins
        .into_iter()
        .map(|(period, mag)| DominantPeriod {
            period_seconds: period,
            relative_magnitude: mag / total_ac,
        })
        .collect();
    result.sort_by(|a, b| b.relative_magnitude.partial_cmp(&a.relative_magnitude).unwrap());
    result.truncate(top_k);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_series_yields_empty() {
        assert!(rhythm(&[], 1.0, 3).is_empty());
        assert!(rhythm(&[true, false, true], 1.0, 3).is_empty());
    }

    #[test]
    fn all_constant_true_yields_empty() {
        assert!(rhythm(&[true; 8], 1.0, 3).is_empty());
    }

    #[test]
    fn all_constant_false_yields_empty() {
        assert!(rhythm(&[false; 8], 1.0, 3).is_empty());
    }

    #[test]
    fn top_k_zero_yields_empty() {
        let b = [true, false, true, false, true, false, true, false];
        assert!(rhythm(&b, 1.0, 0).is_empty());
    }

    #[test]
    fn non_positive_duration_yields_empty() {
        let b = [true, false, true, false, true, false, true, false];
        assert!(rhythm(&b, 0.0, 3).is_empty());
        assert!(rhythm(&b, -1.0, 3).is_empty());
    }

    #[test]
    fn alternating_dominant_period_is_2s() {
        // Alternating true/false at 1-second buckets: dominant period = 2 * 1.0 s.
        let b = [true, false, true, false, true, false, true, false];
        let result = rhythm(&b, 1.0, 1);
        assert!(!result.is_empty());
        assert!((result[0].period_seconds - 2.0).abs() < 0.001,
            "alternating dominant period should be ~2 s, got {}", result[0].period_seconds);
    }

    #[test]
    fn sorted_descending_by_relative_magnitude() {
        let b = [true, false, true, false, true, false, true, false,
                 true, false, true, false, true, false, true, false];
        let result = rhythm(&b, 1.0, 4);
        for w in result.windows(2) {
            assert!(w[0].relative_magnitude >= w[1].relative_magnitude);
        }
    }

    #[test]
    fn capped_to_top_k() {
        let b = [true, false, true, false, true, false, true, false];
        let result = rhythm(&b, 1.0, 2);
        assert!(result.len() <= 2);
    }

    #[test]
    fn relative_magnitudes_sum_at_most_one() {
        let b = [true, false, true, true, false, false, true, false];
        let result = rhythm(&b, 60.0, 10);
        let sum: f64 = result.iter().map(|d| d.relative_magnitude).sum();
        assert!(sum <= 1.0 + 1e-9, "relative magnitudes sum = {}", sum);
    }

    #[test]
    fn deterministic() {
        let b = [true, false, true, false, true, false, true, false];
        let r1 = rhythm(&b, 3600.0, 3);
        let r2 = rhythm(&b, 3600.0, 3);
        assert_eq!(r1, r2);
    }

    // C-17 fidelity: dominant period must equal the period of the highest-magnitude
    // positive-frequency bin from a direct fft::forward call on the same padded input.
    #[test]
    fn c17_fidelity_period_equals_primitive() {
        let b = [true, false, true, false, true, false, true, false];
        let duration = 1.0f64;
        let real: Vec<f64> = b.iter().map(|&v| if v { 1.0 } else { 0.0 }).collect();
        let spectrum = fft::forward(&real);  // N=8, already power-of-two
        let n2 = real.len() / 2;
        let dom_bin = (1..=n2)
            .max_by(|&i, &j| spectrum[i].magnitude().partial_cmp(&spectrum[j].magnitude()).unwrap())
            .unwrap();
        let expected_period = (real.len() as f64) / (dom_bin as f64) * duration;
        let result = rhythm(&b, duration, 1);
        assert!(!result.is_empty());
        assert!((result[0].period_seconds - expected_period).abs() < 1e-9,
            "lens period must equal fft::forward bin period");
    }
}
