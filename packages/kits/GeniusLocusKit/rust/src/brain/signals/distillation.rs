// brain/signals/distillation.rs — Rust mirror of `DistillationSignal.swift`.
//
// Architecture spec §11.2, signal 8. Runs the distillation sweep on each
// hourly fire and surfaces the result as a diagnostic. Mirrors
// TemporalCausalitySignal in structure: hourly cadence, .single concurrency,
// diagnostic-only emission.
//
// The `spec` factory accepts a closure that returns the factoid count from a
// live distillation cycle. `default_spec` is the no-op scaffold variant used
// when no live cycle is available (e.g., test scaffolds or
// registerDefaultStandingSignals before Dg4 wires the live closure).

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct DistillationSignal;

impl DistillationSignal {
    /// Default cadence in seconds (3 600 = 1 hour). Architecture spec §11.2,
    /// signal 8. Mirrors Swift's `DistillationSignal.defaultCadenceSeconds`.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 3_600;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "distillation-sweep";

    /// Build a signal spec that invokes the distillation pipeline on each fire.
    ///
    /// `distillation_cycle` is called on each emit and returns the number of
    /// factoids produced (`Ok(count)`) or an error description (`Err(msg)`).
    /// An `Ok(0)` is correct when no clusters were ready to distill.
    /// Errors are surfaced as a "distillation-sweep.error" diagnostic so
    /// the scheduler's drain loop is not interrupted.
    pub fn spec<F>(distillation_cycle: Arc<F>) -> SignalSpec
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
            emit: Arc::new(move |context: &SignalContext| match distillation_cycle() {
                Ok(count) => {
                    let diagnostic = DiagnosticReport {
                        title: "distillation-sweep.complete".into(),
                        detail: format!(
                            "produced {} factoid(s); signal={}",
                            count, context.signal_id.0
                        ),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    // Surface sweep errors as diagnostics so the scheduler's
                    // drain loop is not interrupted.
                    let diagnostic = DiagnosticReport {
                        title: "distillation-sweep.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }

    /// Build a diagnostic-only spec for test and registration contexts
    /// where no live distillation cycle is available.
    ///
    /// Fires at the hourly cadence and emits a single diagnostic confirming
    /// the fire. No distillation work is performed.
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
                // No-op sweep: fires the scheduled signal and surfaces a
                // diagnostic so the scheduler's cadence is observable.
                let diagnostic = DiagnosticReport {
                    title: "distillation-sweep.fired".into(),
                    detail: format!(
                        "sweep signal fired (no-op); signal={}",
                        context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                };
                vec![SignalEmission::Diagnostic(diagnostic)]
            }),
        }
    }
}
