// brain/signals/dreaming.rs — Rust mirror of `DreamingSignal.swift`.
//
// Architecture spec §11.2 row 1 / cookbook §15 — the dreaming daemon.
// Emits mining-pattern proposals on each fire via an injected daemon cycle
// closure. Cadence: weekly per cookbook §15.2.
//
// The `spec` factory accepts a closure that returns proposals from the
// dreaming daemon. The caller constructs a `DreamingDaemon` (neuron_kit)
// with production seam implementations and captures it in the closure.
// genius_locus_kit cannot depend on neuron_kit (circular crate dependency);
// the closure is the architectural bridge between the two crates.

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

    /// Build a signal spec that invokes the dreaming daemon on each fire.
    ///
    /// `daemon_cycle` is called on each emit and returns the proposals the
    /// daemon emitted. An empty `Vec` is correct when the estate has no
    /// co-occurrence candidates. The Rust emit closure is synchronous;
    /// the daemon_cycle closure should already have its seam inputs bound.
    ///
    /// Usage: construct a `DreamingDaemon` (neuron_kit), wrap its
    /// `run_cycle` result's `proposals_emitted` in an `Arc<dyn Fn>`, and
    /// pass it here.
    pub fn spec<F>(daemon_cycle: Arc<F>) -> SignalSpec
    where
        F: Fn() -> Vec<ProposalFrame> + Send + Sync + 'static,
    {
        SignalSpec {
            name: Self::SIGNAL_NAME.to_string(),
            trigger: SignalTrigger::Interval {
                seconds: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS),
            },
            resource_cost: ResourceCostEstimate::ZERO,
            freshness_target: Duration::from_secs(Self::DEFAULT_CADENCE_SECONDS * 2),
            concurrency_policy: ConcurrencyPolicy::Single,
            // Map each ProposalFrame from the daemon cycle to a
            // SignalEmission::Propose. An empty cycle returns vec![].
            emit: Arc::new(move |_context: &SignalContext| {
                daemon_cycle()
                    .into_iter()
                    .map(SignalEmission::Propose)
                    .collect()
            }),
        }
    }
}
