// brain/signals/span_encode.rs — Rust mirror of `SpanEncodeSignal.swift`.
//
// ENCODER_RERANK_CONTRACT §10, signal 13. Replaces `adornment.rs` (removed):
// fires the span-encode drain duty on each REM-ALPHA (30 s) tick and
// surfaces the encoded-drawer count as a diagnostic.
//
// Mirrors `AnomalySweepSignal` exactly in structure: 30 s cadence (REM-ALPHA),
// `.single` concurrency, diagnostic-only emission, injected closure for the
// live cycle. The `spec` factory accepts a closure returning the encoded-drawer
// count; `default_spec` is the no-op scaffold variant used when no live encoder
// is available (correct for test scaffolds and `default_standing_signal_specs`
// before a live encoder is wired).

use std::sync::Arc;
use std::time::Duration;

use crate::brain::scheduler::api::*;

pub struct SpanEncodeSignal;

impl SpanEncodeSignal {
    /// REM-ALPHA cadence in seconds — 30 s, matching `RemCycleTable`.
    /// Significantly faster than the hourly adornment pass this replaces.
    /// Mirrors Swift `SpanEncodeSignal.defaultCadenceSeconds`.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 30;

    /// Stable name surfaced in `SignalReport.name`.
    /// Contract §10: signal name is "span-encode".
    /// Mirrors Swift `SpanEncodeSignal.signalName`.
    pub const SIGNAL_NAME: &'static str = "span-encode";

    /// Build a signal spec that invokes the span-encode drain on each fire.
    ///
    /// `span_encode_cycle` is called on each emit and returns the number of
    /// drawers encoded (`Ok(count)`) or an error description (`Err(msg)`).
    /// `Ok(0)` is correct when no unindexed drawers are present or the
    /// encoder is nil. Errors are surfaced as "span-encode.error" diagnostics
    /// so the scheduler's drain loop is not interrupted.
    pub fn spec<F>(span_encode_cycle: Arc<F>) -> SignalSpec
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
            emit: Arc::new(move |context: &SignalContext| match span_encode_cycle() {
                Ok(count) => {
                    let diagnostic = DiagnosticReport {
                        title: "span-encode.complete".into(),
                        detail: format!(
                            "encoded {} drawer(s); signal={}",
                            count, context.signal_id.0
                        ),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    // Surface drain errors as diagnostics so the scheduler's
                    // drain loop is not interrupted. Matches the Swift spec
                    // factory's catch block behaviour.
                    let diagnostic = DiagnosticReport {
                        title: "span-encode.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }

    /// Build a diagnostic-only spec for test and registration contexts
    /// where no live encoder is wired.
    ///
    /// Fires at the REM-ALPHA cadence and emits a single diagnostic
    /// confirming the fire. No encoding work is performed.
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
                // No-op drain: fires the scheduled signal and surfaces a
                // diagnostic so the scheduler's cadence is observable.
                let diagnostic = DiagnosticReport {
                    title: "span-encode.fired".into(),
                    detail: format!(
                        "span-encode signal fired (no-op); signal={}",
                        context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                };
                vec![SignalEmission::Diagnostic(diagnostic)]
            }),
        }
    }
}
