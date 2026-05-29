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
