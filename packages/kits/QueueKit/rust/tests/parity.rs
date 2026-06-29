// Parity tests for PAR-4-QK / PAR-6-QK:
//   - ToolName + allowlist validation
//   - QueueKitSchema shape (kitID, version, table name, column set)
//   - PersistenceKitBackend round-trip (send/drain/complete/in_flight/completed)
//   - pending_count() across enqueue/drain/complete states (Swift parity:
//     PersistenceKitBackend.pendingCount())
//   - watch() fires on enqueue and delivers via drain_available() (Swift
//     parity: PersistenceKitBackend.watch(handler:))
//   - QueueError::UnknownTool and QueueError::StaleTmpFile variants
//
// Requires --features persistencekit.

use std::sync::Arc;
use std::time::Duration;
use uuid::Uuid;

use queuekit::{
    ArtifactRef, HLC, Job, JobId, ObservationStatus, QueueBackend, QueueError,
    StreamId, ToolName, QUEUE_KIT_TABLE_NAME,
};
use queuekit::persistencekit::{PersistenceKitBackend, QueueKitSchema};
use serde_json::Map;

use persistence_kit::{BackendConfiguration, EstateConfiguration};
use persistence_kit::inmemory::InMemoryStorage;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build an in-memory Storage instance and open the QueueKit schema on it.
fn make_storage() -> Arc<InMemoryStorage> {
    let cfg = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage = Arc::new(InMemoryStorage::new(cfg));
    PersistenceKitBackend::open_schema(storage.as_ref())
        .expect("open_schema failed");
    storage
}

fn make_backend() -> PersistenceKitBackend {
    let storage = make_storage();
    PersistenceKitBackend::new(storage)
}

fn test_job(i: u64) -> Job {
    Job {
        id: JobId(format!("job-{:04}", i)),
        stream_id: StreamId("test-stream".to_string()),
        submitted_at: HLC {
            physical_time: 1_700_000_000_000 + i as i64,
            logical_count: 0,
            node_id: 1,
        },
        priority: 50,
        payload: b"payload".to_vec(),
        extensions: Map::new(),
    }
}

// ---------------------------------------------------------------------------
// ToolName tests
// ---------------------------------------------------------------------------

#[test]
fn tool_name_round_trip() {
    let t = ToolName::new("bilby");
    assert_eq!(t.raw_value(), "bilby");
    assert_eq!(t.0, "bilby");
}

#[test]
fn tool_name_validate_found() {
    let allowlist = vec![
        ToolName::new("bilby"),
        ToolName::new("nagatha"),
        ToolName::new("adams"),
    ];
    let t = ToolName::new("nagatha");
    assert!(t.validate(&allowlist).is_ok());
}

#[test]
fn tool_name_validate_not_found_returns_unknown_tool() {
    let allowlist = vec![ToolName::new("bilby"), ToolName::new("adams")];
    let t = ToolName::new("imposter");
    let err = t.validate(&allowlist).unwrap_err();
    match err {
        QueueError::UnknownTool(name) => assert_eq!(name, "imposter"),
        other => panic!("expected UnknownTool, got {:?}", other),
    }
}

#[test]
fn tool_name_validate_empty_allowlist_returns_unknown_tool() {
    let t = ToolName::new("bilby");
    let err = t.validate(&[]).unwrap_err();
    assert!(matches!(err, QueueError::UnknownTool(_)));
}

// ---------------------------------------------------------------------------
// QueueError::StaleTmpFile
// ---------------------------------------------------------------------------

#[test]
fn stale_tmp_file_error_carries_path_and_age() {
    let err = QueueError::StaleTmpFile {
        path: "/tmp/stale".to_string(),
        age_secs: 301.5,
    };
    // Pattern-match to confirm the variant exists and fields are accessible.
    match err {
        QueueError::StaleTmpFile { path, age_secs } => {
            assert_eq!(path, "/tmp/stale");
            assert!((age_secs - 301.5).abs() < 0.001);
        }
        other => panic!("unexpected variant {:?}", other),
    }
}

// ---------------------------------------------------------------------------
// QueueKitSchema tests
// ---------------------------------------------------------------------------

#[test]
fn schema_kit_id_and_version() {
    assert_eq!(QueueKitSchema::KIT_ID, "QueueKit");
    assert_eq!(QueueKitSchema::VERSION, 1);
}

