// training/pipeline.rs — Rust mirror of `EnrichmentPipeline.swift`.
//
// Folds the post-watermark audit-log tail into the matrix tier
// through the same surfaces the rebuild path uses
// (`MatrixTier::apply_capture`). Bundles entries by
// (tier, row, hlc) so the co-occurrence walk sees every fingerprint
// field of a row together. The watermark is returned to the caller
// for incremental ticks.

use std::collections::HashMap;

use crate::audit::{AuditTier, EntryUUID, UnifiedAuditLog, UnifiedAuditValue, UnifiedAuditVerb};
use crate::matrix::{MatrixCalibrationRegistry, MatrixTier, MatrixValueCoord};
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

// MARK: - Pass result

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EnrichmentPassResult {
    pub transitions_considered: i64,
    pub f_cells_touched: i64,
    pub o_keys_touched: i64,
    pub t_keys_touched: i64,
    pub calibration_observations_recorded: i64,
    pub high_water_mark: HLC,
}

impl EnrichmentPassResult {
    pub fn empty() -> Self {
        Self {
            transitions_considered: 0,
            f_cells_touched: 0,
            o_keys_touched: 0,
            t_keys_touched: 0,
            calibration_observations_recorded: 0,
            high_water_mark: HLC::new(0, 0, 0),
        }
    }
}

// MARK: - Pipeline

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct EnrichmentPipeline;

impl EnrichmentPipeline {
    pub fn new() -> Self {
        Self
    }

    /// Fold the post-`high_water_mark` tail of `log` into `tier`. The
    /// calibration registry is taken by mutable reference because the
    /// future structured-pair hook will write to it; today the field
    /// passes through unchanged.
    pub fn run(
        &self,
        log: &UnifiedAuditLog,
        tier: &mut MatrixTier,
        calibration: &mut MatrixCalibrationRegistry,
        high_water_mark: HLC,
    ) -> EnrichmentPassResult {
        let _ = calibration; // suppression hook — see file header
        let entries = log.entries_since(high_water_mark);
        if entries.is_empty() {
            return EnrichmentPassResult {
                transitions_considered: 0,
                f_cells_touched: 0,
                o_keys_touched: 0,
                t_keys_touched: 0,
                calibration_observations_recorded: 0,
                high_water_mark,
            };
        }

        let before_f = tier.field_presence.len() as i64;
        let before_o = tier.co_occurrence.len() as i64;
        let before_t = tier.temporal_causality.len() as i64;

        type RowKey = (AuditTier, EntryUUID, HLC);
        let mut bitmap_bundle: HashMap<RowKey, Vec<(String, u64)>> = HashMap::new();
        let mut value_bundle: HashMap<RowKey, Vec<MatrixValueCoord>> = HashMap::new();
        let mut bundle_sign: HashMap<RowKey, i64> = HashMap::new();
        let mut bundle_order: Vec<RowKey> = Vec::new();
        let mut transitions_considered: i64 = 0;
        let mut max_hlc = high_water_mark;

        for entry in entries {
            if entry.hlc > max_hlc {
                max_hlc = entry.hlc;
            }
            let key: RowKey = (entry.tier, entry.row_id, entry.hlc);

            let sign: Option<i64> = match entry.verb {
                UnifiedAuditVerb::Capture => {
                    transitions_considered += 1;
                    Some(1)
                }
                UnifiedAuditVerb::Expunge => {
                    transitions_considered += 1;
                    Some(-1)
                }
                UnifiedAuditVerb::Mutate | UnifiedAuditVerb::Reanchor => {
                    transitions_considered += 1;
                    None
                }
                UnifiedAuditVerb::Withdraw => {
                    // Soft tombstone — decrement liveRowCount without
                    // touching F / O for this row's fields.
                    tier.apply_capture(&[], &[], entry.hlc, -1);
                    transitions_considered += 1;
                    None
                }
                UnifiedAuditVerb::Recall
                | UnifiedAuditVerb::Propose
                | UnifiedAuditVerb::Associate
                | UnifiedAuditVerb::Learn
                | UnifiedAuditVerb::DreamCompact
                | UnifiedAuditVerb::Migrate => None,
            };
            let Some(s) = sign else {
                continue;
            };

            if !bundle_sign.contains_key(&key) {
                bundle_order.push(key);
            }
            bundle_sign.insert(key, s);

            match &entry.after_value {
                UnifiedAuditValue::Bitmap(v) => {
                    bitmap_bundle
                        .entry(key)
                        .or_default()
                        .push((entry.field_path.clone(), *v));
                }
                _ => {
                    value_bundle
                        .entry(key)
                        .or_default()
                        .push(MatrixValueCoord::new(
                            entry.field_path.clone(),
                            entry.after_value.clone(),
                        ));
                }
            }
        }

        // Apply bundles in HLC order. Use the recorded `bundle_order`
        // to preserve insertion order; within identical HLCs the
        // capture order matters and a HashMap iteration would
        // otherwise be nondeterministic.
        bundle_order.sort_by_key(|a| a.2);
        for key in &bundle_order {
            let sign = match bundle_sign.get(key) {
                Some(s) => *s,
                None => continue,
            };
            let bm = bitmap_bundle.remove(key).unwrap_or_default();
            let vs = value_bundle.remove(key).unwrap_or_default();
            tier.apply_capture(&bm, &vs, key.2, sign);
        }

        let f_delta = (tier.field_presence.len() as i64 - before_f).max(0);
        let o_delta = (tier.co_occurrence.len() as i64 - before_o).max(0);
        let t_delta = (tier.temporal_causality.len() as i64 - before_t).max(0);

        EnrichmentPassResult {
            transitions_considered,
            f_cells_touched: f_delta,
            o_keys_touched: o_delta,
            t_keys_touched: t_delta,
            calibration_observations_recorded: 0,
            high_water_mark: max_hlc,
        }
    }
}
