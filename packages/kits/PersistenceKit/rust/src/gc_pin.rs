//! GC pin via snapshot-registry minimum HLC (ADR-017 §15).
//!
//! The maintenance vacuum must not delete tombstoned/superseded rows
//! that are newer than the oldest live snapshot's HLC. This module
//! provides the "minimum retainable HLC" query: the MIN(hlc) across
//! all snapshots. When no snapshots exist, returns None — meaning all
//! rows are vacuumable.

use crate::predicate::OrderClause;
use crate::row_store::RowStore;
use crate::snapshot_registry::SNAPSHOT_REGISTRY_TABLE;
use crate::error::StorageResult;
use crate::types::{Column, TypedValue};
use substrate_types::hlc::HLC;

/// Returns the minimum HLC across all snapshots (the GC pin boundary).
/// Rows with HLC >= this value must not be vacuumed.
/// Returns None when no snapshots exist (all rows are vacuumable).
pub fn minimum_retainable_hlc(row_store: &dyn RowStore) -> StorageResult<Option<HLC>> {
    let rows = row_store.query(
        SNAPSHOT_REGISTRY_TABLE,
        None,
        &[OrderClause::ascending(Column::new(
            SNAPSHOT_REGISTRY_TABLE,
            "hlc",
        ))],
        Some(1),
        None,
    )?;
    let hlc = rows.first().and_then(|row| match row.get("hlc") {
        Some(TypedValue::Hlc(h)) => Some(*h),
        // SQLite read-back returns Text or Int for HLC columns; parse packed i64.
        Some(TypedValue::Text(s)) => {
            let packed: i64 = s.parse().ok()?;
            Some(HLC::from_packed(packed as u64))
        }
        Some(TypedValue::Int(i)) => Some(HLC::from_packed(*i as u64)),
        _ => None,
    });
    Ok(hlc)
}

/// Check whether a row at the given HLC is pinned (must not be vacuumed).
/// A row is pinned if its HLC >= the minimum retainable HLC.
/// When no snapshots exist, nothing is pinned (returns false).
pub fn is_pinned(row_store: &dyn RowStore, row_hlc: HLC) -> StorageResult<bool> {
    match minimum_retainable_hlc(row_store)? {
        None => Ok(false),
        // Pinned if the row's HLC is at or after the oldest snapshot's HLC.
        Some(min_hlc) => Ok(row_hlc.packed() >= min_hlc.packed()),
    }
}
