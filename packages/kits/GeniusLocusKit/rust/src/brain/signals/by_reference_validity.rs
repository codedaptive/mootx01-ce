// brain/signals/by_reference_validity.rs — Rust mirror of
// `ByReferenceValiditySignal.swift`.
//
// Architecture spec §11.2 row 5 / §10 row 7. Emits one `propose`
// (drift) plus a scan-summary diagnostic on every weekly fire.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct ByReferenceValiditySignal;

impl ByReferenceValiditySignal {
    /// Default cadence in seconds (604 800 = 7 days).
    pub const DEFAULT_CADENCE_SECONDS: u64 = 604_800;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "by-reference-validity";

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
                let drift = ProposalFrame {
                    target: "by_reference/aged-row".into(),
                    kind: ProposalKind::ByReferenceDrift,
                    justification: Some(format!(
                        "weekly byReference validation pass observed drift; signal={}",
                        context.signal_id.0
                    )),
                };
                let diagnostic = DiagnosticReport {
                    title: "by_reference.validation.summary".into(),
                    detail: format!(
                        "weekly byReference pass observed 1 drift candidate; signal={}",
                        context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                };
                vec![
                    SignalEmission::Propose(drift),
                    SignalEmission::Diagnostic(diagnostic),
                ]
            }),
        }
    }
}
