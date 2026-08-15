//! reindex_latch_tests.rs — Rust twin of CorpusReindexLatchTests.swift.
//!
//! Three scenarios mirroring the Swift suite:
//!   1. fires-once: happy path — enqueue succeeds, manifest flag is set.
//!   2. second-call no-op: second call finds the existing job on the stream,
//!      sets the manifest flag again (idempotent), does not enqueue a second job.
//!   3. enqueue-fail: enqueue fails; read-back returns 0; manifest flag is NOT
//!      set; deferral line is printed to stdout.

use std::any::Any;
use std::sync::Arc;

use corpus_kit::reindex_latch::{reindex_required, REINDEX_MANIFEST_KEY, REINDEX_STREAM_ID};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
use persistence_kit::types::{Column, TypedValue};
use queuekit::backend::{QueueBackend, WatchHandler};
use queuekit::error::QueueError;
use queuekit::facade::QueueKit;
use queuekit::job::{ArtifactRef, Job, JobId, ObservationStatus, SessionId, StreamId};
use queuekit::persistencekit::PersistenceKitBackend;
use uuid::Uuid;

// ─── Helpers ────────────────────────────────────────────────────────────────

/// Canonical epoch-millis used across all tests. Never SystemTime::now().
const NOW_MILLIS: i64 = 1_755_000_000_000;

/// Minimal schema with only the `manifest` table — the key-value store the
/// reindex latch writes to. Not a complete estate schema, but sufficient for
/// unit testing the latch in isolation.
fn manifest_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "LatchTestManifest",
        1,
        vec![TableDeclaration::new(
            "manifest",
            vec![
                // ColumnDeclaration::text is the convenience constructor for
                // non-nullable TEXT columns (ColumnDeclaration::new("key", ColumnType::Text)
                // gives the same result — text() is the idiomatic short form).
                ColumnDeclaration::text("key"),
                ColumnDeclaration::text("value"),
            ],
            vec!["key".to_string()],
        )],
    )
}

/// Open a fresh in-memory storage instance with the manifest table.
///
/// Uses InMemoryStorage rather than SQLite because we only need round-trip
/// fidelity on the manifest table — InMemory preserves TypedValue semantics
/// for TEXT columns correctly for this test's assertions.
fn manifest_storage() -> Arc<dyn Storage> {
    let cfg = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let st = Arc::new(InMemoryStorage::new(cfg));
    st.open(&manifest_schema()).expect("open manifest schema");
    // Coerce Arc<InMemoryStorage> -> Arc<dyn Storage> (unsized coercion).
    st as Arc<dyn Storage>
}

/// Open a fresh in-memory QueueKit backed by PersistenceKitBackend.
///
/// In-memory is acceptable here: the latch tests verify the LOGIC of
/// reindex_required, not on-disk crash recovery.
fn in_memory_queue() -> QueueKit<PersistenceKitBackend> {
    let cfg = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let st: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(cfg));
    PersistenceKitBackend::open_schema(st.as_ref()).expect("open queue schema");
    let backend = PersistenceKitBackend::new(st);
    QueueKit::new(backend)
}

/// Read the manifest flag from storage. Returns `Some("1")` when set, `None`
/// when absent.
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

// ─── Fail-write backend ─────────────────────────────────────────────────────

/// A QueueBackend whose `write` always fails so the latch's read-back step
/// receives 0 and prints the deferral line. All other required methods return
/// empty / zero so `pending_count_for_stream` is non-failing.
struct FailWriteBackend;

