// watch_polling.rs — Parity tests for the default-build (no `watch` feature)
// `FilesystemBackend::watch()` polling implementation.
//
// CONTRACT UNDER TEST (QUEUEKIT_SPEC §3, §5 B-3):
//   1. watch() works in a default build (no --features watch) — it is NOT
//      BackendUnavailable. Swift's filesystem backend watches by default via
//      kqueue/poll; the Rust default must match.
//   2. Drain-first semantics: the handler is invoked through drain_available(),
//      not from the wake payload. A job written AFTER watch() starts is delivered
//      within a bounded time (near-realtime via polling).
//   3. handler() errors propagate: watch() returns Err when the handler returns
//      Err, satisfying the fail-closed contract (SPEC §5 B-3).
//   4. Jobs already present before watch() starts are drained in the initial
//      drain pass (before the poll loop), not lost.
//
// All tests terminate in well under 3 seconds (watchdog rule).
// The 200 ms WATCH_POLL_INTERVAL means any test waiting for a handler
// invocation needs to allow at most a few poll ticks — 1 s is generous.

#[cfg(not(feature = "watch"))]
mod polling_tests {
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use queuekit::{
        FilesystemBackend, HLC, Job, JobId, QueueBackend, QueueError, StreamId,
    };
    use serde_json::Map;

    fn make_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("qk-watch-poll-{}-{}", tag, uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn make_job(tag: &str) -> Job {
        Job {
            id: JobId(uuid::Uuid::new_v4().to_string().replace('-', "")),
            stream_id: StreamId("watch-test".to_string()),
            submitted_at: HLC {
                physical_time: 1_700_000_000_000,
                logical_count: 0,
                node_id: 1,
            },
            priority: 50,
            payload: tag.as_bytes().to_vec(),
            extensions: Map::new(),
        }
    }

    // --- TEST 1 ---
    // watch() is NOT BackendUnavailable in a default build.
    // A job written before watch() is enqueued and collected from the initial
    // drain pass; handler fires, then the handler deliberately returns Err to
    // terminate watch() after the first job (controlled exit).
    #[test]
    fn watch_default_build_is_not_backend_unavailable() {
        let dir = make_dir("notunav");
        let backend = Arc::new(FilesystemBackend::new(&dir, 1).unwrap());

        // Write a job BEFORE watch() so it lands in the initial drain pass.
        backend.write(&make_job("preload")).unwrap();

        let collected: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(vec![]));
        let collected2 = Arc::clone(&collected);

        let b = Arc::clone(&backend);
        let result = std::thread::spawn(move || {
            b.watch(move |job, _session| {
                collected2.lock().unwrap().push(
                    String::from_utf8_lossy(&job.payload).to_string()
                );
                // Return a deliberate error to terminate watch() after
                // collecting the first job — controlled test exit.
                Err(QueueError::WatcherFailed("test-exit".to_string()))
            })
        }).join().unwrap();

        // The result is Err("test-exit") from the handler — NOT BackendUnavailable.
        match &result {
            Err(QueueError::WatcherFailed(msg)) => {
                assert_eq!(msg, "test-exit", "unexpected watcher error: {}", msg);
            }
            Err(QueueError::BackendUnavailable(msg)) => {
                panic!("watch() returned BackendUnavailable — parity broken: {}", msg);
            }
            Err(other) => panic!("unexpected error: {:?}", other),
            Ok(()) => panic!("watch() returned Ok unexpectedly (should have stopped on handler error)"),
        }

        // Handler was called with the pre-loaded job.
        let got = collected.lock().unwrap();
        assert_eq!(got.as_slice(), &["preload"],
            "expected pre-loaded job in initial drain pass, got: {:?}", *got);
    }

    // --- TEST 2 ---
    // Drain-first: a job written AFTER watch() starts is delivered within a
    // bounded time via polling. The job payload is NOT the wake argument —
    // it comes from drain_available() inside the poll loop.
    //
    // Approach: watch() blocks on a thread. A second thread writes a job after a
    // short stagger. The handler records the payload and stops watch() via Err.
    // Main thread joins both within a tight deadline (1 s).
    #[test]
    fn watch_delivers_job_written_after_start() {
        let dir = make_dir("after-start");
        let backend = Arc::new(FilesystemBackend::new(&dir, 2).unwrap());

        let collected: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(vec![]));
        let collected2 = Arc::clone(&collected);

