//! §11.5 Option B add-coverage conformance tests for the Rust port.
//!
//! Mirrors `ContainerFingerprintStoreTests.addCoverageGuaranteeAllThreeBitmaps`
//! and `addCoverageTwoDrawersSameRoom` in Swift.
//!
//! Invariant: after adding a drawer through the sanctioned path
//! (`Estate::capture`), `aggregate & drawer_bits == drawer_bits` must hold for
//! each of the three bitmap fields (adjective, operational, provenance), at both
//! the room-level AND the wing-level container aggregate. Coverage is now
//! structurally guaranteed because `add_drawer` folds the FP update inside
//! itself — this test proves the fold works correctly.

#![cfg(test)]

use crate::adjectives::AdjectiveSensitivity;
use crate::drawer_operational::{CaptureChannel, DrawerFeatureFlags};
use crate::drawer_store::DrawerStore;
use crate::drawer_store_inmemory::InMemoryDrawerStore;
use crate::estate::Estate;
use crate::estate_types::{LatticeAnchor, OwnerCredentials};
use crate::frames::CaptureFrame;
use crate::provenance::SourceType;
use std::sync::Arc;

const NOW: i64 = 1_700_000_000;

fn make_estate() -> (Estate, Arc<InMemoryDrawerStore>) {
    let store = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let estate = Estate::create(store.clone(), OwnerCredentials::new("cov-owner"), None).unwrap();
    (estate, store)
}

// -----------------------------------------------------------------------
// §11.5 coverage: single capture covers room and wing for all three bitmaps
// -----------------------------------------------------------------------

/// After adding a drawer through the sanctioned path (`Estate::capture`),
/// all three bitmap fields must be fully covered by both the room-level AND
/// the wing-level container aggregate: `aggregate & drawer_bits == drawer_bits`
/// for adjective, operational, and provenance. Mirrors Swift
/// `addCoverageGuaranteeAllThreeBitmaps`.
#[test]
fn add_coverage_guarantee_all_three_bitmaps() {
    let (estate, store) = make_estate();

    // Build a frame with non-trivial values in all three bitmap axes.
    // .voiced channel (raw 1) occupies operationalBitmap bits 0–5;
    // .code kind (raw 1) occupies bits 6–11; .restricted sensitivity
    // (raw 32) sits in adjectiveBitmap bits 6–11; .observed sourceType
    // (raw 1) sits in provenance bits 0–5.
    let mut frame = CaptureFrame::new(
        "coverage-test",
        CaptureChannel::Voiced,
        "r-cov",
        LatticeAnchor::udc("004"),
        "cov-tester",
        "model-v1",
    );
    frame.sensitivity = AdjectiveSensitivity::Restricted;
    frame.source_type = SourceType::Observed;
    // content_kind defaults to Prose (raw 0); channel=Voiced sets op bits 0–5
    // to the raw value of Voiced (1). This produces non-zero values in all fields.

    let drawer = estate.capture(frame, NOW).unwrap();

    // wing/room resolved from node tree via parent_node_id.
    let names = store.resolve_node_names(&[drawer.parent_node_id.clone()]).unwrap();
    let (wing, room) = names.get(&drawer.parent_node_id).expect("node must resolve");
    let wing = wing.clone();
    let room = room.clone();

    // Room-level aggregate must cover all three fields.
    let room_fp = store
        .get_container_fingerprint(&wing, &room)
        .unwrap()
        .expect("room aggregate must exist after capture");
    assert_eq!(
        room_fp.adjective & drawer.adjective_bitmap,
        drawer.adjective_bitmap,
        "room adjective aggregate must cover drawer.adjective_bitmap"
    );
    assert_eq!(
        room_fp.operational & drawer.operational_bitmap,
        drawer.operational_bitmap,
        "room operational aggregate must cover drawer.operational_bitmap"
    );
    assert_eq!(
        room_fp.provenance & drawer.provenance,
        drawer.provenance,
        "room provenance aggregate must cover drawer.provenance"
    );

    // Wing-level rollup (room == "") must also cover all three fields.
    let wing_fp = store
        .get_container_fingerprint(&wing, "")
        .unwrap()
        .expect("wing aggregate must exist after capture");
    assert_eq!(
        wing_fp.adjective & drawer.adjective_bitmap,
        drawer.adjective_bitmap,
        "wing adjective aggregate must cover drawer.adjective_bitmap"
    );
    assert_eq!(
        wing_fp.operational & drawer.operational_bitmap,
        drawer.operational_bitmap,
        "wing operational aggregate must cover drawer.operational_bitmap"
    );
    assert_eq!(
        wing_fp.provenance & drawer.provenance,
        drawer.provenance,
        "wing provenance aggregate must cover drawer.provenance"
    );
}

// -----------------------------------------------------------------------
// §11.5 coverage: two drawers in same room, aggregate covers both
// -----------------------------------------------------------------------

