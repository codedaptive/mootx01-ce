// parity.rs — conformance gate for the GeniusLocusKit Rust port.
//
// The shared test vectors below encode the same scenarios the Swift
// reference exercises in CrossEstateOverlapTests.swift. The vector
// set is small (three estates at fixed zoom windows; queries at four
// canonical regions) because the conformance unit here is the
// overlap predicate, not the per-drawer recall payload — the
// LocusKit Rust port has not yet shipped, so per-drawer parity is
// out of scope for this scaffold mission.
//
// Whenever the Swift predicate changes, this file must change with
// it; the parity gate exists precisely to catch drift between ports.

use genius_locus_kit::{
    EstateCoordinator, EstateHandle, GeniusLocusKitError, LatticeRegion,
};

/// The shared estate set used by every parity test below. Three
/// estates with distinct, partially-overlapping zoom windows.
/// Identical to the windows used in
/// `Tests/GeniusLocusKitTests/CrossEstateOverlapTests.swift`.
fn open_three_estates() -> (EstateCoordinator, EstateHandle, EstateHandle, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    // UUID bytes chosen so sort order matches the test expectations
    // below (low < mid < high lexicographically).
    let u_low: [u8; 16]  = [1; 16];
    let u_mid: [u8; 16]  = [2; 16];
    let u_high: [u8; 16] = [3; 16];
    let h_low  = coord.open(u_low,  0,  10, "low".into()).expect("open low");
    let h_mid  = coord.open(u_mid,  5,  15, "mid".into()).expect("open mid");
    let h_high = coord.open(u_high, 20, 30, "high".into()).expect("open high");
    (coord, h_low, h_mid, h_high)
}

#[test]
fn lifecycle_three_estates() {
    let (coord, _h_low, _h_mid, _h_high) = open_three_estates();
    assert_eq!(coord.open_estate_count(), 3);
    assert_eq!(coord.handles().len(), 3);
}

#[test]
fn close_leaves_remaining_handles_live() {
    let (mut coord, h_low, h_mid, h_high) = open_three_estates();
    coord.close(&h_mid).expect("close mid");
    assert_eq!(coord.open_estate_count(), 2);
    let live: std::collections::HashSet<EstateHandle> =
        coord.handles().into_iter().collect();
    assert!(live.contains(&h_low));
    assert!(live.contains(&h_high));
    assert!(!live.contains(&h_mid));

    // Stale handle lookup raises EstateNotOpen.
    let err = coord.state_for(&h_mid).err().expect("expected EstateNotOpen");
    assert_eq!(
        err,
        GeniusLocusKitError::EstateNotOpen { estate_uuid: h_mid.estate_uuid }
    );
}

#[test]
fn duplicate_open_is_rejected() {
    let mut coord = EstateCoordinator::new();
    let uuid: [u8; 16] = [42; 16];
    coord.open(uuid, 0, 10, "first".into()).expect("first open");
    let err = coord
        .open(uuid, 0, 10, "second".into())
        .err()
        .expect("expected DuplicateEstate");
    assert_eq!(err, GeniusLocusKitError::DuplicateEstate { estate_uuid: uuid });
}

#[test]
fn overlap_routes_to_low_and_mid() {
    let (coord, h_low, h_mid, _h_high) = open_three_estates();
    // Region [4, 8] overlaps low ([0,10]) and mid ([5,15]); high is
    // disjoint. Parity expectation identical to the Swift test.
    let hits = coord
        .estates_overlapping(LatticeRegion::new(4, 8))
        .expect("overlap query");
    assert_eq!(hits, vec![h_low, h_mid]);
}

#[test]
fn overlap_routes_to_high_only() {
    let (coord, _h_low, _h_mid, h_high) = open_three_estates();
    let hits = coord
        .estates_overlapping(LatticeRegion::new(25, 28))
        .expect("overlap query");
    assert_eq!(hits, vec![h_high]);
}

#[test]
fn disjoint_region_returns_empty() {
    let (coord, ..) = open_three_estates();
    let hits = coord
        .estates_overlapping(LatticeRegion::new(40, 50))
        .expect("overlap query");
    assert!(hits.is_empty());
}

#[test]
fn inverted_region_throws() {
    let (coord, ..) = open_three_estates();
    let err = coord
        .estates_overlapping(LatticeRegion::new(10, 4))
        .err()
        .expect("expected InvalidLatticeRegion");
    assert_eq!(
        err,
        GeniusLocusKitError::InvalidLatticeRegion { low: 10, high: 4 }
    );
}

#[test]
fn fan_out_returns_contribution_per_overlapping_estate() {
    let (coord, h_low, h_mid, _h_high) = open_three_estates();
    let contributions = coord
        .fan_out_recall(LatticeRegion::new(4, 8))
        .expect("fan-out");
    assert_eq!(contributions.len(), 2);
    let handles: std::collections::HashSet<EstateHandle> =
        contributions.iter().map(|c| c.handle).collect();
    assert_eq!(
        handles,
        std::collections::HashSet::from([h_low, h_mid])
    );
}
