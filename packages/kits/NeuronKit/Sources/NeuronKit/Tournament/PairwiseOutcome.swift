// PairwiseOutcome.swift
//
// One pairwise win/loss record between two named competitors — the
// input unit of the Bradley-Terry batch MLE fitter (mission NK-BT-01,
// NEURONKIT_SPEC § 4.4 Tournament scoring).
//
// This is a NeuronKit reasoning value type. It carries no behaviour,
// touches no substrate, and executes no SQL (behavioural contract
// B-1/B-3). It is a plain Sendable/Equatable/Codable record so callers
// can persist tallies or stream them in from any source.
//
// A note on the `count` field rather than a Bool or a flag: a single
// `PairwiseOutcome` can represent many identical resolutions of the
// same pairing (e.g. "A beat B 17 times") without forcing the caller
// to materialise 17 records. This is a pure aggregation convenience,
// not entity state — there are no bitmap concerns here (no entity, no
// SQLite column).

import Foundation

/// A single directed win/loss record: `winner` beat `loser`,
/// `count` times.
///
/// Used as the input element to `bradleyTerry(outcomes:)`. Callers may
/// pass either one record per individual comparison (`count == 1`) or a
/// pre-aggregated tally (`count > 1`); the fitter treats
/// `PairwiseOutcome(winner: a, loser: b, count: 5)` as exactly
/// equivalent to five separate single-count records between the same
/// pair.
///
/// Invariant: `winner != loser`. A competitor cannot beat itself. The
/// fitter treats a self-pairing as a programmer error and throws
/// `MOOTx01Error.selfPairing` rather than silently dropping it, so the
/// caller learns its tally construction is wrong instead of getting a
/// quietly skewed ranking.
public struct PairwiseOutcome: Sendable, Equatable, Codable {

    /// Competitor ID of the winner of this pairing.
    public let winner: String

    /// Competitor ID of the loser of this pairing.
    public let loser: String

    /// Number of times this exact `winner`-beats-`loser` outcome
    /// occurred. Defaults to 1 so a single comparison reads naturally.
    /// Lets callers pass aggregated tallies instead of repeated
    /// records. A non-positive `count` contributes nothing to the fit
    /// (it adds zero wins and zero comparisons); the fitter does not
    /// reject it, because an empty tally is a meaningful "no data for
    /// this pair" statement, not an error.
    public let count: Int

    /// Creates a pairwise outcome. `winner` and `loser` are competitor
    /// IDs; `count` is how many times this outcome occurred (default 1).
    /// The `winner != loser` invariant is enforced by the fitter, not
    /// this initializer, so a malformed record can still round-trip
    /// through `Codable` and be reported by the fitter at fit time.
    public init(winner: String, loser: String, count: Int = 1) {
        self.winner = winner
        self.loser = loser
        self.count = count
    }
}
