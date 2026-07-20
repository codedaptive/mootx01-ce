// dreaming_queue_parity.rs — Rust parity gate for dreaming-queue enqueue-on-recall

//
// Mirrors Swift DreamingQueueTests.swift. Five scenarios:
//   1. External-origin recall_scored surfacing ≥ 2 drawers enqueues exactly one
//      dreaming job on stream="dreaming" (the production MCP path).
//   2. Internal-origin recall_scored surfacing ≥ 2 drawers enqueues NOTHING (B-10a).
//      Also: recall_external surfacing ≥ 2 drawers enqueues NOTHING — it is an
//      internal-origin path; dreaming enqueue lives in recall_scored + External guard
//      (B-10a anti-regression test that would have caught the original T6 bug).
//   3. External-origin recall_scored surfacing < 2 drawers enqueues nothing (guard fires).
//   4. Stream isolation: the dreaming job is NOT claimed by an encode or signals drain.
//   5. Payload round-trip: the enqueued DreamingItem contains the surfaced drawer ids.
//
// Production path: `EstateCoordinator::recall_scored` with
// `request.origin = RecallOrigin::External` — called by `run_memory_search` for
// moot_memory_search, moot_recall_precise, moot_recall_shaped.
//
// All tests use an InMemory estate so no temp-dir cleanup is needed.

use std::sync::Arc;

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::DreamingItem;
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::recall::{GLKRecallMode, GLKRecallRequest, GLKRecallScoring,
    RecallFallbackPolicy};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use queuekit::{PersistenceKitBackend, QueueBackend, QueueKit, StreamId};

/// Deterministic wall-clock reference (epoch-ms). Used for all capture/recall calls
/// so tests are deterministic (CLAUDE.md: never call SystemTime::now() inside engines).
const NOW_MS: i64 = 1_720_000_000_000;

/// A recall frame that matches every live drawer in the estate (Filter::Unconfirmed).
fn recall_all() -> RecallFrame {
    RecallFrame::new(vec![Filter::Unconfirmed])
}

/// Build a CaptureFrame with distinct content for each drawer.
fn cap_frame(idx: usize) -> CaptureFrame {
    CaptureFrame::new(
        &format!("dreaming-test-drawer-{idx}"),
        CaptureChannel::Typed,
        "dreaming-test-room",
        LatticeAnchor::udc("0"),
        "dreaming-queue-tests",
        "test-embed-v1",
    )
}

/// Open a fresh InMemory estate and return (coordinator, handle).
fn open_one() -> (EstateCoordinator, EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW_MS, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("dreaming-test-owner"), 0, 100)
        .expect("open estate");
    (coord, handle)
}

/// Capture `count` distinct drawers and return their ids.
fn capture_drawers(
    coord: &mut EstateCoordinator,
    handle: &EstateHandle,
    count: usize,
) -> Vec<String> {
    (0..count)
        .map(|i| {
            coord
                .capture(handle, cap_frame(i), NOW_MS + i as i64)
                .expect("capture")
                .id
        })
        .collect()
}

