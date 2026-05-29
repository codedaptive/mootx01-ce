// Tournament.swift
//
// The tournament orchestration layer (mission NK-TOUR-01). It sits on
// top of the branch benchmark NK-BR-01 ships: `runTournament`
// benchmarks a set of COW branches, applies the zero-silent-loss
// disqualification gate, ranks the survivors by a combined benchmark
// score, and surfaces an advisory winner. It produces no new substrate
// writes and never promotes a branch.
//
// SCORING MODEL DEVIATION (recorded per the mission's Known
// Ambiguities). NEURONKIT_SPEC § 4.4 specifies a substrate-signal
// scoring model (averageReward, proposalAcceptanceRate,
// tunnelFormationRate, …) behind a summed-weight ScoringConfig. That
// signature predates branch benchmarking. NK-BR-01 (which post-dates
// the § 4.4 draft) is the source of `benchmark()`, `recallOverlap`, and
// `meanReciprocalRank`. The mission brief's benchmark-derived model is
// authoritative for this mission: survivors are ranked by
// `recallOverlap * meanReciprocalRank`, both read from each branch's
// `BenchmarkReport`. The § 4.4 substrate-signal types are NOT invented
// here — they do not exist on `BenchmarkReport`.
//
// INVARIANT I-16 (never auto-promote) is NOT superseded and holds here:
// `runTournament` performs zero substrate writes and never calls any
// branch-promotion verb (promotion lives on the GeniusLocusKit verb
// surface as `glkPromoteBranch`, which this file neither imports nor
// calls). `winner` is advisory only.
//
// DETERMINISM: `evaluatedAt` and `interval` arrive as parameters and
// are passed straight through; this file never reads the wall clock. Tie
// breaks resolve on a stable key (branch identifier string) so output
// is reproducible across runs.

import Foundation
import GeniusLocusKit

/// Why a branch was excluded from tournament ranking.
///
/// Modelled as a typed enum so callers can switch on the reason and
/// recover the supporting count rather than parse a string. The single
/// v1 case is the zero-silent-loss gate (NK-BR-01 invariant C-13): a
/// branch whose benchmark detected migration loss is disqualified.
public enum DisqualificationReason: Sendable, Equatable {
    /// The branch's benchmark reported a non-empty `notFoundInBranch`
    /// set — at least one origin-corpus concept was absent from branch
    /// recall (silent migration loss). `notFoundCount` is
    /// `BenchmarkReport.notFoundInBranch.count` at evaluation time.
    case silentLoss(notFoundCount: Int)
}

/// A surviving branch and its combined tournament score.
///
/// Carries the branch handle, that branch's full `BenchmarkReport` for
/// inspection, and the derived combined score
/// `recallOverlap * meanReciprocalRank` (both read from the report).
///
/// Not `Codable`: `BenchmarkReport` and `BranchHandle` are not Codable,
/// so a synthesized conformance is impossible and none is invented.
/// `Equatable` is hand-written because `any BranchHandle` is an
/// existential over a non-`Equatable`, reference-typed protocol; two
/// scores are equal when their branch identity, report, and score
/// match.
public struct BranchScore: Sendable, Equatable {
    /// The branch this score describes.
    public let branch: any BranchHandle
    /// The branch's recall-fidelity report (NK-BR-01 § 4.7).
    public let report: BenchmarkReport
    /// Combined ranking score: `report.recallOverlap *
    /// report.meanReciprocalRank`. Higher is better.
    public let combinedScore: Float

    /// Create a score for a surviving branch.
    /// - Parameters:
    ///   - branch: the branch being scored.
    ///   - report: the branch's benchmark report.
    ///   - combinedScore: the derived `recallOverlap *
    ///     meanReciprocalRank` product.
    public init(branch: any BranchHandle, report: BenchmarkReport, combinedScore: Float) {
        self.branch = branch
        self.report = report
        self.combinedScore = combinedScore
    }

    /// Equal when branch identity, report, and combined score all match.
    /// `branch` is compared by `branchID` because `any BranchHandle` is
    /// not itself `Equatable`.
    public static func == (lhs: BranchScore, rhs: BranchScore) -> Bool {
        lhs.branch.branchID == rhs.branch.branchID
            && lhs.report == rhs.report
            && lhs.combinedScore == rhs.combinedScore
    }
}