/// Two drawers in the same room: aggregate covers both, so no field of
/// either drawer is absent from the aggregate. Mirrors Swift
/// `addCoverageTwoDrawersSameRoom`.
#[test]
fn add_coverage_two_drawers_same_room() {
    let (estate, store) = make_estate();

    let frame1 = CaptureFrame::new(
        "first",
        CaptureChannel::Voiced,
        "r-cov2",
        LatticeAnchor::udc("004"),
        "t",
        "m",
    );
    let frame2 = CaptureFrame::new(
        "second",
        CaptureChannel::Typed,
        "r-cov2",
        LatticeAnchor::udc("004"),
        "t",
        "m",
    );

    let d1 = estate.capture(frame1, NOW).unwrap();
    let d2 = estate.capture(frame2, NOW + 1).unwrap();

    // wing resolved from node tree via parent_node_id.
    let names = store.resolve_node_names(&[d1.parent_node_id.clone()]).unwrap();
    let (wing, _) = names.get(&d1.parent_node_id).expect("node must resolve");

    let room_fp = store
        .get_container_fingerprint(wing, "r-cov2")
        .unwrap()
        .expect("room aggregate must exist after two captures");

    // The aggregate must cover d1's bits AND d2's bits.
    assert_eq!(room_fp.adjective & d1.adjective_bitmap, d1.adjective_bitmap,
               "aggregate must cover d1 adjective");
    assert_eq!(room_fp.adjective & d2.adjective_bitmap, d2.adjective_bitmap,
               "aggregate must cover d2 adjective");
    assert_eq!(room_fp.operational & d1.operational_bitmap, d1.operational_bitmap,
               "aggregate must cover d1 operational");
    assert_eq!(room_fp.operational & d2.operational_bitmap, d2.operational_bitmap,
               "aggregate must cover d2 operational");
    assert_eq!(room_fp.provenance & d1.provenance, d1.provenance,
               "aggregate must cover d1 provenance");
    assert_eq!(room_fp.provenance & d2.provenance, d2.provenance,
               "aggregate must cover d2 provenance");
}

// -----------------------------------------------------------------------
// setDistilledRepresentation fingerprint maintenance
// -----------------------------------------------------------------------

/// `DrawerStoreCore::set_distilled_representation` must OR bit 19
/// (`HAS_CURRENT_REPRESENTATION`) into the room/wing OR aggregate in the
/// same logical operation, so a subsequent recall filter on
/// `HasFeatureFlag(HasCurrentRepresentation)` does not falsely exclude
/// the container mid-session without requiring an estate reopen.
/// Mirrors Swift `ContainerFingerprintStoreTests
/// .setDistilledRepresentationUpdatesFingerprint`.
#[test]
fn set_distilled_representation_updates_fingerprint() {
    let (estate, store) = make_estate();

    // Capture a drawer — bit 19 (HAS_CURRENT_REPRESENTATION) is clear at capture.
    let frame = CaptureFrame::new(
        "dist-content",
        CaptureChannel::Voiced,
        "r-dist",
        LatticeAnchor::udc("004"),
        "t",
        "m",
    );
    let drawer = estate.capture(frame, NOW).unwrap();
    let bit19 = DrawerFeatureFlags::HAS_CURRENT_REPRESENTATION;

    // Resolve wing/room from the node tree.
    let names = store
        .resolve_node_names(&[drawer.parent_node_id.clone()])
        .unwrap();
    let (wing, _) = names
        .get(&drawer.parent_node_id)
        .expect("node must resolve");
    let wing = wing.clone();

    // Bit 19 absent from OR aggregate before distillation.
    let pre_fp = store
        .get_container_fingerprint(&wing, "r-dist")
        .unwrap()
        .expect("room aggregate must exist after capture");
    assert_eq!(
        pre_fp.operational & bit19,
        0,
        "bit 19 must be absent from the room aggregate before distillation"
    );

    // Distil the drawer post-capture — no estate reopen.
    let updated = estate
        .set_distilled_representation(&drawer.id, "distilled text", "v1", 42, NOW + 1000)
        .unwrap();
    assert_eq!(updated, 1);

    // Bit 19 must now appear in both room-level and wing-level OR aggregates.
    let post_room_fp = store
        .get_container_fingerprint(&wing, "r-dist")
        .unwrap()
        .expect("room aggregate must exist after distillation");
    assert_eq!(
        post_room_fp.operational & bit19,
        bit19,
        "bit 19 must be set in the room OR aggregate after set_distilled_representation"
    );
    let post_wing_fp = store
        .get_container_fingerprint(&wing, "")
        .unwrap()
        .expect("wing aggregate must exist after distillation");
    assert_eq!(
        post_wing_fp.operational & bit19,
        bit19,
        "bit 19 must be set in the wing OR aggregate after set_distilled_representation"
    );
}
