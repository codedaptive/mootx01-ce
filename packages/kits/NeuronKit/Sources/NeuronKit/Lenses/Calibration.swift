import GeniusLocusKit

// Calibration lens — maps claimed confidence values through a
// MatrixCalibrationCurve to data-backed empirical success rates
// (SPEC § 8.2, Lens 5 Grounding+Trust).
//
// Delegates to MatrixCalibrationCurve.calibrate for each claimed value.
// `isCalibrated` is derived from the bucket observation count using the
// same index formula as `calibrate()` — necessary because `calibrate()`
// returns the claimed value unchanged when count == 0, making it
// impossible to distinguish a calibrated result coincidentally equal to
// the claim. The bucket index is not new math; it is structural input
// shaping (I-17). Pure, stateless, no estate access (I-18, B-5).
// Total over edge inputs (B-8, C-16).

/// One claimed confidence value mapped to its data-backed calibrated rate.
public struct CalibratedValue: Sendable, Equatable {
    /// Original claimed confidence supplied by the caller (0.0–1.0).
    public let claimed: Float
    /// Empirical success rate from the calibration curve's matching bin.
    /// Equals `claimed` when `isCalibrated` is false.
    public let calibrated: Float
    /// True when the matching bin has at least one observation.
    public let isCalibrated: Bool

    public init(claimed: Float, calibrated: Float, isCalibrated: Bool) {
        self.claimed = claimed
        self.calibrated = calibrated
        self.isCalibrated = isCalibrated
    }
}

extension NeuronKit {
    /// Maps a batch of claimed confidence values through a calibration curve.
    ///
    /// - Parameters:
    ///   - curve: Twenty-bin `MatrixCalibrationCurve` from a prior GLK read.
    ///   - claimed: Claimed confidence values in [0.0, 1.0].
    /// - Returns: One `CalibratedValue` per input element. Returns empty for
    ///   empty `claimed` (B-8).
    public static func calibrate(
        curve: MatrixCalibrationCurve,
        claimed: [Float]
    ) -> [CalibratedValue] {
        guard !claimed.isEmpty else { return [] }
        return claimed.map { c in
            // Replicate the bucket-index formula from MatrixCalibrationCurve.calibrate
            // so we can read observation count without adding a dedicated query method.
            // bucketCount is 20 per MatrixCalibrationCurve.bucketCount.
            let clamped = max(0.0, min(0.99999, c))
            let idx = min(MatrixCalibrationCurve.bucketCount - 1,
                         Int(clamped * Float(MatrixCalibrationCurve.bucketCount)))
            let bucketHasData = curve.buckets[idx].count > 0
            let calibratedVal = curve.calibrate(claimedConfidence: c)
            return CalibratedValue(claimed: c,
                                   calibrated: calibratedVal,
                                   isCalibrated: bucketHasData)
        }
    }
}
