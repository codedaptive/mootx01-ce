// brain/signals/contradiction_scout.rs — the contradiction hunter's
// background half (signal 10). Rust mirror of
// `ContradictionScoutSignal.swift`.
//
// On each fire the injected `hunt_cycle` closure runs one incremental
// `EstateCoordinator::hunt_contradictions` pass (kNN candidate mining +
// SubstrateML conflict_cue screen). The hunt persists any strong finding
// itself as a `contradicts` tunnel with lifecycle `Proposed` /
// origin class `Derived` — the scheduler must NOT re-dispatch anything
// (single-write invariant, same as the dreaming signal), so the closure
// returns (proposed, borderline) counts and the signal emits exactly one
// summary diagnostic.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct ContradictionScoutSignal;

impl ContradictionScoutSignal {
    /// Hourly cadence in seconds (3 600 = 1 hour). Content does not
    /// change on the five-minute tempo of vector-proximity maintenance,
    /// and the durable contradicts-tunnel dedup makes tighter re-screens
    /// pointless. Mirrors Swift's
    /// `ContradictionScoutSignal.defaultCadenceSeconds`.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 3_600;

    /// Stable name surfaced in `SignalReport.name` (signal 10).
    /// Mirrors Swift's `ContradictionScoutSignal.signalName`.
    pub const SIGNAL_NAME: &'static str = "contradiction-scout";

    /// Build a signal spec that runs one hunt pass on each fire.
    ///
    /// `hunt_cycle` returns `Ok((proposed, borderline))` counts — zero /
    /// zero is correct when nothing new conflicts. On `Err(msg)` the
    /// error is surfaced as a "contradiction-scout.pass.error" diagnostic
    /// so the scheduler's drain loop is not interrupted.
    pub fn spec<F>(hunt_cycle: Arc<F>) -> SignalSpec
    where
        F: Fn() -> Result<(usize, usize), String> + Send + Sync + 'static,
    {
        SignalSpec {
            name: Self::SIGNAL_NAME.to_string(),
            trigger: SignalTrigger::Interval {
                seconds: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS),
            },
            resource_cost: ResourceCostEstimate::ZERO,
            freshness_target: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS * 2),
            concurrency_policy: ConcurrencyPolicy::Single,
            emit: Arc::new(move |context: &SignalContext| match hunt_cycle() {
                Ok((proposed, borderline)) => {
                    // The hunt already persisted proposed tunnels through
                    // the estate verb surface — summary diagnostic only.
                    let diagnostic = DiagnosticReport {
                        title: "contradiction-scout.pass.complete".into(),
                        detail: format!(
                            "proposed {} contradiction(s), {} borderline candidate(s); signal={}",
                            proposed, borderline, context.signal_id.0
                        ),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    let diagnostic = DiagnosticReport {
                        title: "contradiction-scout.pass.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }

    /// No-op spec for registration without a wired hunter (tests, and the
    /// generic default-set helper which cannot supply estate-specific
    /// closures). Fires on cadence and surfaces a diagnostic so the
    /// scheduler's rhythm stays observable.
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
                let diagnostic = DiagnosticReport {
                    title: "contradiction-scout.fired".into(),
                    detail: format!(
                        "contradiction scout fired (no-op); signal={}",
                        context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                };
                vec![SignalEmission::Diagnostic(diagnostic)]
            }),
        }
    }
}
