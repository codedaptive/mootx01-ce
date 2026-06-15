// await_drain.rs — Rust parity for the await-empty latch added for the
// Dual-Path Intake wiring (P5 / G7). Mirrors AwaitDrainTests.swift:
// `QueueBackend::await_drain(...)` blocks until both maildir frontiers
// (pending `new/` and in-flight `cur/`) are clear, returns promptly on an
// already-empty queue, and times out rather than hanging when work never
// completes. Also covers `pending_count()`, the depth probe await_drain reads.

use std::sync::Arc;
use std::time::{Duration, Instant};

use queuekit::{
    FilesystemBackend, HLC, Job, JobId, ObservationStatus, QueueBackend, QueueError, StreamId,
};
use serde_json::Map;

fn make_backend() -> (FilesystemBackend, std::path::PathBuf) {
    let dir = std::env::temp_dir()
        .join(format!("queuekit-awaitdrain-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let backend = FilesystemBackend::new(&dir, 1).unwrap();
    (backend, dir)
}

fn make_job(tag: &str) -> Job {
    Job {
        id: JobId(uuid::Uuid::new_v4().to_string()),
        stream_id: StreamId("encode".to_string()),
        submitted_at: HLC { physical_time: 1, logical_count: 0, node_id: 1 },
        priority: 50,
        payload: tag.as_bytes().to_vec(),
        extensions: Map::new(),
    }
}

// Returns promptly on an already-empty queue: the first poll sees zero/zero
// and returns without sleeping or timing out.
#[test]
fn await_drain_returns_promptly_when_already_empty() {
    let (backend, _dir) = make_backend();
    let start = Instant::now();
    backend
        .await_drain(Duration::from_millis(20), Duration::from_secs(30))
        .expect("empty queue must drain promptly");
    // Far below the 20 ms poll interval: it returned on the first probe.
    assert!(start.elapsed() < Duration::from_millis(15));
}

// pending_count reflects the new/ frontier; zero after every job is completed.
#[test]
fn pending_count_tracks_new_frontier() {
    let (backend, _dir) = make_backend();
    assert_eq!(backend.pending_count().unwrap(), 0);
    backend.write(&make_job("a")).unwrap();
    backend.write(&make_job("b")).unwrap();
    assert_eq!(backend.pending_count().unwrap(), 2);
    // Claiming moves new/ → cur/, so pending drops to zero while in_flight=2.
    let batch = backend.drain_available().unwrap();
    assert_eq!(backend.pending_count().unwrap(), 0);
    assert_eq!(backend.in_flight().unwrap().len(), 2);
    for (job, _) in &batch {
        backend.complete(&job.id, ObservationStatus::Done, vec![]).unwrap();
    }
    assert_eq!(backend.in_flight().unwrap().len(), 0);
}

// Releases only after the last job is drained AND completed: a concurrent
// worker drains both and replies terminal so they move new/ → cur/ → done/.
// await_drain must not release until both completions have landed.
#[test]
fn await_drain_releases_after_full_processing() {
    let (backend, _dir) = make_backend();
    let backend = Arc::new(backend);
    backend.write(&make_job("a")).unwrap();
    backend.write(&make_job("b")).unwrap();

    let worker = {
        let b = Arc::clone(&backend);
        std::thread::spawn(move || {
            // Small stagger so await_drain observes a non-empty frontier first.
            std::thread::sleep(Duration::from_millis(30));
            let batch = b.drain_available().unwrap();
            for (job, _) in &batch {
                b.complete(&job.id, ObservationStatus::Done, vec![]).unwrap();
            }
        })
    };

    backend
        .await_drain(Duration::from_millis(20), Duration::from_secs(30))
        .expect("await_drain must release after full processing");
    worker.join().unwrap();

    // Post-condition: both frontiers empty, both jobs in done/.
    assert_eq!(backend.in_flight().unwrap().len(), 0);
    assert_eq!(backend.pending_count().unwrap(), 0);
    assert_eq!(backend.completed(None).unwrap().len(), 2);
}

// Does NOT release while a job is claimed but not completed: an unreplied
// in-flight job counts as "not yet drained", so await_drain times out.
#[test]
fn await_drain_blocks_while_in_flight() {
    let (backend, _dir) = make_backend();
    backend.write(&make_job("a")).unwrap();
    // Claim (new/ → cur/) but never complete — it stays in-flight.
    let _ = backend.drain_available().unwrap();
    assert_eq!(backend.in_flight().unwrap().len(), 1);

    let result = backend.await_drain(
        Duration::from_millis(10), Duration::from_millis(120));
    match result {
        Err(QueueError::DrainTimeout { pending, in_flight }) => {
            assert_eq!(pending, 0);
            assert_eq!(in_flight, 1);
        }
        other => panic!("expected DrainTimeout, got {other:?}"),
    }
}

// Times out rather than hanging when pending never clears (no worker drains).
#[test]
fn await_drain_times_out_on_stuck_pending() {
    let (backend, _dir) = make_backend();
    backend.write(&make_job("a")).unwrap();
    let result = backend.await_drain(
        Duration::from_millis(10), Duration::from_millis(100));
    match result {
        Err(QueueError::DrainTimeout { pending, in_flight }) => {
            assert_eq!(pending, 1);
            assert_eq!(in_flight, 0);
        }
        other => panic!("expected DrainTimeout, got {other:?}"),
    }
}
