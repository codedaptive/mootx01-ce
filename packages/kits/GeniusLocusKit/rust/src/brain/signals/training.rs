// brain/signals/training.rs — Rust mirror of `TrainingSignal.swift`.
//
// The training
// daemon was previously an orphan (zero production callers); this signal
// registers it in the default standing-signal set so the autonomic governor
// drives it on an hourly cadence.
//
// The `spec` factory accepts a closure that invokes `TrainingDaemon::run_once`
// against the caller-owned audit log, matrix tier, and calibration registry,
// and returns a detail string for the diagnostic emission. There is no no-op
// variant: `default_standing_signal_specs` pushes this signal only when
// handed a live `training_cycle`, which the resident passes only while the
// estate's `adaptive_recall` preference is not `Off`.
//
// The daemon's own threshold gate
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
    /// TemporalCausalitySignal rhythm at §11.2.
    /// Mirrors Swift's `TrainingSignal.defaultCadenceSeconds`.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 3_600;

    /// Stable name surfaced in `SignalReport.name` (signal 9, brain-layer governor ownership).
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
}
