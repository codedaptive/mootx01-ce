// audit/projection.rs — Deterministic current-state and asOf
// projection over the unified audit log (Rust mirror).
//
// Swift reference: `AuditProjection.swift`. Last-writer-wins per
// field-path, HLC ordered, tier-scoped per-row keying.

use std::collections::BTreeMap;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;

use super::log::{
    AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog, UnifiedAuditValue, UnifiedAuditVerb,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Ord, PartialOrd)]
pub struct UnifiedProjectionKey {
    pub tier: AuditTier,
    pub row_id: EntryUUID,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnifiedRowProjection {
    pub tier: AuditTier,
    pub row_id: EntryUUID,
    pub fields: BTreeMap<String, UnifiedAuditValue>,
    pub last_hlc: HLC,
    pub last_verb: UnifiedAuditVerb,
    pub withdrawn: bool,
    pub expunged: bool,
}

impl UnifiedRowProjection {
    fn fresh(tier: AuditTier, row_id: EntryUUID) -> Self {
        Self {
            tier,
            row_id,
            fields: BTreeMap::new(),
            last_hlc: HLC::ZERO,
            last_verb: UnifiedAuditVerb::Capture,
            withdrawn: false,
            expunged: false,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Default)]
pub struct UnifiedProjection {
    pub rows: BTreeMap<UnifiedProjectionKey, UnifiedRowProjection>,
}

impl UnifiedProjection {
    pub fn count(&self) -> usize {
        self.rows.len()
    }
    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    pub fn row(&self, tier: AuditTier, row_id: EntryUUID) -> Option<&UnifiedRowProjection> {
        self.rows.get(&UnifiedProjectionKey { tier, row_id })
    }

    pub fn rows_in_tier(&self, tier: AuditTier) -> Vec<&UnifiedRowProjection> {
        self.rows.values().filter(|r| r.tier == tier).collect()
    }
}

pub struct AuditProjectionFold;

impl AuditProjectionFold {
    pub fn project(log: &UnifiedAuditLog) -> UnifiedProjection {
        Self::fold_ordered(log.ordered_entries())
    }

    pub fn project_as_of(log: &UnifiedAuditLog, cutoff: HLC) -> UnifiedProjection {
        Self::fold_ordered(log.entries_as_of(cutoff))
    }

    fn fold_ordered(entries: Vec<UnifiedAuditEntry>) -> UnifiedProjection {
        let mut rows: BTreeMap<UnifiedProjectionKey, UnifiedRowProjection> = BTreeMap::new();
        for entry in entries {
            let key = UnifiedProjectionKey {
                tier: entry.tier,
                row_id: entry.row_id,
            };
            let state = rows
                .entry(key)
                .or_insert_with(|| UnifiedRowProjection::fresh(entry.tier, entry.row_id));
            // Last-writer-wins per field-path; HLC order makes this
            // deterministic across replicas (cookbook §5.3).
            state
                .fields
                .insert(entry.field_path.clone(), entry.after_value.clone());
            state.last_hlc = entry.hlc;
            state.last_verb = entry.verb;
            match entry.verb {
                UnifiedAuditVerb::Withdraw => state.withdrawn = true,
                UnifiedAuditVerb::Expunge => state.expunged = true,
                UnifiedAuditVerb::Capture if !state.expunged => {
                    // Re-capture after expunge would be a new instance
                    // with a new UUID in the substrate; if this row has
                    // already been expunged, the projection leaves the
                    // tombstone flag in place.
                    state.withdrawn = false;
                }
                _ => {}
            }
        }
        UnifiedProjection { rows }
    }
}
