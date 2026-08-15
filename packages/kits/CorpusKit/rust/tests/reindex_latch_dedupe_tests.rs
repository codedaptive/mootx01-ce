//! reindex_latch_dedupe_tests.rs — Rust twin of
//! CorpusReindexLatchDedupeTests.swift.
//!
//! Discriminating tests for the manifest-flag dedupe fix in
//! `reindex_required`. Finding E (commit bc0e989): `pending_count_for_stream`
//! counts only `status = 'new'` rows. Once the drainer claims the marker job
//! ('new' → 'cur'), the count returns 0 and the old code enqueued a second
//! rebuild job. The fix reads the durable manifest flag before touching the
//! queue — returning early when a rebuild is already owed.
//!
//! Covered windows:
//!   (i)  job is 'cur' (claimed, not yet completed) — pending_count == 0
//!   (ii) job is 'done' (completed, flag not yet cleared) — pending_count == 0
//!
//! Window (iii) — concurrent callers — is outside the documented contract
//! (sequential migration train) and is not tested here.

use std::sync::Arc;

use corpus_kit::reindex_latch::{reindex_required, REINDEX_MANIFEST_KEY, REINDEX_STREAM_ID};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
use persistence_kit::types::{Column, TypedValue};
use queuekit::facade::QueueKit;
use queuekit::job::{ArtifactRef, ObservationStatus, StreamId};
use queuekit::persistencekit::PersistenceKitBackend;
use uuid::Uuid;

// ─── Helpers ────────────────────────────────────────────────────────────────

/// Canonical epoch-millis. Never SystemTime::now().
const NOW_MILLIS: i64 = 1_755_100_000_000;

/// Epoch seconds as f64, for drain_for_stream's now parameter.
fn now_epoch_secs() -> f64 {
    NOW_MILLIS as f64 / 1000.0
}

/// Minimal schema with only the `manifest` table.
fn dedupe_manifest_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "LatchDedupeManifest",
        1,
        vec![TableDeclaration::new(
            "manifest",
            vec![
                ColumnDeclaration::text("key"),
                ColumnDeclaration::text("value"),
            ],
            vec!["key".to_string()],
        )],
    )
}

/// Fresh in-memory storage with the manifest table.
fn dedupe_manifest_storage() -> Arc<dyn Storage> {
    let cfg = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let st = Arc::new(InMemoryStorage::new(cfg));
    st.open(&dedupe_manifest_schema()).expect("open manifest schema");
    st as Arc<dyn Storage>
}

/// Fresh in-memory QueueKit.
fn dedupe_in_memory_queue() -> QueueKit<PersistenceKitBackend> {
    let cfg = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let st: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(cfg));
    PersistenceKitBackend::open_schema(st.as_ref()).expect("open queue schema");
    let backend = PersistenceKitBackend::new(st);
    QueueKit::new(backend)
}

/// Read the manifest flag. Returns `Some("1")` when set, `None` when absent.
fn read_manifest_flag(storage: &dyn Storage) -> Option<String> {
    let key_col = Column::new("manifest", "key");
    let rows = storage
        .row_store()
        .query(
            "manifest",
            Some(&StoragePredicate::Eq(
                key_col,
                TypedValue::Text(REINDEX_MANIFEST_KEY.to_string()),
            )),
            &[],
            None,
            None,
        )
        .expect("query manifest");
    rows.into_iter().next().and_then(|row| {
        row.get("value").and_then(|v| {
            if let TypedValue::Text(s) = v {
                Some(s.clone())
            } else {
                None
            }
        })
    })
}

// ─── Tests ──────────────────────────────────────────────────────────────────