/// A branch excluded from ranking by the zero-silent-loss gate.
///
/// Retained in the report (rather than dropped) so the disqualification
/// is visible and auditable, carrying the typed reason and the branch's
/// own `BenchmarkReport` for inspection.
///
/// `Equatable` is hand-written for the same reason as `BranchScore`:
/// `any BranchHandle` is not `Equatable`.
public struct DisqualifiedBranch: Sendable, Equatable {
    /// The disqualified branch.
    public let branch: any BranchHandle
    /// Why the branch was disqualified.
    public let reason: DisqualificationReason
    /// The branch's benchmark report, retained for inspection.
    public let report: BenchmarkReport

    /// Create a disqualification record.
    /// - Parameters:
    ///   - branch: the disqualified branch.
    ///   - reason: the typed disqualification reason.
    ///   - report: the branch's benchmark report.
    public init(branch: any BranchHandle, reason: DisqualificationReason, report: BenchmarkReport) {
        self.branch = branch
        self.reason = reason
        self.report = report
    }

    /// Equal when branch identity, reason, and report all match.
    public static func == (lhs: DisqualifiedBranch, rhs: DisqualifiedBranch) -> Bool {
        lhs.branch.branchID == rhs.branch.branchID
            && lhs.reason == rhs.reason
            && lhs.report == rhs.report
    }
}

/// The outcome of a tournament over a set of branches.
///
/// `winner` is advisory only (spec invariant I-16): the tournament
/// never promotes a branch. It is `nil` when every branch was
/// disqualified or the input set was empty.
public struct TournamentReport: Sendable, Equatable {
    /// The top-ranked survivor, or `nil` when there is no survivor.
    /// Advisory: the tournament performs no promotion.
    public let winner: BranchScore?
    /// Survivors ranked descending by `combinedScore`, ties broken by
    /// ascending branch identifier string. Excludes disqualified
    /// branches.
    public let ranking: [BranchScore]
    /// Branches excluded by the zero-silent-loss gate, each with its
    /// typed reason.
    public let disqualified: [DisqualifiedBranch]
    /// Caller-supplied evaluation instant (never read from the wall
    /// clock — the fleet determinism rule).
    public let evaluatedAt: Date
    /// Caller-supplied evaluation interval, passed through for the
    /// caller's record.
    public let interval: DateInterval

    /// Assemble a tournament report.
    /// - Parameters:
    ///   - winner: the advisory top survivor, or `nil`.
    ///   - ranking: survivors in descending score order.
    ///   - disqualified: gate-excluded branches.
    ///   - evaluatedAt: evaluation instant, recorded verbatim.
    ///   - interval: evaluation interval, recorded verbatim.
    public init(
        winner: BranchScore?,
        ranking: [BranchScore],
        disqualified: [DisqualifiedBranch],
        evaluatedAt: Date,
        interval: DateInterval
    ) {
        self.winner = winner
        self.ranking = ranking
        self.disqualified = disqualified
        self.evaluatedAt = evaluatedAt
        self.interval = interval
    }
}

// MARK: - Tournament orchestration (§ 4.4, benchmark-derived model)

public extension NeuronKit {

