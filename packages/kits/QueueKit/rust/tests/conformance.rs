// Byte-identical conformance — Rust must produce the same bytes as
// Swift for every fixture in Tests/QueueKitTests/Fixtures/.

use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

use queuekit::{
    encode_job, encode_signal, filename_for_job, ArtifactRef, FilesystemBackend,
    HLC, Job, JobId, ObservationStatus, QueueBackend, SignalFile, StreamId,
};
use serde_json::{Map, Value};

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/QueueKitTests/Fixtures")
}

fn signed_node(unsigned: u64) -> i32 {
    if unsigned < 0x8000_0000 {
        unsigned as i32
    } else {
        (unsigned as i64 - 0x1_0000_0000_i64) as i32
    }
}

fn load_job_input(name: &str) -> Job {
    let p = fixtures_dir().join(format!("{}_input.json", name));
    let raw = fs::read_to_string(&p)
        .unwrap_or_else(|_| panic!("missing {:?}", p));
    let v: Value = serde_json::from_str(&raw).unwrap();
    let obj = v.as_object().unwrap();
    let payload_hex = obj.get("payload_bytes_hex")
        .and_then(|v| v.as_str()).unwrap_or("");
    let payload: Vec<u8> = (0..payload_hex.len()).step_by(2)
        .map(|i| u8::from_str_radix(&payload_hex[i..i+2], 16).unwrap())
        .collect();
    let sa = obj["submitted_at"].as_object().unwrap();
    let unsigned = sa["node_id"].as_u64().unwrap();
    let hlc = HLC {
        physical_time: sa["physical_time"].as_i64().unwrap(),
        logical_count: sa["logical_count"].as_i64().unwrap() as i32,
        node_id: signed_node(unsigned),
    };
    let extensions: Map<String, Value> = obj["extensions"]
        .as_object().cloned().unwrap_or_default();
    Job {
        id: JobId(obj["id"].as_str().unwrap().to_string()),
        stream_id: StreamId(obj["stream_id"].as_str().unwrap().to_string()),
        submitted_at: hlc,
        priority: obj["priority"].as_i64().unwrap() as i32,
        payload,
        extensions,
    }
}

fn load_signal_input(name: &str) -> SignalFile {
    let p = fixtures_dir().join(format!("signal_{}_input.json", name));
    let raw = fs::read_to_string(&p).unwrap();
    let v: Value = serde_json::from_str(&raw).unwrap();
    let obj = v.as_object().unwrap();
    let arts: Vec<ArtifactRef> = obj["artifacts"].as_array().unwrap()
        .iter().map(|a| {
            let am = a.as_object().unwrap();
            let t = am["type"].as_str().unwrap();
            let val = am["value"].as_str().unwrap().to_string();
            match t {
                "file_path" => ArtifactRef::FilePath(val),
                "commit_hash" => ArtifactRef::CommitHash(val),
                "signal_file" => ArtifactRef::SignalFile(val),
                "trajectory_step_id" => ArtifactRef::TrajectoryStepId(val),
                _ => panic!("unknown artifact type {}", t),
            }
        }).collect();
    let ca = obj["completed_at"].as_object().unwrap();
    SignalFile {
        job_id: JobId(obj["job_id"].as_str().unwrap().to_string()),
        status: ObservationStatus::from_raw(obj["status"].as_str().unwrap())
            .unwrap(),
        artifacts: arts,
        completed_at: HLC {
            physical_time: ca["physical_time"].as_i64().unwrap(),
            logical_count: ca["logical_count"].as_i64().unwrap() as i32,
            node_id: signed_node(ca["node_id"].as_u64().unwrap()),
        },
    }
}

#[test]
fn job_byte_identical() {
    for name in &["job_001", "job_002", "job_003", "job_004", "job_005"] {
        let job = load_job_input(name);
        let expected = fs::read(fixtures_dir().join(format!("{}_file.json", name)))
            .unwrap();
        let actual = encode_job(&job);
        assert_eq!(actual, expected,
            "fixture {} byte mismatch:\n  expected: {}\n  actual:   {}",
            name,
            String::from_utf8_lossy(&expected),
            String::from_utf8_lossy(&actual));
    }
}

#[test]
fn filename_byte_identical() {
    for name in &["job_001", "job_002", "job_003", "job_004", "job_005"] {
        let job = load_job_input(name);
        let expected = fs::read_to_string(
            fixtures_dir().join(format!("{}_filename.txt", name)))
            .unwrap().trim_end().to_string();
        let actual = filename_for_job(&job);
        assert_eq!(actual, expected, "filename {}", name);
    }
}