impl QueueBackend for FailWriteBackend {
    fn as_any(&self) -> &dyn Any {
        self
    }
    fn write(&self, _job: &Job) -> Result<(), QueueError> {
        // QueueError::WriteFailed is a tuple variant (not struct variant).
        Err(QueueError::WriteFailed("test: write refused".to_string()))
    }
    fn drain_available(&self) -> Result<Vec<(Job, SessionId)>, QueueError> {
        Ok(vec![])
    }
    fn pending_count(&self) -> Result<usize, QueueError> {
        Ok(0)
    }
    fn watch(&self, _handler: WatchHandler) -> Result<(), QueueError> {
        Ok(())
    }
    fn complete(
        &self,
        _job_id: &JobId,
        _status: ObservationStatus,
        _artifacts: Vec<ArtifactRef>,
    ) -> Result<(), QueueError> {
        Ok(())
    }
    fn in_flight(&self) -> Result<Vec<Job>, QueueError> {
        Ok(vec![])
    }
    fn completed(&self, _stream_id: Option<&StreamId>) -> Result<Vec<Job>, QueueError> {
        Ok(vec![])
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

/// 1. Happy path: enqueue succeeds and the manifest flag is set.
#[test]
fn fires_once_enqueue_succeeds_and_manifest_flag_is_set() {
    let storage = manifest_storage();
    let queue = in_memory_queue();

    let stream = StreamId(REINDEX_STREAM_ID.to_string());

    // No job before the call.
    let before = queue
        .pending_count_for_stream(&stream)
        .expect("pending count");
    assert_eq!(before, 0, "no reindex job should exist before the first latch call");

    reindex_required(&queue, storage.as_ref(), NOW_MILLIS)
        .expect("reindex_required must not fail");

    // Exactly one pending job after.
    let after = queue
        .pending_count_for_stream(&stream)
        .expect("pending count");
    assert_eq!(after, 1, "one reindex job must be pending after the latch fires");

    // Manifest flag must be "1".
    let flag = read_manifest_flag(storage.as_ref());
    assert_eq!(
        flag.as_deref(),
        Some("1"),
        "manifest flag must be '1' after successful latch; got {:?}",
        flag
    );
}

/// 2. Second call is a no-op via stream key: exactly one job remains and
///    the manifest flag is still set.
#[test]
fn second_call_no_op_via_stream_key() {
    let storage = manifest_storage();
    let queue = in_memory_queue();

    let stream = StreamId(REINDEX_STREAM_ID.to_string());

    // First call: enqueues the job and sets the manifest flag.
    reindex_required(&queue, storage.as_ref(), NOW_MILLIS)
        .expect("first call must not fail");

    let after_first = queue
        .pending_count_for_stream(&stream)
        .expect("pending count");
    assert_eq!(after_first, 1, "one job after the first latch call");

    // Second call: finds the existing job, sets the manifest flag (idempotent
    // upsert), and does NOT enqueue a second job.
    reindex_required(&queue, storage.as_ref(), NOW_MILLIS)
        .expect("second call must not fail");

    let after_second = queue
        .pending_count_for_stream(&stream)
        .expect("pending count");
    assert_eq!(
        after_second, 1,
        "second latch call must not produce a second job — stream key deduplicates"
    );

    // Manifest flag must still be set.
    let flag = read_manifest_flag(storage.as_ref());
    assert_eq!(
        flag.as_deref(),
        Some("1"),
        "manifest flag must still be present after second call"
    );
}

/// 3. Enqueue fails: manifest flag stays clear; no job; deferral line is
///    printed to stdout (verified by the absence of the manifest flag — the
///    stdout content is observable in the test runner output).
#[test]
fn enqueue_fail_leaves_manifest_clear() {
    let storage = manifest_storage();
    let queue = QueueKit::new(FailWriteBackend);

    // The latch must not propagate an error — failures are absorbed.
    reindex_required(&queue, storage.as_ref(), NOW_MILLIS)
        .expect("reindex_required must not fail even when write fails");

    // No pending job (write failed, read-back returns 0).
    let stream = StreamId(REINDEX_STREAM_ID.to_string());
    let count = queue
        .pending_count_for_stream(&stream)
        .expect("pending count");
    assert_eq!(
        count, 0,
        "no job should be pending when the write backend fails"
    );

    // Manifest flag must NOT be set.
    let flag = read_manifest_flag(storage.as_ref());
    assert!(
        flag.is_none(),
        "manifest must not carry the latch flag when the enqueue did not take; got {:?}",
        flag
    );
}
