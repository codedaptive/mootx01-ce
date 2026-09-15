// brain/signals/contradiction_sweep.rs — Rust mirror of
// `ContradictionSweepSignal.swift`.
//
// Hourly tiered conflict-tunnel proposer. Fires one
// `EstateCoordinator::propose_conflict_tunnels` pass per tick and surfaces
// the proposed-tunnel count as a diagnostic. Same structure as
// `AnomalySweepSignal`: hourly cadence, .single concurrency, diagnostic-only
// emission, injected closure for the live cycle.
//
// Preference-gated: there is no `default_spec`. The host registers this
// signal only when the estate's `contradiction_sweep` preference is not
// `Off`, by passing a live closure to `default_standing_signal_specs`; an
// opted-out estate carries no such signal at all.
//
// Single-write invariant: the proposal pass persists its tunnels through the
// estate verb surface; the signal emits one summary diagnostic and never
// re-dispatches proposals.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::conflict_projection_sweep::ConflictTunnelProposalReport;
use crate::brain::scheduler::api::*;

pub struct ContradictionSweepSignal;

impl ContradictionSweepSignal {
    /// Hourly cadence in seconds (3 600 = 1 hour). Mirrors Swift
    /// `ContradictionSweepSignal.defaultCadenceSeconds`.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 3_600;

    /// Stable name surfaced in `SignalReport.name`.
    /// Mirrors Swift `ContradictionSweepSignal.signalName`.
    pub const SIGNAL_NAME: &'static str = "contradiction-sweep";

    /// Build a signal spec that runs one conflict-tunnel proposal pass on
    /// each fire.
    ///
    /// `sweep_cycle` is called on each emit and returns the pass's
    /// `ConflictTunnelProposalReport` (`Ok(report)`) or an error description
    /// (`Err(msg)`). The diagnostic detail carries the count of tunnels
    /// proposed across all three tiers. Errors are surfaced as a
    /// "contradiction-sweep.error" diagnostic so the scheduler's drain loop
    /// is not interrupted.
    pub fn spec<F>(sweep_cycle: Arc<F>) -> SignalSpec
    where
        F: Fn() -> Result<ConflictTunnelProposalReport, String> + Send + Sync + 'static,
    {
        SignalSpec {
            name: Self::SIGNAL_NAME.to_string(),
            trigger: SignalTrigger::Interval {
                seconds: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS),
            },
            resource_cost: ResourceCostEstimate::ZERO,
            freshness_target: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS * 2),
            concurrency_policy: ConcurrencyPolicy::Single,
            emit: Arc::new(move |context: &SignalContext| match sweep_cycle() {
                Ok(report) => {
                    // Proposed count spans the typed tier and both lexical
                    // tiers; the pass already persisted the tunnels.
                    let proposed = report.proposed_tunnel_ids.len()
                        + report.proposed_tier2_ids.len()
                        + report.proposed_tier3_ids.len();
                    let diagnostic = DiagnosticReport {
                        title: "contradiction-sweep.complete".into(),
                        detail: format!(
                            "proposed {} tunnel(s); suppressed {}; signal={}",
                            proposed, report.suppressed, context.signal_id.0
                        ),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    // Surface sweep errors as diagnostics so the scheduler's
                    // drain loop is not interrupted.
                    let diagnostic = DiagnosticReport {
                        title: "contradiction-sweep.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }
}
