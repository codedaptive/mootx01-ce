// brain/signals/temporal_causality.rs — Rust mirror of
// `TemporalCausalitySignal.swift`.
//
// Architecture spec §11.2, signal 7. Runs the T-population fold on each
// hourly fire and surfaces the result as a diagnostic. Added 2026-06-04 per
// hourly temporal-matrix scheduling, superseding the cookbook
// §6.4 weekly cadence.
//
// The `spec` factory accepts a closure that runs the T-population fold.
// There is no no-op variant: `default_standing_signal_specs` pushes this
// signal only when handed a live `fold_cycle`, which the resident passes
// only while the estate's `adaptive_recall` preference is not `Off`.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct TemporalCausalitySignal;

impl TemporalCausalitySignal {
    /// Hourly cadence in seconds (3 600 = 1 hour) per design-council
    /// 2026-06-04 decision. Mirrors Swift's
    /// `TemporalCausalitySignal.defaultCadenceSeconds`.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 3_600;

    /// Stable name surfaced in `SignalReport.name`.
    /// Mirrors Swift's `TemporalCausalitySignal.signalName`.
    pub const SIGNAL_NAME: &'static str = "temporal-causality-fold";

    /// Build a signal spec that invokes the T-population fold on each fire.
    ///
    /// `fold_cycle` is called on each emit. An `Ok(())` return surfaces a
    /// "temporal-causality-fold.complete" diagnostic. On `Err(msg)` the
    /// error is surfaced as a diagnostic so the scheduler's drain loop is
    /// not interrupted.
    pub fn spec<F>(fold_cycle: Arc<F>) -> SignalSpec
    where
        F: Fn() -> Result<(), String> + Send + Sync + 'static,
    {
        SignalSpec {
            name: Self::SIGNAL_NAME.to_string(),
            trigger: SignalTrigger::Interval {
                seconds: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS),
            },
            resource_cost: ResourceCostEstimate::ZERO,
            freshness_target: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS * 2),
            concurrency_policy: ConcurrencyPolicy::Single,
            emit: Arc::new(move |context: &SignalContext| match fold_cycle() {
                Ok(()) => {
                    let diagnostic = DiagnosticReport {
                        title: "temporal-causality-fold.complete".into(),
                        detail: format!(
                            "T-population fold completed; signal={}",
                            context.signal_id.0
                        ),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    // Surface fold errors as diagnostics so the scheduler's
                    // drain loop is not interrupted.
                    let diagnostic = DiagnosticReport {
                        title: "temporal-causality-fold.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }
}
