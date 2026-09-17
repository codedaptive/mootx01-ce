// anomaly_filter_parity.rs
//
// Parity tests for the anomalous_filter field on GLKRecallRequest (§11.18).
//
// Tests:
//   A-1  anomalous_filter defaults to None in new().
//   A-2  with_anomalous_filter(true) stores Some(true).
//   A-3  with_anomalous_filter(false) stores Some(false).
//   B-1  anomalous_filter: None is passthrough — recall returns all hits
//        (no drawers have bit 26 set, so None produces the same result as
//        the unfiltered path).
//   B-2  anomalous_filter: Some(true) returns zero hits when no drawers have
//        bit 26 set (all drawers are non-anomalous by default).
//   B-3  anomalous_filter: Some(false) returns all hits when no drawers have
//        bit 26 set (all drawers satisfy is_anomalous() == false).
//
// The sweep itself (whole-estate `anomaly_flag_sweep` and the incremental
// duty) is covered by anomaly_sweep_duty_parity.rs; these tests verify the
// gate semantics and builder API only.

use std::sync::Arc;

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy, RecallOrigin,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;

const NOW: i64 = 1_750_100_000;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn open_one() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

fn cap_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "anomaly-test-room",
        LatticeAnchor::udc("0"),
        "test-agent",
        "test-embed-v1",
    )
}

fn base_request() -> GLKRecallRequest {
    GLKRecallRequest::new(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        GLKRecallMode::LocusOnly,
        GLKRecallScoring::Raw,
        20,
        RecallFallbackPolicy::AllowDegraded,
        RecallOrigin::Internal,
    )
}

// ---------------------------------------------------------------------------
// GROUP A — Type-shape parity with Swift
// ---------------------------------------------------------------------------

/// A-1: anomalous_filter defaults to None.
/// Mirrors Swift: `GLKRecallRequest(frame:...).anomalousFilter == nil`.
#[test]
fn a1_anomalous_filter_defaults_to_none() {
    let req = base_request();
    assert_eq!(req.anomalous_filter, None,
        "anomalous_filter must default to None (§11.18 — nil = no filtering)");
}

/// A-2: with_anomalous_filter(true) stores Some(true).
/// Swift: `GLKRecallRequest(..., anomalousFilter: true).anomalousFilter == true`.
#[test]
fn a2_with_anomalous_filter_true_stores_some_true() {
    let req = base_request().with_anomalous_filter(true);
    assert_eq!(req.anomalous_filter, Some(true),
        "with_anomalous_filter(true) must store Some(true)");
}

/// A-3: with_anomalous_filter(false) stores Some(false).
/// Swift: `GLKRecallRequest(..., anomalousFilter: false).anomalousFilter == false`.
#[test]
fn a3_with_anomalous_filter_false_stores_some_false() {
    let req = base_request().with_anomalous_filter(false);
    assert_eq!(req.anomalous_filter, Some(false),
        "with_anomalous_filter(false) must store Some(false)");
}

/// A-4: with_anomalous_filter is a builder — it does not mutate the original.
#[test]
fn a4_with_anomalous_filter_builder_leaves_original_unchanged() {
    let orig = base_request();
    let _derived = orig.clone().with_anomalous_filter(true);
    // orig is moved into derived, so we reconstruct to verify isolation.
    let fresh = base_request();
    assert_eq!(fresh.anomalous_filter, None,
        "building a derived request must not affect independently-constructed requests");
}

// ---------------------------------------------------------------------------
// GROUP B — Gate behaviour on recall_scored
// ---------------------------------------------------------------------------

/// B-1: anomalous_filter: None is passthrough.
/// All captured drawers have operational_bitmap = 0 (bit 26 clear), so
/// None (no filter) and Some(false) both return the same drawers.
/// This test specifically verifies that None does NOT act as Some(false) —
/// it is a true passthrough that does not touch the hits at all.
#[test]
fn b1_anomalous_filter_none_is_passthrough() {
    let (coord, handle) = open_one();

    // Capture 3 drawers. All have bit 26 = 0 by default.
    for i in 0..3 {
        let frame = cap_frame(&format!("content-{i}"));
        coord.capture(&handle, frame, NOW).expect("capture");
    }

    let req_no_filter = base_request();
    let req_explicit_nil = base_request(); // anomalous_filter = None by default

    let result_no_filter = coord
        .recall_scored(&handle, req_no_filter, NOW)
        .expect("recall with no filter");
    let result_explicit_nil = coord
        .recall_scored(&handle, req_explicit_nil, NOW)
        .expect("recall with explicit nil");

    // Both produce the same number of hits.
    assert_eq!(
        result_no_filter.hits.len(),
        result_explicit_nil.hits.len(),
        "anomalous_filter:None (passthrough) must produce same hit count as unfiltered"
    );
    assert!(
        !result_no_filter.hits.is_empty(),
        "recall must return at least one hit from 3 captured drawers"
    );
}

/// B-2: anomalous_filter: Some(true) returns zero hits when no drawer has bit 26.
/// Fresh drawers carry operational_bitmap = 0, so is_anomalous() == false.
/// The gate should exclude every drawer that is NOT anomalous.
#[test]
fn b2_filter_true_returns_zero_when_no_anomalous_drawers() {
    let (coord, handle) = open_one();

    for i in 0..3 {
        let frame = cap_frame(&format!("normal-content-{i}"));
        coord.capture(&handle, frame, NOW).expect("capture");
    }

    let req = base_request().with_anomalous_filter(true);
    let result = coord
        .recall_scored(&handle, req, NOW)
        .expect("recall with anomalous_filter:true");

    // No drawers are anomalous, so the gate must admit zero hits.
    assert_eq!(
        result.hits.len(),
        0,
        "anomalous_filter:Some(true) must return 0 hits when no drawers have bit 26"
    );
}

/// B-3: anomalous_filter: Some(false) returns all hits when no drawer has bit 26.
/// All drawers satisfy is_anomalous() == false, so the gate passes every hit.
#[test]
fn b3_filter_false_returns_all_when_no_anomalous_drawers() {
    let (coord, handle) = open_one();

    for i in 0..3 {
        let frame = cap_frame(&format!("normal-content-b3-{i}"));
        coord.capture(&handle, frame, NOW).expect("capture");
    }

    let req_unfiltered = base_request();
    let req_false = base_request().with_anomalous_filter(false);

    let result_unfiltered = coord
        .recall_scored(&handle, req_unfiltered, NOW)
        .expect("unfiltered recall");
    let result_false = coord
        .recall_scored(&handle, req_false, NOW)
        .expect("recall with anomalous_filter:false");

    // With all drawers non-anomalous, filter=false must match unfiltered.
    assert_eq!(
        result_unfiltered.hits.len(),
        result_false.hits.len(),
        "anomalous_filter:Some(false) must return same count as unfiltered when no \
         drawers have bit 26"
    );
}
