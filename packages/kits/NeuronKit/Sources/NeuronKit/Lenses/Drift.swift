import SubstrateML

// Drift — distributional shift between two windows (SPEC § 7.5, Lens 5
// Surprise): the NeuronKit reasoning surface over SubstrateML's
// `InformationTheory`. Given two topic/category distributions (e.g. two
// time windows), the Jensen-Shannon and KL divergences quantify how far
// the second has moved from the first — "your interests shifted in
// April." Surfaces the gated divergence math; owns no math (I-17). Pure
// and total (I-18, B-8). CognitionKit sequences it (build the two
// distributions from the estate, then call this). The distributions
// must share support (same length, aligned bins); the caller aligns
// them.

/// How far one distribution has drifted from another.
public struct DriftScore: Sendable, Equatable, Codable {
    /// Jensen-Shannon divergence (symmetric, bounded) — the primary
    /// drift signal. 0 = identical; grows with separation.
    public let jensenShannon: Float
    /// KL divergence D(p‖q) (asymmetric) — how surprising q is under p.
    public let klDivergence: Float
    public init(jensenShannon: Float, klDivergence: Float) {
        self.jensenShannon = jensenShannon
        self.klDivergence = klDivergence
    }
}

extension NeuronKit {
    /// Drift of `q` from `p`. `p` and `q` are distributions over the
    /// same aligned support (same length); the caller normalizes and
    /// aligns them.
    public static func drift(from p: [Float], to q: [Float]) -> DriftScore {
        DriftScore(
            jensenShannon: InformationTheory.jensenShannon(p, q),
            klDivergence: InformationTheory.klDivergence(p, q))
    }
}
