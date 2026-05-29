// Calibration.swift
//
// Mission GLK-06 — Per-model LLM calibration curves.
//
// A calibration curve maps a model's claimed confidence into its
// empirical success rate. A proposal carrying claimed 0.8 from a
// model whose 0.8 bucket has historically resolved at 0.6 is deflated
// to 0.6 for downstream decision-making (cookbook §6.6).
//
// Twenty equal-width buckets cover [0.0, 1.0). Each bucket holds a
// rolling success rate updated incrementally on every observed
// outcome. The curve is keyed by model identifier and ships with the
// matrix tier so consumers can correct overconfidence on the fly.

import Foundation

// MARK: - Bucket

/// One bucket of one calibration curve. `count` is the number of
/// observations; `successRate` is the running mean of `1.0` for
/// success outcomes and `0.0` for failure outcomes.
public struct MatrixCalibrationBucket: Sendable, Equatable, Codable {
    public var count: Int32
    public var successRate: Float

    public init(count: Int32 = 0, successRate: Float = 0.0) {
        self.count = count
        self.successRate = successRate
    }
}

/// Outcome of one observation feeding the calibration curve. The
/// `success` outcome moves the bucket mean up; `failure` moves it
/// down (toward zero). The cookbook leaves `partial` and `regressed`
/// for the action-outcome matrix (§6.5), which is not in scope here.
public enum MatrixCalibrationOutcome: String, Sendable, Codable {
    case success
    case failure
}

// MARK: - Curve

/// Calibration curve for one model. Twenty buckets cover the unit
/// interval; each bucket tracks count and rolling success rate.
public struct MatrixCalibrationCurve: Sendable, Equatable, Codable {

    /// Number of buckets per cookbook §6.6: 20 buckets of 0.05 width.
    public static let bucketCount: Int = 20

    public private(set) var buckets: [MatrixCalibrationBucket]

    public init() {
        self.buckets = Array(
            repeating: MatrixCalibrationBucket(),
            count: Self.bucketCount
        )
    }

    /// Record one observation. Confidence is clamped to `[0, 1)` so
    /// the bucket index always lands in range.
    public mutating func record(
        claimedConfidence: Float,
        outcome: MatrixCalibrationOutcome
    ) {
        let clamped = max(0.0, min(0.99999, claimedConfidence))
        let idx = min(
            Self.bucketCount - 1,
            Int(clamped * Float(Self.bucketCount))
        )
        var bucket = buckets[idx]
        let oldCount = Float(bucket.count)
        bucket.count &+= 1
        let outcomeBit: Float = (outcome == .success) ? 1.0 : 0.0
        // Running mean: new_mean = old_mean * (n-1)/n + outcome / n.
        bucket.successRate =
            (bucket.successRate * oldCount + outcomeBit) / Float(bucket.count)
        buckets[idx] = bucket
    }

    /// Deflate (or inflate) a claimed confidence to the empirical
    /// success rate of its bucket. Buckets with zero observations
    /// pass the claimed value through unchanged — there is no
    /// evidence to override the model's claim.
    public func calibrate(claimedConfidence: Float) -> Float {
        let clamped = max(0.0, min(0.99999, claimedConfidence))
        let idx = min(
            Self.bucketCount - 1,
            Int(clamped * Float(Self.bucketCount))
        )
        let bucket = buckets[idx]
        return bucket.count > 0 ? bucket.successRate : claimedConfidence
    }
}

// MARK: - Curve registry

/// Per-model calibration curve registry. Keyed by stable model id
/// (e.g. "anthropic.claude-opus-4-7", "openai.gpt-4o"). The substrate
/// keeps one curve per id; cross-model calibration would mask
/// systematic per-model bias and is explicitly avoided.
public struct MatrixCalibrationRegistry: Sendable, Equatable, Codable {
    public private(set) var curves: [String: MatrixCalibrationCurve]

    public init() {
        self.curves = [:]
    }

    /// Record an observation against `modelID`. Creates the curve on
    /// first sight.
    public mutating func record(
        modelID: String,
        claimedConfidence: Float,
        outcome: MatrixCalibrationOutcome
    ) {
        var curve = curves[modelID] ?? MatrixCalibrationCurve()
        curve.record(claimedConfidence: claimedConfidence,
                     outcome: outcome)
        curves[modelID] = curve
    }

    /// Calibrate one claimed confidence for one model. Unknown models
    /// pass through unchanged; the substrate cannot deflate what it
    /// has not yet observed.
    public func calibrate(
        modelID: String,
        claimedConfidence: Float
    ) -> Float {
        guard let curve = curves[modelID] else { return claimedConfidence }
        return curve.calibrate(claimedConfidence: claimedConfidence)
    }
}