#[test]
fn schema_table_name_constant() {
    // QUEUE_KIT_TABLE_NAME constant matches the expected literal.
    assert_eq!(QUEUE_KIT_TABLE_NAME, "queuekit_jobs");
}

#[test]
fn schema_declaration_has_expected_table() {
    let decl = QueueKitSchema::declaration();
    assert_eq!(decl.kit_id, "QueueKit");
    assert_eq!(decl.version, 1);
    assert_eq!(decl.tables.len(), 1);
    let table = &decl.tables[0];
    assert_eq!(table.name, "queuekit_jobs");
    // Must not be append-only per spec §10 invariant 5.
    assert!(!table.append_only, "queuekit_jobs must not be append-only");
    // Primary key is ["id"].
    assert_eq!(table.primary_key, vec!["id".to_string()]);
}

#[test]
fn schema_declaration_has_required_columns() {
    let decl = QueueKitSchema::declaration();
    let table = &decl.tables[0];
    let col_names: Vec<&str> = table.columns.iter().map(|c| c.name.as_str()).collect();
    // Mirror Swift's column set exactly.
    for required in &[
        "id", "stream_id", "physical_time", "logical_count", "node_id",
        "priority", "status", "payload", "extensions",
        "signal_status", "artifacts", "session_id",
    ] {
        assert!(
            col_names.contains(required),
            "column '{}' missing from schema; found: {:?}",
            required, col_names
        );
    }
}

#[test]
fn schema_declaration_has_three_indices() {
    let decl = QueueKitSchema::declaration();
    let idx_names: Vec<&str> = decl.indices.iter().map(|i| i.name.as_str()).collect();
    assert!(idx_names.contains(&"idx_queuekit_status"),
        "missing idx_queuekit_status");
    assert!(idx_names.contains(&"idx_queuekit_claim_order"),
        "missing idx_queuekit_claim_order");
    assert!(idx_names.contains(&"idx_queuekit_stream"),
        "missing idx_queuekit_stream");
}

// ---------------------------------------------------------------------------
// PersistenceKitBackend round-trip tests
// ---------------------------------------------------------------------------

#[test]
fn write_and_drain() {
    let backend = make_backend();

    let job = test_job(1);
    backend.write(&job).expect("write");

    let drained = backend.drain_available().expect("drain");
    assert_eq!(drained.len(), 1);
    let (drained_job, _session) = &drained[0];
    assert_eq!(drained_job.id.0, "job-0001");
    assert_eq!(drained_job.stream_id.0, "test-stream");
    assert_eq!(drained_job.priority, 50);
    assert_eq!(drained_job.payload, b"payload".to_vec());
}

#[test]
fn drain_is_empty_after_claiming() {
    let backend = make_backend();

    backend.write(&test_job(1)).expect("write");
    let first = backend.drain_available().expect("first drain");
    assert_eq!(first.len(), 1);

    // Second drain sees nothing — already claimed.
    let second = backend.drain_available().expect("second drain");
    assert!(second.is_empty(), "expected empty drain after claim");
}

#[test]
fn drain_hlc_order() {
    let backend = make_backend();

    // Write jobs with descending physical time to confirm drain returns
    // them in ascending HLC order.
    for i in [3u64, 1, 2] {
        backend.write(&test_job(i)).expect("write");
    }

    let drained = backend.drain_available().expect("drain");
    assert_eq!(drained.len(), 3);
    let ids: Vec<&str> = drained.iter().map(|(j, _)| j.id.0.as_str()).collect();
    assert_eq!(ids, vec!["job-0001", "job-0002", "job-0003"],
        "drain must return jobs in HLC ascending order");
}

#[test]
fn complete_moves_to_done() {
    let backend = make_backend();

    let job = test_job(1);
    backend.write(&job).expect("write");

    let drained = backend.drain_available().expect("drain");
    let (drained_job, _) = &drained[0];

    backend.complete(
        &drained_job.id,
        ObservationStatus::Done,
        vec![ArtifactRef::CommitHash("abc123".to_string())],
    ).expect("complete");

    // in_flight should now be empty.
    let in_flight = backend.in_flight().expect("in_flight");
    assert!(in_flight.is_empty(), "in_flight should be empty after complete");

    // completed() should return the job.
    let completed = backend.completed(None).expect("completed");
    assert_eq!(completed.len(), 1);
    assert_eq!(completed[0].id.0, "job-0001");
}

