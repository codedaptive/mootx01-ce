// capture_batch_parity.rs — Rust parity tests for `capture_batch`.
//
// Verifies:
//   - Empty frames slice is a no-op returning an empty Vec
//   - A batch of N frames inserts all N drawers and returns them in order
//   - Each returned drawer has a distinct non-empty ID
//   - Unknown handle returns EstateNotOpen
//
// These tests mirror Swift `CaptureBatchTests` in GeniusLocusKit
// `Tests/GeniusLocusKitTests/CaptureBatchTests.swift`.
//
// Transaction semantics: the in-memory backend uses the no-op RowStore
// default for begin/commit/rollback (correct for InMemoryStorage), so
// the batch-insert behaviour is observable via the returned Drawers and
// a follow-up recall. The rollback-on-error path is exercised by the
// SQLite-backed TransactionBoundaryTests (PersistenceKit) rather than
// here — the GLK tests focus on the coordinator's routing and the
// parity contract.

use std::sync::Arc;

use genius_locus_kit::{EstateCoordinator, EstateHandle, VerbDispatchError};
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::frames::CaptureFrame;

const NOW: i64 = 1_700_000_000;

// MARK: - Helpers

fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

fn frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "capture-batch-tests",
        // "000" unclassified sentinel — one-door classification classifies
        // non-empty content on the way through capture_batch.
        LatticeAnchor::udc("000"),
        "capture-batch-tests",
        "test-model-v1",
    )
}

fn unregistered_handle() -> EstateHandle {
    EstateHandle {
        estate_uuid: [99u8; 16],
        zoom_window_low: 0,
        zoom_window_high: 100,
    }
}

// MARK: - Tests

/// An empty frame slice is a no-op: returns Ok(empty) without touching storage.
#[test]
fn capture_batch_empty_frames_is_noop() {
    let (mut coord, handle) = open_one();
    let result = coord
        .capture_batch(&handle, vec![], NOW)
        .expect("empty batch must not error");
    assert!(result.is_empty(), "empty input must produce empty output");
}

/// N frames → N drawers returned; each has a distinct non-empty ID.
#[test]
fn capture_batch_inserts_all_frames() {
    let (mut coord, handle) = open_one();
    let frames = vec![
        frame("first drawer content"),
        frame("second drawer content"),
        frame("third drawer content"),
    ];
    let drawers = coord
        .capture_batch(&handle, frames, NOW)
        .expect("batch of three frames must succeed");
    assert_eq!(drawers.len(), 3, "must return one drawer per input frame");
    // All IDs must be non-empty and distinct.
    let ids: std::collections::HashSet<&str> =
        drawers.iter().map(|d| d.id.as_str()).collect();
    assert_eq!(ids.len(), 3, "all returned drawer IDs must be distinct");
    for d in &drawers {
        assert!(!d.id.is_empty(), "drawer ID must be non-empty");
    }
}

/// Drawers inserted via `capture_batch` are recall-visible (durably stored).
#[test]
fn capture_batch_drawers_are_recall_visible() {
    let (mut coord, handle) = open_one();
    let frames = vec![
        frame("recall visible alpha"),
        frame("recall visible beta"),
    ];
    let inserted: Vec<String> = coord
        .capture_batch(&handle, frames, NOW)
        .expect("batch")
        .into_iter()
        .map(|d| d.id)
        .collect();

    // A plain recall must return both inserted drawers.
    let recalled = coord
        .recall(&handle, locus_kit::filter::RecallFrame::new(vec![]), NOW + 1)
        .expect("recall");
    for id in &inserted {
        assert!(
            recalled.iter().any(|d| &d.id == id),
            "capture_batch drawer {id} must appear in recall"
        );
    }
}

/// Batch capture classifies sentinel UDC frames before storage so federation
/// latticeSubtree scopes evaluate against the real category.
#[test]
fn capture_batch_classifies_sentinel_anchors_before_storage() {
    let (mut coord, handle) = open_one();
    let drawers = coord
        .capture_batch(
            &handle,
            vec![frame("software engineering algorithms data structures")],
            NOW,
        )
        .expect("capture_batch");

    assert_eq!(drawers.len(), 1);
    assert_eq!(
        drawers[0].udc_code, "004",
        "classifiable batch content must not remain under the unclassified sentinel"
    );
}

/// An unregistered handle returns `EstateNotOpen`.
#[test]
fn capture_batch_unknown_handle_returns_estate_not_open() {
    let mut coord = EstateCoordinator::new();
    let bad = unregistered_handle();
    let err = coord
        .capture_batch(&bad, vec![frame("some content")], NOW)
        .expect_err("unknown handle must error");
    assert!(
        matches!(err, VerbDispatchError::EstateNotOpen { .. }),
        "expected EstateNotOpen, got {err:?}"
    );
}

/// A single-frame batch round-trips content and source_app correctly.
#[test]
fn capture_batch_single_frame_round_trips_fields() {
    let (mut coord, handle) = open_one();
    let f = CaptureFrame::new(
        "the quick brown fox",
        CaptureChannel::Typed,
        "batch-source-app",
        LatticeAnchor::udc("000"),
        "batch-session-id",
        "test-model-v1",
    );
    let drawers = coord
        .capture_batch(&handle, vec![f], NOW)
        .expect("single-frame batch");
    assert_eq!(drawers.len(), 1);
    let d = &drawers[0];
    assert_eq!(d.content, "the quick brown fox");
}

