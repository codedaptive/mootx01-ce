//! Pool submissions must never be written to a process-relative directory.
//!
//! `default_pool_dir()` returns a `PathBuf::from(".")` sentinel when no trusted
//! per-user base resolves (no `LATTICE_POOL_DIR`, and `HOME` / `LOCALAPPDATA`
//! unavailable — including the macOS Application Support branch). Pool files
//! carry plaintext novel tokens, so treating that sentinel as a usable
//! directory would disclose them into whatever directory the process happens to
//! be running in. The submitter must discard instead.

use lattice_lib::local_dir_submitter;
use lattice_lib::novel_token_cache::PoolSubmission;
use std::path::PathBuf;

fn probe_submission() -> PoolSubmission {
    PoolSubmission {
        table_version: "1.1.0".to_string(),
        platform: "test".to_string(),
        tagger_version: "test".to_string(),
        entries: Vec::new(),
    }
}

#[test]
fn submitter_refuses_a_relative_pool_directory() {
    // A relative directory that does not exist yet: if the guard is absent the
    // submitter creates it under the current working directory.
    let relative = PathBuf::from("pool_guard_probe_b73c");
    let absolute = std::env::current_dir()
        .expect("cwd must resolve")
        .join(&relative);
    let _ = std::fs::remove_dir_all(&absolute);

    let submitter = local_dir_submitter(relative);
    submitter(probe_submission());

    let created = absolute.exists();
    let _ = std::fs::remove_dir_all(&absolute);

    assert!(
        !created,
        "a relative pool directory must be refused, not created under the CWD"
    );
}

#[test]
fn submitter_still_writes_to_an_absolute_pool_directory() {
    let dir = std::env::temp_dir().join("pool_guard_probe_ok_b73c");
    let _ = std::fs::remove_dir_all(&dir);

    let submitter = local_dir_submitter(dir.clone());
    submitter(probe_submission());

    let wrote = std::fs::read_dir(&dir)
        .map(|entries| entries.filter(|e| e.is_ok()).count())
        .unwrap_or(0);
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        wrote > 0,
        "an absolute pool directory must still receive submissions"
    );
}