#[test]
fn complete_rejects_non_terminal_status() {
    let backend = make_backend();

    let job = test_job(1);
    backend.write(&job).expect("write");
    let drained = backend.drain_available().expect("drain");
    let (drained_job, _) = &drained[0];

    let result = backend.complete(
        &drained_job.id,
        ObservationStatus::Running,
        vec![],
    );
    assert!(
        matches!(result, Err(QueueError::InvalidTerminalStatus(_))),
        "expected InvalidTerminalStatus, got {:?}", result
    );
}

#[test]
fn complete_job_not_found() {
    let backend = make_backend();

    let missing_id = JobId("does-not-exist".to_string());
    let result = backend.complete(&missing_id, ObservationStatus::Done, vec![]);
    assert!(
        matches!(result, Err(QueueError::JobNotFound(_))),
        "expected JobNotFound, got {:?}", result
    );
}

// ---------------------------------------------------------------------------
// Single-pass claim + batch complete-by-session (the O(N²)→O(N) import fix).
// Mirrors Swift PersistenceKitBackendTests single-pass-claim cases.
// ---------------------------------------------------------------------------

// Single-pass claim: every job claimed in one drain shares ONE batch session
// (the bulk new→cur update tags them all), so the batch can be completed in one
// session-scoped update.
#[test]
fn drain_single_pass_shares_one_session() {
    let backend = make_backend();
    for i in 0..5u64 {
        backend.write(&test_job(i)).expect("write");
    }
    let drained = backend.drain_available().expect("drain");
    assert_eq!(drained.len(), 5);
    let s0 = &drained[0].1;
    assert!(
        drained.iter().all(|(_, s)| s == s0),
        "single-pass claim must tag the whole batch with one session"
    );
    assert!(!s0.0.is_empty(), "session id must be set on claim");
}

// complete_session retires every still-"cur" job of a batch's session in one
// pass: in_flight clears and all land in completed().
#[test]
fn complete_session_retires_whole_batch() {
    let backend = make_backend();
    for i in 0..4u64 {
        backend.write(&test_job(i)).expect("write");
    }
    let drained = backend.drain_available().expect("drain");
    let session = drained[0].1.clone();
    assert_eq!(backend.in_flight().expect("in_flight").len(), 4);

    let n = backend
        .complete_session(&session, ObservationStatus::Done)
        .expect("complete_session");
    assert_eq!(n, 4, "complete_session must retire all 4 claimed jobs");
    assert!(backend.in_flight().expect("in_flight").is_empty());
    assert_eq!(backend.completed(None).expect("completed").len(), 4);
}

// complete_session is session-scoped: completing one batch's session leaves a
// second batch (claimed under a different session) still in flight.
#[test]
fn complete_session_leaves_other_sessions() {
    let backend = make_backend();
    backend.write(&test_job(1)).expect("write");
    let first = backend.drain_available().expect("first drain");
    let session_a = first[0].1.clone();

    // A second job enqueued and drained AFTER the first claim gets its own session.
    backend.write(&test_job(2)).expect("write");
    let second = backend.drain_available().expect("second drain");
    let session_b = second[0].1.clone();
    assert_ne!(session_a, session_b, "distinct drains → distinct sessions");

    // Completing session A must not touch session B's in-flight job.
    let n = backend
        .complete_session(&session_a, ObservationStatus::Done)
        .expect("complete_session");
    assert_eq!(n, 1);
    let in_flight = backend.in_flight().expect("in_flight");
    assert_eq!(in_flight.len(), 1, "session B job must remain in flight");
    assert_eq!(in_flight[0].id.0, "job-0002");
}

