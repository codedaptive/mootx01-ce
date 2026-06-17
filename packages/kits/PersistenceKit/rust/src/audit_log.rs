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
use std::collections::HashSet;
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
    /// Human-readable reason for the mutation, persisted in the `reason`
    /// column of `_storagekit_audit`. None when the caller supplied no
    /// reason; stored as nullable TEXT.
    pub reason: Option<String>,
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

    /// Return the subset of `row_ids` that have at least one audit event
    /// whose verb matches any entry in `verbs`.
    ///
    /// This is the set-membership half of a SQL LEFT JOIN between the drawers
    /// table and the audit table:
    ///
    /// ```sql
    /// SELECT DISTINCT "row_id" FROM "_storagekit_audit"
    /// WHERE "row_id" IN (?) AND "verb" IN (?)
    /// ```
    ///
    /// SQL-backed implementations (SQLite, PostgreSQL) express this as a single
    /// indexed query. The InMemory backend scans its in-memory event vec.
    ///
    /// Used by `DrawerStoreCore::tombstoned_rows_without_expunge_audit` to
    /// replace N per-row `events_for_row` calls with a single batch query,
    /// giving O(tombstoned + audit_index_scan) instead of
    /// O(tombstoned × events_per_drawer).
    ///
    /// An empty `row_ids` or empty `verbs` slice returns an empty set without
    /// touching the backend.
    fn row_ids_with_audit_verbs(
        &self,
        row_ids: &[RowKey],
        verbs: &[&str],
    ) -> StorageResult<HashSet<RowKey>>;

    /// Total event count.
    fn count(&self) -> StorageResult<usize>;
}
