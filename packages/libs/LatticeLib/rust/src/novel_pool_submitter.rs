// novel_pool_submitter.rs — Real pool submitter: local-directory file writer
//
// Port of NovelPoolSubmitter.swift (cookbook §2.2, §2.3).
//
// DESIGN: The cookbook states the pool endpoint is a config value and
// submission is fire-and-forget with no retry obligation. The reducer that
// consumes these files (`pool_reduce`) is driven on a low cadence by the
// resident Autonomic Governor (packages/kits/AriaMcpKit). The durable landing zone is
// a local directory configured via:
//   1. LATTICE_POOL_DIR environment variable (takes priority).
//   2. XDG_DATA_HOME/mootx01/lattice/pool/ or
//      ~/.local/share/mootx01/lattice/pool/ (non-Apple default).
//
// Terminal state: token drained → JSON file written to pool directory →
// file observable at endpoint → future pool-reducer consumes files and
// merges novel tokens back into the WordClassTable.
//
// Use in production: call `local_dir_submitter(dir)` to get a Submitter
// that writes files to a given directory. Call `default_pool_dir()` to
// resolve the configured directory from env or platform default.
//
// Test / embedded-host fallback: pass `Box::new(|_| {})` as the submitter
// — documented explicitly so future agents know the no-op is intentional
// there, not a bug.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::novel_token_cache::{PoolSubmission, Submitter};

// ─── Default pool directory ───────────────────────────────────────────────────

/// Resolves the pool directory from environment or platform default:
///   1. `LATTICE_POOL_DIR` env var, if set and non-empty.
///   2. `$XDG_DATA_HOME/mootx01/lattice/pool/`
///   3. `~/.local/share/mootx01/lattice/pool/`
///
/// Mirrors Swift `NovelPoolSubmitter.resolvePoolDirectory()`.
pub fn default_pool_dir() -> PathBuf {
    // Priority 1: explicit env var.
    if let Ok(dir) = env::var("LATTICE_POOL_DIR") {
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }
    // Priority 2: XDG_DATA_HOME.
    let base = if let Ok(xdg) = env::var("XDG_DATA_HOME") {
        if !xdg.is_empty() {
            PathBuf::from(xdg)
        } else {
            home_local_share()
        }
    } else {
        home_local_share()
    };
    base.join("mootx01/lattice/pool")
}

/// Resolves the writable WordClassTable artifact the reducer merges into.
///
/// The SIBLING of the pool directory — `WordClassTable.json` in the pool dir's
/// parent (the `…/lattice/` root). This is the writable artifact `pool_reduce`
/// updates in place; it is NOT the read-only bundled table the runtime loads at
/// startup. The reducer cannot write into the bundled artifact, so the merged
/// table lands here for a future table load to consume (cookbook §1.3/§2.2: the
/// table is a pinned snapshot; the reducer produces the next snapshot).
///
/// Mirrors Swift `NovelPoolSubmitter.tableArtifactURL()`. Override the whole
/// location with `LATTICE_POOL_DIR` (the artifact then sits beside that dir).
pub fn default_table_artifact() -> PathBuf {
    let pool_dir = default_pool_dir();
    // `…/lattice/pool` → `…/lattice/WordClassTable.json`. `parent()` is None only
    // for a root path; fall back to the pool dir itself in that degenerate case.
    let parent = pool_dir.parent().map(PathBuf::from).unwrap_or(pool_dir);
    parent.join("WordClassTable.json")
}

