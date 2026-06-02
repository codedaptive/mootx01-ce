//! Estate audit and history API. Ports `EstateAudit.swift`.
//!
//! Three methods sit on `Estate` here: two flavours of `audit_trail`
//! (per-row and time-range) and a historical `bitmap_state`
//! reconstruction. All three return `Result<T, LocusKitError>` to match
//! the verb surface error contract.
//!
//! ## Reconstruction via the audit log fold (cookbook § 5.3)
//!
//! `bitmap_state(row_id, as_of: HLC)` folds the row's sealed audit
//! events via `AuditLogFold::project_state_at`: events at or before
//! `as_of` are replayed in HLC order starting from the genesis
//! capture event, producing the projected
//! `(adjective, operational, provenance)` snapshot. State is keyed on
//! HLC, not wall-clock (DECISION_CLOCK_TRIANGLE_TIME_MODEL §11:
//! wall-clock is not a fold axis).
//!
//! All three bitmap columns are reconstructed from the same fold —
//! each `AuditEvent` carries the after-snapshot for all columns; the
//! audit log is a single sequence per row, not per-column partitions.
//! The earlier `bitmap_audit` and `provenance_audit` tables were
//! retired in the F13 audit-log migration.

use crate::audit_types::BitmapState;
use crate::drawer_store_inmemory::require_uuid;
use crate::error::LocusKitError;
use crate::estate::Estate;

impl Estate {
    // -----------------------------------------------------------------------
    // audit_trail (per-row)
    // -----------------------------------------------------------------------

    /// All bitmap audit rows for a single row, ordered by `changed_at`
    /// ascending. Returns an empty `Vec` when no mutations have been
    /// recorded — a freshly-captured drawer's trail is empty until its
    /// first `withdraw` / `mutate_adjective` / `mutate_operational` call
    /// (capture is an INSERT, not a mutation).
    ///
    /// # Parameters
    ///
    /// - `row_id`: the drawer's stable id.
    ///
    /// # Errors
    ///
    /// Returns `LocusKitError::DatabaseUnavailable` or
    /// `LocusKitError::SqliteError` if the substrate query fails.
    pub fn audit_trail(
        &self,
        row_id: &str,
    ) -> Result<Vec<substrate_lib::verbs::AuditEvent>, LocusKitError> {
        // The row's sealed audit events in HLC order — the audit-log
        // source of truth (DECISION_CLOCK_TRIANGLE_TIME_MODEL). Events
        // are snapshots, not deltas. The cross-row wall-clock window form
        // was dropped in the audit-log migration (§11: wall-clock is not
        // an ordering/fold axis).
        self.store.audit_events_for_row(row_id)
    }

    // -----------------------------------------------------------------------
    // bitmap_state
    // -----------------------------------------------------------------------

