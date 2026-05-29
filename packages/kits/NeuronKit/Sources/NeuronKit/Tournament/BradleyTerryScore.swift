// BradleyTerryScore.swift
//
// One competitor's fitted result from the Bradley-Terry batch MLE
// ranker (mission NK-BT-01). Output element of
// `bradleyTerry(outcomes:)`.
//
// This is a NeuronKit reasoning value type: no behaviour, no substrate,
// no SQL (B-1/B-3). Plain Sendable/Equatable/Codable record.

import Foundation

/// A competitor's estimated Bradley-Terry strength and its 95%
/// confidence interval.
///
/// ## Strength scale
///
/// Bradley-Terry models the probability that competitor *i* beats
/// competitor *j* as `p_i / (p_i + p_j)`, where each `p > 0` is a
/// latent strength on the linear scale. `strength` here is the **log**
/// of that linear strength: `strength_i = log(p_i)`. The log scale is
/// used because differences are what matter (the model depends only on
/// `p_i / p_j`, i.e. `strength_i - strength_j`) and because the
/// confidence interval is symmetric and additive on the log scale.
///
/// BT strengths are identifiable only up to an additive constant on the
/// log scale (multiplying every `p` by the same factor leaves every
/// win probability unchanged). To make the numbers comparable across
/// separate `bradleyTerry(outcomes:)` calls, the fitter pins the gauge
/// so the **log strengths sum to zero** — equivalently, the linear
/// strengths have geometric mean 1. A `strength` of 0 therefore means
/// "exactly average competitor"; positive is above average, negative
/// is below.
///
/// ## Confidence interval
///
/// `confidenceLow` and `confidenceHigh` bracket `strength` at the 95%
/// level: `strength ± 1.96 × SE`, where `SE` is the standard error of
/// the MLE estimate derived from the Fisher information (the diagonal
/// of the inverse negative-log-likelihood Hessian). The interval is on
/// the same log scale as `strength`, so it is symmetric around it:
/// `confidenceLow == strength - 1.96·SE` and
/// `confidenceHigh == strength + 1.96·SE`. A wider interval means the
/// available comparisons pin this competitor's strength less precisely
/// (typically a competitor with few comparisons).
public struct BradleyTerryScore: Sendable, Equatable, Codable {

    /// The competitor this score describes.
    public let competitorID: String

    /// Estimated latent strength on the log Bradley-Terry scale.
    /// Normalised so that all returned strengths sum to zero (see the
    /// type's strength-scale documentation). Higher is stronger.
    public let strength: Double

    /// Lower bound of the 95% confidence interval around `strength`
    /// (`strength - 1.96 × SE`), on the same log scale.
    public let confidenceLow: Double

    /// Upper bound of the 95% confidence interval around `strength`
    /// (`strength + 1.96 × SE`), on the same log scale.
    public let confidenceHigh: Double

    /// Creates a Bradley-Terry score. Normally constructed only by
    /// `bradleyTerry(outcomes:)`; public so callers can build fixtures
    /// and decode persisted results.
    public init(
        competitorID: String,
        strength: Double,
        confidenceLow: Double,
        confidenceHigh: Double
    ) {
        self.competitorID = competitorID
        self.strength = strength
        self.confidenceLow = confidenceLow
        self.confidenceHigh = confidenceHigh
    }
}
