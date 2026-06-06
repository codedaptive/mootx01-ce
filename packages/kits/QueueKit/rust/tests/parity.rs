// Parity tests for PAR-4-QK / PAR-6-QK:
//   - ToolName + allowlist validation
//   - QueueKitSchema shape (kitID, version, table name, column set)
//   - PersistenceKitBackend round-trip (send/drain/complete/in_flight/completed)
//   - QueueError::UnknownTool and QueueError::StaleTmpFile variants
//
// Requires --features persistencekit.

use std::sync::Arc;
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
