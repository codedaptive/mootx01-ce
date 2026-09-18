// brain/signals/decay_sweep.rs — Rust mirror of `DecaySweepSignal.swift`.
//
// Architecture spec §11.2 row 5. Fires the NeuronKit maintenance
// engine's `decay` category on each tick
// (`MaintenanceDaemon::run_cycle_scoped`), which proposes its candidates
// through the engine's own sink; the signal surfaces the `decay_candidates`
// count as a diagnostic. Mirrors AnomalySweepSignal in structure: interval
// cadence, Single concurrency, diagnostic-only emission, injected closure
// for the live cycle. Preference-gated on `maintenance`: the host passes a
// live closure only when the preference is not Off, and the governor tick
// never pumps the engine on this category.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct DecaySweepSignal;

impl DecaySweepSignal {
    /// Default cadence in seconds (86 400 = 1 day; cookbook §15.2).
    pub const DEFAULT_CADENCE_SECONDS: u64 = 86_400;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "decay-sweep";

    /// Build a signal spec that runs the engine's `decay` category on each fire.
    ///
    /// `cycle` is called on each emit and returns `decay_candidates` from the
    /// scoped maintenance cycle (`Ok(count)`) or an error description
    /// (`Err(msg)`). Errors are surfaced as a "decay-sweep.error" diagnostic so
    /// the scheduler's drain loop is not interrupted.
    pub fn spec<F>(cycle: Arc<F>) -> SignalSpec
    where
        F: Fn() -> Result<i64, String> + Send + Sync + 'static,
    {
        SignalSpec {
            name: Self::SIGNAL_NAME.to_string(),
            trigger: SignalTrigger::Interval {
                seconds: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS),
            },
            resource_cost: ResourceCostEstimate::ZERO,
            freshness_target: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS * 2),
            concurrency_policy: ConcurrencyPolicy::Single,
            emit: Arc::new(move |context: &SignalContext| match cycle() {
                Ok(count) => {
                    let diagnostic = DiagnosticReport {
                        title: "decay-sweep.complete".into(),
                        detail: format!("{} decay candidate(s); signal={}", count, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    // Surface cycle errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. Matches the Swift spec
                    // factory's catch block behaviour.
                    let diagnostic = DiagnosticReport {
                        title: "decay-sweep.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }
}
