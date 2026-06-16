import SubstrateML
import SubstrateTypes

// Rhythm lens — finds the top-K dominant periodic signals in a boolean
// activity series (SPEC § 8.2, Lens 2 Prediction+Time).
//
// Series is a sequence of equal-duration time buckets; true = activity
// present in that bucket, false = absent. The lens zero-pads to the next
// power of two (required by FFT.forward), calls FFT.forward, extracts
// positive-frequency bins 1..N/2, normalises each bin's magnitude by
// total AC energy, and returns the top-K periods sorted by relative
// magnitude descending. Owns no math (I-17). Pure, stateless, no estate
// access (I-18). Total over edge inputs (B-8, C-16).
//
// DC component (bin 0) is skipped — it encodes mean activity level, not
// periodicity.

/// One dominant periodic component extracted from the activity series.
public struct DominantPeriod: Sendable, Equatable {
    /// Duration of the dominant cycle in seconds.
    public let periodSeconds: Double
    /// Fraction of total AC spectral energy in this period (0.0–1.0).
    public let relativeMagnitude: Double

    public init(periodSeconds: Double, relativeMagnitude: Double) {
        self.periodSeconds = periodSeconds
        self.relativeMagnitude = relativeMagnitude
    }
}

extension NeuronKit {
    /// Finds the top-K dominant periodic components in a boolean activity series.
    ///
    /// - Parameters:
    ///   - buckets: Activity presence flags for equal-duration time buckets.
    ///   - bucketDurationSeconds: Duration of each bucket in seconds; must be > 0.
    ///   - topK: Maximum number of dominant periods to return.
    /// - Returns: `DominantPeriod` array sorted by relative magnitude descending,
    ///   length ≤ `topK`. Returns empty for series shorter than 4 buckets,
    ///   all-constant series, non-positive `bucketDurationSeconds`, or `topK` ≤ 0 (B-8).
    public static func rhythm(
        buckets: [Bool],
        bucketDurationSeconds: Double,
        topK: Int
    ) -> [DominantPeriod] {
        guard topK > 0,
              bucketDurationSeconds > 0,
              buckets.count >= 4 else { return [] }

        let real = buckets.map { $0 ? 1.0 : 0.0 }

        // All-constant series carries no frequency information.
        guard !real.dropFirst().allSatisfy({ $0 == real[0] }) else { return [] }

        // Zero-pad to next power of two as required by FFT.forward.
        var nPadded = 1
        while nPadded < real.count { nPadded <<= 1 }
        let padded = real + [Double](repeating: 0.0, count: nPadded - real.count)

        let spectrum = FFT.forward(real: padded)

        // Positive-frequency bins 1..N/2 (skip DC at 0, skip conjugate mirror above N/2).
        // Period for bin i = nPadded buckets / i bins = nPadded / i * bucketDurationSeconds.
        let n2 = nPadded / 2
        var bins: [(period: Double, magnitude: Double)] = []
        bins.reserveCapacity(n2)
        for i in 1...n2 {
            let mag = spectrum[i].magnitude
            let period = Double(nPadded) / Double(i) * bucketDurationSeconds
            bins.append((period: period, magnitude: mag))
        }

        // Total AC energy for relative magnitude normalisation.
        let totalAC = bins.reduce(0.0) { $0 + $1.magnitude }
        guard totalAC > 0 else { return [] }

        return bins
            .map { DominantPeriod(periodSeconds: $0.period,
                                  relativeMagnitude: $0.magnitude / totalAC) }
            .sorted { $0.relativeMagnitude > $1.relativeMagnitude }
            .prefix(topK)
            .map { $0 }
    }
}