#[test]
fn signal_byte_identical() {
    for name in &["001", "002", "003", "004", "005"] {
        let sig = load_signal_input(name);
        let expected = fs::read(
            fixtures_dir().join(format!("signal_{}_output.json", name)))
            .unwrap();
        let actual = encode_signal(&sig);
        assert_eq!(actual, expected, "signal {} byte mismatch", name);
    }
}

// -------------------------------------------------------------
// Area 4: concurrent-claim conformance per QUEUEKIT_SPEC §9.
// Ten drainer threads, 100 jobs, zero duplicates. Confirms the
// Rust FilesystemBackend honours POSIX rename atomicity.
// -------------------------------------------------------------

fn make_test_job(i: u32) -> Job {
    Job {
        id: JobId(format!("job-{:04}", i)),
        stream_id: StreamId("area4".to_string()),
        submitted_at: HLC {
            physical_time: 1_700_000_000_000 + i as i64,
            logical_count: 0,
            node_id: 0xDEAD_BEEFu32 as i32,
        },
        priority: 0,
        payload: Vec::new(),
        extensions: Map::new(),
    }
}

#[test]
fn area4_concurrent_claim_filesystem() {
    let dir = std::env::temp_dir()
        .join(format!("queuekit-area4-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&dir).unwrap();

    let backend = Arc::new(
        FilesystemBackend::new(&dir, 0xDEAD_BEEFu32 as i32).unwrap()
    );

    for i in 0..100u32 {
        let job = make_test_job(i);
        backend.write(&job).unwrap();
    }

    let handles: Vec<_> = (0..10).map(|_| {
        let b = Arc::clone(&backend);
        std::thread::spawn(move || {
            b.drain_available().unwrap()
        })
    }).collect();

    let mut all_ids: Vec<String> = handles
        .into_iter()
        .flat_map(|h| h.join().unwrap())
        .map(|(job, _)| job.id.0.clone())
        .collect();

    assert_eq!(all_ids.len(), 100,
        "Expected 100 jobs claimed, got {}", all_ids.len());
    all_ids.sort();
    let before_dedup = all_ids.len();
    all_ids.dedup();
    assert_eq!(all_ids.len(), before_dedup,
        "Duplicate claims detected — POSIX rename atomicity violated");
    assert_eq!(all_ids.len(), 100,
        "Expected 100 unique ids after dedup, got {}", all_ids.len());

    let _ = fs::remove_dir_all(&dir);
}

// -------------------------------------------------------------
// File-mode verification: queue files must be 0600.
//
// Queue files carry encoded job payloads that may include sensitive
// content from the estate. World-readable (0644) permissions are a
// defense-in-depth failure. This test writes one job and verifies
// that the file in the `new/` maildir slot has exactly mode 0o600.
// Compiled only on Unix targets; Windows has no equivalent octal
// permission model.
// -------------------------------------------------------------

#[cfg(unix)]
#[test]
fn queue_files_created_with_mode_0600() {
    use std::os::unix::fs::PermissionsExt;

    let dir = std::env::temp_dir()
        .join(format!("queuekit-mode-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&dir).unwrap();

    let backend = FilesystemBackend::new(&dir, 1).unwrap();
    let job = Job {
        id: JobId("mode-check-job".to_string()),
        stream_id: StreamId("mode-check".to_string()),
        submitted_at: HLC { physical_time: 1_700_000_000_000, logical_count: 0, node_id: 1 },
        priority: 50,
        payload: b"mode-test".to_vec(),
        extensions: Map::new(),
    };
    backend.write(&job).unwrap();

    // Exactly one file should be in new/ after a single write.
    let new_dir = dir.join("new");
    let entries: Vec<_> = fs::read_dir(&new_dir).unwrap().collect();
    assert_eq!(entries.len(), 1, "Expected exactly one file in new/ after write");

    let entry = entries.into_iter().next().unwrap().unwrap();
    let meta = fs::metadata(entry.path()).unwrap();
    // Mode 0o100600: regular file (0o100000) + owner r/w (0o600).
    // Mask off the file-type bits — keep only the 12 permission bits.
    let mode = meta.permissions().mode() & 0o7777;
    assert_eq!(
        mode, 0o600,
        "Queue file mode was 0o{:o} — expected 0o600 (owner r/w only)",
        mode
    );

    let _ = fs::remove_dir_all(&dir);
}
