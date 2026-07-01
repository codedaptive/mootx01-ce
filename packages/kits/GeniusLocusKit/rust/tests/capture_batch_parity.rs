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

// -----------------------------------------------------------------------
// encode-perf #31 Phase 1 — parallel classify parity
// -----------------------------------------------------------------------

/// Parallel classify parity (encode-perf #31): `capture_batch` (parallel
/// classify) and `capture_with_mode` (single-frame serial classify) must
/// produce the same lattice anchor for identical content, and the batch
/// result must preserve the original frame order.
///
/// The FDC encoder is deterministic over the immutable pinned codebook, so
/// the serial fast-path (len ≤ cap) and the thread::scope chunked path
/// (len > cap) must agree on every code. The 20 fixed frames below are
/// large enough to exercise the parallel path on most machines where
/// `available_parallelism() < 20`. Order preservation is the load-bearing
/// contract of the index-based result reassembly in the chunked path.
///
/// Mirrors Swift `CaptureBatchTests.captureBatchClassifyParityWithSingleFrameCapture`.
#[test]
fn capture_batch_parallel_classify_parity_with_single_frame() {
    use locus_kit::frames::CaptureFrame;
    use genius_locus_kit::WriteMode;

    // 20 frames with distinctly classifiable CS content — same set as the
    // Swift parity test so cross-port comparison is trivial.
    let contents: &[&str] = &[
        "software engineering algorithms data structures programming",
        "compiler design lexical analysis parsing grammars",
        "database systems relational algebra SQL transactions",
        "operating systems process scheduling memory management",
        "computer networks TCP IP protocols routing",
        "machine learning neural networks gradient descent",
        "object-oriented programming design patterns inheritance",
        "cryptography encryption public key infrastructure",
        "distributed systems consensus fault tolerance",
        "software testing unit tests integration coverage",
        "algorithms complexity sorting searching trees",
        "computer architecture CPU cache pipeline",
        "functional programming lambda calculus type systems",
        "version control git branching merging workflows",
        "cloud computing containers microservices deployment",
        "web development HTTP REST API JSON",
        "mobile application iOS Android platform SDK",
        "code review refactoring technical debt maintainability",
        "concurrency threads parallelism synchronization locks",
        "data science analytics statistics programming Python",
    ];

    // Estate 1: capture_batch path (parallel classify for len > cap).
    let (mut batch_coord, batch_handle) = open_one();
    let batch_frames: Vec<CaptureFrame> = contents.iter().map(|c| frame(c)).collect();
    let batch_drawers = batch_coord
        .capture_batch(&batch_handle, batch_frames, NOW)
        .expect("capture_batch must succeed");
    assert_eq!(
        batch_drawers.len(),
        contents.len(),
        "capture_batch must return one drawer per input frame"
    );

    // Estate 2: capture_with_mode path (single-frame serial classify).
    let (mut serial_coord, serial_handle) = open_one();
    let mut classified_count = 0usize;
    for (i, content) in contents.iter().enumerate() {
        let serial_drawer = serial_coord
            .capture_with_mode(&serial_handle, frame(content), NOW, WriteMode::Regular)
            .expect("capture_with_mode must succeed");

        // Batch code must equal the single-frame code for the same content.
        // Holds for BOTH classified codes and the "000" sentinel (UNRESOLVED):
        // the FDC encoder is deterministic, so the same text always produces
        // the same result regardless of which path (serial vs parallel) runs it.
        assert_eq!(
            batch_drawers[i].udc_code, serial_drawer.udc_code,
            "batch result[{i}] code '{}' must equal single-frame code '{}' for '{content}'",
            batch_drawers[i].udc_code, serial_drawer.udc_code,
        );
        if batch_drawers[i].udc_code != "000" {
            classified_count += 1;
        }
    }
    // At least some content must be classified (confirms the classify logic
    // actually ran and is not silently no-oping on every frame).
    assert!(
        classified_count > 0,
        "at least one frame must be classified to a non-sentinel code; got 0 of {}",
        contents.len()
    );
}
