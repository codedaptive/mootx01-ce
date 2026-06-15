// training/daemon.rs — Rust mirror of `TrainingDaemon.swift`.
//
// Composes the threshold gate and the enrichment pipeline into the
// runOnce surface. Dormant ticks short-circuit and leave the watermark
// unchanged; active ticks fold the post-watermark tail and advance
// the watermark in place. The Swift port uses a final class with
// scheduler-actor isolation; the Rust mirror uses `&mut self` because
// the parity test owns the daemon from a single-threaded driver.

use crate::audit::UnifiedAuditLog;
use crate::matrix::{MatrixCalibrationRegistry, MatrixTier};
use crate::training::gate::{TrainingThresholdDecision, TrainingThresholdGate};
use crate::training::pipeline::{EnrichmentPassResult, EnrichmentPipeline};
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;

// MARK: - Tick

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TrainingDaemonTick {
    pub decision: TrainingThresholdDecision,
    pub pass_result: EnrichmentPassResult,
    pub watermark_after: HLC,
}

// MARK: - Report

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TrainingDaemonReport {
    pub estate_id_bytes: [u8; 16],
    pub tick: TrainingDaemonTick,
}

impl TrainingDaemonReport {
    pub fn diagnostic_title(&self) -> &'static str {
        if self.tick.decision.is_active() {
            "training.daemon.active"
        } else {
            "training.daemon.dormant"
        }
    }
}

// MARK: - Daemon

#[derive(Clone, Debug)]
pub struct TrainingDaemon {
    pub gate: TrainingThresholdGate,
    pub pipeline: EnrichmentPipeline,
    watermark: HLC,
}

impl TrainingDaemon {
    pub fn new(gate: TrainingThresholdGate) -> Self {
        Self {
            gate,
            pipeline: EnrichmentPipeline::new(),
            watermark: HLC::new(0, 0, 0),
        }
    }

    pub fn with_pipeline(gate: TrainingThresholdGate, pipeline: EnrichmentPipeline) -> Self {
        Self {
            gate,
            pipeline,
            watermark: HLC::new(0, 0, 0),
        }
    }

    /// Reset the watermark. Used by callers that want the next tick
    /// to re-scan the full audit log.
    pub fn reset_watermark(&mut self) {
        self.watermark = HLC::new(0, 0, 0);
    }

    pub fn watermark(&self) -> HLC {
        self.watermark
    }

    /// Run one daemon pass over `log`. Dormant ticks return an empty
    /// pass result and leave the watermark untouched.
    pub fn run_once(
        &mut self,
        log: &UnifiedAuditLog,
        tier: &mut MatrixTier,
        calibration: &mut MatrixCalibrationRegistry,
    ) -> TrainingDaemonTick {
        let count = TrainingThresholdGate::transition_count(log);
        let decision = self.gate.decide(count);
        if !decision.is_active() {
            return TrainingDaemonTick {
                decision,
                pass_result: EnrichmentPassResult::empty(),
                watermark_after: self.watermark,
            };
        }
        let pass = self.pipeline.run(log, tier, calibration, self.watermark);
        self.watermark = pass.high_water_mark;
        TrainingDaemonTick {
            decision,
            pass_result: pass,
            watermark_after: self.watermark,
        }
    }
}
