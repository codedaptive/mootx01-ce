//! Capture-into-wing conformance tests for the Rust port.
//!
//! Mirrors `CaptureIntoWingTests.swift`. Asserts that:
//!   - Supplying `wing: Some("User Canon")` in `CaptureFrame` causes the
//!     stored drawer to land in that wing.
//!   - Supplying `wing: None` falls through to the estate default
//!     ("Agentic Memory"), preserving byte-identical behaviour for all
//!     existing callers.
//!
//! ADR-016: wing targeting at capture time.
//! ADR-017: wing/room resolved from node tree via parent_node_id.

#![cfg(test)]

use crate::default_wings::DEFAULT_WING_NAME;
use crate::drawer::Drawer;
use crate::drawer_operational::CaptureChannel;
use crate::drawer_store::DrawerStore;
use crate::drawer_store_inmemory::InMemoryDrawerStore;
use crate::estate::Estate;
use crate::estate_types::{LatticeAnchor, OwnerCredentials};
use crate::frames::CaptureFrame;
use std::sync::Arc;

const NOW: i64 = 1_700_000_000;

/// Build a fresh estate on an in-memory store (no disk I/O needed for
/// capture-into-wing; tests assert wing/room placement through the
/// node tree via `resolve_node_names`, not only on the returned Drawer).
fn make_estate() -> Estate {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    Estate::create(store, OwnerCredentials::new("wing-test-owner"), None).unwrap()
}

/// Build a minimal `CaptureFrame` with an optional wing slot.
fn frame_with_wing(content: &str, wing: Option<&str>) -> CaptureFrame {
    let mut f = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::udc("004"),
        "test-agent",
        "minilm-v6",
    );
    f.wing = wing.map(|s| s.to_string());
    f
}

/// Resolve the wing name for a drawer via its parent_node_id in the
/// estate's node tree (ADR-017).
fn resolve_wing(estate: &Estate, drawer: &Drawer) -> String {
    let names = estate.store.resolve_node_names(&[drawer.parent_node_id.clone()]).unwrap();
    let (wing, _) = names.get(&drawer.parent_node_id).expect("wing node must resolve");
    wing.clone()
}

// -----------------------------------------------------------------------
// 1. Explicit wing — drawer lands in the named wing
// -----------------------------------------------------------------------
#[test]
fn capture_explicit_wing_drawer_lands_in_wing() {
    let estate = make_estate();
    let frame = frame_with_wing("user canon content", Some("User Canon"));
    let drawer = estate.capture(frame, NOW).unwrap();
    assert_eq!(
        resolve_wing(&estate, &drawer), "User Canon",
        "drawer wing should equal the frame's explicit wing, not the default"
    );
}

#[test]
fn capture_personal_wing_drawer_lands_in_personal() {
    let estate = make_estate();
    let frame = frame_with_wing("personal note", Some("Personal"));
    let drawer = estate.capture(frame, NOW).unwrap();
    assert_eq!(resolve_wing(&estate, &drawer), "Personal");
}

// -----------------------------------------------------------------------
// 2. None wing — drawer lands in default wing ("Agentic Memory")
// -----------------------------------------------------------------------
#[test]
fn capture_none_wing_drawer_lands_in_default_wing() {
    let estate = make_estate();
    let frame = frame_with_wing("agentic capture", None);
    let drawer = estate.capture(frame, NOW).unwrap();
    assert_eq!(
        resolve_wing(&estate, &drawer), DEFAULT_WING_NAME,
        "None wing must fall through to the estate default '{}'",
        DEFAULT_WING_NAME
    );
}

#[test]
fn capture_no_wing_field_default_wing_unchanged() {
    let estate = make_estate();
    // Construct the frame exactly as all existing callers do — via
    // CaptureFrame::new() which sets wing: None. The stored drawer
    // must land in the same default wing as before this slot existed.
    let frame = CaptureFrame::new(
        "backward compat content",
        CaptureChannel::Voiced,
        "stream",
        LatticeAnchor::udc("300"),
        "legacy-caller",
        "minilm-v6",
    );
    // Confirm new() still defaults wing to None.
    assert!(frame.wing.is_none(), "CaptureFrame::new() must set wing: None");
    let drawer = estate.capture(frame, NOW).unwrap();
    assert_eq!(
        resolve_wing(&estate, &drawer), "Agentic Memory",
        "omitting wing must preserve the 'Agentic Memory' default"
    );
}

// -----------------------------------------------------------------------
// 3. Two captures, different wings — both stored with correct wing
// -----------------------------------------------------------------------
#[test]
fn capture_two_wings_both_stored_correctly() {
    let estate = make_estate();

    let canon_frame = frame_with_wing("canon content", Some("User Canon"));
    let agentic_frame = frame_with_wing("agentic content", None);

    let canon = estate.capture(canon_frame, NOW).unwrap();
    let agentic = estate.capture(agentic_frame, NOW + 1).unwrap();

    assert_eq!(resolve_wing(&estate, &canon), "User Canon");
    assert_eq!(resolve_wing(&estate, &agentic), DEFAULT_WING_NAME);
    // IDs must differ.
    assert_ne!(canon.id, agentic.id);
}
