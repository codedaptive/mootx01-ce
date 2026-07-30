// brain/signals/consolidation.rs — consolidation sweep standing signal
// (signal 11). Rust mirror of `ConsolidationSignal.swift`.
//
// Cadence: daily (86 400 s) — the THETA-window cadence class. Each fire
// runs ONE bounded sweep (the D9 candidate cap inside ConsolidationConfig
// bounds the work per window; the sweep resumes from its cursor next fire
// so a large aged estate consolidates across cycles without starving other
// dream-cycle work).
//
// Single-write invariant: the consolidation sweep itself persists vague
// drawers and constituent bitmaps through the estate verb surface — the
// signal must NOT re-dispatch anything. The injected closure returns a
// `ConsolidationSweepReport` and the signal emits exactly one summary
// diagnostic. Same pattern as `ContradictionScoutSignal` (signal 10).

use std::sync::Arc;
use std::time::Duration;

use crate::brain::consolidation_cycle::ConsolidationSweepReport;
use crate::brain::scheduler::api::*;

pub struct ConsolidationSignal;

impl ConsolidationSignal {
    /// Daily cadence in seconds — Wave-2 D9/D11 maintenance-window class.
    /// Mirrors Swift's `ConsolidationSignal.defaultCadenceSeconds`.
    pub const DEFAULT_CADENCE_SECONDS: u64 = 86_400;

    /// Stable name surfaced in `SignalReport.name` (signal 11).
    /// Mirrors Swift's `ConsolidationSignal.signalName`.
    pub const SIGNAL_NAME: &'static str = "consolidation-sweep";

    /// Build a signal spec that runs one bounded consolidation sweep per fire.
    ///
    /// `consolidation_cycle` returns `Ok(ConsolidationSweepReport)` on success.
    /// Errors are caught and surfaced as a "consolidation-sweep.error" diagnostic
    /// so the scheduler's drain loop continues unaffected. The fold-in rejection
    /// counter in the report is surfaced in the diagnostic so the D10 drift
    /// policy (defrag trigger) can be evaluated from `recentDiagnostics` without
    /// a separate metrics channel.
    ///
    /// The single-write invariant applies: the closure persists vague drawers
    /// and constituent bitmap updates through the estate verb surface; the signal
    /// itself emits only a summary diagnostic, not re-dispatched proposals.
    ///
    /// Mirrors Swift `ConsolidationSignal.spec`.
    pub fn spec<F>(consolidation_cycle: Arc<F>) -> SignalSpec
    where
        F: Fn() -> Result<ConsolidationSweepReport, String> + Send + Sync + 'static,
    {
        SignalSpec {
            name: Self::SIGNAL_NAME.to_string(),
            trigger: SignalTrigger::Interval {
                seconds: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS),
            },
            resource_cost: ResourceCostEstimate::ZERO,
            freshness_target: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS * 2),
            concurrency_policy: ConcurrencyPolicy::Single,
            emit: Arc::new(move |context: &SignalContext| match consolidation_cycle() {
                Ok(report) => {
                    // The sweep already persisted vague drawers and constituent
                    // bitmaps through the estate verb surface — summary diagnostic
                    // only (single-write invariant).
                    let diagnostic = DiagnosticReport {
                        title: "consolidation-sweep.complete".into(),
                        detail: format!(
                            "new={} foldIns={} foldInRejections={}; signal={}",
                            report.new_vague_items,
                            report.fold_ins,
                            report.fold_in_rejections,
                            context.signal_id.0
                        ),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
                Err(msg) => {
                    let diagnostic = DiagnosticReport {
                        title: "consolidation-sweep.error".into(),
                        detail: format!("{}; signal={}", msg, context.signal_id.0),
                        observed_at_nanos: context.now_nanos,
                    };
                    vec![SignalEmission::Diagnostic(diagnostic)]
                }
            }),
        }
    }

    /// No-op spec for registration contexts where no live consolidation cycle
    /// can be supplied (tests, and the generic `default_standing_signal_specs`
    /// helper which cannot supply estate-specific closures). Fires on cadence
    /// and surfaces a "consolidation-sweep.fired" diagnostic so the scheduler's
    /// rhythm remains observable.
    ///
    /// Mirrors Swift `ConsolidationSignal.defaultSpec`.
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
                    title: "consolidation-sweep.fired".into(),
                    detail: format!(
                        "consolidation sweep fired (no-op); signal={}",
                        context.signal_id.0
                    ),
                    observed_at_nanos: context.now_nanos,
                };
                vec![SignalEmission::Diagnostic(diagnostic)]
            }),
        }
    }
}
