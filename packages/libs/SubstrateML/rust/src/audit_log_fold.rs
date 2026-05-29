// audit_log_fold.rs
//
// Audit-log fold per cookbook § 8.15 (refers back to § 5.3).
// Mirror of glref-swift-AuditLogFold.swift.

use substrate_types::{AuditEvent, LatticeAnchor, NounType, RowId};
use substrate_types::hlc::HLC;
use std::collections::HashMap;

/// Projected row state — the result of folding a row's audit
/// events. Mirrors the Swift `ProjectedRowState`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectedRowState {
    pub row_id: RowId,
    pub noun_type: NounType,
    pub state_raw: u8,
    pub adjective_bitmap: i64,
    pub operational_bitmap: i64,
    pub provenance_bitmap: i64,
    pub lattice_anchor: LatticeAnchor,
    pub tombstoned: bool,
    pub last_event_hlc: HLC,
}

pub struct AuditLogFold;

impl AuditLogFold {
    /// Project a row's current state from its events.
    pub fn project_current_state(
        row_id: RowId,
        noun_type: NounType,
        events: &[AuditEvent],
    ) -> Option<ProjectedRowState> {
        let mut ordered: Vec<&AuditEvent> = events.iter().filter(|e| e.row_id == row_id).collect();
        ordered.sort_by_key(|e| e.hlc);
        Self::fold_ordered(row_id, noun_type, &ordered)
    }

    /// Project a row's state AS OF a specific HLC.
    pub fn project_state_at(
        row_id: RowId,
        noun_type: NounType,
        events: &[AuditEvent],
        as_of: HLC,
    ) -> Option<ProjectedRowState> {
        let mut truncated: Vec<&AuditEvent> = events
            .iter()
            .filter(|e| e.row_id == row_id && e.hlc <= as_of)
            .collect();
        truncated.sort_by_key(|e| e.hlc);
        Self::fold_ordered(row_id, noun_type, &truncated)
    }

    /// Project all rows from a full audit log, optionally
    /// truncated at `as_of`.
    pub fn project_all<F>(
        events: &[AuditEvent],
        as_of: Option<HLC>,
        noun_type_for: F,
    ) -> HashMap<RowId, ProjectedRowState>
    where
        F: Fn(RowId) -> NounType,
    {
        let truncated: Vec<&AuditEvent> = match as_of {
            Some(cutoff) => events.iter().filter(|e| e.hlc <= cutoff).collect(),
            None => events.iter().collect(),
        };
        let mut by_row: HashMap<RowId, Vec<&AuditEvent>> = HashMap::new();
        for event in &truncated {
            by_row.entry(event.row_id).or_default().push(event);
        }
        let mut result = HashMap::new();
        for (rid, mut row_events) in by_row.into_iter() {
            row_events.sort_by_key(|e| e.hlc);
            if let Some(proj) = Self::fold_ordered(rid, noun_type_for(rid), &row_events) {
                result.insert(rid, proj);
            }
        }
        result
    }

    fn fold_ordered(
        row_id: RowId,
        noun_type: NounType,
        ordered: &[&AuditEvent],
    ) -> Option<ProjectedRowState> {
        let first = ordered.first()?;
        let mut state = ProjectedRowState {
            row_id,
            noun_type,
            state_raw: (first.after_bitmaps.0 & 0x3F) as u8,
            adjective_bitmap: first.after_bitmaps.0,
            operational_bitmap: first.after_bitmaps.1,
            provenance_bitmap: first.after_bitmaps.2,
            lattice_anchor: first.after_lattice_anchor,
            tombstoned: ((first.after_bitmaps.0 & 0x3F) as u8) == 33,
            last_event_hlc: first.hlc,
        };
        for event in ordered.iter().skip(1) {
            state.adjective_bitmap = event.after_bitmaps.0;
            state.operational_bitmap = event.after_bitmaps.1;
            state.provenance_bitmap = event.after_bitmaps.2;
            state.state_raw = (event.after_bitmaps.0 & 0x3F) as u8;
            state.lattice_anchor = event.after_lattice_anchor;
            state.tombstoned = state.tombstoned || state.state_raw == 33;
            state.last_event_hlc = event.hlc;
        }
        Some(state)
    }
}
