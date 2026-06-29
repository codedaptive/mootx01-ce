// Identifier validation tests (CAND-023 — planned security hardening).
//
// A stream_id or job id containing path separators, "." / "..", or ASCII
// control characters must be rejected before any filesystem path is
// constructed. Parity with Swift and Python ports.

use std::path::PathBuf;

use queuekit::{FilesystemBackend, HLC, Job, JobId, ObservationStatus, QueueBackend, StreamId};
use serde_json::Map;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

struct TempDir {
    path: PathBuf,
}

impl TempDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "queuekit-idval-{}", uuid::Uuid::new_v4()
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

/// Build a minimal Job using the given stream_id and job_id strings.
fn make_job(stream_id: impl Into<String>, job_id: impl Into<String>) -> Job {
    Job {
        id: JobId(job_id.into()),
        stream_id: StreamId(stream_id.into()),
        submitted_at: HLC {
            physical_time: 1_700_000_000_000,
            logical_count: 0,
            node_id: 1,
        },
        priority: 50,
        payload: Vec::new(),
        extensions: Map::new(),
    }
}

// ---------------------------------------------------------------------------
// write() — rejection tests
// ---------------------------------------------------------------------------

#[test]
fn rejects_dotdot_stream_id() {
    // ".." in stream_id escapes the queue root when embedded in the filename.
    let dir = TempDir::new();
    let backend = make_backend(&dir);
    let job = make_job("..", "abc123");
    assert!(
        backend.write(&job).is_err(),
        "write must reject '..' stream_id"
    );
}

#[test]
fn rejects_dotdot_job_id() {
    // ".." as a job id appears in signal file names (e.g. "..".signal),
    // which would resolve outside done/.
    let dir = TempDir::new();
    let backend = make_backend(&dir);
    let job = make_job("encode", "..");
    assert!(
        backend.write(&job).is_err(),
        "write must reject '..' job_id"
    );
}

#[test]
fn rejects_forward_slash_in_stream_id() {
    // "/" injects a directory separator into the filename component.
    let dir = TempDir::new();
    let backend = make_backend(&dir);
    let job = make_job("evil/stream", "abc123");
    assert!(
        backend.write(&job).is_err(),
        "write must reject '/' in stream_id"
    );
}

#[test]
fn rejects_backslash_in_job_id() {
    // "\" is the Windows path separator; reject to maintain cross-platform safety.
    let dir = TempDir::new();
    let backend = make_backend(&dir);
    let job = make_job("encode", "bad\\id");
    assert!(
        backend.write(&job).is_err(),
        "write must reject '\\' in job_id"
    );
}

#[test]
fn rejects_absolute_path_as_stream_id() {
    // An absolute path starts with "/" — caught by the separator check.
    let dir = TempDir::new();
    let backend = make_backend(&dir);
    let job = make_job("/etc/passwd", "abc123");
    assert!(
        backend.write(&job).is_err(),
        "write must reject absolute path as stream_id"
    );
}

#[test]
fn rejects_control_character_in_job_id() {
    // Control characters (0x00–0x1F) produce problematic filenames.
    let dir = TempDir::new();
    let backend = make_backend(&dir);
    let job = make_job("encode", "bad\x01id");
    assert!(
        backend.write(&job).is_err(),
        "write must reject control character in job_id"
    );
}

// ---------------------------------------------------------------------------
// complete() — rejection tests
// ---------------------------------------------------------------------------

#[test]
fn rejects_dotdot_job_id_on_complete() {
    // complete() constructs a signal file path from the job id;
    // ".." would escape done/.
    let dir = TempDir::new();
    let backend = make_backend(&dir);
    let result = backend.complete(
        &JobId("..".to_string()),
        ObservationStatus::Done,
        Vec::new(),
    );
    assert!(
        result.is_err(),
        "complete must reject '..' job_id"
    );
}

#[test]
fn rejects_forward_slash_job_id_on_complete() {
    let dir = TempDir::new();
    let backend = make_backend(&dir);
    let result = backend.complete(
        &JobId("a/b".to_string()),
        ObservationStatus::Done,
        Vec::new(),
    );
    assert!(
        result.is_err(),
        "complete must reject '/' in job_id"
    );
}

// ---------------------------------------------------------------------------
// Legitimate identifiers must still work
// ---------------------------------------------------------------------------

#[test]
fn accepts_hex_job_id_and_kebab_stream_id() {
    // 32-char hex job ids and kebab-case stream names are the standard form;
    // they must not be rejected.
    let dir = TempDir::new();
    let backend = make_backend(&dir);
    let job = make_job("encode-corpus", "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4");
    backend.write(&job).expect("legitimate identifiers must not be rejected");
    let results = backend.drain_available().expect("drain");
    assert_eq!(results.len(), 1, "drained job count must be 1");
}
