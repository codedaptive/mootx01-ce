// av01_dream_marker_verb_validation.rs — AV-01 regression coverage at the
// GLK coordinator seam.
//
// Codex finding (LOW), commit dc0f362: the Rust dream-cycle marker write
// path accepted a caller-supplied verb string with zero validation against
// the estate's defined verb set. The fix lives in LocusKit
// (`estate_verbs.rs` / `drawer_store_inmemory.rs`); this file proves the
// fix is reachable end-to-end through the seam NeuronKit's dreaming sink
// actually calls — `EstateCoordinator::append_dream_cycle_marker` — so the
// dream-marker path specifically cannot write an arbitrary verb, not just
// the LocusKit-internal functions in isolation.
//
// Relies on encode markers being ON by default (MOOTX01_ENCODE_MARKERS
// unset in this process) — see `coordinator.rs::encode_markers_enabled`.

use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, EstateHandle};
use locus_kit::{
    drawer_store::DrawerStore, drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::OwnerCredentials,
};

const NOW: i64 = 1_700_000_000;

fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

/// The dream-marker path specifically cannot write an arbitrary verb
/// through the GLK seam — this is the exact call shape
/// `NeuronKit::estate_dreaming_sink` uses (`self.coordinator.append_dream_cycle_marker(&handle, verb, session_id, marked_at)`).
#[test]
fn glk_seam_rejects_arbitrary_dream_marker_verb() {
    let (coord, handle) = open_one();
    let result =
        coord.append_dream_cycle_marker(&handle, "dreamCompromised", "cycle-attack", NOW * 1000);
    assert!(
        result.is_err(),
        "an undefined verb must be rejected at the GLK seam, not silently written"
    );

    // Confirm nothing landed in the audit log under the forged verb.
    let events = coord
        .audit_events(&handle, None, 100)
        .expect("audit_events read must succeed even though the marker write was rejected");
    assert!(events.iter().all(|e| e.verb != "dreamCompromised"));
}

/// Both real values still work through the same seam after the fix.
#[test]
fn glk_seam_accepts_both_defined_dream_verbs() {
    let (coord, handle) = open_one();
    coord
        .append_dream_cycle_marker(&handle, "dreamStart", "cycle-real", NOW * 1000)
        .expect("dreamStart must still be accepted");
    coord
        .append_dream_cycle_marker(&handle, "dreamEnd", "cycle-real", NOW * 1000 + 60_000)
        .expect("dreamEnd must still be accepted");

    let events = coord
        .audit_events(&handle, None, 100)
        .expect("audit_events read must succeed");
    let verbs: Vec<&str> = events
        .iter()
        .filter(|e| e.reason.as_deref() == Some("session=cycle-real"))
        .map(|e| e.verb.as_str())
        .collect();
    assert_eq!(verbs, vec!["dreamStart", "dreamEnd"]);
}
