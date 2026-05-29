//! Audit subsystem types. Ports `AuditTypes.swift`.
//!
//! `BitmapState` is the read-side projection returned by
//! `Estate::bitmap_state(row_id, as_of)`. It is reconstructed from the
//! row's audit log via `AuditLogFold::project_state_at` — wall-clock
//! is not a fold axis (clock-decision §11; state evolves in ingest-HLC
//! order).

use crate::estate_types::RowID;

/// Snapshot of all three bitmap columns for a row at a specific HLC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BitmapState {
    pub row_id: RowID,
    pub as_of: substrate_types::hlc::HLC,
    pub adjective_bitmap: i64,
    pub operational_bitmap: i64,
    pub provenance_bitmap: i64,
}