/// Window (i): second call after the marker job is claimed ('cur').
///
/// Without the fix, `pending_count_for_stream` returns 0 for claimed jobs and
/// a second enqueue fires. With the fix, the manifest flag check returns early.
#[test]
fn second_call_after_claim_produces_one_job() {
    let storage = dedupe_manifest_storage();
    let queue = dedupe_in_memory_queue();

    let stream = StreamId(REINDEX_STREAM_ID.to_string());

    // First call: enqueues the marker job and sets the manifest flag.
    reindex_required(&queue, storage.as_ref(), NOW_MILLIS)
        .expect("first call must not fail");

    let after_first = queue
        .pending_count_for_stream(&stream)
        .expect("pending count");
    assert_eq!(after_first, 1, "exactly one pending job after the first latch call");

    // Drain the job — transitions 'new' → 'cur'. pending_count now returns 0.
    let claimed = queue
        .drain_for_stream(&stream, now_epoch_secs())
        .expect("drain must succeed");
    assert_eq!(claimed.len(), 1, "the reindex marker job must be drainable");

    let pending_after_drain = queue
        .pending_count_for_stream(&stream)
        .expect("pending count");
    assert_eq!(
        pending_after_drain, 0,
        "pending_count must be 0 after claim — this is the vulnerability window"
    );

    // Without the fix, this second call sees pending_count == 0 and enqueues
    // a new job. With the fix, it sees the manifest flag and returns early.
    reindex_required(&queue, storage.as_ref(), NOW_MILLIS)
        .expect("second call must not fail");

    // Assert total outstanding work: the one in-flight job, no new pending.
    let pending_after_second = queue
        .pending_count_for_stream(&stream)
        .expect("pending count");
    assert_eq!(
        pending_after_second, 0,
        "second latch call must not enqueue a second job — manifest flag dedupe closes window (i)"
    );

    let in_flight = queue.in_flight().expect("in_flight");
    let reindex_in_flight: Vec<_> = in_flight
        .iter()
        .filter(|j| j.stream_id == stream)
        .collect();
    assert_eq!(
        reindex_in_flight.len(),
        1,
        "exactly one reindex job must exist in total (the original, still in-flight)"
    );

    // Manifest flag must still be set — the second call did not disturb it.
    let flag = read_manifest_flag(storage.as_ref());
    assert_eq!(
        flag.as_deref(),
        Some("1"),
        "manifest flag must still be set after the second (no-op) call"
    );
}

/// Window (ii): second call after the marker job completes ('done').
///
/// Without the fix, `pending_count_for_stream` returns 0 for completed jobs
/// and a second enqueue fires. With the fix, the manifest flag check returns
/// early.
#[test]
fn second_call_after_job_completion_produces_one_job() {
    let storage = dedupe_manifest_storage();
    let queue = dedupe_in_memory_queue();

    let stream = StreamId(REINDEX_STREAM_ID.to_string());

    // First call: enqueues the marker job and sets the manifest flag.
    reindex_required(&queue, storage.as_ref(), NOW_MILLIS)
        .expect("first call must not fail");

    let after_first = queue
        .pending_count_for_stream(&stream)
        .expect("pending count");
    assert_eq!(after_first, 1, "exactly one pending job after the first latch call");

    // Drain the job ('new' → 'cur') then complete it ('cur' → 'done').
    let claimed = queue
        .drain_for_stream(&stream, now_epoch_secs())
        .expect("drain must succeed");
    assert_eq!(claimed.len(), 1, "the reindex marker job must be drainable");

    let job_id = &claimed[0].0.id;
    // Complete the job — simulating the drain worker finishing the rebuild.
    // The manifest flag is NOT cleared here; clearing is outside latch scope.
    queue
        .reply(job_id, ObservationStatus::Done, Vec::<ArtifactRef>::new())
        .expect("reply must succeed");

    // Verify: no pending, no in-flight — only a 'done' row.
    let pending_after_complete = queue
        .pending_count_for_stream(&stream)
        .expect("pending count");
    assert_eq!(
        pending_after_complete, 0,
        "no pending jobs after the marker job completes"
    );

    let in_flight_after_complete = queue.in_flight().expect("in_flight");
    assert!(
        in_flight_after_complete.is_empty(),
        "no in-flight jobs after the marker job completes"
    );

    // Without the fix, this second call sees pending_count == 0 and enqueues
    // a new job. With the fix, it sees the manifest flag and returns early.
    reindex_required(&queue, storage.as_ref(), NOW_MILLIS)
        .expect("second call must not fail");

    // Total jobs: one 'done' row, zero new pending.
    let pending_after_second = queue
        .pending_count_for_stream(&stream)
        .expect("pending count");
    assert_eq!(
        pending_after_second, 0,
        "second latch call must not enqueue a new job — manifest flag dedupe closes window (ii)"
    );

    let completed = queue
        .completed(Some(&stream))
        .expect("completed");
    assert_eq!(
        completed.len(),
        1,
        "exactly one completed reindex job must exist — no duplicate was added"
    );
}