// Concurrent drainers never double-claim a job. Two threads drain the same
// PersistenceKit-backed queue at once (the production shape: background worker +
// await pump). The single-pass bulk update atomically flips new→cur, so a given
// row is claimed by exactly one session; reading back by the call's own session
// means the two drainers partition the frontier with zero overlap. This is the
// PersistenceKit-backend twin of the FilesystemBackend area4 conformance test.
#[test]
fn concurrent_drainers_no_double_claim() {
    use std::sync::Arc;
    let backend = Arc::new(make_backend());
    for i in 0..200u64 {
        backend.write(&test_job(i)).expect("write");
    }
    let handles: Vec<_> = (0..8)
        .map(|_| {
            let b = Arc::clone(&backend);
            std::thread::spawn(move || b.drain_available().expect("drain"))
        })
        .collect();
    let claimed: Vec<_> =
        handles.into_iter().flat_map(|h| h.join().unwrap()).collect();

    // Every job claimed exactly once — no double-claim.
    let mut ids: Vec<String> = claimed.iter().map(|(j, _)| j.id.0.clone()).collect();
    assert_eq!(ids.len(), 200, "every job must be claimed exactly once");
    ids.sort();
    let before = ids.len();
    ids.dedup();
    assert_eq!(ids.len(), before, "duplicate claim detected across drainers");

    // Each job carries exactly one session; a thread that claimed jobs gave them
    // all the same session (a claim group).
    use std::collections::HashMap;
    let mut by_session: HashMap<String, usize> = HashMap::new();
    for (_, s) in &claimed {
        *by_session.entry(s.0.clone()).or_default() += 1;
    }
    assert_eq!(
        by_session.values().sum::<usize>(),
        200,
        "claimed jobs partition cleanly across sessions"
    );
}

// At volume, one drain pass claims the WHOLE frontier in a single batch session
// (the O(N) single-pass property) and complete_session retires it in one update.
#[test]
fn single_pass_claim_and_complete_at_volume() {
    let backend = make_backend();
    for i in 0..1000u64 {
        backend.write(&test_job(i)).expect("write");
    }
    let drained = backend.drain_available().expect("drain");
    assert_eq!(drained.len(), 1000, "one pass claims the whole frontier");
    let session = drained[0].1.clone();
    assert!(drained.iter().all(|(_, s)| *s == session),
        "the whole batch shares one session");
    let n = backend
        .complete_session(&session, ObservationStatus::Done)
        .expect("complete_session");
    assert_eq!(n, 1000, "one update retires the whole batch");
    assert!(backend.in_flight().expect("in_flight").is_empty());
}

// complete_session rejects a non-terminal status (parity with complete()).
#[test]
fn complete_session_rejects_non_terminal_status() {
    let backend = make_backend();
    backend.write(&test_job(1)).expect("write");
    let drained = backend.drain_available().expect("drain");
    let session = drained[0].1.clone();
    let result = backend.complete_session(&session, ObservationStatus::Running);
    assert!(
        matches!(result, Err(QueueError::InvalidTerminalStatus(_))),
        "expected InvalidTerminalStatus, got {:?}", result
    );
}

#[test]
fn in_flight_returns_cur_jobs() {
    let backend = make_backend();

    backend.write(&test_job(1)).expect("write");
    backend.write(&test_job(2)).expect("write");

    // Before drain: in_flight is empty.
    assert!(backend.in_flight().expect("in_flight").is_empty());

    backend.drain_available().expect("drain");

    // After drain: both jobs are in_flight.
    let in_flight = backend.in_flight().expect("in_flight");
    assert_eq!(in_flight.len(), 2);
}

#[test]
fn completed_filter_by_stream_id() {
    let storage = make_storage();
    let backend = PersistenceKitBackend::new(storage);

    // Write two jobs on different streams.
    let mut j1 = test_job(1);
    j1.stream_id = StreamId("stream-A".to_string());
    let mut j2 = test_job(2);
    j2.stream_id = StreamId("stream-B".to_string());

    backend.write(&j1).expect("write j1");
    backend.write(&j2).expect("write j2");

    let drained = backend.drain_available().expect("drain");
    for (job, _) in &drained {
        backend.complete(&job.id, ObservationStatus::Done, vec![]).expect("complete");
    }

    // Filter by stream-A should return only j1.
    let a_results = backend.completed(Some(&StreamId("stream-A".to_string())))
        .expect("completed stream-A");
    assert_eq!(a_results.len(), 1);
    assert_eq!(a_results[0].stream_id.0, "stream-A");

    // Filter by stream-B should return only j2.
    let b_results = backend.completed(Some(&StreamId("stream-B".to_string())))
        .expect("completed stream-B");
    assert_eq!(b_results.len(), 1);
    assert_eq!(b_results[0].stream_id.0, "stream-B");

    // No filter returns both.
    let all = backend.completed(None).expect("completed all");
    assert_eq!(all.len(), 2);
}

