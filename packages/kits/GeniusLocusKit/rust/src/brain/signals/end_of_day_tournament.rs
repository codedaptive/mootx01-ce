// brain/signals/end_of_day_tournament.rs — Rust mirror of
// `EndOfDayTournamentSignal.swift`.
//
// Architecture spec §6.5 / §6.7 / cookbook §8.12. Runs the host's
// end-of-day tournament cycle (`EstateCoordinator::end_of_day_tournament`)
// on every daily fire: the day's recall traces are folded through
// Bradley-Terry into `recall_ratings` rows, and one summary diagnostic is
// emitted. There is no no-op variant: `default_standing_signal_specs`
// pushes this signal only when handed a live `tournament_cycle`, which the
// resident passes only while the estate's `adaptive_recall` preference is
// not `Off`.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::end_of_day_tournament::TournamentReport;
use crate::brain::scheduler::api::*;

pub struct EndOfDayTournamentSignal;

impl EndOfDayTournamentSignal {
    /// Default cadence in seconds (86 400 = 1 day). Cookbook §15.2.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 86_400;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "end-of-day-tournament";

    /// Build a signal spec that runs one end-of-day tournament pass per fire.
    ///
    /// `tournament_cycle` returns `Ok(TournamentReport)` on success; the
    /// cycle itself persists the `recall_ratings` rows, so the signal emits
    /// only a summary diagnostic (single-write invariant). Errors are caught
    /// and surfaced as an "end-of-day-tournament.error" diagnostic so the
    /// scheduler's drain loop continues unaffected.
    ///
    /// Mirrors Swift `EndOfDayTournamentSignal.spec(tournamentCycle:)`.
    pub fn spec<F>(tournament_cycle: Arc<F>) -> SignalSpec
    where
        F: Fn() -> Result<TournamentReport, String> + Send + Sync + 'static,
    {
        SignalSpec {
            name: Self::SIGNAL_NAME.to_string(),
            trigger: SignalTrigger::Interval {
                seconds: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS),
            },
            resource_cost: ResourceCostEstimate::ZERO,
            freshness_target: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS * 2),
            concurrency_policy: ConcurrencyPolicy::Single,
            emit: Arc::new(move |context: &SignalContext| match tournament_cycle() {
                Ok(report) => {
                    let diagnostic = DiagnosticReport {
                        title: "end-of-day-tournament.complete".into(),
                        detail: format!(
                            "contests={} ratedDrawers={}; signal={}",
                            report.contests, report.rated_drawers, context.signal_id.0
                        ),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    let diagnostic = DiagnosticReport {
                        title: "end-of-day-tournament.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }
}
