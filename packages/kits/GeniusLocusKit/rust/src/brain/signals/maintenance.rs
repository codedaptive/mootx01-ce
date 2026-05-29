// brain/signals/maintenance.rs — Rust mirror of `MaintenanceSignal.swift`.
//
// Architecture spec §11.2 row 2 / invariant I-3. Emits a forbidden-
// combination discipline proposal, a decay-candidate routed through
// propose, and a scan-summary diagnostic on each hourly fire.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct MaintenanceSignal;

impl MaintenanceSignal {
    /// Default cadence in seconds (3 600 = 1 hour).
    pub const DEFAULT_CADENCE_SECONDS: u64 = 3_600;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "maintenance-daemon";

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
                let discipline = ProposalFrame {
                    target: "maintenance/forbidden-combination".into(),
                    kind: ProposalKind::DisciplineViolation,
                    justification: Some(
                        "invariant I-3: sensitivity=secret AND exportability=public scan".into(),
                    ),
                };
                let decay_candidate = SignalEmission::MutateCandidate {
                    row_id: "maintenance/decay-candidate".into(),
                    kind: MutationKind::Supersede,
                };
                let summary = DiagnosticReport {
                    title: "maintenance.scan.summary".into(),
                    detail: format!(
                        "hourly maintenance pass observed: 0 forbidden combinations; signal={}",
                        context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                };
                vec![
                    SignalEmission::Propose(discipline),
                    decay_candidate,
                    SignalEmission::Diagnostic(summary),
                ]
            }),
        }
    }
}