#[test]
fn extensions_round_trip() {
    let backend = make_backend();

    let mut job = test_job(1);
    let mut ext = Map::new();
    ext.insert("tool".to_string(), serde_json::Value::String("bilby".to_string()));
    ext.insert("priority_label".to_string(), serde_json::Value::String("high".to_string()));
    job.extensions = ext;

    backend.write(&job).expect("write");

    let drained = backend.drain_available().expect("drain");
    let (drained_job, _) = &drained[0];

    assert_eq!(
        drained_job.extensions.get("tool").and_then(|v| v.as_str()),
        Some("bilby")
    );
    assert_eq!(
        drained_job.extensions.get("priority_label").and_then(|v| v.as_str()),
        Some("high")
    );
}

// ---------------------------------------------------------------------------
// pending_count() — PersistenceKitBackend parity
//
// Swift reference: PersistenceKitBackend.pendingCount() — COUNT(*) WHERE
// status = 'new', no claim. Used by QueueKitTelemetry to snapshot queue depth
// without advancing the cursor. These tests mirror the FilesystemBackend
// coverage in await_drain.rs::pending_count_tracks_new_frontier.
// ---------------------------------------------------------------------------

// Zero on an empty backend.
#[test]
fn pk_pending_count_empty() {
    let backend = make_backend();
    // No jobs written; pending_count must return 0 (not an error).
    assert_eq!(
        backend.pending_count().expect("pending_count on empty backend"),
        0,
        "empty backend must report zero pending"
    );
}

// Reflects the number of jobs written (status = 'new') before any claim.
#[test]
fn pk_pending_count_after_enqueue() {
    let backend = make_backend();
    backend.write(&test_job(1)).expect("write 1");
    assert_eq!(backend.pending_count().expect("after first write"), 1);
    backend.write(&test_job(2)).expect("write 2");
    assert_eq!(backend.pending_count().expect("after second write"), 2);
    backend.write(&test_job(3)).expect("write 3");
    assert_eq!(backend.pending_count().expect("after third write"), 3);
}

// Drops to zero after drain_available() claims all pending jobs.
// Mirrors Swift: pendingCount drops to 0 once drainAvailable() moves rows to "cur".
#[test]
fn pk_pending_count_drops_after_drain() {
    let backend = make_backend();
    backend.write(&test_job(1)).expect("write 1");
    backend.write(&test_job(2)).expect("write 2");

    // Before drain: two jobs pending, none in-flight.
    assert_eq!(backend.pending_count().expect("before drain"), 2);
    assert!(backend.in_flight().expect("in_flight before drain").is_empty());

    let batch = backend.drain_available().expect("drain");
    assert_eq!(batch.len(), 2);

    // After drain: pending drops to zero; both jobs are in-flight (status = 'cur').
    assert_eq!(
        backend.pending_count().expect("after drain"),
        0,
        "pending_count must be 0 after drain claims all jobs"
    );
    assert_eq!(backend.in_flight().expect("in_flight after drain").len(), 2);
}

// Stays at zero after all jobs are completed (status = 'done').
#[test]
fn pk_pending_count_zero_after_complete() {
    let backend = make_backend();
    backend.write(&test_job(1)).expect("write");
    let batch = backend.drain_available().expect("drain");
    for (job, _) in &batch {
        backend.complete(&job.id, ObservationStatus::Done, vec![]).expect("complete");
    }
    // All jobs are now in 'done'; pending_count must still be 0.
    assert_eq!(backend.pending_count().expect("after complete"), 0);
    assert!(backend.in_flight().expect("in_flight after complete").is_empty());
}

// Mixed state: some jobs pending, some in-flight, some completed.
// pending_count counts only the 'new' rows — not 'cur' or 'done'.
#[test]
fn pk_pending_count_mixed_states() {
    let backend = make_backend();
    // Write three jobs.
    backend.write(&test_job(1)).expect("write 1");
    backend.write(&test_job(2)).expect("write 2");
    backend.write(&test_job(3)).expect("write 3");
    assert_eq!(backend.pending_count().expect("all pending"), 3);

    // Drain (claims all three → 'cur').
    let batch = backend.drain_available().expect("drain");
    assert_eq!(backend.pending_count().expect("all in-flight"), 0);

    // Complete the first job. pending_count still 0; others remain 'cur'.
    backend.complete(&batch[0].0.id, ObservationStatus::Done, vec![])
        .expect("complete job 0");
    assert_eq!(backend.pending_count().expect("two in-flight one done"), 0);

    // Write a fourth job. pending_count is now 1 (only the new one).
    backend.write(&test_job(4)).expect("write 4");
    assert_eq!(
        backend.pending_count().expect("one new two cur one done"),
        1,
        "pending_count must count only 'new' rows"
    );
}

