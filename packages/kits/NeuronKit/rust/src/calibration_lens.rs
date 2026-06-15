// calibration_lens.rs
//
// Calibration lens — maps claimed confidence values through a
// MatrixCalibrationCurve to data-backed empirical success rates
// (NEURONKIT_SPEC.md § 8.2, Lens 5 Grounding+Trust).
//
// Delegates to MatrixCalibrationCurve::calibrate for each claimed value.
// `is_calibrated` is derived from the bucket observation count using the
// same index formula as `calibrate()` — necessary because `calibrate()`
// returns the claimed value unchanged when count == 0, making it
// impossible to distinguish a calibrated result coincidentally equal to
// the claim. The bucket index is structural input shaping (I-17).
// Pure, stateless, no estate access (I-18, B-5). Total over edge inputs (B-8, C-16).

use genius_locus_kit::MatrixCalibrationCurve;

/// One claimed confidence value mapped to its data-backed calibrated rate.
#[derive(Debug, Clone, PartialEq)]
pub struct CalibratedValue {
    /// Original claimed confidence supplied by the caller ([0.0, 1.0]).
    pub claimed: f32,
    /// Empirical success rate from the calibration curve's matching bin.
    /// Equals `claimed` when `is_calibrated` is false.
    pub calibrated: f32,
    /// True when the matching bin has at least one observation.
    pub is_calibrated: bool,
}

/// Maps a batch of claimed confidence values through a calibration curve.
///
/// Returns empty for empty `claimed` (B-8).
pub fn calibrate(curve: &MatrixCalibrationCurve, claimed: &[f32]) -> Vec<CalibratedValue> {
    if claimed.is_empty() {
        return vec![];
    }
    claimed.iter().map(|&c| {
        // Replicate the bucket-index formula from MatrixCalibrationCurve::calibrate
        // to read observation count for the is_calibrated flag.
        // BUCKET_COUNT = 20.
        let clamped = c.clamp(0.0, 0.99999);
        let idx = ((clamped * MatrixCalibrationCurve::BUCKET_COUNT as f32) as usize)
            .min(MatrixCalibrationCurve::BUCKET_COUNT - 1);
        let bucket_has_data = curve.buckets[idx].count > 0;
        let calibrated = curve.calibrate(c);
        CalibratedValue {
            claimed: c,
            calibrated,
            is_calibrated: bucket_has_data,
        }
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use genius_locus_kit::{MatrixCalibrationCurve, MatrixCalibrationOutcome};

    #[test]
    fn empty_claimed_yields_empty() {
        let curve = MatrixCalibrationCurve::new();
        assert!(calibrate(&curve, &[]).is_empty());
    }

    #[test]
    fn no_data_curve_all_uncalibrated() {
        let curve = MatrixCalibrationCurve::new();
        let result = calibrate(&curve, &[0.1, 0.5, 0.9]);
        assert_eq!(result.len(), 3);
        assert!(result.iter().all(|v| !v.is_calibrated));
    }

    #[test]
    fn no_data_curve_pass_through() {
        let curve = MatrixCalibrationCurve::new();
        let result = calibrate(&curve, &[0.4]);
        assert!((result[0].calibrated - 0.4).abs() < 1e-6);
        assert_eq!(result[0].claimed, 0.4);
    }

    #[test]
    fn data_backed_bin_is_calibrated() {
        let mut curve = MatrixCalibrationCurve::new();
        curve.record(0.7, MatrixCalibrationOutcome::Success);
        let result = calibrate(&curve, &[0.7]);
        assert!(result[0].is_calibrated);
    }

    #[test]
    fn calibrated_value_matches_curve() {
        let mut curve = MatrixCalibrationCurve::new();
        curve.record(0.3, MatrixCalibrationOutcome::Success);
        curve.record(0.3, MatrixCalibrationOutcome::Failure);
        let claimed = 0.3f32;
        let result = calibrate(&curve, &[claimed]);
        let direct = curve.calibrate(claimed);
        assert!((result[0].calibrated - direct).abs() < 1e-6);
    }

    #[test]
    fn result_length_equals_claimed_length() {
        let curve = MatrixCalibrationCurve::new();
        let result = calibrate(&curve, &[0.1, 0.2, 0.3, 0.4, 0.5]);
        assert_eq!(result.len(), 5);
    }

    #[test]
    fn claimed_field_preserved() {
        let curve = MatrixCalibrationCurve::new();
        let result = calibrate(&curve, &[0.25, 0.75]);
        assert_eq!(result[0].claimed, 0.25);
        assert_eq!(result[1].claimed, 0.75);
    }

    #[test]
    fn deterministic() {
        let mut curve = MatrixCalibrationCurve::new();
        curve.record(0.5, MatrixCalibrationOutcome::Success);
        let r1 = calibrate(&curve, &[0.5, 0.9]);
        let r2 = calibrate(&curve, &[0.5, 0.9]);
        assert_eq!(r1, r2);
    }

    // C-17 fidelity: calibrated value must equal MatrixCalibrationCurve::calibrate directly.
    #[test]
    fn c17_fidelity_calibrated_equals_primitive() {
        let mut curve = MatrixCalibrationCurve::new();
        curve.record(0.65, MatrixCalibrationOutcome::Success);
        curve.record(0.65, MatrixCalibrationOutcome::Failure);
        let claimed = 0.65f32;
        let direct = curve.calibrate(claimed);
        let result = calibrate(&curve, &[claimed]);
        assert_eq!(result[0].calibrated, direct,
            "lens calibrated must equal MatrixCalibrationCurve::calibrate on the same input");
    }
}
