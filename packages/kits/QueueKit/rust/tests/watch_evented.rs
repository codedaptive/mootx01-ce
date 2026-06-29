// watch_evented.rs — Contract tests for `FilesystemBackend::watch()` via the
// `notify`-backed evented path, and for `poll_watch_loop` called directly as
// the forced-fallback path.
//
// Compiled and run when the `watch` feature is present (now the default).
// These tests cover the same four-point contract as `watch_polling.rs` but
// drive it through the OS-event path (`notify::RecommendedWatcher`):
//   - Linux:   inotify
//   - macOS:   kqueue / FSEvents
//   - Windows: ReadDirectoryChangesW
//
// CONTRACT UNDER TEST (QUEUEKIT_SPEC §3, §5 B-3):
//   1. watch() works — it is NOT BackendUnavailable. Jobs present before watch()
//      starts are delivered via the initial drain pass.
//   2. Drain-first semantics: handler is called through drain_available(), not
//      from the wake payload. A job written AFTER watch() starts is delivered
//      promptly via OS event notification.
//   3. handler() errors propagate fail-closed (SPEC §5 B-3).
//   4. Jobs already present before watch() starts are drained first, not lost.
//   5. poll_watch_loop fallback: the poll helper delivers jobs correctly when
//      called directly — validating the fallback path independently of whether
//      the evented watcher succeeded.
//
// All tests terminate in well under 3 seconds (watchdog rule).
// The OS-event path fires within milliseconds; 1 s deadlines are generous.

#[cfg(feature = "watch")]
mod evented_tests {
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use queuekit::{FilesystemBackend, HLC, Job, JobId, QueueBackend, QueueError, StreamId};
    use serde_json::Map;

