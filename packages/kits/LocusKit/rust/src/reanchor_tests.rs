//! Reanchor verb conformance suite (VERB-REA-01).
//!
//! Case-for-case mirror of `ReanchorTests.swift` (I-19):
//!
//!   - DrawerStore::reanchor_gated room move
//!   - DrawerStore::reanchor_gated lattice move
//!   - DrawerStore::reanchor_gated audit event appended
//!   - DrawerStore::reanchor_gated absent row → DrawerNotFound
//!   - Estate::reanchor empty args → InvalidContent
//!   - Estate::reanchor non-existent rowID → DrawerNotFound
//!   - Estate::reanchor to new room
//!   - Estate::reanchor to new lattice
//!   - Estate::reanchor bitmaps unchanged
//!   - Estate::reanchor audit entry written
//!   - Estate::reanchor both room and lattice simultaneously

#[cfg(test)]
mod tests {
    use crate::drawer_operational::CaptureChannel;
    use crate::drawer_store::DrawerStore;
    use crate::drawer_store_inmemory::InMemoryDrawerStore;
    use crate::error::LocusKitError;
    use crate::estate::Estate;
    use crate::estate_types::{LatticeAnchor, OwnerCredentials};
    use crate::frames::CaptureFrame;
    use std::sync::Arc;

    // -----------------------------------------------------------------------
    // Fixture helpers
    // -----------------------------------------------------------------------

    fn make_store() -> Arc<InMemoryDrawerStore> {
        // InMemoryDrawerStore::new allocates InMemoryStorage internally —
        // backend identity is visible at the type, not the argument.
        Arc::new(InMemoryDrawerStore::new(1_700_000_000, None).unwrap())
    }

    fn make_estate() -> Estate {
        let store = Arc::new(InMemoryDrawerStore::new(1_700_000_000, None).unwrap());
        Estate::create(store, OwnerCredentials::new("owner"), None).unwrap()
    }

