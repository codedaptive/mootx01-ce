//! A single audit row. Cookbook §5.1 (G-Set CRDT). Stored by
//! the GSetAuditLog under HLC ordering.
//!
//! Moved here from substrate-lib in Phase 6.6 of the pre-ship
//! refactor (decision 2026-05-28 §6.6).
//!
//! Note: this is the canonical wire/audit AuditEvent that mirrors
//! Swift's AuditEvent. `glref-rust-sqlite_tail.rs` carries a
//! different `AuditEvent` struct for the persistence-tail layer
//! with different fields; that one is NOT the same type and stays
//! in substrate-lib.

use crate::hlc::HLC;
use crate::lattice_anchor::LatticeAnchor;
use crate::row::RowId;

#[derive(Debug, Clone)]
pub struct AuditEvent {
    /// Deterministic content-ID (SHA-256 over the wire fields incl. verb
    /// name, first 16 bytes). Set by `audit_gate::content_id`; gives
    /// federation idempotence. Swift `AuditEvent.eventID` is a random
    /// UUID, not a content hash — the two are not equivalent.
    pub event_id: u128,
    pub estate_uuid: u128,
    pub row_id: RowId,
    pub hlc: HLC,
    pub verb: String,
    pub before_bitmaps: Option<(i64, i64, i64)>,
    pub after_bitmaps: (i64, i64, i64),
    pub before_lattice_anchor: Option<LatticeAnchor>,
    pub after_lattice_anchor: LatticeAnchor,
    pub actor: String,
    /// Human-readable reason for the mutation. Threaded from the verb call
    /// site (e.g. expunge_gated(reason:)) and persisted in the `reason`
    /// column of the audit table. None when the caller supplied no reason.
    pub reason: Option<String>,
}