    /// Reconstruct a row's bitmap state as of an HLC by folding the
    /// sealed audit log via `AuditLogFold::project_state_at`
    /// (cookbook § 5.3). State evolves in ingest-HLC order per the
    /// clock decision; `as_of` is an HLC, not wall-clock.
    pub fn bitmap_state(
        &self,
        row_id: &str,
        as_of: substrate_types::hlc::HLC,
    ) -> Result<BitmapState, LocusKitError> {
        let uuid = require_uuid(row_id, "rowID")?;
        let events = self.store.audit_events_for_row(row_id)?;
        let projected = substrate_ml::audit_log_fold::AuditLogFold::project_state_at(
            substrate_lib::verbs::RowId(uuid.as_u128()),
            substrate_lib::verbs::NounType::Drawer,
            &events,
            as_of,
        )
        .ok_or_else(|| LocusKitError::DrawerNotFound {
            id: row_id.to_string(),
        })?;

        Ok(BitmapState {
            row_id: row_id.to_string(),
            as_of,
            adjective_bitmap: projected.adjective_bitmap,
            operational_bitmap: projected.operational_bitmap,
            provenance_bitmap: projected.provenance_bitmap,
        })
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use crate::adjectives::State;
    use crate::audit_types::BitmapState;
    use crate::drawer_operational::CaptureChannel;
    use crate::drawer_store_inmemory::InMemoryDrawerStore;
    use crate::estate::Estate;
    use crate::estate_types::{LatticeAnchor, OwnerCredentials};
    use crate::frames::CaptureFrame;
    use std::sync::Arc;

    fn make_estate() -> Estate {
        // InMemoryDrawerStore::new allocates InMemoryStorage internally —
        // backend identity is visible at the type, not the argument.
        let store = Arc::new(InMemoryDrawerStore::new(1_700_000_000, None).unwrap());
        Estate::create(store, OwnerCredentials::new("owner"), None).unwrap()
    }

    fn capture_one(estate: &Estate, now: i64) -> String {
        let frame = CaptureFrame::new(
            "audit-test content",
            CaptureChannel::Typed,
            "archive",
            LatticeAnchor::udc("7"),
            "carol",
            "test-v1",
        );
        estate.capture(frame, now).unwrap().id
    }

    // --- audit_trail (per row) ---

    #[test]
    fn audit_trail_has_genesis_event_for_fresh_drawer() {
        // Capture now emits a gated genesis event (the moment of
        // remembering is in the log), so a freshly-captured drawer's
        // trail holds exactly one event: the capture.
        let estate = make_estate();
        let id = capture_one(&estate, 1_700_000_001);
        let trail = estate.audit_trail(&id).unwrap();
        assert_eq!(trail.len(), 1, "fresh drawer has its genesis capture event");
        assert_eq!(trail[0].verb, "capture");
    }

    #[test]
    fn audit_trail_records_withdraw() {
        let estate = make_estate();
        let id = capture_one(&estate, 1_700_000_001);
        estate.withdraw(&id, Some("test"), 1_700_000_002).unwrap();
        let trail = estate.audit_trail(&id).unwrap();
        // Two events now: the genesis capture, then the withdraw. Events
        // are HLC-ordered snapshots (after_bitmaps), not deltas.
        assert_eq!(trail.len(), 2, "capture + withdraw = two events");
        assert_eq!(trail[0].verb, "capture");
        assert_eq!(trail[0].after_bitmaps.0 & 0x3F, State::Active.raw_value());
        assert_eq!(trail[1].verb, "retract");
        assert_eq!(
            trail[1].after_bitmaps.0 & 0x3F,
            State::Withdrawn.raw_value()
        );
    }

    // --- bitmap_state ---

    #[test]
    fn bitmap_state_not_found_for_unknown_row() {
        let estate = make_estate();
        // A valid-but-absent UUID: no events for it → DrawerNotFound.
        // (A non-UUID id is a different, louder contract error.)
        let err = estate
            .bitmap_state(
                "99999999-9999-4999-8999-999999999999",
                substrate_types::hlc::HLC::new(1_700_000_000, 0, 0),
            )
            .unwrap_err();
        assert!(matches!(
            err,
            crate::error::LocusKitError::DrawerNotFound { .. }
        ));
    }

    #[test]
    fn bitmap_state_not_found_when_at_precedes_filed_at() {
        let estate = make_estate();
        let id = capture_one(&estate, 1_700_000_100);
        // Ask for state before the genesis event existed: no events at or
        // before this HLC → DrawerNotFound (the row had no state yet).
        let err = estate
            .bitmap_state(&id, substrate_types::hlc::HLC::new(1_700_000_050, 0, 0))
            .unwrap_err();
        assert!(matches!(
            err,
            crate::error::LocusKitError::DrawerNotFound { .. }
        ));
    }

    #[test]
    fn bitmap_state_at_current_time_matches_live_bitmap() {
        let estate = make_estate();
        let id = capture_one(&estate, 1_700_000_001);
        // Genesis event now exists; folding as of its HLC yields the live
        // value (no mutations on top). Use the capture event's own HLC.
        let trail = estate.audit_trail(&id).unwrap();
        let cap_hlc = trail[0].hlc;
        let state: BitmapState = estate.bitmap_state(&id, cap_hlc).unwrap();
        let live = estate.store.get_drawer(&id).unwrap().unwrap();
        assert_eq!(state.adjective_bitmap, live.adjective_bitmap);
        assert_eq!(state.operational_bitmap, live.operational_bitmap);
    }

    #[test]
    fn bitmap_state_at_genesis_hlc_reconstructs_pre_withdraw_state() {
        let estate = make_estate();
        let id = capture_one(&estate, 1_700_000_001);
        // Capture HLC — the genesis event that the fold reconstructs from.
        let cap_hlc = estate.audit_trail(&id).unwrap()[0].hlc;
        let before = estate.bitmap_state(&id, cap_hlc).unwrap();

        // Withdraw happens later.
        estate.withdraw(&id, None, 1_700_000_006).unwrap();

        // Reconstructing as of the capture HLC (before the withdraw) gives
        // the original Active state, not Withdrawn — the genesis event
        // makes this reconstruction possible at all.
        let reconstructed = estate.bitmap_state(&id, cap_hlc).unwrap();
        assert_eq!(reconstructed.adjective_bitmap, before.adjective_bitmap);
        let state = State::from_raw(reconstructed.adjective_bitmap & 0x3F);
        assert_eq!(state, State::Active);
    }
}