    fn make_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("qk-evented-{}-{}", tag, uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn make_job(tag: &str) -> Job {
        Job {
            id: JobId(uuid::Uuid::new_v4().to_string().replace('-', "")),
            stream_id: StreamId("evented-test".to_string()),
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
    // watch() is NOT BackendUnavailable with the `watch` feature enabled.
    // A job written before watch() starts is delivered in the initial drain pass;
    // the handler stops watch() via a deliberate Err after collecting the first job.
    #[test]
    fn watch_evented_is_not_backend_unavailable() {
        let dir = make_dir("notunav");
        let backend = Arc::new(FilesystemBackend::new(&dir, 1).unwrap());

        backend.write(&make_job("preload-evented")).unwrap();

        let collected: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(vec![]));
        let collected2 = Arc::clone(&collected);

        let b = Arc::clone(&backend);
        let result = std::thread::spawn(move || {
            b.watch(Box::new(move |job, _session| {
                collected2.lock().unwrap().push(
                    String::from_utf8_lossy(&job.payload).to_string()
                );
                // Deliberate error to terminate watch() after first job.
                Err(QueueError::WatcherFailed("test-exit".to_string()))
            }))
        }).join().unwrap();

        // Err("test-exit") from handler — NOT BackendUnavailable.
        match &result {
            Err(QueueError::WatcherFailed(msg)) => {
                assert_eq!(msg, "test-exit", "unexpected watcher error: {}", msg);
            }
            Err(QueueError::BackendUnavailable(msg)) => {
                panic!("watch() returned BackendUnavailable — parity broken: {}", msg);
            }
            Err(other) => panic!("unexpected error: {:?}", other),
            Ok(()) => panic!("watch() returned Ok unexpectedly"),
        }

        let got = collected.lock().unwrap();
        assert_eq!(got.as_slice(), &["preload-evented"],
            "expected pre-loaded job in initial drain pass, got: {:?}", *got);
    }

    // --- TEST 2 ---
    // Drain-first via OS events: a job written AFTER watch() starts is delivered
    // promptly. The evented path (inotify on Linux, kqueue on macOS) fires within
    // milliseconds of the write. The 1 s deadline is generous enough for any
    // scheduler jitter.
    //
    // We wait 300 ms before writing so the watcher's initial drain pass completes
    // and the watcher enters its event-wait loop — the same stagger as the poll
    // test, still valid for the evented path.
    #[test]
    fn watch_evented_delivers_job_written_after_start() {
        let dir = make_dir("after-start");
        let backend = Arc::new(FilesystemBackend::new(&dir, 2).unwrap());

        let collected: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(vec![]));
        let collected2 = Arc::clone(&collected);

        let b_watch = Arc::clone(&backend);
        let watch_handle = std::thread::spawn(move || {
            b_watch.watch(Box::new(move |job, _session| {
                collected2.lock().unwrap().push(
                    String::from_utf8_lossy(&job.payload).to_string()
                );
                Err(QueueError::WatcherFailed("test-exit".to_string()))
            }))
        });

        // Stagger: let the watcher enter its event-wait loop before the write.
        std::thread::sleep(Duration::from_millis(300));

        backend.write(&make_job("evented-after-start")).unwrap();

        // OS-event path fires in < 50 ms on Linux/macOS; 1 s is a safe upper bound.
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            if watch_handle.is_finished() { break; }
            if Instant::now() > deadline {
                panic!("watch() did not deliver the job within 1 s — evented path broken");
            }
            std::thread::sleep(Duration::from_millis(20));
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
        assert!(got.iter().any(|s| s == "evented-after-start"),
            "expected 'evented-after-start' payload, got: {:?}", *got);
    }

    // --- TEST 3 ---
    // Drain-first semantics: the job delivered to the handler is confirmed to
    // have been moved from new/ to cur/ (claimed by drain_available()), not
    // still sitting in new/. This confirms the handler receives the job through
    // the drain path, not a separate mechanism — same check as the poll test.
    #[test]
    fn watch_evented_handler_receives_claimed_job_not_raw_file() {
        let dir = make_dir("claim-check");
        let backend = Arc::new(FilesystemBackend::new(&dir, 3).unwrap());

        backend.write(&make_job("evented-claim-me")).unwrap();

        assert_eq!(backend.pending_count().unwrap(), 1);

        let b = Arc::clone(&backend);
        let _ = std::thread::spawn(move || {
            b.watch(Box::new(|_job, _session| {
                Err(QueueError::WatcherFailed("test-exit".to_string()))
            }))
        }).join().unwrap();

        // Job has been moved to cur/ (claimed by drain_available()).
        assert_eq!(backend.pending_count().unwrap(), 0,
            "job still in new/ after handler ran — drain-first semantics broken");
        let in_flight = backend.in_flight().unwrap();
        assert_eq!(in_flight.len(), 1,
            "expected job in cur/ (in-flight) after handler ran, got: {}", in_flight.len());
    }

    // --- TEST 4 ---
    // Handler error propagates fail-closed: watch() returns Err when the handler
    // returns Err, satisfying SPEC §5 B-3.
    #[test]
    fn watch_evented_propagates_handler_error_fail_closed() {
        let dir = make_dir("fail-closed");
        let backend = FilesystemBackend::new(&dir, 4).unwrap();

        backend.write(&make_job("evented-fail-me")).unwrap();

        let result = backend.watch(Box::new(|_job, _session| {
            Err(QueueError::BackendUnavailable("injected-failure".to_string()))
        }));

        match result {
            Err(QueueError::BackendUnavailable(ref msg)) if msg == "injected-failure" => {}
            other => panic!("expected injected failure to propagate, got: {:?}", other),
        }
    }

    // --- TEST 5 ---
    // poll_watch_loop forced-fallback contract: calling poll_watch_loop directly
    // (bypassing the evented setup) delivers jobs via 200 ms polling.
    //
    // This tests the RUNTIME FALLBACK path: the same code that runs when
    // RecommendedWatcher::new() or .watch() fails at runtime (inotify
    // watch-limit exhausted, unsupported filesystem, etc.). It verifies that:
    //   - the fallback is not BackendUnavailable
    //   - jobs are delivered via drain_available() inside the poll loop
    //   - the 200 ms cadence is met (delivery within 1 s of write)
    #[test]
    fn watch_poll_loop_fallback_delivers_job() {
        let dir = make_dir("poll-fallback");
        let backend = Arc::new(FilesystemBackend::new(&dir, 5).unwrap());

        let collected: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(vec![]));
        let collected2 = Arc::clone(&collected);

        // Call poll_watch_loop directly to exercise the fallback path.
        let b_watch = Arc::clone(&backend);
        let poll_handle = std::thread::spawn(move || {
            b_watch.poll_watch_loop(Box::new(move |job, _session| {
                collected2.lock().unwrap().push(
                    String::from_utf8_lossy(&job.payload).to_string()
                );
                Err(QueueError::WatcherFailed("poll-exit".to_string()))
            }))
        });

        // Stagger past the initial drain pass and the first poll sleep.
        std::thread::sleep(Duration::from_millis(300));

        backend.write(&make_job("poll-fallback-job")).unwrap();

        // Poll fires within one 200 ms interval; 1 s is generous.
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            if poll_handle.is_finished() { break; }
            if Instant::now() > deadline {
                panic!("poll_watch_loop fallback did not deliver job within 1 s");
            }
            std::thread::sleep(Duration::from_millis(50));
        }

        let result = poll_handle.join().unwrap();
        match result {
            Err(QueueError::WatcherFailed(ref msg)) if msg == "poll-exit" => {}
            other => panic!("unexpected poll_watch_loop result: {:?}", other),
        }

        let got = collected.lock().unwrap();
        assert!(got.iter().any(|s| s == "poll-fallback-job"),
            "expected 'poll-fallback-job' payload from fallback path, got: {:?}", *got);
    }

    // --- TEST 6 ---
    // Jobs already present BEFORE poll_watch_loop starts are drained in the
    // initial drain pass (not missed). Mirrors the evented path's drain-before-wait.
    #[test]
    fn watch_poll_loop_drains_pre_existing_jobs() {
        let dir = make_dir("poll-preload");
        let backend = FilesystemBackend::new(&dir, 6).unwrap();

        backend.write(&make_job("pre-existing")).unwrap();

        let collected: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(vec![]));
        let collected2 = Arc::clone(&collected);

        let _ = std::thread::spawn(move || {
            backend.poll_watch_loop(Box::new(move |job, _session| {
                collected2.lock().unwrap().push(
                    String::from_utf8_lossy(&job.payload).to_string()
                );
                Err(QueueError::WatcherFailed("test-exit".to_string()))
            }))
        }).join().unwrap();

        let got = collected.lock().unwrap();
        assert_eq!(got.as_slice(), &["pre-existing"],
            "expected pre-existing job in initial drain pass, got: {:?}", *got);
    }
}
