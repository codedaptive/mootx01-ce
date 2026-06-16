// Calibration.swift
//
// Per-model LLM calibration curves (cookbook §6.6).
//
// A calibration curve maps a model's claimed confidence into its
// empirical success rate. A proposal carrying claimed 0.8 from a
// model whose 0.8 bucket has historically resolved at 0.6 is deflated
// to 0.6 for downstream decision-making.
//
// Twenty equal-width buckets cover [0.0, 1.0). Each bucket holds a
// rolling success rate updated incrementally on every observed
// outcome. The curve is keyed by model identifier and ships with the
// matrix tier so consumers can correct overconfidence on the fly.
//
// Decay (math treatise §8, dormant-surfaces mission Part 4):
//   Observations lose influence over time via a 30-day half-life.
//   Decay is lazy — applied at write time, not on a schedule.
//   The multiplicative factor `0.5^(elapsed / halfLife)` is applied
//   to each bucket's `count`, reducing the weight of old observations
//   without changing the bucket's current success rate. On the next
//   `record` call the decayed count participates in the running mean
//   at its reduced weight. A model that was last updated 30 days ago
//   loses half its historic influence before the new outcome lands.

import Foundation

// MARK: - Bucket

/// One bucket of one calibration curve. `count` is the effective
/// (possibly decayed) number of observations; `successRate` is the
/// running mean of 1.0 for success outcomes and 0.0 for failure.
public struct MatrixCalibrationBucket: Sendable, Equatable, Codable {
    public var count: Int32
    public var successRate: Float

    public init(count: Int32 = 0, successRate: Float = 0.0) {
        self.count = count
        self.successRate = successRate
    }

    /// Apply multiplicative decay to this bucket's effective count.
    ///
    /// `factor` is `0.5^(elapsedDays / halfLifeDays)`. Applying decay
    /// reduces the influence of past observations on future running-mean
    /// updates without changing the current success rate. A count that
    /// decays to zero means no historical evidence remains for this bucket.
    public mutating func applyDecay(factor: Double) {
        let decayed = Int32(max(0, (Double(count) * factor).rounded()))
        count = decayed
        // successRate is a rate, not a sum — it does not change under decay.
        // Only the observation weight (count) shrinks.
    }
}

/// Outcome of one observation feeding the calibration curve.
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

    /// Apply multiplicative decay to all buckets.
    ///
    /// `elapsedDays` is the time since the last update. `halfLifeDays`
    /// is 30 per math treatise §8. Decay is skipped for sub-day intervals
    /// to avoid floating-point noise on rapid successive calls.
    public mutating func applyDecay(
        elapsedDays: Double,
        halfLifeDays: Double = 30.0
    ) {
        guard elapsedDays >= 1.0 else { return }
        let factor = pow(0.5, elapsedDays / halfLifeDays)
        for i in 0..<buckets.count {
            buckets[i].applyDecay(factor: factor)
        }
    }
}

// MARK: - Curve registry

/// Per-model calibration curve registry. Keyed by stable model id
/// (e.g. "anthropic.claude-opus-4-7", "openai.gpt-4o"). The substrate
/// keeps one curve per id; cross-model calibration would mask
/// systematic per-model bias and is explicitly avoided.
public struct MatrixCalibrationRegistry: Sendable, Equatable, Codable {
    public private(set) var curves: [String: MatrixCalibrationCurve]

    /// Last-update timestamps keyed by model id.
    ///
    /// Stored as `Double` (seconds since reference date) for Codable
    /// simplicity. Used by `recordWithDecay` to compute elapsed time
    /// for the lazy decay pass. Decoded with `decodeIfPresent` so
    /// snapshots written before the dormant-surfaces mission round-trip
    /// cleanly — a missing key means no decay has been applied yet.
    public private(set) var updateTimestamps: [String: Double]

    public init() {
        self.curves = [:]
        self.updateTimestamps = [:]
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case curves
        case updateTimestamps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        curves = try container.decode([String: MatrixCalibrationCurve].self, forKey: .curves)
        // Backward-compatible decode: snapshots written before this field existed
        // decode to an empty dict, which means all models start with no timestamp
        // and receive no decay on first write (correct — no prior history to decay).
        updateTimestamps = try container.decodeIfPresent(
            [String: Double].self,
            forKey: .updateTimestamps
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(curves, forKey: .curves)
        try container.encode(updateTimestamps, forKey: .updateTimestamps)
    }

    // MARK: Plain record (no decay)

    /// Record an observation against `modelID`. Creates the curve on
    /// first sight.
    public mutating func record(
        modelID: String,
        claimedConfidence: Float,
        outcome: MatrixCalibrationOutcome
    ) {
        var curve = curves[modelID] ?? MatrixCalibrationCurve()
        curve.record(claimedConfidence: claimedConfidence, outcome: outcome)
        curves[modelID] = curve
    }

    // MARK: Decay-aware record (dormant-surfaces §8)

    /// Apply 30-day-half-life decay then record one observation.
    ///
    /// Decay is computed lazily from the last recorded timestamp for
    /// `modelID` and the supplied `now`. If this is the first observation
    /// for the model, no decay is applied. After recording, `updateTimestamps`
    /// is advanced to `now` so the next call's decay window starts here.
    ///
    /// - Parameters:
    ///   - modelID: Stable model identifier.
    ///   - claimedConfidence: The model's claimed confidence, in `[0, 1)`.
    ///   - outcome: Observed result of the prediction.
    ///   - now: Current date (caller-supplied for determinism).
    ///   - halfLifeDays: Observation half-life in days (default 30 per §8).
    public mutating func recordWithDecay(
        modelID: String,
        claimedConfidence: Float,
        outcome: MatrixCalibrationOutcome,
        now: Date,
        halfLifeDays: Double = 30.0
    ) {
        var curve = curves[modelID] ?? MatrixCalibrationCurve()

        // Apply decay proportional to elapsed time since last update.
        if let lastTs = updateTimestamps[modelID] {
            let lastDate = Date(timeIntervalSinceReferenceDate: lastTs)
            let elapsedDays = now.timeIntervalSince(lastDate) / 86_400
            curve.applyDecay(elapsedDays: elapsedDays, halfLifeDays: halfLifeDays)
        }

        curve.record(claimedConfidence: claimedConfidence, outcome: outcome)
        curves[modelID] = curve
        updateTimestamps[modelID] = now.timeIntervalSinceReferenceDate
    }

    // MARK: Calibrate

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
