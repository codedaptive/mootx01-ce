// AnomalyDetection.swift
//
// Anomaly detection per cookbook § 8.13.
//
// Statistical anomaly scoring for ambient streams and matrix-tier
// cells. The substrate computes z-scores against a rolling window
// baseline and flags rows whose values fall outside a threshold
// (default ±3 standard deviations, ~0.27% false positive rate on
// a normal distribution). For non-normal distributions (heavy
// tails, count data), the modified z-score using median absolute
// deviation provides a more robust signal.
//
//   z(x; μ, σ)        = (x - μ) / σ
//   z_modified(x;     = 0.6745 × (x - median) / MAD
//                med, MAD)
//   anomalous(z; T)   = |z| ≥ T            T default 3.0
//
// Used by:
//   § 8.13   Anomaly detection definition (this file)
//   § 3.9    Ambient stream ingest (per-sample anomaly tag)
//   § 11.18  Anomaly-aware recall (probe with anomalous flag)
//   § 15     Dreaming daemon rule 7 (anomaly scan)

import Foundation

public enum AnomalyDetection {

    /// Classic z-score. Returns 0 when stddev is zero (no
    /// statistical structure to score against).
    @inlinable
    public static func zScore(value: Float32,
                              mean: Float32,
                              stddev: Float32) -> Float32 {
        guard stddev > 0 else { return 0 }
        return (value - mean) / stddev
    }

    /// Rolling-window z-score using the supplied window as the
    /// baseline distribution. Empty window returns 0.
    public static func rollingZScore(window: [Float32],
                                     current: Float32) -> Float32 {
        guard !window.isEmpty else { return 0 }
        let n = Float32(window.count)
        let mean = window.reduce(0, +) / n
        let variance = window.reduce(Float32(0)) { acc, x in
            let d = x - mean
            return acc + d * d
        } / n
        let stddev = variance.squareRoot()
        return zScore(value: current, mean: mean, stddev: stddev)
    }

    /// Modified z-score using median absolute deviation. More
    /// robust to outliers and heavy-tailed distributions than
    /// the classic mean/stddev approach. The 0.6745 constant
    /// makes the score consistent with the normal-distribution
    /// z-score (so the same threshold applies on normal data).
    public static func modifiedZScore(value: Float32,
                                      median: Float32,
                                      mad: Float32) -> Float32 {
        guard mad > 0 else { return 0 }
        return 0.6745 * (value - median) / mad
    }

    /// Rolling modified z-score. Computes median and MAD from
    /// the window in-place.
    public static func rollingModifiedZScore(window: [Float32],
                                             current: Float32) -> Float32 {
        guard !window.isEmpty else { return 0 }
        // In-place sort on a single mutable copy instead of
        // `.sorted()` (which allocates a fresh array per call).
        // At n=100k Swift's .sorted() was allocating ~400KB per
        // call on top of the sort work; doing sort() in place on
        // a single clone is ~5x faster on the bench. Sort order
        // identical to Rust's `sort_by(partial_cmp().unwrap_or(Equal))`
        // for all non-NaN inputs (which is every conformance
        // vector case). anomaly CRC 0x6c6fda4d unchanged.
        var sortedWindow = window
        sortedWindow.sort()
        let median = sortedWindow[sortedWindow.count / 2]
        var deviations = window.map { abs($0 - median) }
        deviations.sort()
        let mad = deviations[deviations.count / 2]
        return modifiedZScore(value: current, median: median, mad: mad)
    }

    /// Apply the |z| ≥ threshold rule. Default threshold of 3.0
    /// yields ~0.27% false positive rate under normal distribution.
    @inlinable
    public static func isAnomalous(zScore: Float32,
                                   threshold: Float32 = 3.0) -> Bool {
        return abs(zScore) >= threshold
    }
}
