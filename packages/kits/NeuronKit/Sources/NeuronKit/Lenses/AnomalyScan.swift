import SubstrateML

// Anomaly scan — z-score outlier detection (SPEC § 7.5, Lens 5
// Surprise): the NeuronKit reasoning surface over SubstrateML's
// `AnomalyDetection`. Given a value series, flag the entries that stand
// out from the rest — the substrate of the "contradiction /
// odd-one-out" lens (a memory whose cohesion with its peers is
// anomalously low doesn't fit; the estate notices the tension).
// Surfaces the gated z-score math; the lens only shapes a series into
// flagged outliers (I-17). Pure and total (I-18, B-8). CognitionKit
// sequences it (derive the series from the estate, then call this).

/// One flagged entry: its index in the input series and its z-score
/// (signed — negative = below the mean, e.g. a low-cohesion outlier).
public struct Anomaly: Sendable, Equatable, Codable {
    public let index: Int
    public let zScore: Float
    public init(index: Int, zScore: Float) {
        self.index = index
        self.zScore = zScore
    }
}

extension NeuronKit {
    /// Flag series entries whose z-score magnitude meets `threshold`.
    /// The mean and standard deviation are computed over the whole
    /// series; a series with (near) zero spread has no outliers
    /// (guarded — avoids a divide-by-zero z-score).
    public static func anomalies(values: [Float], threshold: Float) -> [Anomaly] {
        guard !values.isEmpty else { return [] }
        let n = Float(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let stddev = variance.squareRoot()
        guard stddev >= 1e-6 else { return [] }   // no spread ⇒ nothing stands out

        return values.enumerated().compactMap { index, value in
            let z = AnomalyDetection.zScore(value: value, mean: mean, stddev: stddev)
            guard AnomalyDetection.isAnomalous(zScore: z, threshold: threshold) else {
                return nil
            }
            return Anomaly(index: index, zScore: z)
        }
    }
}
