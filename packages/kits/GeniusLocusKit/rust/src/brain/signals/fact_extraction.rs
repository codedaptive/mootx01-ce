use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct FactExtractionSignal;

impl FactExtractionSignal {
    pub const DEFAULT_CADENCE_SECONDS: u64 = 300;
    pub const SIGNAL_NAME: &'static str = "fact-extraction";

    pub fn spec<F>(cycle: Arc<F>) -> SignalSpec
    where
        F: Fn() -> Result<i64, String> + Send + Sync + 'static,
    {
        Self::spec_with_cadence(Self::DEFAULT_CADENCE_SECONDS, cycle)
    }

    /// `cadence_seconds` is the host's `duties.fact_extraction_cadence_seconds`
    /// (§ DUTY_LIFECYCLE); the freshness target is twice the cadence.
    pub fn spec_with_cadence<F>(cadence_seconds: u64, cycle: Arc<F>) -> SignalSpec
    where
        F: Fn() -> Result<i64, String> + Send + Sync + 'static,
    {
        let cadence_seconds = cadence_seconds.max(1);
        SignalSpec {
            name: Self::SIGNAL_NAME.into(),
            trigger: SignalTrigger::Interval {
                seconds: Duration::from_secs(cadence_seconds),
            },
            resource_cost: ResourceCostEstimate::ZERO,
            freshness_target: Duration::from_secs(cadence_seconds * 2),
            concurrency_policy: ConcurrencyPolicy::Single,
            emit: Arc::new(move |context| {
                let (title, detail) = match cycle() {
                    Ok(count) => (
                        "fact-extraction.complete",
                        format!(
                            "completed {count} source(s); signal={}",
                            context.signal_id.0
                        ),
                    ),
                    Err(error) => (
                        "fact-extraction.error",
                        format!("{error}; signal={}", context.signal_id.0),
                    ),
                };
                vec![SignalEmission::Diagnostic(DiagnosticReport {
                    title: title.into(),
                    detail,
                    observed_at_nanos: context.now_nanos,
                })]
            }),
        }
    }

    pub fn default_spec() -> SignalSpec {
        Self::spec(Arc::new(|| Ok(0)))
    }
}
