// brain/signals/training.rs — Rust mirror of `TrainingSignal.swift`.
//
// Architecture spec §11.2, signal 9. Wired per ADR-018 F1: the training
// daemon was previously an orphan (zero production callers); this signal
// registers it in the default standing-signal set so the autonomic governor
// drives it on an hourly cadence.
//
// The `spec` factory accepts a closure that invokes `TrainingDaemon::run_once`
// against the caller-owned audit log, matrix tier, and calibration registry,
// and returns a detail string for the diagnostic emission.
// `default_spec` is the no-op scaffold variant.
//
// The daemon's own threshold gate (DECISION_TRAINING_DAEMON_THRESHOLD_2026-05-21)
// decides whether to actually enrich on each invocation; the signal fires the
// daemon unconditionally and the gate short-circuits below the threshold. Both
// dormant and active ticks produce exactly one diagnostic emission so the
// signal's cadence is always observable.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct TrainingSignal;

impl TrainingSignal {
    /// Hourly cadence in seconds (3 600 = 1 hour) matching the
    /// DistillationSignal and TemporalCausalitySignal rhythm at §11.2.
    /// Mirrors Swift's `TrainingSignal.defaultCadenceSeconds`.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 3_600;

    /// Stable name surfaced in `SignalReport.name` (signal 9, ADR-018 F1).
    /// Mirrors Swift's `TrainingSignal.signalName`.
    pub const SIGNAL_NAME: &'static str = "training-daemon";

    /// Build a signal spec that invokes the training daemon on each fire.
    ///
    /// `training_cycle` is called on each emit. It should invoke
    /// `TrainingDaemon::run_once` against the estate's audit log, matrix
    /// tier, and calibration registry, then return a detail string
    /// (`Ok(detail)`) summarising the tick outcome for the diagnostic.
    /// On `Err(msg)` the error is surfaced as a "training-daemon.error"
    /// diagnostic so the scheduler's drain loop is not interrupted.
    ///
    /// The daemon's threshold gate handles the dormant/active decision.
    /// The signal merely invokes `run_once` unconditionally, and the gate
    /// short-circuits below the threshold so no matrix work occurs.
    pub fn spec<F>(training_cycle: Arc<F>) -> SignalSpec
    where
        F: Fn() -> Result<String, String> + Send + Sync + 'static,
    {
        SignalSpec {
            name: Self::SIGNAL_NAME.to_string(),
            trigger: SignalTrigger::Interval {
                seconds: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS),
            },
            resource_cost: ResourceCostEstimate::ZERO,
            freshness_target: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS * 2),
            concurrency_policy: ConcurrencyPolicy::Single,
            emit: Arc::new(move |context: &SignalContext| match training_cycle() {
                Ok(detail) => {
                    let diagnostic = DiagnosticReport {
                        title: "training-daemon.tick".into(),
                        detail: format!("{}; signal={}", detail, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    // Surface daemon errors as diagnostics so the scheduler's
                    // drain loop is not interrupted.
                    let diagnostic = DiagnosticReport {
                        title: "training-daemon.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }

    /// Build a diagnostic-only spec for test and registration contexts
    /// where no live training daemon is available.
    ///
    /// Fires at the hourly cadence and emits a single diagnostic confirming
    /// the fire. No enrichment or matrix work is performed. This is the
    /// correct spec for `default_standing_signal_specs`, which cannot supply
    /// estate-specific context (daemon, audit log, matrix tier) without
    /// breaking the helper's generic signature.
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
                    title: "training-daemon.fired".into(),
                    detail: format!(
                        "training signal fired (no-op); signal={}",
                        context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                };
                vec![SignalEmission::Diagnostic(diagnostic)]
            }),
        }
    }
}