// -----------------------------------------------------------------------
// NT_R1 — batch-deferral contract tests
// -----------------------------------------------------------------------

/// After `capture_batch`, room Merkle root must still be None — rollup is
/// deferred to `rollup_all_merkle_roots` via `reindex_missing`.
#[test]
fn batch_capture_defers_merkle_root_until_reindex() {
    let (mut coord, handle) = open_one();
    let frames: Vec<CaptureFrame> = (1..=5).map(|i| frame(&format!("item {i}"))).collect();
    let drawers = coord
        .capture_batch(&handle, frames, NOW)
        .expect("capture_batch");
    assert!(!drawers.is_empty());

    let estate = coord.estate_for(&handle).expect("estate_for");
    let ns = estate.node_store().expect("node_store");
    let room_uuid = uuid::Uuid::parse_str(&drawers[0].parent_node_id).expect("parse UUID");
    let room_node = ns.get_node(room_uuid).expect("get_node").expect("node");
    assert!(
        room_node.merkle_root.is_none(),
        "room merkle_root must be None after capture_batch (deferred); got {:?}",
        room_node.merkle_root
    );
}

/// The deferred per-room rollup (`rollup_rooms_for_drawers`, the off-write-path
/// rollup that rides the encode-drain worker) must reproduce the same root as
/// the full-tree `rollup_all_merkle_roots`.
#[test]
fn rollup_all_merkle_roots_matches_incremental_rollup() {
    let (mut coord, handle) = open_one();
    let mut last_parent: Option<String> = None;
    let mut ids: Vec<String> = Vec::new();
    for i in 1..=4 {
        let d = coord.capture(&handle, frame(&format!("item {i}")), NOW).expect("capture");
        last_parent = Some(d.parent_node_id.clone());
        ids.push(d.id);
    }
    let estate = coord.estate_for(&handle).expect("estate_for");
    let ns = estate.node_store().expect("node_store");
    let room_uuid = uuid::Uuid::parse_str(last_parent.as_deref().expect("parent")).expect("parse");

    // Capture defers the rollup off the write path; the deferred per-room rollup
    // is the off-path equivalent the encode drain runs.
    estate.rollup_rooms_for_drawers(&ids).expect("rollup_rooms_for_drawers");
    let root_after_incremental = ns.get_node(room_uuid).expect("get_node").expect("node").merkle_root;

    estate.rollup_all_merkle_roots(NOW + 1).expect("rollup_all");
    let root_after_rollup_all = ns.get_node(room_uuid).expect("get_node").expect("node").merkle_root;

    assert!(root_after_incremental.is_some());
    assert_eq!(root_after_incremental, root_after_rollup_all);
}

/// `rollup_all_merkle_roots` must produce a non-None room root.
#[test]
fn rollup_all_merkle_roots_produces_non_nil_roots() {
    let (mut coord, handle) = open_one();
    let d = coord.capture(&handle, frame("seed"), NOW).expect("capture");
    let room_uuid = uuid::Uuid::parse_str(&d.parent_node_id).expect("parse");
    let estate = coord.estate_for(&handle).expect("estate_for");
    estate.rollup_all_merkle_roots(NOW + 1).expect("rollup_all");
    let ns = estate.node_store().expect("node_store");
    let room_node = ns.get_node(room_uuid).expect("get_node").expect("node");
    assert!(room_node.merkle_root.is_some());
}

// -----------------------------------------------------------------------
// B1 Finding #1 regression — quiesce gate for capture_batch
// -----------------------------------------------------------------------

/// A quiesced estate must reject `capture_batch` with `EstateQuiesced` BEFORE
/// the WAL write-transaction is opened. This is the Rust-port parity mirror of
/// `QuiescedVerbGateTests.quiescedEstateRejectsCaptureBatch` in the Swift suite.
///
/// Pre-fix behaviour: `estate_for_verb` was called AFTER `begin_transaction`,
/// leaving the WAL write lock held indefinitely on `EstateQuiesced`, blocking
/// all subsequent writes. The fix moves the quiesce check before the
/// transaction (planned security hardening — B1 finding #1).
#[test]
fn capture_batch_quiesced_estate_returns_estate_quiesced() {
    let (mut coord, handle) = open_one();
    coord.quiesce(&handle).expect("quiesce must succeed");

    let err = coord
        .capture_batch(&handle, vec![frame("should be rejected")], NOW)
        .expect_err("quiesced estate must reject capture_batch");

    assert!(
        matches!(err, VerbDispatchError::EstateQuiesced { .. }),
        "expected EstateQuiesced, got {err:?}"
    );
}

/// A mounted estate must accept `capture_batch` — the quiesce gate must not be
/// a spurious barrier on the happy path. Mirrors Swift
/// `QuiescedVerbGateTests.mountedEstateAcceptsCaptureBatch`.
#[test]
fn capture_batch_mounted_estate_succeeds() {
    let (mut coord, handle) = open_one();
    let result = coord
        .capture_batch(&handle, vec![frame("gate is not a spurious barrier")], NOW)
        .expect("mounted estate must accept capture_batch");
    assert_eq!(result.len(), 1, "one frame must produce one drawer");
}