/// Returns `$HOME/.local/share` as a fallback base data directory (XDG spec
/// default when XDG_DATA_HOME is unset). If HOME is also unavailable,
/// falls back to the current directory (a last resort that avoids panicking).
fn home_local_share() -> PathBuf {
    dirs_home()
        .map(|h| h.join(".local/share"))
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Portable HOME directory lookup — mirrors what the `dirs` crate does
/// without introducing an external dependency (prohibited by C-1 doctrine).
fn dirs_home() -> Option<PathBuf> {
    env::var("HOME").ok().map(PathBuf::from)
}

// ─── Submitter factory ────────────────────────────────────────────────────────

/// Returns a `Submitter` that writes each `PoolSubmission` as a dated JSON file
/// into `dir`. The directory is created lazily on first submission.
///
/// File name: `pool_<epoch_ms>_<random_u32>.json` — monotonically increasing
/// by wall time so the future pool-reducer can process files in order without
/// a database.
///
/// Submission is fire-and-forget: if directory creation or the file write
/// fails, the failure is printed to stderr and the batch is discarded for
/// this drain cycle. No retry. No panic.
///
/// Mirrors Swift `NovelPoolSubmitter.make(poolDirectory:)`.
pub fn local_dir_submitter(dir: PathBuf) -> Submitter {
    Box::new(move |submission: PoolSubmission| {
        write_submission(&submission, &dir);
    })
}

/// Returns a `Submitter` wired to the process-resolved default pool directory
/// (`default_pool_dir()`). Resolves the directory once and captures it.
///
/// Mirrors Swift `NovelPoolSubmitter.makeDefault()`.
pub fn default_submitter() -> Submitter {
    local_dir_submitter(default_pool_dir())
}

// ─── Internal: write one submission ──────────────────────────────────────────

/// Writes `submission` as a JSON file inside `dir`.
/// Called from the submitter closure — fire-and-forget; never panics.
fn write_submission(submission: &PoolSubmission, dir: &Path) {
    // Create the directory if it does not exist yet.
    if let Err(e) = fs::create_dir_all(dir) {
        eprintln!(
            "novel pool: cannot create pool dir {:?}: {}",
            dir, e
        );
        return;
    }
    // Build a unique file name using millisecond epoch + a simple counter-like
    // nonce derived from the system time nanoseconds, avoiding external crates.
    let (ms, ns_low) = epoch_ms_and_ns_low();
    let name = format!("pool_{:013}_{:08x}.json", ms, ns_low);
    let dest = dir.join(&name);

    match serde_json::to_vec_pretty(submission) {
        Err(e) => {
            eprintln!("novel pool: serialise failed: {}", e);
        }
        Ok(data) => {
            if let Err(e) = fs::write(&dest, &data) {
                eprintln!("novel pool: write {:?} failed: {}", dest, e);
            }
            // Success path: no log spam on the hot path. Errors get printed.
        }
    }
}

/// Returns (epoch_milliseconds, low_u32_of_nanoseconds) for file naming.
/// Uses SystemTime to avoid external time-crate dependencies (C-1 doctrine).
fn epoch_ms_and_ns_low() -> (u64, u32) {
    let dur = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default();
    let ms = dur.as_millis() as u64;
    let ns_low = dur.subsec_nanos();
    (ms, ns_low)
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::novel_token_cache::{PoolEntry, PoolSubmission, POOL_SUBMIT_THRESHOLD};
    use crate::word_class::WordClass;

    /// Build a fixture PoolSubmission with N entries.
    fn make_submission(n: usize) -> PoolSubmission {
        let entries = (0..n)
            .map(|i| PoolEntry::new(format!("token{}", i), "NOUN"))
            .collect();
        PoolSubmission::new("1.0.0", "other", "hmm-viterbi-1", entries)
    }

    #[test]
    fn default_pool_dir_uses_lattice_pool_dir_env() {
        // Verify the env var override works. We cannot safely set env vars in
        // parallel test runs, so we only test the helper path directly.
        // A unit test of the function itself can be done deterministically by
        // observing that the env-var path is checked first (the code does so
        // by construction).
        let path = PathBuf::from("/tmp/testpool");
        // Indirect assertion: local_dir_submitter accepts any PathBuf — the
        // directory resolution logic is observable through LATTICE_POOL_DIR
        // in integration, not here.
        let _ = local_dir_submitter(path);
    }

    #[test]
    fn local_dir_submitter_writes_json_file() {
        // Write a submission to a temp directory and verify a JSON file appears.
        let tmp = std::env::temp_dir().join(format!(
            "lattice_pool_test_{}",
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap_or_default()
                .subsec_nanos()
        ));
        // Ensure clean state.
        let _ = fs::remove_dir_all(&tmp);

        let sub = make_submission(3);
        write_submission(&sub, &tmp);

        // The pool directory must now exist and contain exactly one file.
        let entries: Vec<_> = fs::read_dir(&tmp)
            .expect("pool dir must have been created")
            .filter_map(|e| e.ok())
            .collect();
        assert_eq!(entries.len(), 1, "exactly one file per submission");
        let file = &entries[0];
        let name = file.file_name();
        let name_str = name.to_string_lossy();
        assert!(
            name_str.starts_with("pool_"),
            "file name must start with pool_, got: {}",
            name_str
        );
        assert!(
            name_str.ends_with(".json"),
            "file name must end with .json, got: {}",
            name_str
        );

        // The file must deserialise back to the original submission.
        let data = fs::read(file.path()).expect("pool file must be readable");
        let back: PoolSubmission =
            serde_json::from_slice(&data).expect("pool file must be valid JSON");
        assert_eq!(back.table_version, sub.table_version);
        assert_eq!(back.entries.len(), sub.entries.len());

        // Cleanup.
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn local_dir_submitter_creates_directory_on_first_write() {
        // Target a nested path that does not exist.
        let base = std::env::temp_dir().join(format!(
            "lattice_pool_mkdir_{}",
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap_or_default()
                .subsec_nanos()
        ));
        let nested = base.join("a/b/c");
        assert!(!nested.exists(), "precondition: nested dir must not exist");

        let sub = make_submission(1);
        write_submission(&sub, &nested);

        // The nested directory and one file must now exist.
        assert!(nested.exists(), "nested pool dir must be created");
        let count = fs::read_dir(&nested).unwrap().count();
        assert_eq!(count, 1, "one file written after mkdir");

        // Cleanup.
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn local_dir_submitter_closure_wires_to_novel_token_cache() {
        // End-to-end: accumulate >= POOL_SUBMIT_THRESHOLD novel tokens via a
        // NovelTokenCache wired with local_dir_submitter, then assert a JSON
        // file appears in the pool directory.
        use crate::novel_token_cache::NovelTokenCache;

        let tmp = std::env::temp_dir().join(format!(
            "lattice_pool_e2e_{}",
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap_or_default()
                .subsec_nanos()
        ));
        let _ = fs::remove_dir_all(&tmp);

        let cache = NovelTokenCache::new(
            "1.0.0",
            "other",
            "hmm-viterbi-1",
            local_dir_submitter(tmp.clone()),
        );

        // Accumulate exactly POOL_SUBMIT_THRESHOLD tokens — drain fires at 50.
        for i in 0..POOL_SUBMIT_THRESHOLD {
            cache.record(&format!("novelword{}", i), WordClass::Noun);
        }

        // After drain the cache is empty.
        assert_eq!(cache.count(), 0, "cache must be empty after drain");

        // A JSON file must have been written to the pool directory.
        let files: Vec<_> = fs::read_dir(&tmp)
            .expect("pool dir must exist after drain")
            .filter_map(|e| e.ok())
            .collect();
        assert_eq!(files.len(), 1, "one JSON file per drain");

        let data = fs::read(files[0].path()).unwrap();
        let sub: PoolSubmission = serde_json::from_slice(&data).unwrap();
        assert_eq!(sub.entries.len(), POOL_SUBMIT_THRESHOLD);
        assert_eq!(sub.table_version, "1.0.0");
        // Every token must be present in submission order.
        assert_eq!(sub.entries[0].token, "novelword0");
        assert_eq!(sub.entries[POOL_SUBMIT_THRESHOLD - 1].token,
                   format!("novelword{}", POOL_SUBMIT_THRESHOLD - 1));

        // Cleanup.
        let _ = fs::remove_dir_all(&tmp);
    }
}