/// Build an external-origin GLKRecallRequest for the LocusOnly lane.
/// This is the production MCP path: recall_scored with origin=External.
fn external_recall_request() -> GLKRecallRequest {
    GLKRecallRequest::new(recall_all())
        .with_mode(GLKRecallMode::LocusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(50)
        .with_fallback(RecallFallbackPolicy::FailClosed)
        .external() // B-10a: only ARIA boundary sets External
}

/// Build an internal-origin GLKRecallRequest. Must NEVER enqueue dreaming items.
fn internal_recall_request() -> GLKRecallRequest {
    GLKRecallRequest::new(recall_all())
        .with_mode(GLKRecallMode::LocusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(50)
        .with_fallback(RecallFallbackPolicy::FailClosed)
    // origin defaults to Internal — B-10a
}

/// Build a standalone in-memory QueueKit for stream inspection.
fn inmem_inspection_queue(store_id: uuid::Uuid) -> QueueKit<Box<dyn QueueBackend>> {
    let storage = Arc::new(InMemoryStorage::with_estate(store_id));
    PersistenceKitBackend::open_schema(storage.as_ref())
        .expect("InMemoryStorage open_schema cannot fail");
    let backend = PersistenceKitBackend::new(storage);
    QueueKit::new(Box::new(backend) as Box<dyn QueueBackend>)
}

// ---------------------------------------------------------------------------
// Test 1 — External-origin recall_scored surfacing ≥ 2 drawers enqueues one job
// ---------------------------------------------------------------------------

#[test]
fn t6_r01_external_origin_recall_scored_surfacing_two_or_more_drawers_enqueues_one_dreaming_job() {
    let (mut coord, handle) = open_one();

    // Capture 3 drawers so recall has content to surface.
    let _captured_ids = capture_drawers(&mut coord, &handle, 3);

    // External-origin scored recall — the production MCP path (run_memory_search).
    let result = coord
        .recall_scored(&handle, external_recall_request(), NOW_MS)
        .expect("recall_scored");
    let drawers: Vec<_> = result.hits.iter().filter_map(|h| h.drawer.clone()).collect();
    assert!(
        drawers.len() >= 2,
        "recall must surface ≥ 2 drawers for the dreaming guard to pass (got {})",
        drawers.len()
    );

    // The dreaming queue must have been lazily mounted and contain exactly 1 job.
    // Access via borrow_mut on the coordinator's internal dreaming_queues RefCell.
    // We use a second external recall to confirm count grows monotonically (2 recals → 2 jobs),
    // proving the first recall enqueued exactly 1 job before the second.
    let result2 = coord
        .recall_scored(&handle, external_recall_request(), NOW_MS + 1)
        .expect("second recall_scored");
    let drawers2: Vec<_> = result2.hits.iter().filter_map(|h| h.drawer.clone()).collect();
    assert!(
        drawers2.len() >= 2,
        "second recall must also surface ≥ 2 drawers (got {})",
        drawers2.len()
    );

    // Both recalls succeeded without propagating enqueue errors — the non-fatal
    // side-effect contract is met. The observable: count grew from 1 to 2.
    // We verify count=2 via the test-seam accessor (recall-driven dreaming: test-seam methods
    // follow the same #[cfg(any(test, ...))] pattern as inject_* seams).
    let pending = coord
        .dreaming_queue_pending_count(&handle)
        .expect("dreaming queue must be mounted after external recall");
    assert_eq!(
        pending, 2,
        "two external recalls with ≥ 2 drawers must enqueue two dreaming jobs (got {})",
        pending
    );
}

// ---------------------------------------------------------------------------
// Test 2 — Internal-origin recall_scored and recall_external must NOT enqueue (B-10a)
// ---------------------------------------------------------------------------

#[test]
fn t6_r02_internal_origin_recall_scored_must_not_enqueue() {
    let (mut coord, handle) = open_one();
    let _captured_ids = capture_drawers(&mut coord, &handle, 3);

    // Internal-origin scored recall — dreaming daemon, standing signals, recipes, migration.
    // MUST NOT enqueue (B-10a): these are system reads, not external user actions.
    let result = coord
        .recall_scored(&handle, internal_recall_request(), NOW_MS)
        .expect("recall_scored internal");
    let drawers: Vec<_> = result.hits.iter().filter_map(|h| h.drawer.clone()).collect();
    assert!(
        drawers.len() >= 2,
        "precondition: ≥ 2 drawers must surface to confirm the guard would fire (got {})",
        drawers.len()
    );

    // The dreaming queue must NOT be mounted (guard fired before lazy-mount).
    assert!(
        !coord.dreaming_queue_is_mounted(&handle),
        "internal-origin recall_scored must NEVER mount or enqueue to the dreaming queue (B-10a)"
    );
}

#[test]
fn t6_r02b_recall_external_must_not_enqueue_dreaming_items() {
    // recall_external is the legacy flat-array external path with trace_limit wiring.
    // Dreaming enqueue lives ONLY in recall_scored + External guard.
    // recall_external does NOT enqueue — this is the B-10a anti-regression test
    // that would have caught the original T6 bug (enqueue in the wrong method).
    let (mut coord, handle) = open_one();
    let _captured_ids = capture_drawers(&mut coord, &handle, 3);

    let surfaced = coord
        .recall_external(&handle, recall_all(), NOW_MS)
        .expect("recall_external");
    assert!(
        surfaced.len() >= 2,
        "precondition: ≥ 2 drawers must surface (got {})",
        surfaced.len()
    );

    // The dreaming queue must NOT be mounted — recall_external does not enqueue.
    assert!(
        !coord.dreaming_queue_is_mounted(&handle),
        "recall_external must NEVER enqueue dreaming items — dreaming enqueue is in recall_scored + External guard (B-10a)"
    );
}

// ---------------------------------------------------------------------------
// Test 3 — External-origin recall_scored surfacing < 2 drawers → no job enqueued
// ---------------------------------------------------------------------------

#[test]
fn t6_r03_external_origin_recall_surfacing_fewer_than_two_drawers_enqueues_nothing() {
    let (mut coord, handle) = open_one();

    // Capture exactly 1 drawer — the guard requires ≥ 2 distinct ids.
    let _captured_ids = capture_drawers(&mut coord, &handle, 1);

    let result = coord
        .recall_scored(&handle, external_recall_request(), NOW_MS)
        .expect("recall_scored");
    let drawers: Vec<_> = result.hits.iter().filter_map(|h| h.drawer.clone()).collect();
    assert!(
        drawers.len() <= 1,
        "estate has 1 drawer — recall must surface ≤ 1 (got {})",
        drawers.len()
    );

    // The dreaming queue must NOT be mounted (guard fired before lazy-mount).
    assert!(
        !coord.dreaming_queue_is_mounted(&handle),
        "fewer than 2 drawers surfaced — dreaming queue must not be mounted (guard fires before lazy-mount)"
    );
}

// ---------------------------------------------------------------------------
// Test 4 — Stream isolation: dreaming jobs not claimed by encode drain
// ---------------------------------------------------------------------------

#[test]
fn t6_r04_dreaming_job_not_claimed_by_encode_stream_drain() {
    // Build a standalone InMemory QueueKit to verify stream isolation at the
    // TYPE level: a job submitted with stream_id="dreaming" is NOT claimed by
    // drain_for_stream("encode"). Correct isolation means encode-stream drain
    // returns empty for a queue that only has "dreaming" jobs.

    let store_id = uuid::Uuid::from_u128(0xd3ea_d3ea_d3ea_d3ea_d3ea_d3ea_d3ea_0004);
    let queue = inmem_inspection_queue(store_id);

    // Enqueue a synthetic dreaming job directly to the inspection queue.
    let dreaming_item = DreamingItem {
        recall_event_id: "test-recall-event-id-stream-isolation".to_string(),
        drawer_ids: vec!["drawer-a".to_string(), "drawer-b".to_string()],
    };
    let payload = serde_json::to_vec(&dreaming_item).expect("serialize DreamingItem");
    let hlc = substrate_types::hlc::HLC {
        physical_time: NOW_MS,
        logical_count: 0,
        node_id: 1,
    };
    let job = queuekit::Job {
        id: queuekit::JobId(uuid::Uuid::new_v4().simple().to_string()),
        stream_id: queuekit::StreamId("dreaming".to_string()),
        submitted_at: hlc,
        priority: 50,
        payload,
        extensions: serde_json::Map::new(),
    };
    queue.send(&job).expect("send dreaming job");

    // Drain the "encode" stream — must return empty (no encode jobs were submitted).
    let encode_drained = queue
        .drain_for_stream(&StreamId("encode".to_string()), NOW_MS as f64 / 1000.0)
        .expect("drain encode stream");
    assert!(
        encode_drained.is_empty(),
        "encode-stream drain must not claim dreaming-stream jobs (stream isolation)"
    );

    // The dreaming job must still be pending.
    let dreaming_count = queue
        .pending_count_for_stream(&StreamId("dreaming".to_string()))
        .expect("pending_count_for_stream dreaming");
    assert_eq!(
        dreaming_count, 1,
        "dreaming job must remain pending after encode-stream drain"
    );
}

// ---------------------------------------------------------------------------
// Test 5 — Payload round-trip: drawer ids in the DreamingItem payload
// ---------------------------------------------------------------------------

#[test]
fn t6_r05_dreaming_job_payload_contains_surfaced_drawer_ids() {
    let (mut coord, handle) = open_one();

    // Capture 3 drawers.
    let captured_ids = capture_drawers(&mut coord, &handle, 3);
    let captured_set: std::collections::HashSet<_> = captured_ids.iter().collect();

    // External-origin scored recall — the production enqueue seam.
    let result = coord
        .recall_scored(&handle, external_recall_request(), NOW_MS)
        .expect("recall_scored");
    let surfaced_drawers: Vec<_> = result.hits.iter().filter_map(|h| h.drawer.clone()).collect();
    assert!(
        surfaced_drawers.len() >= 2,
        "precondition: ≥ 2 drawers must surface (got {})",
        surfaced_drawers.len()
    );
    let surfaced_ids: std::collections::HashSet<_> = surfaced_drawers.iter().map(|d| &d.id).collect();

    // Verify exactly one dreaming job was enqueued, then drain to get the payload.
    // Uses test-seam accessors — same pattern as inject_* seams.
    let pending = coord
        .dreaming_queue_pending_count(&handle)
        .expect("dreaming queue must be mounted after external recall");
    assert_eq!(pending, 1, "exactly one dreaming job must be enqueued");

    // Drain to get the job payload.
    let jobs = coord
        .dreaming_queue_drain(&handle, NOW_MS as f64 / 1000.0)
        .expect("dreaming queue must be mounted to drain");
    // drain_for_stream returns Vec<(Job, SessionId)>; the first element is the job.
    let (job, _session_id) = jobs.into_iter().next().expect("one drained job");
    let item: DreamingItem = serde_json::from_slice(&job.payload)
        .expect("deserialize DreamingItem");

    assert!(!item.recall_event_id.is_empty(),
        "recall_event_id must be non-empty (32-hex UUID per JobId convention)");
    assert!(item.drawer_ids.len() >= 2,
        "drawer_ids must have ≥ 2 entries per spec §12.2 guard");

    // Every id in the payload must be from the captured drawers.
    let payload_set: std::collections::HashSet<_> = item.drawer_ids.iter().collect();
    assert!(
        !payload_set.is_disjoint(&captured_set),
        "all payload drawer ids must be ids of captured drawers"
    );

    // All surfaced drawer ids must appear in the payload.
    assert_eq!(
        payload_set, surfaced_ids,
        "payload drawer ids must exactly match the surfaced drawer id set"
    );

    // JSON key names must be snake_case (cross-port payload legibility with Swift).
    let json_str = serde_json::to_string(&item).expect("to_string");
    assert!(json_str.contains("\"recall_event_id\""),
        "JSON must use snake_case key 'recall_event_id' to match Swift CodingKeys");
    assert!(json_str.contains("\"drawer_ids\""),
        "JSON must use snake_case key 'drawer_ids' to match Swift CodingKeys");
}
