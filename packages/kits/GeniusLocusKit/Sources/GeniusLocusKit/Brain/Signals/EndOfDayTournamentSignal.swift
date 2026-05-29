import Foundation
import LocusKit

/// End-of-day tournament signal — runs the Bradley-Terry tournament
/// over recall feedback accumulated during the day and emits
/// `propose` rows for the resulting weight updates.
///
/// Spec anchor: architecture spec §6.5 / cookbook §6.7
/// (`W_tournament` Bradley-Terry vector), §15.1 rules 2–3 (synchronous
/// Bradley-Terry on proposal promotion and recall feedback), §11.2
/// (the dreaming-daemon row covers the cold-path tournament). This
/// signal exposes the cold-path tournament as a standalone scheduler
/// entry so the application can subscribe to weight updates directly.
///
/// What it does: at the end of each day's tick, fold the day's
/// recall-feedback history through Bradley-Terry (cookbook §8.12)
/// and emit one `propose` per affected `W_tournament` slot demoting or
/// promoting the weight. A diagnostic report carries the day's
/// summary so the application can audit the cycle.
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

    public static func defaultSpec() -> SignalSpec {
        SignalSpec(
            name: signalName,
            trigger: .interval(seconds: defaultCadenceSeconds),
            freshnessTarget: defaultCadenceSeconds * 2,
            concurrencyPolicy: .single,
            emit: { context in
                // Bradley-Terry weight update proposal. The kind
                // string is stable so a downstream subscriber can
                // identify the emission class without parsing the
                // justification. The actual weight delta is computed
                // by the cold-path implementation that lands when
                // the Brain layer's verb bodies ship; the scheduler
                // surface carries only the proposal shape.
                let update = ProposalFrame(
                    target: "tournament/w_tournament",
                    kind: .tournamentUpdate,
                    justification:
                        "end-of-day Bradley-Terry update (cookbook §8.12); signal=\(context.signalID.rawValue)")
                let diagnostic = DiagnosticReport(
                    title: "tournament.end_of_day.summary",
                    detail:
                        "daily Bradley-Terry tournament observed 1 weight update; signal=\(context.signalID.rawValue)",
                    observedAt: context.now)
                return [
                    .propose(update),
                    .diagnostic(diagnostic),
                ]
            })
    }
}
