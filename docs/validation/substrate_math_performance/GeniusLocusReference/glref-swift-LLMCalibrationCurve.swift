// LLMCalibrationCurve.swift
//
// LLM calibration curve per cookbook § 6.6.
//
// Records the empirical reliability of language-model confidence
// claims. The cognition tier (§ 10) emits a (claimed_confidence,
// actual_outcome) pair whenever a probabilistic claim resolves;
// the curve bins claimed values into 20 buckets of width 0.05 and
// records hit/miss counts per bucket.
//
//   bin[i] = (predicted_count, hit_count)   for i in 0..19
//   bin width = 0.05
//
// Aggregate metrics (computed on demand):
//   actual_rate(i) = hit_count[i] / predicted_count[i]
//   expected_calibration_error = sum_i  (predicted_count[i] / N)
//                                       × |actual_rate(i) - midpoint(i)|
//   brier_score = sum_i  (predicted_count[i] / N)
//                        × (actual_rate(i) - midpoint(i))^2
//
// Bitmap field referenced (cookbook § 2.4):
//   o09 confidence_bucket — 6 bits, twenty buckets at 0.05 increments
//                            over [0, 1] for calibration tracking.
//
// Decay: calibration HAS decay (cookbook § 6.8 table). Half-life:
// 30 days. Decay is fractional rather than count-zeroing so older
// observations contribute proportionally less.
//
// Used by:
//   § 6.6   Calibration curve definition (this file)
//   § 11.6  Recall confidence-interval annotation
//   § 15    Dreaming daemon rule 5 (calibration refresh)

import Foundation

public struct LLMCalibrationCurve: Sendable {
    public static let binCount: Int = 20
    public static let binWidth: Float32 = 0.05

    public private(set) var bins: [(predicted: UInt32, hit: UInt32)]
    public private(set) var sampleCount: UInt64

    public init() {
        bins = Array(repeating: (predicted: 0, hit: 0), count: Self.binCount)
        sampleCount = 0
    }

    /// Record one (claimedConfidence, actualOutcome) observation.
    public mutating func observe(claimedConfidence: Float32, actualOutcome: Bool) {
        precondition(claimedConfidence.isFinite,
                     "claimedConfidence must be finite")
        let clamped = max(0.0, min(0.999_999, claimedConfidence))
        let bucket = min(Self.binCount - 1,
                         Int(clamped * Float32(Self.binCount)))
        bins[bucket].predicted &+= 1
        if actualOutcome { bins[bucket].hit &+= 1 }
        sampleCount &+= 1
    }

    /// Actual hit rate in the given bucket, or nil for empty.
    public func actualRate(in bucket: Int) -> Float32? {
        precondition(bucket >= 0 && bucket < Self.binCount,
                     "bucket out of range")
        let b = bins[bucket]
        guard b.predicted > 0 else { return nil }
        return Float32(b.hit) / Float32(b.predicted)
    }

    /// Bucket midpoint, e.g. bucket 0 → 0.025, bucket 19 → 0.975.
    @inlinable
    public static func midpoint(of bucket: Int) -> Float32 {
        return (Float32(bucket) + 0.5) * binWidth
    }

    /// Expected calibration error: weighted absolute deviation of
    /// each populated bucket from the y = x reference line.
    public func expectedCalibrationError() -> Float32 {
        var weighted: Float32 = 0
        var total: Float32 = 0
        for (i, b) in bins.enumerated() where b.predicted > 0 {
            let actual = Float32(b.hit) / Float32(b.predicted)
            let weight = Float32(b.predicted)
            weighted += weight * abs(actual - Self.midpoint(of: i))
            total += weight
        }
        return total > 0 ? weighted / total : 0
    }

    /// Brier score: weighted squared deviation of each populated
    /// bucket from y = x. Lower is better.
    public func brierScore() -> Float32 {
        var sum: Float32 = 0
        var total: Float32 = 0
        for (i, b) in bins.enumerated() where b.predicted > 0 {
            let actual = Float32(b.hit) / Float32(b.predicted)
            let weight = Float32(b.predicted)
            let d = actual - Self.midpoint(of: i)
            sum += weight * d * d
            total += weight
        }
        return total > 0 ? sum / total : 0
    }

    /// Apply fractional decay to all bins. Used by MatrixDecay
    /// driven from the dreaming daemon. factor in [0, 1].
    public mutating func decay(factor: Float32) {
        precondition(factor >= 0 && factor <= 1,
                     "decay factor must be in [0,1]")
        for i in 0..<Self.binCount {
            bins[i].predicted = UInt32(Float32(bins[i].predicted) * factor)
            bins[i].hit = UInt32(Float32(bins[i].hit) * factor)
        }
        sampleCount = UInt64(Float32(sampleCount) * factor)
    }
}
