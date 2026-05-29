// brain/signals/vector_similarity.rs — Rust mirror of
// `VectorSimilaritySignal.swift`.
//
// Architecture spec §11.2 row 6. Emits one `Associate` proposal plus a
// scan-summary diagnostic on every five-minute fire.

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct VectorSimilaritySignal;

impl VectorSimilaritySignal {
    /// Default cadence in seconds (300 = 5 minutes). Cookbook §15.2.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 300;

    /// Stable name surfaced in `SignalReport.name`.
    pub const SIGNAL_NAME: &'static str = "vector-similarity";

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
                let pair = AssociationFrame {
                    a: "vector/row-a".into(),
                    b: "vector/row-b".into(),
                    weight: 0.75,
                };
                let diagnostic = DiagnosticReport {
                    title: "vector_similarity.scan.summary".into(),
                    detail: format!(
                        "5-minute proximity pass observed 1 candidate pair; signal={}",
                        context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                };
                vec![
                    SignalEmission::Associate(pair),
                    SignalEmission::Diagnostic(diagnostic),
                ]
            }),
        }
    }
}
