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

use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, EstateHandle, GeniusLocusKitError, LatticeRegion};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;

/// Open one estate over a fresh in-memory store whose estate UUID is fixed
/// from `uuid_bytes` (so the handle UUID — derived from the opened estate —
/// is deterministic and the sort order below holds). Uses
/// `InMemoryDrawerStore::with_storage` to pin the estate UUID; all other
/// construction sites use `InMemoryDrawerStore::new`.
fn open_estate(
    coord: &mut EstateCoordinator,
    uuid_bytes: [u8; 16],
    low: i64,
    high: i64,
) -> EstateHandle {
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::from_bytes(uuid_bytes)));
    let store = Arc::new(InMemoryDrawerStore::with_storage(storage, 1_700_000_000, None).unwrap());
    coord
        .open(store, OwnerCredentials::new("owner"), low, high)
        .expect("open")
}

/// The shared estate set used by every parity test below. Three estates
/// with distinct, partially-overlapping zoom windows. Identical to the
/// windows used in `Tests/GeniusLocusKitTests/CrossEstateOverlapTests.swift`.
fn open_three_estates() -> (EstateCoordinator, EstateHandle, EstateHandle, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    // UUID bytes chosen so sort order matches the test expectations below
    // (low < mid < high lexicographically).
    let h_low = open_estate(&mut coord, [1; 16], 0, 10);
    let h_mid = open_estate(&mut coord, [2; 16], 5, 15);
    let h_high = open_estate(&mut coord, [3; 16], 20, 30);
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
    let live: std::collections::HashSet<EstateHandle> = coord.handles().into_iter().collect();
    assert!(live.contains(&h_low));
    assert!(live.contains(&h_high));
    assert!(!live.contains(&h_mid));

    // Stale handle lookup raises EstateNotOpen.
    let err = coord
        .estate_for(&h_mid)
        .expect_err("expected EstateNotOpen");
    assert_eq!(
        err,
        GeniusLocusKitError::EstateNotOpen {
            estate_uuid: h_mid.estate_uuid
        }
    );
}

#[test]
fn duplicate_open_is_rejected() {
    let mut coord = EstateCoordinator::new();
    // The faithful duplicate scenario is the SAME database opened twice:
    // one store, opened through two handles. Both reads resolve the same
    // immutable manifest estate UUID (§ 7.7), so the second open is rejected.
    // with_storage pins the estate UUID to [42;16] for this test.
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::from_bytes([42; 16])));
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::with_storage(storage, 1_700_000_000, None).unwrap());
    let h = coord
        .open(store.clone(), OwnerCredentials::new("owner"), 0, 10)
        .expect("first open");
    let err = coord
        .open(store.clone(), OwnerCredentials::new("owner"), 0, 10)
        .expect_err("expected DuplicateEstate");
    assert_eq!(
        err,
        GeniusLocusKitError::DuplicateEstate {
            estate_uuid: h.estate_uuid
        }
    );
}

#[test]
fn overlap_routes_to_low_and_mid() {
    let (coord, h_low, h_mid, _h_high) = open_three_estates();
    // Region [4, 8] overlaps low ([0,10]) and mid ([5,15]); high is
    // disjoint. Parity expectation identical to the Swift test.
    let hits = coord
        .estates_overlapping(LatticeRegion::new(4, 8))
        .expect("overlap query");
    // The contract is set-based (the sort in estates_overlapping is a test
    // convenience); compare as a set so the result is robust to the
    // estate UUIDs the in-memory store mints.
    let hit_set: std::collections::HashSet<EstateHandle> = hits.into_iter().collect();
    assert_eq!(hit_set, std::collections::HashSet::from([h_low, h_mid]));
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
        .expect_err("expected InvalidLatticeRegion");
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
    assert_eq!(handles, std::collections::HashSet::from([h_low, h_mid]));
}
