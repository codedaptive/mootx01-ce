// capture_into_wing_parity.rs — GLK-level capture-into-wing conformance.
//
// Mirrors `CaptureIntoWingTests.swift` (GeniusLocusKitTests). Asserts that
// the EstateCoordinator.capture path threads `CaptureFrame.wing` through
// to the stored drawer, mirroring the Swift GLK surface behaviour.
//
// ADR-016: wing targeting at capture time.

use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, EstateHandle};
use locus_kit::{
    default_wings::DEFAULT_WING_NAME,
    drawer_operational::CaptureChannel,
    drawer_store::DrawerStore,
    drawer_store_inmemory::InMemoryDrawerStore,
    estate_types::{LatticeAnchor, OwnerCredentials},
    frames::CaptureFrame,
};

const NOW: i64 = 1_700_000_000;

/// Build a coordinator with one open estate. Returns (coordinator, handle).
fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("wing-test-owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

/// Build a `locus_kit::CaptureFrame` with an optional wing.
fn frame_with_wing(content: &str, wing: Option<&str>) -> CaptureFrame {
    let mut f = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "test-room",
        LatticeAnchor::udc("004"),
        "glk-test-agent",
        "test-model-v1",
    );
    f.wing = wing.map(|s| s.to_string());
    f
}

// -----------------------------------------------------------------------
// 1. Explicit wing — drawer lands in the named wing
// -----------------------------------------------------------------------

#[test]
fn glk_capture_explicit_wing_drawer_lands_in_wing() {
    let (coord, handle) = open_one();
    let frame = frame_with_wing("user canon content via GLK", Some("User Canon"));
    let drawer = coord.capture(&handle, frame, NOW).expect("capture");
    assert_eq!(
        drawer.wing, "User Canon",
        "GLK coordinator capture must thread the explicit wing to the stored drawer"
    );
}

#[test]
fn glk_capture_personal_wing_drawer_lands_in_personal() {
    let (coord, handle) = open_one();
    let frame = frame_with_wing("personal diary entry via GLK", Some("Personal"));
    let drawer = coord.capture(&handle, frame, NOW).expect("capture");
    assert_eq!(drawer.wing, "Personal");
}

// -----------------------------------------------------------------------
// 2. None wing — drawer lands in default wing ("Agentic Memory")
// -----------------------------------------------------------------------

#[test]
fn glk_capture_none_wing_drawer_lands_in_default_wing() {
    let (coord, handle) = open_one();
    let frame = frame_with_wing("agentic capture via GLK", None);
    let drawer = coord.capture(&handle, frame, NOW).expect("capture");
    assert_eq!(
        drawer.wing, DEFAULT_WING_NAME,
        "None wing must fall through to '{}'",
        DEFAULT_WING_NAME
    );
}

#[test]
fn glk_capture_new_frame_default_wing_unchanged() {
    let (coord, handle) = open_one();
    // CaptureFrame::new() sets wing: None — confirm the default is preserved.
    let frame = CaptureFrame::new(
        "backward compat content via GLK",
        CaptureChannel::Voiced,
        "stream",
        LatticeAnchor::udc("300"),
        "legacy-caller",
        "test-model-v1",
    );
    assert!(frame.wing.is_none(), "CaptureFrame::new() must set wing: None");
    let drawer = coord.capture(&handle, frame, NOW).expect("capture");
    assert_eq!(
        drawer.wing, "Agentic Memory",
        "omitting wing must preserve the 'Agentic Memory' default"
    );
}
