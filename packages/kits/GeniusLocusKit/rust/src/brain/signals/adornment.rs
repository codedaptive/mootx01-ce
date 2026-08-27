// brain/signals/adornment.rs — Rust mirror of `AdornmentPassSignal.swift`.
//
// GENIUSLOCUSKIT_SPEC 2.0.0 § 16, signal 13. Fires the dream-time
// adornment-minting pass on each hourly tick and surfaces the adorned-pair
// count as a diagnostic. Work unit = (drawer, active-minter) pair;
// batch_size counts PAIRS; per-pair failure isolation (a failure leaves
// only that pair missing, never disables the minter). Mirrors
// AnomalySweepSignal exactly in structure: hourly cadence, .single
// concurrency, diagnostic-only emission, injected closure for the live cycle.
//
// The `spec` factory accepts a closure returning the adorned-pair count
// from a live adornment cycle. `default_spec` is the no-op scaffold
// variant used when no live cycle is available (e.g., test scaffolds or
// register_default_standing_signals before the live closure is wired).

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct AdornmentPassSignal;

impl AdornmentPassSignal {
    /// Hourly cadence in seconds (3 600 = 1 hour). SPEC_ADORNMENT §4,
    /// signal 13. Mirrors Swift `AdornmentPassSignal.defaultCadenceSeconds`.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 3_600;

    /// Stable name surfaced in `SignalReport.name`.
    /// Mirrors Swift `AdornmentPassSignal.signalName`.
    pub const SIGNAL_NAME: &'static str = "adornment-pass";

    /// Build a signal spec that invokes the adornment-minting pass on
    /// each hourly fire.
    ///
    /// `adornment_cycle` is called on each emit and returns the number of
    /// (drawer, minter) pairs that were adorned (`Ok(count)`) or an error
    /// description (`Err(msg)`). `Ok(0)` is correct when no debt pairs are
    /// present. Errors are surfaced as an "adornment-pass.error" diagnostic
    /// so the scheduler's drain loop is not interrupted.
    pub fn spec<F>(adornment_cycle: Arc<F>) -> SignalSpec
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
            emit: Arc::new(move |context: &SignalContext| match adornment_cycle() {
                Ok(count) => {
                    let diagnostic = DiagnosticReport {
                        title: "adornment-pass.complete".into(),
                        detail: format!(
                            "adorned {} pair(s); signal={}",
                            count, context.signal_id.0
                        ),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    // Surface pass errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. Matches the Swift spec
                    // factory's catch block behaviour.
                    let diagnostic = DiagnosticReport {
                        title: "adornment-pass.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }

    /// Build a diagnostic-only spec for test and registration contexts
    /// where no live adornment cycle is available.
    ///
    /// Fires at the hourly cadence and emits a single diagnostic
    /// confirming the fire. No minting work is performed.
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
                // No-op pass: fires the scheduled signal and surfaces a
                // diagnostic so the scheduler's cadence is observable.
                let diagnostic = DiagnosticReport {
                    title: "adornment-pass.fired".into(),
                    detail: format!(
                        "adornment pass signal fired (no-op); signal={}",
                        context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                };
                vec![SignalEmission::Diagnostic(diagnostic)]
            }),
        }
    }
}
