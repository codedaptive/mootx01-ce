// brain/signals/decay_sweep.rs — Rust mirror of `DecaySweepSignal.swift`.
//
// Architecture spec §11.2 / §6.8. Emits one `mutate_candidate` (routed
// through propose per §11.1) plus a scan-summary diagnostic on every
// daily fire.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct DecaySweepSignal;

impl DecaySweepSignal {
    /// Default cadence in seconds (86 400 = 1 day). Cookbook §15.2.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 86_400;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "decay-sweep";

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
                let candidate = SignalEmission::MutateCandidate {
                    row_id: "decay/aged-candidate".into(),
                    kind: MutationKind::Supersede,
                };
                let diagnostic = DiagnosticReport {
                    title: "decay_sweep.pass.summary".into(),
                    detail: format!(
                        "daily decay pass observed 1 aged candidate; signal={}",
                        context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                };
                vec![candidate, SignalEmission::Diagnostic(diagnostic)]
            }),
        }
    }
}
