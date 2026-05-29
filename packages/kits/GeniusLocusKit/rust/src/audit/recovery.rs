// audit/recovery.rs — Rebuild-from-audit recovery (Rust mirror).
//
// Swift reference: `AuditRecovery.swift`. CRDT properties of the log
// (cookbook §5.1, §5.4) guarantee the rebuild is deterministic and
// order-independent.

use super::log::{AuditTier, UnifiedAuditEntry, UnifiedAuditLog};
use super::projection::{AuditProjectionFold, UnifiedProjection, UnifiedProjectionKey, UnifiedRowProjection};
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuditRecoveryResult {
    pub projection: UnifiedProjection,
    pub entries_replayed: usize,
    pub rows_rebuilt: usize,
    pub locus_rows: usize,
    pub rag_rows: usize,
}

impl AuditRecoveryResult {
    fn from(projection: UnifiedProjection, entries_replayed: usize) -> Self {
        let rows_rebuilt = projection.count();
        let locus_rows = projection
            .rows
            .values()
            .filter(|r| r.tier == AuditTier::Locus)
            .count();
        let rag_rows = projection
            .rows
            .values()
            .filter(|r| r.tier == AuditTier::Rag)
            .count();
        Self {
            projection,
            entries_replayed,
            rows_rebuilt,
            locus_rows,
            rag_rows,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RowMismatch {
    pub key: UnifiedProjectionKey,
    pub expected: Option<UnifiedRowProjection>,
    pub rebuilt: Option<UnifiedRowProjection>,
}

#[derive(Clone, Debug, Eq, PartialEq, Default)]
pub struct AuditRecoveryDivergence {
    pub mismatches: Vec<RowMismatch>,
}

impl AuditRecoveryDivergence {
    pub fn is_empty(&self) -> bool { self.mismatches.is_empty() }
}

pub struct AuditRecovery;

impl AuditRecovery {
    pub fn rebuild(log: &UnifiedAuditLog) -> AuditRecoveryResult {
        let projection = AuditProjectionFold::project(log);
        AuditRecoveryResult::from(projection, log.count())
    }

    pub fn rebuild_as_of(log: &UnifiedAuditLog, cutoff: HLC) -> AuditRecoveryResult {
        let truncated = log.entries_as_of(cutoff);
        let entry_count = truncated.len();
        let log_slice = UnifiedAuditLog::with_entries(truncated);
        let projection = AuditProjectionFold::project(&log_slice);
        AuditRecoveryResult::from(projection, entry_count)
    }

    pub fn rebuild_streaming<I: IntoIterator<Item = UnifiedAuditEntry>>(
        entries: I,
    ) -> AuditRecoveryResult {
        let mut log = UnifiedAuditLog::new();
        for entry in entries {
            log.add(entry);
        }
        Self::rebuild(&log)
    }

    pub fn verify(
        rebuilt: &UnifiedProjection,
        reference: &UnifiedProjection,
    ) -> AuditRecoveryDivergence {
        let mut mismatches = Vec::new();
        let mut keys: Vec<UnifiedProjectionKey> = rebuilt.rows.keys().copied().collect();
        for k in reference.rows.keys() {
            if !keys.contains(k) {
                keys.push(*k);
            }
        }
        for key in keys {
            let r = rebuilt.rows.get(&key).cloned();
            let e = reference.rows.get(&key).cloned();
            if r != e {
                mismatches.push(RowMismatch { key, expected: e, rebuilt: r });
            }
        }
        AuditRecoveryDivergence { mismatches }
    }
}
