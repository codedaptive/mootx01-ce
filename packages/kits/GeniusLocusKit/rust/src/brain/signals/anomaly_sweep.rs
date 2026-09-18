// brain/signals/anomaly_sweep.rs — Rust mirror of `AnomalySweepSignal.swift`.
//
// Architecture spec §11.18, signal 12. Fires each hour; the resident's
// live closure ENQUEUES the anomaly-sweep duty (§ DUTY_LIFECYCLE) and the
// duty worker scores, off the tick, only the rooms touched since their last
// scoring (brain/anomaly_flag_sweep.rs). The closure's count is surfaced as
// a diagnostic. Mirrors TemporalCausalitySignal in structure: hourly
// cadence, .single concurrency, diagnostic-only emission, injected closure
// for the live cycle.
//
// The `spec` factory accepts a closure returning a count for the
// diagnostic. `default_spec` is the no-op scaffold variant
// used when no live cycle is available (e.g., test scaffolds or
// registerDefaultStandingSignals before the live closure is wired).

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct AnomalySweepSignal;

impl AnomalySweepSignal {
    /// Hourly cadence in seconds (3 600 = 1 hour). Architecture spec §11.18,
    /// signal 12. Mirrors Swift `AnomalySweepSignal.defaultCadenceSeconds`.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 3_600;

    /// Stable name surfaced in `SignalReport.name`.
    /// Mirrors Swift `AnomalySweepSignal.signalName`.
    pub const SIGNAL_NAME: &'static str = "anomaly-flag-sweep";

    /// Build a signal spec that invokes the anomaly-flag sweep on each fire.
    ///
    /// `anomaly_cycle` is called on each emit and returns the number of
    /// drawers whose bit 26 changed state (`Ok(count)`) or an error
    /// description (`Err(msg)`). `Ok(0)` is correct when no bits changed.
    /// Errors are surfaced as an "anomaly-flag-sweep.error" diagnostic so
    /// the scheduler's drain loop is not interrupted.
    pub fn spec<F>(anomaly_cycle: Arc<F>) -> SignalSpec
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
            emit: Arc::new(move |context: &SignalContext| match anomaly_cycle() {
                Ok(count) => {
                    let diagnostic = DiagnosticReport {
                        title: "anomaly-flag-sweep.complete".into(),
                        detail: format!(
                            "updated {} drawer(s); signal={}",
                            count, context.signal_id.0
                        ),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    // Surface sweep errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. Matches the Swift spec
                    // factory's catch block behaviour.
                    let diagnostic = DiagnosticReport {
                        title: "anomaly-flag-sweep.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }

    /// Build a diagnostic-only spec for test and registration contexts
    /// where no live anomaly cycle is available.
    ///
    /// Fires at the hourly cadence and emits a single diagnostic
    /// confirming the fire. No sweep work is performed.
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
                    title: "anomaly-flag-sweep.fired".into(),
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
