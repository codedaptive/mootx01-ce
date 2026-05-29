//! AuditLog trait: append-only audit log per
//! DECISION_STORAGEKIT_DESIGN section 9 (Q7).
//!
//! AuditEvent here is a Rust-side mirror of Swift's `AuditEvent`
//! with two simplifications: bitmap triples are flat fields
//! rather than tuples (Rust doesn't have named tuples), and the
//! LatticeAnchor type is stored as raw u64 codes since
//! persistence-kit doesn't import the lattice algebra (which lives
//! in substrate-lib / locus-kit). When the full audit chain
//! lands in Rust LocusKit, this struct gains the lattice anchor
//! decoder; for v1.0 the codes are sufficient for round-trip.

use crate::error::StorageResult;
use crate::types::RowKey;
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

#[derive(Debug, Clone)]
pub struct AuditEvent {
    pub event_id: RowKey,
    pub estate_uuid: RowKey,
    pub row_id: RowKey,
    pub hlc: HLC,
    pub verb: String,
    pub before_adjective: Option<i64>,
    pub before_operational: Option<i64>,
    pub before_provenance: Option<i64>,
    pub after_adjective: i64,
    pub after_operational: i64,
    pub after_provenance: i64,
    pub before_lattice_anchor: Option<u64>,
    pub after_lattice_anchor: u64,
    pub actor: String,
}

pub trait AuditLog: Send + Sync {
    /// Append a single event. Idempotent on (event_id, hlc).
    fn append(&self, event: AuditEvent) -> StorageResult<()>;

    /// Bulk append for sync inbound. Idempotent.
    fn append_batch(&self, events: Vec<AuditEvent>) -> StorageResult<()>;

    /// Iterate in HLC order. Resume via `after` cursor.
    fn iterate(
        &self,
        after: Option<HLC>,
        row_id: Option<RowKey>,
        limit: usize,
    ) -> StorageResult<Vec<AuditEvent>>;

    /// Read events for a row, in HLC order.
    fn events_for_row(&self, row_id: RowKey) -> StorageResult<Vec<AuditEvent>>;

    /// Total event count.
    fn count(&self) -> StorageResult<usize>;
}
