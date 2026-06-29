// stream_scoped.rs — Integration tests for ADR-021 Decision 7 / T1:
// stream-scoped drain and pending_count_for_stream.
//
// Covers:
//   1. Stream isolation: drain_available_for_stream("a") returns ONLY "a" jobs
//      and leaves "b" jobs claimable by a subsequent drain for "b".
//   2. pending_count_for_stream returns the per-stream count, not the total.
//   3. Back-compat: the all-streams drain_available() and pending_count()
//      are unchanged.
//
// Tests run on BOTH PersistenceKitBackend (feature-gated) and FilesystemBackend.
// Mirrors Swift's StreamScopedDrainTests.

use std::path::PathBuf;
use std::sync::Arc;

use queuekit::{HLC, Job, JobId, QueueBackend, StreamId};
use serde_json::Map;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_job(i: u64, stream: &str) -> Job {
    Job {
        id: JobId(format!("job-{:04}-{}", i, stream)),
        stream_id: StreamId(stream.to_string()),
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
// PersistenceKitBackend stream-scoped tests (requires --features persistencekit)
// ---------------------------------------------------------------------------

#[cfg(feature = "persistencekit")]
mod pk {
    use super::*;
    use persistence_kit::{BackendConfiguration, EstateConfiguration};
    use persistence_kit::inmemory::InMemoryStorage;
    use queuekit::persistencekit::PersistenceKitBackend;

    fn make_backend() -> PersistenceKitBackend {
        let cfg = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
        let storage = Arc::new(InMemoryStorage::new(cfg));
        PersistenceKitBackend::open_schema(storage.as_ref()).expect("open_schema");
        PersistenceKitBackend::new(storage)
    }

    // ── Isolation ─────────────────────────────────────────────────────────

    /// drain_available_for_stream("a") returns ONLY "a" jobs; "b" jobs remain
    /// claimable and are returned by a subsequent drain for "b".
    #[test]
    fn pk_stream_isolation_drain() {
        let backend = make_backend();

        let a1 = make_job(1, "a");
        let a2 = make_job(2, "a");
        let b1 = make_job(3, "b");
        let b2 = make_job(4, "b");

        backend.write(&a1).unwrap();
        backend.write(&b1).unwrap();
        backend.write(&a2).unwrap();
        backend.write(&b2).unwrap();

        // Drain stream "a".
        let stream_a = StreamId("a".to_string());
        let drained_a = backend
            .drain_available_for_stream(&stream_a)
            .expect("drain stream a");
        assert_eq!(drained_a.len(), 2, "stream-a drain must return exactly 2 jobs");
        let ids_a: std::collections::HashSet<String> =
            drained_a.iter().map(|(j, _)| j.id.0.clone()).collect();
        assert!(ids_a.contains(&a1.id.0));
        assert!(ids_a.contains(&a2.id.0));
        assert!(!ids_a.contains(&b1.id.0));
        assert!(!ids_a.contains(&b2.id.0));

        // Stream "b" jobs are still claimable.
        let stream_b = StreamId("b".to_string());
        let drained_b = backend
            .drain_available_for_stream(&stream_b)
            .expect("drain stream b");
        assert_eq!(drained_b.len(), 2, "stream-b drain must return exactly 2 jobs");
        let ids_b: std::collections::HashSet<String> =
            drained_b.iter().map(|(j, _)| j.id.0.clone()).collect();
        assert!(ids_b.contains(&b1.id.0));
        assert!(ids_b.contains(&b2.id.0));
    }

    /// pending_count_for_stream returns only that stream's count.
    #[test]
    fn pk_stream_isolation_pending_count() {
        let backend = make_backend();

        backend.write(&make_job(1, "encode")).unwrap();
        backend.write(&make_job(2, "encode")).unwrap();
        backend.write(&make_job(3, "dreaming")).unwrap();

        let encode = StreamId("encode".to_string());
        let dreaming = StreamId("dreaming".to_string());

        assert_eq!(backend.pending_count_for_stream(&encode).unwrap(), 2);
        assert_eq!(backend.pending_count_for_stream(&dreaming).unwrap(), 1);

        // Drain "encode" — "dreaming" count must remain 1.
        backend.drain_available_for_stream(&encode).unwrap();
        assert_eq!(backend.pending_count_for_stream(&encode).unwrap(), 0);
        assert_eq!(backend.pending_count_for_stream(&dreaming).unwrap(), 1);
    }

    /// pending_count_for_stream is per-stream, not the total.
    #[test]
    fn pk_pending_count_is_per_stream() {
        let backend = make_backend();

        for i in 0..3u64 {
            backend.write(&make_job(i, "encode")).unwrap();
        }
        for i in 3..7u64 {
            backend.write(&make_job(i, "dreaming")).unwrap();
        }

        let encode = StreamId("encode".to_string());
        let dreaming = StreamId("dreaming".to_string());

        assert_eq!(backend.pending_count_for_stream(&encode).unwrap(), 3);
        assert_eq!(backend.pending_count_for_stream(&dreaming).unwrap(), 4);
        assert_eq!(backend.pending_count().unwrap(), 7, "all-streams total is 7");
    }

    // ── Back-compat ────────────────────────────────────────────────────────

    /// The all-streams drain_available() is unchanged — still claims everything.
    #[test]
    fn pk_back_compat_all_streams_drain() {
        let backend = make_backend();
        backend.write(&make_job(1, "a")).unwrap();
        backend.write(&make_job(2, "b")).unwrap();
        backend.write(&make_job(3, "c")).unwrap();

        let all = backend.drain_available().expect("all-streams drain");
        assert_eq!(all.len(), 3, "all-streams drain must return all 3 jobs");
    }

    /// The all-streams pending_count() is unchanged.
    #[test]
    fn pk_back_compat_pending_count() {
        let backend = make_backend();
        backend.write(&make_job(1, "a")).unwrap();
        backend.write(&make_job(2, "b")).unwrap();

        assert_eq!(backend.pending_count().unwrap(), 2);
        let a = StreamId("a".to_string());
        assert_eq!(backend.pending_count_for_stream(&a).unwrap(), 1);
    }

    // ── Empty streams ──────────────────────────────────────────────────────

    /// Draining a stream with no jobs returns empty without error.
    #[test]
    fn pk_drain_empty_stream() {
        let backend = make_backend();
        backend.write(&make_job(1, "other")).unwrap();

        let result = backend
            .drain_available_for_stream(&StreamId("nojobs".to_string()))
            .expect("drain empty stream");
        assert!(result.is_empty());
    }

    /// pending_count_for_stream returns 0 for a stream with no jobs.
    #[test]
    fn pk_pending_count_empty_stream() {
        let backend = make_backend();
        let count = backend
            .pending_count_for_stream(&StreamId("nojobs".to_string()))
            .expect("pending_count empty stream");
        assert_eq!(count, 0);
    }

    // ── Facade passthroughs ────────────────────────────────────────────────

    /// QueueKit::drain_for_stream and pending_count_for_stream pass through to
    /// the backend correctly.
    #[test]
    fn pk_facade_passthroughs() {
        use queuekit::QueueKit;
        let storage = {
            let cfg = EstateConfiguration::new(
                uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
            Arc::new(InMemoryStorage::new(cfg))
        };
        PersistenceKitBackend::open_schema(storage.as_ref()).unwrap();
        let backend = PersistenceKitBackend::new(storage);
        let kit = QueueKit::new(backend);

        kit.send(&make_job(1, "encode")).unwrap();
        kit.send(&make_job(2, "dreaming")).unwrap();

        let encode = StreamId("encode".to_string());
        let dreaming = StreamId("dreaming".to_string());

        // drain_for_stream returns only the requested stream.
        let now = 1_700_000_000.0f64;
        let drained = kit.drain_for_stream(&encode, now).expect("drain_for_stream");
        assert_eq!(drained.len(), 1);
        assert_eq!(drained[0].0.stream_id.0, "encode");

        // dreaming job is still pending.
        assert_eq!(kit.pending_count_for_stream(&dreaming).unwrap(), 1);
    }
}

// ---------------------------------------------------------------------------
// FilesystemBackend stream-scoped tests
// ---------------------------------------------------------------------------

mod fs_tests {
    use super::*;
    use queuekit::FilesystemBackend;

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "queuekit-stream-{}", uuid::Uuid::new_v4()
            ));
            std::fs::create_dir_all(&path).expect("create temp dir");
            TempDir { path }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn make_backend(dir: &TempDir) -> FilesystemBackend {
        FilesystemBackend::new(&dir.path, 1).expect("make FilesystemBackend")
    }

    // ── Isolation ─────────────────────────────────────────────────────────

    /// drain_available_for_stream("a") returns ONLY "a" jobs; "b" files are
    /// renamed back to new/ and remain claimable.
    #[test]
    fn fs_stream_isolation_drain() {
        let dir = TempDir::new();
        let backend = make_backend(&dir);

        let a1 = make_job(1, "a");
        let a2 = make_job(2, "a");
        let b1 = make_job(3, "b");
        let b2 = make_job(4, "b");

        backend.write(&a1).unwrap();
        backend.write(&b1).unwrap();
        backend.write(&a2).unwrap();
        backend.write(&b2).unwrap();

        let stream_a = StreamId("a".to_string());
        let drained_a = backend
            .drain_available_for_stream(&stream_a)
            .expect("drain stream a");
        assert_eq!(drained_a.len(), 2, "stream-a drain must return exactly 2 jobs");
        let ids_a: std::collections::HashSet<String> =
            drained_a.iter().map(|(j, _)| j.id.0.clone()).collect();
        assert!(ids_a.contains(&a1.id.0));
        assert!(ids_a.contains(&a2.id.0));
        assert!(!ids_a.contains(&b1.id.0));
        assert!(!ids_a.contains(&b2.id.0));

        // Stream "b" files were renamed back to new/ and are still drainable.
        let stream_b = StreamId("b".to_string());
        let drained_b = backend
            .drain_available_for_stream(&stream_b)
            .expect("drain stream b");
        assert_eq!(drained_b.len(), 2, "stream-b drain must return exactly 2 jobs");
        let ids_b: std::collections::HashSet<String> =
            drained_b.iter().map(|(j, _)| j.id.0.clone()).collect();
        assert!(ids_b.contains(&b1.id.0));
        assert!(ids_b.contains(&b2.id.0));
    }

    /// pending_count_for_stream counts only that stream's new/ files.
    #[test]
    fn fs_stream_isolation_pending_count() {
        let dir = TempDir::new();
        let backend = make_backend(&dir);

        backend.write(&make_job(1, "encode")).unwrap();
        backend.write(&make_job(2, "encode")).unwrap();
        backend.write(&make_job(3, "dreaming")).unwrap();

        let encode = StreamId("encode".to_string());
        let dreaming = StreamId("dreaming".to_string());

        assert_eq!(backend.pending_count_for_stream(&encode).unwrap(), 2);
        assert_eq!(backend.pending_count_for_stream(&dreaming).unwrap(), 1);

        // Drain "encode" — "dreaming" count must remain 1.
        backend.drain_available_for_stream(&encode).unwrap();
        assert_eq!(backend.pending_count_for_stream(&encode).unwrap(), 0);
        assert_eq!(backend.pending_count_for_stream(&dreaming).unwrap(), 1);
    }

    // ── Back-compat ────────────────────────────────────────────────────────

    /// The all-streams drain_available() is unchanged.
    #[test]
    fn fs_back_compat_all_streams_drain() {
        let dir = TempDir::new();
        let backend = make_backend(&dir);

        backend.write(&make_job(1, "a")).unwrap();
        backend.write(&make_job(2, "b")).unwrap();

        let all = backend.drain_available().expect("all-streams drain");
        assert_eq!(all.len(), 2);
    }

    /// The all-streams pending_count() is unchanged.
    #[test]
    fn fs_back_compat_pending_count() {
        let dir = TempDir::new();
        let backend = make_backend(&dir);

        backend.write(&make_job(1, "a")).unwrap();
        backend.write(&make_job(2, "b")).unwrap();

        assert_eq!(backend.pending_count().unwrap(), 2);
        let a = StreamId("a".to_string());
        assert_eq!(backend.pending_count_for_stream(&a).unwrap(), 1);
    }

    // ── Empty streams ──────────────────────────────────────────────────────

    /// Draining a stream with no files returns empty.
    #[test]
    fn fs_drain_empty_stream() {
        let dir = TempDir::new();
        let backend = make_backend(&dir);
        backend.write(&make_job(1, "other")).unwrap();

        let result = backend
            .drain_available_for_stream(&StreamId("nojobs".to_string()))
            .expect("drain empty stream");
        // "nojobs" jobs are 0; "other" job was un-claimed back to new/.
        assert!(result.is_empty());
        // The "other" job is still pending.
        assert_eq!(backend.pending_count().unwrap(), 1);
    }

    /// pending_count_for_stream returns 0 for an empty stream.
    #[test]
    fn fs_pending_count_empty_stream() {
        let dir = TempDir::new();
        let backend = make_backend(&dir);
        let count = backend
            .pending_count_for_stream(&StreamId("nojobs".to_string()))
            .expect("pending_count empty stream");
        assert_eq!(count, 0);
    }

    // ── Facade passthroughs ────────────────────────────────────────────────

    /// QueueKit::drain_for_stream and pending_count_for_stream pass through to
    /// the FilesystemBackend correctly.
    #[test]
    fn fs_facade_passthroughs() {
        use queuekit::QueueKit;
        let dir = TempDir::new();
        let backend = make_backend(&dir);
        let kit = QueueKit::new(backend);

        kit.send(&make_job(1, "encode")).unwrap();
        kit.send(&make_job(2, "dreaming")).unwrap();

        let encode = StreamId("encode".to_string());
        let dreaming = StreamId("dreaming".to_string());

        let now = 1_700_000_000.0f64;
        let drained = kit.drain_for_stream(&encode, now).expect("drain_for_stream");
        assert_eq!(drained.len(), 1);
        assert_eq!(drained[0].0.stream_id.0, "encode");

        // "dreaming" job is still pending.
        assert_eq!(kit.pending_count_for_stream(&dreaming).unwrap(), 1);
    }
}