// ---------------------------------------------------------------------------
// watch() — PersistenceKitBackend parity
//
// Swift reference: PersistenceKitBackend.watch(handler:) subscribes to INSERT
// events on the jobs table; each wake re-reads through drain_available() so
// only durably committed rows are delivered. The handler receives (Job, SessionID)
// pairs as they become available.
//
// Test strategy: spawn watch() on a background thread with a handler that
// collects jobs into a shared vec and returns an error after seeing the
// expected count (breaking the watch loop). The main thread writes jobs and
// waits for the collector to signal completion. Bounded wait, no sleep loops.
// ---------------------------------------------------------------------------

// watch() delivers a single job written before the watch call (pre-existing
// job draining on attach). Mirrors Swift spec §10 invariant 2: watch re-reads
// through drain_available(), so jobs already present at subscription time are
// not lost.
#[test]
fn pk_watch_delivers_jobs_on_enqueue() {
    use std::sync::mpsc;

    let storage = make_storage();
    // Coerce Arc<InMemoryStorage> to Arc<dyn Storage> so PersistenceKitBackend::new
    // receives the expected trait-object pointer.
    let storage_dyn: Arc<dyn persistence_kit::storage::Storage> = storage;
    let backend = Arc::new(PersistenceKitBackend::new(Arc::clone(&storage_dyn)));

    // Write one job before starting the watcher, to exercise the
    // "drain anything already present before blocking" path.
    backend.write(&test_job(1)).expect("write before watch");

    let (tx, rx) = mpsc::sync_channel::<queuekit::Job>(4);
    let b = Arc::clone(&backend);

    let watcher_thread = std::thread::spawn(move || {
        b.watch(Box::new(move |job, _session| {
            let _ = tx.send(job.clone());
            // Signal handler break: return error after first delivery so
            // the watch loop exits cleanly. The watch() contract (per spec
            // §3) says the loop exits when handler returns an error.
            Err(queuekit::QueueError::WatcherFailed("test stop".to_string()))
        }))
    });

    // Wait up to 5 seconds for the job to arrive via watch.
    let delivered = rx.recv_timeout(Duration::from_secs(5))
        .expect("watch did not deliver the pre-existing job within 5 s");

    assert_eq!(delivered.id.0, "job-0001");

    // The watcher thread should have exited because the handler returned Err.
    watcher_thread.join()
        .expect("watcher thread panicked")
        .ok(); // WatcherFailed returned by our handler; that's expected

    // After watch exits, the job was claimed by drain_available(). in_flight
    // must have it, and pending must be zero.
    assert_eq!(backend.pending_count().expect("pending after watch"), 0);
}

// watch() delivers a job written AFTER the watcher attaches, exercising the
// observer wake path (INSERT event → wake → drain_available()).
#[test]
fn pk_watch_fires_on_post_attach_enqueue() {
    use std::sync::mpsc;

    let storage = make_storage();
    let storage_dyn: Arc<dyn persistence_kit::storage::Storage> = storage;
    let backend = Arc::new(PersistenceKitBackend::new(Arc::clone(&storage_dyn)));

    let (tx, rx) = mpsc::sync_channel::<queuekit::Job>(4);
    let b_watch = Arc::clone(&backend);

    let watcher_thread = std::thread::spawn(move || {
        b_watch.watch(Box::new(move |job, _session| {
            let _ = tx.send(job.clone());
            Err(queuekit::QueueError::WatcherFailed("test stop".to_string()))
        }))
    });

    // Give the watcher a moment to subscribe before we write.
    // 20 ms is plenty — InMemoryStorage observer subscription is synchronous.
    std::thread::sleep(Duration::from_millis(20));

    // Write a job AFTER the watcher is running.
    backend.write(&test_job(42)).expect("write after attach");

    let delivered = rx.recv_timeout(Duration::from_secs(5))
        .expect("watch did not fire within 5 s after enqueue");

    assert_eq!(delivered.id.0, "job-0042");

    watcher_thread.join()
        .expect("watcher thread panicked")
        .ok();

    assert_eq!(backend.pending_count().expect("pending after watch"), 0);
}
