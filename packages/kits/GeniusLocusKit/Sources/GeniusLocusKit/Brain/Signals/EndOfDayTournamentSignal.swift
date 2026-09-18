import Foundation
import LocusKit

/// End-of-day tournament signal — runs the host's Bradley-Terry
/// tournament over the day's recall traces and reports the outcome.
///
/// Spec anchor: architecture spec §6.5 / cookbook §6.7
/// (`W_tournament` Bradley-Terry vector), §15.1 rules 2–3 (synchronous
/// Bradley-Terry on proposal promotion and recall feedback), §11.2
/// (the dreaming-daemon row covers the cold-path tournament). This
/// signal exposes the cold-path tournament as a standalone scheduler
/// entry.
///
/// What it does: on each daily fire the `tournamentCycle` closure runs
/// `kit.endOfDayTournament(_:now:)`, which folds the day's recall traces
/// through Bradley-Terry (cookbook §8.12) and writes one `recall_ratings`
/// row per participating drawer. The cycle persists the ratings itself;
/// the signal emits only a summary diagnostic carrying the contest and
/// rated-drawer counts (single-write invariant). Registered by
/// `registerDefaultStandingSignals` only when handed a live cycle, which
/// the host passes only while the estate's `.adaptiveRecall` preference is
/// not `.off`.
///
/// Cadence: daily. Architecture spec § 6.7 schedules `W_tournament`
/// updates at the day boundary; cookbook §15.2 schedules eigenvalue
/// centrality (the prerequisite for tournament weighting) at the same
/// daily cadence.
public enum EndOfDayTournamentSignal {

    /// Default cadence in seconds (86 400 = 1 day). Cookbook §15.2.
    public static let defaultCadenceSeconds: TimeInterval = 86_400

    /// Stable name surfaced in `SignalReport.name`.
    public static let signalName = "end-of-day-tournament"

    /// Build a signal spec that runs one end-of-day tournament pass per fire.
    ///
    /// - Parameter tournamentCycle: async closure executing the pass with
    ///   the scheduler's `now`; the host wraps `kit.endOfDayTournament(_:now:)`
    ///   and returns its report. Errors are caught and surfaced as
    ///   `.diagnostic` emissions — the scheduler's drain loop continues
    ///   unaffected.
    public static func spec(
        tournamentCycle: @escaping @Sendable (Date) async throws -> TournamentReport
    ) -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                do {
                    let report = try await tournamentCycle(context.now)
                    return [.diagnostic(DiagnosticReport(
                        title: "end-of-day-tournament.complete",
                        detail: "contests=\(report.contests) ratedDrawers=\(report.ratedDrawers) "
                            + "at \(context.now.ISO8601Format())",
                        observedAt: context.now))]
                } catch {
                    return [.diagnostic(DiagnosticReport(
                        title: "end-of-day-tournament.error",
                        detail: "\(error)",
                        observedAt: context.now))]
                }
            })
    }
}
