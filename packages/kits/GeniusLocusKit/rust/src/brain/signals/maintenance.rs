// brain/signals/maintenance.rs — Rust mirror of `MaintenanceSignal.swift`.
//
// Architecture spec §11.2 row 2. Fires the NeuronKit maintenance
// engine's `tombstone` category on each tick
// (`MaintenanceDaemon::run_cycle_scoped`), which proposes its candidates
// through the engine's own sink; the signal surfaces the `tombstone_candidates`
// count as a diagnostic. Mirrors AnomalySweepSignal in structure: interval
// cadence, Single concurrency, diagnostic-only emission, injected closure
// for the live cycle. Preference-gated on `maintenance`: the host passes a
// live closure only when the preference is not Off, and the governor tick
// never pumps the engine on this category.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct MaintenanceSignal;

impl MaintenanceSignal {
    /// Default cadence in seconds (3 600 = 1 hour).
    pub const DEFAULT_CADENCE_SECONDS: u64 = 3_600;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "maintenance-daemon";

    /// Build a signal spec that runs the engine's `tombstone` category on each fire.
    ///
    /// `cycle` is called on each emit and returns `tombstone_candidates` from the
    /// scoped maintenance cycle (`Ok(count)`) or an error description
    /// (`Err(msg)`). Errors are surfaced as a "maintenance-daemon.error" diagnostic so
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
                        title: "maintenance-daemon.complete".into(),
                        detail: format!("{} tombstone candidate(s); signal={}", count, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    // Surface cycle errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. Matches the Swift spec
                    // factory's catch block behaviour.
                    let diagnostic = DiagnosticReport {
                        title: "maintenance-daemon.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }
}