        // Spawn the watcher thread first.
        let b_watch = Arc::clone(&backend);
        let watch_handle = std::thread::spawn(move || {
            b_watch.watch(move |job, _session| {
                collected2.lock().unwrap().push(
                    String::from_utf8_lossy(&job.payload).to_string()
                );
                Err(QueueError::WatcherFailed("test-exit".to_string()))
            })
        });

        // Small stagger: let the watcher enter its poll loop before the write,
        // so it cannot consume the job in the initial drain pass. The poll
        // interval is 200 ms so we wait 300 ms before writing.
        std::thread::sleep(Duration::from_millis(300));

        backend.write(&make_job("after-start")).unwrap();

        // The watcher must deliver the job within 1 s (5 poll ticks at 200 ms).
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            if watch_handle.is_finished() { break; }
            if Instant::now() > deadline {
                panic!("watch() did not deliver the job within 1 s — polling broken");
            }
            std::thread::sleep(Duration::from_millis(50));
        }

        let result = watch_handle.join().unwrap();
        match result {
            Err(QueueError::WatcherFailed(ref msg)) if msg == "test-exit" => {}
            Err(QueueError::BackendUnavailable(msg)) => {
                panic!("watch() returned BackendUnavailable — parity broken: {}", msg);
            }
            other => panic!("unexpected watch() result: {:?}", other),
        }

        let got = collected.lock().unwrap();
        assert!(got.iter().any(|s| s == "after-start"),
            "expected 'after-start' payload, got: {:?}", *got);
    }

    // --- TEST 3 ---
    // Drain-first semantics verified directly: the job delivered by the handler
    // is confirmed to have been moved from new/ to cur/ (claimed by
    // drain_available()), not still sitting in new/. This verifies that the
    // handler receives the job through the drain path, not a separate mechanism.
    #[test]
    fn watch_handler_receives_claimed_job_not_raw_file() {
        let dir = make_dir("claim-check");
        let backend = Arc::new(FilesystemBackend::new(&dir, 3).unwrap());

        backend.write(&make_job("claim-me")).unwrap();

        // Confirm the job is in new/ before watch().
        assert_eq!(backend.pending_count().unwrap(), 1);

        let b = Arc::clone(&backend);
        let _ = std::thread::spawn(move || {
            b.watch(|_job, _session| {
                Err(QueueError::WatcherFailed("test-exit".to_string()))
            })
        }).join().unwrap();

        // After the handler ran, the job has been claimed (moved new/ → cur/).
        // pending_count() must be 0 — it is no longer in new/.
        assert_eq!(backend.pending_count().unwrap(), 0,
            "job still in new/ after handler ran — drain-first semantics broken");

        // The job is now in cur/ (in-flight): drain_available() claimed it and
        // the backend called handler() before complete() was called. In-flight
        // confirms it was processed through the drain path.
        let in_flight = backend.in_flight().unwrap();
        assert_eq!(in_flight.len(), 1,
            "expected job in cur/ (in-flight) after handler ran, got: {}", in_flight.len());
    }

    // --- TEST 4 ---
    // Handler error propagates fail-closed: when drain_available() would return
    // an error in production, watch() surfaces it (SPEC §5 B-3). We test this
    // via handler Err propagation, which exercises the same code path (the
    // `?` on `handler(job, session_id)?` inside the loop).
    #[test]
    fn watch_propagates_handler_error_fail_closed() {
        let dir = make_dir("fail-closed");
        let backend = FilesystemBackend::new(&dir, 4).unwrap();

        backend.write(&make_job("fail-me")).unwrap();

        let result = backend.watch(|_job, _session| {
            Err(QueueError::BackendUnavailable("injected-failure".to_string()))
        });

        match result {
            Err(QueueError::BackendUnavailable(ref msg)) if msg == "injected-failure" => {}
            other => panic!("expected injected failure to propagate, got: {:?}", other),
        }
    }
}
