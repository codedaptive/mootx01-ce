// brain/signals/dreaming.rs — Rust mirror of `DreamingSignal.swift`.
//
// Architecture spec §11.2 row 1 / cookbook §15 — the dreaming daemon.
// Emits a mining-pattern proposal plus a representative association
// on each fire; cadence weekly per cookbook §15.2.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct DreamingSignal;

impl DreamingSignal {
    /// Default cadence in seconds (604 800 = 7 days). Mirrors Swift's
    /// `DreamingSignal.defaultCadenceSeconds`.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 604_800;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "dreaming-daemon";

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
                let mining = ProposalFrame {
                    target: "dreaming/mining-candidate".into(),
                    kind: ProposalKind::MiningPattern,
                    justification: Some(format!(
                        "weekly NMF candidate (cookbook §15.1 rule 8); signal={}",
                        context.signal_id.0
                    )),
                };
                let association = AssociationFrame {
                    a: "dreaming/source".into(),
                    b: "dreaming/target".into(),
                    weight: 1.0,
                };
                vec![
                    SignalEmission::Propose(mining),
                    SignalEmission::Associate(association),
                ]
            }),
        }
    }
}
