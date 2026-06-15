import SubstrateML
import SubstrateTypes

// Precedence lens — ranks the strongest antecedent field-value coordinates
// for a given target from a pre-folded T-matrix (SPEC § 8.2, Lens 3 Prediction).
//
// Input is the output of TemporalCausalityFold.fold already computed by
// GeniusLocusKit and handed to the lens by CognitionKit. The lens shapes
// (filter → sort → take) to produce a ranked antecedent list; it calls no
// fold primitive itself, which preserves I-18 (no estate touch). Owns no
// math (I-17). Pure, stateless (I-18, B-5). Total over edge inputs (B-8, C-16).

/// One antecedent ranked by co-occurrence count.
public struct AntecedentRank: Sendable, Equatable {
    /// Antecedent field-value coordinate that precedes the target.
    public let source: TemporalFieldCoord
    /// Log-spaced lag bucket in minutes for this pair.
    public let lagBucket: Int
    /// Observation count from the T-matrix for this (source → target, lag) triple.
    public let count: Int64

    public init(source: TemporalFieldCoord, lagBucket: Int, count: Int64) {
        self.source = source
        self.lagBucket = lagBucket
        self.count = count
    }
}

extension NeuronKit {
    /// Ranks the strongest antecedents for a target field-value coordinate.
    ///
    /// - Parameters:
    ///   - pairs: Pre-folded T-matrix entries from `TemporalCausalityFold.fold`,
    ///     each pairing a `TemporalCausalityKey` with its observation count.
    ///   - target: The field-value coordinate whose antecedents are sought.
    ///   - k: Maximum number of antecedents to return.
    /// - Returns: `AntecedentRank` array sorted by count descending, length ≤ `k`.
    ///   Returns empty when `pairs` is empty, `k` ≤ 0, or no pair targets `target` (B-8).
    public static func precedence(
        pairs: [(TemporalCausalityKey, Int64)],
        target: TemporalFieldCoord,
        k: Int
    ) -> [AntecedentRank] {
        guard k > 0, !pairs.isEmpty else { return [] }
        return pairs
            .filter { $0.0.target == target }
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .map { AntecedentRank(source: $0.0.source,
                                  lagBucket: $0.0.lagBucket,
                                  count: $0.1) }
    }
}
