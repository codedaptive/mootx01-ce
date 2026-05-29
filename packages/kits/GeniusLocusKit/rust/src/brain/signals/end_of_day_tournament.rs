// brain/signals/end_of_day_tournament.rs — Rust mirror of
// `EndOfDayTournamentSignal.swift`.
//
// Architecture spec §6.5 / §6.7 / cookbook §8.12. Emits one `propose`
// (weight update) plus a scan-summary diagnostic on every daily fire.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct EndOfDayTournamentSignal;

impl EndOfDayTournamentSignal {
    /// Default cadence in seconds (86 400 = 1 day). Cookbook §15.2.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 86_400;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "end-of-day-tournament";

    pub fn default_spec() -> SignalSpec {
        SignalSpec {
            name: Self::SIGNAL_NAME.to_string(),
            trigger: SignalTrigger::Interval {
                seconds: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS),
            },
            resource_cost: ResourceCostEstimate::ZERO,
            freshness_target: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS * 2),
            concurrency_policy: ConcurrencyPolicy::Single,
            emit: Arc::new(|context: &SignalContext| {
                let update = ProposalFrame {
                    target: "tournament/w_tournament".into(),
                    kind: ProposalKind::TournamentUpdate,
                    justification: Some(format!(
                        "end-of-day Bradley-Terry update (cookbook §8.12); signal={}",
                        context.signal_id.0
                    )),
                };
                let diagnostic = DiagnosticReport {
                    title: "tournament.end_of_day.summary".into(),
                    detail: format!(
                        "daily Bradley-Terry tournament observed 1 weight update; signal={}",
                        context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                };
                vec![
                    SignalEmission::Propose(update),
                    SignalEmission::Diagnostic(diagnostic),
                ]
            }),
        }
    }
}