    fn basic_capture(
        estate: &Estate,
        content: &str,
        room: &str,
        udc: &str,
    ) -> crate::drawer::Drawer {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc(udc),
            "test-agent",
            "test-model-v1",
        );
        estate.capture(frame, 1_700_000_001).unwrap()
    }

    fn audit_event_count(store: &dyn DrawerStore, id: &str) -> usize {
        store.audit_events_for_row(id).unwrap().len()
    }

    const ID_ABSENT: &str = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

    // -----------------------------------------------------------------------
    // DrawerStore::reanchor_gated — room move
    // -----------------------------------------------------------------------

    #[test]
    fn reanchor_gated_room_move_updates_room() {
        let estate = make_estate();
        let d = basic_capture(&estate, "placement test", "room-original", "000.100");

        estate
            .store
            .reanchor_gated(&d.id, Some("room-new"), None, None, "test", None, 1_700_000_500)
            .unwrap();

        let after = estate.store.get_drawer(&d.id).unwrap().unwrap();
        // ADR-017: room resolved from node tree via parent_node_id.
        let names = estate.store.resolve_node_names(&[after.parent_node_id.clone()]).unwrap();
        let (_, room) = names.get(&after.parent_node_id).expect("room node must resolve");
        assert_eq!(room, "room-new");
        // Lattice anchor unchanged.
        assert_eq!(after.udc_code, "000.100");
    }

    #[test]
    fn reanchor_gated_room_move_bitmaps_unchanged() {
        let estate = make_estate();
        let d = basic_capture(&estate, "bitmap preserve", "room-orig", "000");
        let before_adj = d.adjective_bitmap;
        let before_op = d.operational_bitmap;
        let before_prov = d.provenance;

        estate
            .store
            .reanchor_gated(&d.id, Some("room-moved"), None, None, "test", None, 1_700_000_500)
            .unwrap();

        let after = estate.store.get_drawer(&d.id).unwrap().unwrap();
        assert_eq!(after.adjective_bitmap, before_adj);
        assert_eq!(after.operational_bitmap, before_op);
        assert_eq!(after.provenance, before_prov);
    }

    // -----------------------------------------------------------------------
    // DrawerStore::reanchor_gated — lattice move
    // -----------------------------------------------------------------------

    #[test]
    fn reanchor_gated_lattice_move_updates_anchor() {
        let estate = make_estate();
        let d = basic_capture(&estate, "lattice test", "room-x", "000");

        let new_anchor = LatticeAnchor {
            udc_code: "003.456".to_string(),
            udc_facets: Some("030".to_string()),
            wikidata_qid: Some("Q12345".to_string()),
            wikidata_qids_secondary: None,
        };
        estate
            .store
            .reanchor_gated(&d.id, None, None, Some(new_anchor), "test", None, 1_700_000_500)
            .unwrap();

        let after = estate.store.get_drawer(&d.id).unwrap().unwrap();
        assert_eq!(after.udc_code, "003.456");
        assert_eq!(after.udc_facets.as_deref(), Some("030"));
        assert_eq!(after.wikidata_qid.as_deref(), Some("Q12345"));
        assert!(after.wikidata_qids_secondary.is_none());
        // Room unchanged — parent_node_id should be the same as before.
        assert_eq!(after.parent_node_id, d.parent_node_id);
    }

    #[test]
    fn reanchor_gated_lattice_move_bitmaps_unchanged() {
        let estate = make_estate();
        let d = basic_capture(&estate, "lattice bitmap", "room-y", "001.000");
        let before_adj = d.adjective_bitmap;
        let before_op = d.operational_bitmap;
        let before_prov = d.provenance;

        estate
            .store
            .reanchor_gated(
                &d.id,
                None,
                None,
                Some(LatticeAnchor::udc("003.000")),
                "test",
                None,
                1_700_000_500,
            )
            .unwrap();

        let after = estate.store.get_drawer(&d.id).unwrap().unwrap();
        assert_eq!(after.adjective_bitmap, before_adj);
        assert_eq!(after.operational_bitmap, before_op);
        assert_eq!(after.provenance, before_prov);
    }

    // -----------------------------------------------------------------------
    // DrawerStore::reanchor_gated — audit event written
    // -----------------------------------------------------------------------

    #[test]
    fn reanchor_gated_audit_event_appended() {
        let estate = make_estate();
        let d = basic_capture(&estate, "audit test", "room-a", "000");
        let count_before = audit_event_count(estate.store.as_ref(), &d.id);
        assert_eq!(count_before, 1); // genesis capture event

        estate
            .store
            .reanchor_gated(&d.id, Some("room-b"), None, None, "test", None, 1_700_000_500)
            .unwrap();

        let count_after = audit_event_count(estate.store.as_ref(), &d.id);
        assert_eq!(count_after, 2); // genesis + reanchor
    }

    // -----------------------------------------------------------------------
    // DrawerStore::reanchor_gated — not found
    // -----------------------------------------------------------------------

    #[test]
    fn reanchor_gated_absent_row_returns_not_found() {
        let store = make_store();
        let err = store
            .reanchor_gated(
                ID_ABSENT,
                Some("new-room"),
                None,
                None,
                "test",
                None,
                1_700_000_100,
            )
            .unwrap_err();
        assert!(matches!(err, LocusKitError::DrawerNotFound { .. }));
    }

    // -----------------------------------------------------------------------
    // Estate::reanchor — verb wrapper
    // -----------------------------------------------------------------------

    #[test]
    fn estate_reanchor_empty_args_returns_invalid_content() {
        let estate = make_estate();
        let d = basic_capture(&estate, "empty guard", "room-a", "000");
        let err = estate.reanchor(&d.id, None, None, None).unwrap_err();
        assert!(matches!(err, LocusKitError::InvalidContent(_)));
    }

    #[test]
    fn estate_reanchor_nonexistent_row_returns_not_found() {
        let estate = make_estate();
        let err = estate
            .reanchor(ID_ABSENT, Some("new-room"), None, None)
            .unwrap_err();
        assert!(matches!(err, LocusKitError::DrawerNotFound { .. }));
    }

    #[test]
    fn estate_reanchor_to_room_updates_room() {
        let estate = make_estate();
        let d = basic_capture(&estate, "room move via estate", "original-room", "000");

        estate.reanchor(&d.id, Some("moved-room"), None, None).unwrap();

        let after = estate.store.get_drawer(&d.id).unwrap().unwrap();
        // ADR-017: room resolved from node tree via parent_node_id.
        let names = estate.store.resolve_node_names(&[after.parent_node_id.clone()]).unwrap();
        let (_, room) = names.get(&after.parent_node_id).expect("room node must resolve");
        assert_eq!(room, "moved-room");
    }

    #[test]
    fn estate_reanchor_to_lattice_updates_anchor() {
        let estate = make_estate();
        let d = basic_capture(&estate, "lattice via estate", "room-x", "000");

        estate
            .reanchor(&d.id, None, None, Some(LatticeAnchor::udc("003.000")))
            .unwrap();

        let after = estate.store.get_drawer(&d.id).unwrap().unwrap();
        assert_eq!(after.udc_code, "003.000");
    }

    #[test]
    fn estate_reanchor_bitmaps_preserved() {
        let estate = make_estate();
        let d = basic_capture(&estate, "bitmaps via estate", "room-a", "000");
        let before_adj = d.adjective_bitmap;
        let before_op = d.operational_bitmap;
        let before_prov = d.provenance;

        estate.reanchor(&d.id, Some("new-room"), None, None).unwrap();

        let after = estate.store.get_drawer(&d.id).unwrap().unwrap();
        assert_eq!(after.adjective_bitmap, before_adj);
        assert_eq!(after.operational_bitmap, before_op);
        assert_eq!(after.provenance, before_prov);
    }

    #[test]
    fn estate_reanchor_audit_entry_written() {
        let estate = make_estate();
        let d = basic_capture(&estate, "audit via estate", "room-a", "000");
        let count_before = audit_event_count(estate.store.as_ref(), &d.id);
        assert_eq!(count_before, 1); // genesis

        estate
            .reanchor(&d.id, Some("audit-moved-room"), None, None)
            .unwrap();

        let count_after = audit_event_count(estate.store.as_ref(), &d.id);
        assert_eq!(count_after, 2); // genesis + reanchor
    }

    #[test]
    fn estate_reanchor_both_room_and_lattice() {
        let estate = make_estate();
        let d = basic_capture(&estate, "both fields via estate", "room-a", "100");

        estate
            .reanchor(&d.id, Some("room-b"), None, Some(LatticeAnchor::udc("200")))
            .unwrap();

        let after = estate.store.get_drawer(&d.id).unwrap().unwrap();
        // ADR-017: room resolved from node tree via parent_node_id.
        let names = estate.store.resolve_node_names(&[after.parent_node_id.clone()]).unwrap();
        let (_, room) = names.get(&after.parent_node_id).expect("room node must resolve");
        assert_eq!(room, "room-b");
        assert_eq!(after.udc_code, "200");
    }

    #[test]
    fn estate_reanchor_to_wing_updates_wing() {
        // Bug J regression: reanchor must update the wing when to_wing is supplied.
        // ADR-017: wing/room resolved from node tree via parent_node_id.
        let estate = make_estate();
        let d = basic_capture(&estate, "wing move via estate", "origin-room", "000");
        let original_names = estate.store.resolve_node_names(&[d.parent_node_id.clone()]).unwrap();
        let (original_wing, _) = original_names.get(&d.parent_node_id).expect("must resolve");
        let original_wing = original_wing.clone();

        estate
            .reanchor(&d.id, Some("target-room"), Some("TargetWing"), None)
            .unwrap();

        let after = estate.store.get_drawer(&d.id).unwrap().unwrap();
        let after_names = estate.store.resolve_node_names(&[after.parent_node_id.clone()]).unwrap();
        let (wing, room) = after_names.get(&after.parent_node_id).expect("must resolve");
        assert_eq!(wing, "TargetWing", "wing must be updated by reanchor");
        assert_eq!(room, "target-room", "room must also be updated");
        assert_ne!(wing, &original_wing, "wing must differ from original");
    }

    // -----------------------------------------------------------------------
    // Finding B: reanchor rejects empty / whitespace-only to_wing
    //
    // Before this fix the guard checked `to_wing.is_none()` only, so an
    // empty string silently persisted as a nameless wing node — estate state
    // that `capture` would refuse to create.
    // -----------------------------------------------------------------------

    #[test]
    fn estate_reanchor_empty_wing_returns_invalid_content() {
        // An empty string wing must be rejected; mirrors the capture-path guard.
        let estate = make_estate();
        let d = basic_capture(&estate, "empty wing guard", "room-a", "000");
        let err = estate
            .reanchor(&d.id, None, Some(""), None)
            .unwrap_err();
        assert!(
            matches!(err, LocusKitError::InvalidContent(_)),
            "expected InvalidContent for empty to_wing, got {err:?}"
        );
    }

    #[test]
    fn estate_reanchor_whitespace_wing_returns_invalid_content() {
        // A whitespace-only string is equivalent to empty for wing names.
        let estate = make_estate();
        let d = basic_capture(&estate, "whitespace wing guard", "room-a", "000");
        let err = estate
            .reanchor(&d.id, None, Some("   "), None)
            .unwrap_err();
        assert!(
            matches!(err, LocusKitError::InvalidContent(_)),
            "expected InvalidContent for whitespace-only to_wing, got {err:?}"
        );
    }

    #[test]
    fn estate_reanchor_valid_nonempty_wing_is_accepted() {
        // The empty-wing guard must not block legitimate wing moves.
        let estate = make_estate();
        let d = basic_capture(&estate, "valid wing move", "room-a", "000");
        estate
            .reanchor(&d.id, None, Some("Personal"), None)
            .expect("non-empty to_wing must succeed");
    }
}
