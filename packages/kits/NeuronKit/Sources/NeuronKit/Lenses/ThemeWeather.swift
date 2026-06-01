import SubstrateML

// Theme weather — recency momentum (SPEC § 7.2, Lens 2 Topics). A category's
// decay-weighted recent attention share, compared to its historical share,
// signals whether it is heating up or cooling down. "Estate planning is rising;
// job search is fading." Surfaces SubstrateML's exponential decay; owns no math
// (I-17), pure and total (I-18, B-8).

/// One category's momentum: its recent attention share minus its historical
/// share. Positive = heating (recent share exceeds historical); negative =
/// cooling.
public struct CategoryMomentum: Sendable, Equatable, Codable {
    public let category: String
    public let momentum: Double
    public init(category: String, momentum: Double) {
        self.category = category
        self.momentum = momentum
    }
}

extension NeuronKit {
    /// Recency weight of an event `elapsedSeconds` old under `halfLifeSeconds` —
    /// 1.0 at "now", halving each half-life. A thin surface over SubstrateML's
    /// `decayFactor` so a recipe can weight recent memories more heavily.
    public static func recencyWeight(elapsedSeconds: Double, halfLifeSeconds: Double) -> Double {
        SubstrateML.MatrixDecay.decayFactor(elapsedSeconds: elapsedSeconds,
                                            halfLifeSeconds: halfLifeSeconds)
    }

    /// Momentum per category from `(category, rawCount, weightedMass)`, where
    /// `weightedMass` is the sum of `recencyWeight` over the category's
    /// memories. Momentum = (weightedMass / Σweighted) − (rawCount / Σraw): a
    /// category whose recent attention share exceeds its historical share is
    /// heating. Returned sorted by momentum descending (hottest first), ties by
    /// ascending category name. Empty input ⇒ empty result (C-16).
    public static func themeWeather(categories: [(category: String, rawCount: Double,
                                                  weightedMass: Double)]) -> [CategoryMomentum] {
        guard !categories.isEmpty else { return [] }

        let totalRaw = categories.reduce(0) { $0 + $1.rawCount }
        let totalWeighted = categories.reduce(0) { $0 + $1.weightedMass }
        // Empty totals would make shares undefined; treat a side with no mass as
        // contributing a zero share (no division by zero).
        let rawShare: (Double) -> Double = { totalRaw > 0 ? $0 / totalRaw : 0 }
        let weightedShare: (Double) -> Double = { totalWeighted > 0 ? $0 / totalWeighted : 0 }

        let momenta = categories.map { c in
            CategoryMomentum(category: c.category,
                             momentum: weightedShare(c.weightedMass) - rawShare(c.rawCount))
        }
        return momenta.sorted { lhs, rhs in
            lhs.momentum == rhs.momentum
                ? lhs.category < rhs.category       // ties: ascending category name
                : lhs.momentum > rhs.momentum       // primary: descending momentum
        }
    }
}