    /// Benchmark a set of branches, disqualify those with silent
    /// migration loss, rank the survivors, and surface an advisory
    /// winner (mission NK-TOUR-01).
    ///
    /// Algorithm, in order:
    /// 1. Benchmark each branch against `baseline` (NK-BR-01 § 4.7).
    /// 2. Zero-silent-loss gate, BEFORE ranking: a branch whose report
    ///    has a non-empty `notFoundInBranch` is disqualified and is
    ///    neither scored nor ranked (invariant C-13).
    /// 3. Score each survivor by `recallOverlap * meanReciprocalRank`.
    /// 4. Rank survivors descending by that product, ties broken by
    ///    ascending branch identifier string for reproducibility.
    /// 5. The advisory `winner` is the top survivor (`nil` if none).
    ///
    /// INVARIANT I-16 (never auto-promote): this function performs ZERO
    /// substrate writes and never calls a branch-promotion verb. Its
    /// only substrate touch is the read-only `benchmark(...)` call,
    /// which itself drives only `BranchHandle.recall(_:)` (the C-13
    /// read-only corollary). Promotion lives on the GeniusLocusKit verb
    /// surface (`glkPromoteBranch`), which this file neither imports nor
    /// calls; there is nothing on `BranchHandle` to promote with.
    /// `winner` is advisory only.
    ///
    /// - Parameters:
    ///   - branches: the branches to evaluate. An empty set yields a
    ///     report with `nil` winner and empty `ranking`/`disqualified`.
    ///   - baseline: the external origin corpus every branch is scored
    ///     against (`benchmark`'s `against:` argument).
    ///   - queries: optional explicit query override forwarded to
    ///     `benchmark`; when empty, the corpus's own
    ///     `asRecallFrames()` is used. Defaults to empty to mirror
    ///     `benchmark(...)`.
    ///   - evaluatedAt: evaluation instant. Forwarded to `benchmark`'s
    ///     `now:` so every branch is scored at the same deterministic
    ///     instant, and recorded on the report. Supplied so the
    ///     tournament is deterministic and testable.
    ///   - interval: evaluation interval, recorded on the report.
    /// - Returns: a `TournamentReport`.
    static func runTournament(
        branches: [any BranchHandle],
        against baseline: ExternalCorpus,
        queries: [RecallFrame] = [],
        evaluatedAt: Date,
        interval: DateInterval
    ) async throws -> TournamentReport {
        // Score each branch with the read-only NK-BR-01 benchmark. Order
        // is preserved so the deterministic tie-break in rankTournament
        // has a stable input. benchmark()'s evaluation instant is
        // labelled `now:`; the tournament's `evaluatedAt` is forwarded
        // there.
        var scored: [(branch: any BranchHandle, report: BenchmarkReport)] = []
        scored.reserveCapacity(branches.count)
        for branch in branches {
            let report = try await benchmark(
                branch: branch,
                against: baseline,
                queries: queries,
                now: evaluatedAt
            )
            scored.append((branch: branch, report: report))
        }
        return rankTournament(scored: scored, evaluatedAt: evaluatedAt, interval: interval)
    }

    /// The pure, deterministic gate-plus-ranking core that
    /// `runTournament` composes after collecting each branch's report.
    ///
    /// Separated from the benchmark I/O on purpose: the benchmark
    /// compares corpus IDs against per-branch minted drawer IDs, so a
    /// single shared corpus can yield a non-disqualified report for at
    /// most one branch. Multi-branch ranking and tie-break behaviour is
    /// therefore exercised by feeding this function fabricated
    /// `BenchmarkReport` fixtures (via its public initializer), while the
    /// real-benchmark wiring is exercised end-to-end through
    /// `runTournament`. This helper never reads the wall clock and
    /// performs no substrate touch.
    ///
    /// - Parameters:
    ///   - scored: each branch paired with its benchmark report, in the
    ///     order branches were supplied.
    ///   - evaluatedAt: evaluation instant, recorded verbatim.
    ///   - interval: evaluation interval, recorded verbatim.
    /// - Returns: the assembled `TournamentReport`.
    internal static func rankTournament(
        scored: [(branch: any BranchHandle, report: BenchmarkReport)],
        evaluatedAt: Date,
        interval: DateInterval
    ) -> TournamentReport {
        var ranking: [BranchScore] = []
        var disqualified: [DisqualifiedBranch] = []
        for pair in scored {
            // Zero-silent-loss gate, applied BEFORE ranking: any branch
            // whose benchmark found at least one missing concept is
            // disqualified, retained with its reason, and never scored
            // or ranked (C-13).
            let notFoundCount = pair.report.notFoundInBranch.count
            if notFoundCount > 0 {
                disqualified.append(DisqualifiedBranch(
                    branch: pair.branch,
                    reason: .silentLoss(notFoundCount: notFoundCount),
                    report: pair.report
                ))
                continue
            }
            // Combined score is the benchmark-derived product the mission
            // brief makes authoritative over the spec § 4.4 model.
            let combined = pair.report.recallOverlap * pair.report.meanReciprocalRank
            ranking.append(BranchScore(
                branch: pair.branch,
                report: pair.report,
                combinedScore: combined
            ))
        }
        // Descending by combined score; equal scores break by ascending
        // branch identifier string so the ordering is reproducible.
        ranking.sort { lhs, rhs in
            if lhs.combinedScore != rhs.combinedScore {
                return lhs.combinedScore > rhs.combinedScore
            }
            return lhs.branch.branchID.uuidString < rhs.branch.branchID.uuidString
        }
        return TournamentReport(
            winner: ranking.first,
            ranking: ranking,
            disqualified: disqualified,
            evaluatedAt: evaluatedAt,
            interval: interval
        )
    }
}
