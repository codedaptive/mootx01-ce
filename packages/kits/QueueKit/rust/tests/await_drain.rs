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
    make_job_stream("encode", tag)
}

fn make_job_stream(stream: &str, tag: &str) -> Job {
    Job {
        id: JobId(uuid::Uuid::new_v4().to_string()),
        stream_id: StreamId(stream.to_string()),
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

// Bug A regression (the encode-stall fix). On a SHARED queue carrying more
// than one stream, `await_drain_for_stream(target)` must release once the
// TARGET stream is clear and must NOT block on other streams' pending jobs
// (e.g. `dreaming` enqueued on recall) that a stream-scoped drainer never
// processes. The GLOBAL `await_drain` WOULD block on them — that was the
// post-T4/T6 encode-stall where every capture's encode barrier hung on
// pending dreaming jobs.
#[test]
fn await_drain_for_stream_ignores_other_streams() {
    let (backend, _dir) = make_backend();
    // One encode job + two dreaming jobs on the same (shared) queue.
    backend.write(&make_job_stream("encode", "e")).unwrap();
    backend.write(&make_job_stream("dreaming", "d1")).unwrap();
    backend.write(&make_job_stream("dreaming", "d2")).unwrap();

    // Drain + complete ONLY the encode stream.
    let batch = backend
        .drain_available_for_stream(&StreamId("encode".to_string()))
        .unwrap();
    assert_eq!(batch.len(), 1, "only the encode job is claimed");
    for (job, _) in &batch {
        backend.complete(&job.id, ObservationStatus::Done, vec![]).unwrap();
    }

    // The encode stream is clear; dreaming still has 2 pending. The
    // stream-scoped barrier must release promptly anyway.
    let start = Instant::now();
    backend
        .await_drain_for_stream(
            &StreamId("encode".to_string()),
            Duration::from_millis(20),
            Duration::from_secs(5),
        )
        .expect("encode barrier must release despite pending dreaming jobs");
    assert!(
        start.elapsed() < Duration::from_secs(1),
        "stream-scoped barrier must not wait out the timeout"
    );

    // Sanity: the GLOBAL barrier WOULD time out — proving the bug the
    // stream-scoped barrier fixes (dreaming jobs still pending).
    match backend.await_drain(Duration::from_millis(10), Duration::from_millis(120)) {
        Err(QueueError::DrainTimeout { pending, .. }) => assert_eq!(pending, 2),
        other => panic!("global await_drain should time out on dreaming; got {other:?}"),
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

// Progress resets the no-progress deadline. A slow-but-progressing drain must
// NOT time out even when the TOTAL wait exceeds `timeout`: the deadline resets
// each time the outstanding count (pending + in-flight) drops below its lowest
// observed value. Regression test for the GLK full-suite drainTimeout
// fragility, where CPU-starved encode workers drained slowly but steadily and
// a wall-clock cap false-timed-out a correct drain. Swift twin:
// awaitDrainProgressResetsDeadline.
#[test]
fn await_drain_progress_resets_deadline() {
    let (backend, _dir) = make_backend();
    let backend = Arc::new(backend);
    for tag in ["a", "b", "c", "d"] {
        backend.write(&make_job(tag)).unwrap();
    }

    // Worker: claim all four up front (pending → in-flight), then complete
    // one every 200 ms. Total drain ≈ 800 ms — double the 400 ms timeout —
    // but every completion lands well inside a fresh 400 ms window.
    let worker = {
        let b = Arc::clone(&backend);
        std::thread::spawn(move || {
            let batch = b.drain_available().unwrap();
            for (job, _) in &batch {
                std::thread::sleep(Duration::from_millis(200));
                b.complete(&job.id, ObservationStatus::Done, vec![]).unwrap();
            }
        })
    };

    // A wall-clock cap would fail at 400 ms with jobs still in flight; the
    // progress-based deadline must ride the resets to completion.
    backend
        .await_drain(Duration::from_millis(10), Duration::from_millis(400))
        .expect("progressing drain must not false-time-out");
    worker.join().unwrap();
    assert_eq!(backend.completed(None).unwrap().len(), 4);
}

// Partial progress then a stall must STILL time out: completing one of three
// jobs resets the deadline once, but the remaining two never move, so the
// no-progress deadline fires. Proves progress-based ≠ never-times-out.
// Swift twin: awaitDrainTimesOutWhenProgressStalls.
#[test]
fn await_drain_times_out_when_progress_stalls() {
    let (backend, _dir) = make_backend();
    for tag in ["a", "b", "c"] {
        backend.write(&make_job(tag)).unwrap();
    }
    // Claim all three (new/ → cur/), complete exactly ONE, then stall.
    let batch = backend.drain_available().unwrap();
    backend
        .complete(&batch[0].0.id, ObservationStatus::Done, vec![])
        .unwrap();

    match backend.await_drain(Duration::from_millis(10), Duration::from_millis(150)) {
        Err(QueueError::DrainTimeout { pending, in_flight }) => {
            assert_eq!(pending, 0);
            assert_eq!(in_flight, 2);
        }
        other => panic!("expected DrainTimeout, got {other:?}"),
    }
}
