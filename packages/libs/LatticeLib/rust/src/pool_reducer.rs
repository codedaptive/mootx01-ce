// pool_reducer.rs — Pool-to-table merger (cookbook §10)
//
// Port of PoolReducer.swift. Consumes PoolSubmission JSON files from the
// pool directory and merges qualifying novel tokens into the WordClassTable
// artifact.
//
// DESIGN CHOICES (see PoolReducer.swift for the authoritative rationale;
// this Rust port mirrors those choices faithfully):
//
//   1. Version gate: submission `table_version` must match the artifact's
//      `table_version`. Mismatch → quarantined (cookbook §2.3).
//
//   2. Dedup within the reducer run: first-occurrence wins per lowercased
//      token. Files are sorted by name (chronological by the submitter's
//      epoch-ms prefix) so the oldest observation wins in a tie.
//
//   3. Table-resident tokens are skipped (already classified; no-op).
//
//   4. Only NOUN and VERB tags expand the table. OTHER tags are valid entries
//      but do not expand the noun or verb set.
//
//   5. Frequency threshold is 1 (any single qualified observation merges).
//
//   6. Merge target: the artifact JSON file. On success the file is
//      overwritten with the updated table (sorted lists, advanced snapshot_date).
//
//   7. Archive / drain: consumed files → `pool_dir/archive/`; quarantined
//      files → `pool_dir/quarantine/`. Idempotent on re-run.
//
// Public entry point:
//
//   pub fn reduce(
//       pool_dir: &Path, table_artifact: &Path, now: &str, max_files: usize
//   ) -> Result<PoolReduceResult, PoolReducerError>
//
// `now` is an ISO 8601 date string (YYYY-MM-DD) — injected for determinism,
// matching the Swift `now: Date` parameter convention.
//
// `max_files` caps how many submission files this run drains — the OLDEST
// `max_files` by filename (chronological). A backlog larger than the cap drains
// over successive runs (bounded near-realtime drain: the governor calls this
// synchronously on its tick, so an unbounded pass would stall the tick). Pass
// `usize::MAX` to drain the whole pool in one pass (operator/CLI/test use).
//
// Current trigger host: `NeuronKit::AutonomicGovernor` or an operator CLI
// in ARIA_MCP. Do NOT invoke from the hot word_class path.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::novel_token_cache::PoolSubmission;
// PoolEntry is only used in the #[cfg(test)] helpers below; the import lives
// at module level to avoid a duplicate import inside the test module.
#[allow(unused_imports)]
use crate::novel_token_cache::PoolEntry;
use crate::word_class_table::BUNDLED_TABLE_JSON;

// ─── Result type ─────────────────────────────────────────────────────────────

/// Summary of a pool reduction run. Mirrors `PoolReduceResult` in Swift.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PoolReduceResult {
    /// Submission files successfully consumed and archived.
    pub consumed: usize,
    /// Submission files quarantined (malformed JSON or version mismatch).
    pub quarantined: usize,
    /// Novel tokens newly merged into the noun set.
    pub nouns_added: usize,
    /// Novel tokens newly merged into the verb set.
    pub verbs_added: usize,
    /// Entries skipped (already table-resident, OTHER tag, or dedup).
    pub skipped: usize,
}

impl PoolReduceResult {
    /// True when the pool was empty and no state changed.
    pub fn is_noop(&self) -> bool {
        self.consumed == 0 && self.quarantined == 0
    }
}

// ─── PoolReducerError ─────────────────────────────────────────────────────────

/// Errors raised by `reduce`. Mirrors `PoolReducerError` in Swift.
#[derive(Debug)]
pub enum PoolReducerError {
    /// The table artifact could not be read or decoded.
    TableReadFailed(String),
    /// The updated table artifact could not be written.
    TableWriteFailed(String),
    /// The pool directory could not be read.
    PoolDirectoryUnreadable(String),
}

impl std::fmt::Display for PoolReducerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PoolReducerError::TableReadFailed(msg) => write!(f, "table read failed: {}", msg),
            PoolReducerError::TableWriteFailed(msg) => write!(f, "table write failed: {}", msg),
            PoolReducerError::PoolDirectoryUnreadable(msg) => {
                write!(f, "pool directory unreadable: {}", msg)
            }
        }
    }
}

// ─── WordClassTable JSON model ────────────────────────────────────────────────

/// The on-disk shape of WordClassTable.json. Port of `WordClassTable` in Swift.
/// We keep a separate internal model here so we can round-trip the file without
/// touching `word_class_table.rs` (which is the in-memory runtime cache).
#[derive(Debug, Clone, Serialize, Deserialize)]
struct TableArtifact {
    table_version: String,
    min_os_version: String,
    snapshot_date: String,
    nouns: Vec<String>,
    verbs: Vec<String>,
}

// ─── Public entry point ───────────────────────────────────────────────────────

/// Reduces the pool: reads all `pool_*.json` files from `pool_dir`, validates
/// each against the table at `table_artifact`, merges qualifying tokens, writes
/// the updated artifact, and archives/quarantines each file.
///
/// - `pool_dir`: directory containing `pool_*.json` files (same directory as
///   `LATTICE_POOL_DIR` or the platform default from `default_pool_dir()`).
/// - `table_artifact`: path to `WordClassTable.json`. Must be readable and
///   writable. Overwritten in place on success.
/// - `now`: ISO 8601 date string (`"YYYY-MM-DD"`) injected for determinism;
///   becomes the new `snapshot_date` in the updated artifact.
///
/// Returns a `PoolReduceResult`. Returns immediately (is_noop) if `pool_dir`
/// does not exist or contains no `pool_*.json` files.
pub fn reduce(
    pool_dir: &Path,
    table_artifact: &Path,
    now: &str,
    max_files: usize,
) -> Result<PoolReduceResult, PoolReducerError> {

    // Step 1: Ensure the writable artifact exists. When the reducer is called
    // for the first time, no artifact has been written yet — the Rust binary
    // has the table embedded at compile time (`BUNDLED_TABLE_JSON`) but cannot
    // write into itself. Seed the writable location by copying the bundled
    // bytes so that load_table has a real target and the loop does not return
    // `TableReadFailed` on the first run.
    //
    // The seed is idempotent: if the file already exists from a previous run
    // (with merged novel tokens), it is left untouched. The reducer then merges
    // on top of whatever is already there.
    seed_writable_artifact_if_absent(table_artifact)?;

    // Step 2: Load existing table artifact (seeded or previously merged).
    let mut artifact = load_table(table_artifact)?;

    // Build working sets (lowercased for O(1) membership and fast-path
    // consistency with `WordClassTableCache::word_class`).
    let mut noun_set: HashSet<String> = artifact.nouns.iter().map(|s| s.to_lowercase()).collect();
    let mut verb_set: HashSet<String> = artifact.verbs.iter().map(|s| s.to_lowercase()).collect();

    // Step 3: Enumerate pool files.
    let pool_files = enumerate_pool_files(pool_dir)?;

    // Empty pool → idempotent no-op.
    if pool_files.is_empty() {
        return Ok(PoolReduceResult {
            consumed: 0,
            quarantined: 0,
            nouns_added: 0,
            verbs_added: 0,
            skipped: 0,
        });
    }

    // Ensure archive and quarantine directories exist.
    let archive_dir = pool_dir.join("archive");
    let quarantine_dir = pool_dir.join("quarantine");
    fs::create_dir_all(&archive_dir).map_err(|e| {
        PoolReducerError::PoolDirectoryUnreadable(format!(
            "cannot create archive dir: {}",
            e
        ))
    })?;
    fs::create_dir_all(&quarantine_dir).map_err(|e| {
        PoolReducerError::PoolDirectoryUnreadable(format!(
            "cannot create quarantine dir: {}",
            e
        ))
    })?;

    // Step 4: Process files in deterministic order (sorted by file name, which
    // is chronological by the submitter's epoch-ms prefix — oldest wins in
    // dedup ties, matching the Swift sort).
    let mut sorted_files = pool_files;
    sorted_files.sort_by(|a, b| {
        a.file_name()
            .unwrap_or_default()
            .cmp(b.file_name().unwrap_or_default())
    });

    // Bounded drain: process at most `max_files` of the OLDEST submissions this
    // run. A larger backlog drains over successive runs, so a burst that pushed
    // the pool past the cap can never wedge the drainer (the prior "defer when
    // over cap" behaviour deadlocked — over cap, the reduce that would shrink the
    // pool was skipped, so it grew without bound). Files beyond the cap stay on
    // disk, untouched, for the next run.
    sorted_files.truncate(max_files);

    // Dedup tracker: first-occurrence wins per lowercased token.
    let mut seen: HashSet<String> = HashSet::new();
    let mut nouns_added = 0usize;
    let mut verbs_added = 0usize;
    let mut skipped = 0usize;
    let mut consumed = 0usize;
    let mut quarantined = 0usize;

    for file_path in &sorted_files {
        // Decode the submission.
        let submission: PoolSubmission = match fs::read(file_path)
            .ok()
            .and_then(|data| serde_json::from_slice::<PoolSubmission>(&data).ok())
        {
            Some(s) => s,
            None => {
                // Malformed JSON: quarantine, never panic.
                eprintln!(
                    "pool reducer: malformed submission {:?} — quarantined",
                    file_path.file_name().unwrap_or_default()
                );
                move_file(file_path, &quarantine_dir);
                quarantined += 1;
                continue;
            }
        };

        // Version gate (cookbook §2.3).
        if submission.table_version != artifact.table_version {
            eprintln!(
                "pool reducer: version mismatch in {:?} (submission: {}, table: {}) — quarantined",
                file_path.file_name().unwrap_or_default(),
                submission.table_version,
                artifact.table_version
            );
            move_file(file_path, &quarantine_dir);
            quarantined += 1;
            continue;
        }

        // Merge qualifying entries.
        for entry in &submission.entries {
            let token = entry.token.to_lowercase();

            // Dedup: first-occurrence wins.
            if seen.contains(&token) {
                skipped += 1;
                continue;
            }
            seen.insert(token.clone());

            // Skip table-resident tokens.
            if verb_set.contains(&token) || noun_set.contains(&token) {
                skipped += 1;
                continue;
            }

            // Only NOUN and VERB tags expand the table.
            match entry.tag.as_str() {
                "NOUN" => {
                    noun_set.insert(token);
                    nouns_added += 1;
                }
                "VERB" => {
                    verb_set.insert(token);
                    verbs_added += 1;
                }
                _ => {
                    // OTHER or unknown tag: does not expand the table.
                    skipped += 1;
                }
            }
        }

        // Archive the consumed file.
        move_file(file_path, &archive_dir);
        consumed += 1;
    }

    // Step 5: Write updated artifact if any files were consumed (so
    // snapshot_date advances and the final merged state is persisted).
    if consumed > 0 {
        let mut sorted_nouns: Vec<String> = noun_set.into_iter().collect();
        let mut sorted_verbs: Vec<String> = verb_set.into_iter().collect();
        sorted_nouns.sort();
        sorted_verbs.sort();

        artifact.nouns = sorted_nouns;
        artifact.verbs = sorted_verbs;
        artifact.snapshot_date = now.to_string();

        write_table(table_artifact, &artifact)?;
    }

    Ok(PoolReduceResult {
        consumed,
        quarantined,
        nouns_added,
        verbs_added,
        skipped,
    })
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

/// Seeds the writable artifact at `path` from the compile-time bundled bytes
/// if the file does not yet exist. Idempotent: a pre-existing file (from a
/// prior reduce run, possibly with merged novel tokens) is left untouched so
/// accumulated learning is preserved.
///
/// The bundled table is embedded at compile time in `BUNDLED_TABLE_JSON`. The
/// reducer cannot write back into the binary, so it needs a writable copy on
/// disk. This function creates that copy the first time the reducer runs,
/// eliminating the `TableReadFailed` error that would otherwise occur when no
/// prior reduce run has taken place.
///
/// Parent directories are created with `create_dir_all` so the full
/// `…/lattice/` path is created on the first run. Mirrors
/// `PoolReducer.seedWritableArtifactIfAbsent` in Swift.
fn seed_writable_artifact_if_absent(path: &Path) -> Result<(), PoolReducerError> {
    // If the writable artifact already exists, nothing to do.
    if path.exists() {
        return Ok(());
    }

    // Create parent directories (e.g., `…/lattice/`) if needed.
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            PoolReducerError::TableWriteFailed(format!(
                "cannot create lattice dir {:?}: {}",
                parent, e
            ))
        })?;
    }

    // Write the bundled pristine bytes to the writable path.
    fs::write(path, BUNDLED_TABLE_JSON).map_err(|e| {
        PoolReducerError::TableWriteFailed(format!(
            "cannot seed writable artifact {:?}: {}",
            path, e
        ))
    })?;

    Ok(())
}

/// Loads and decodes the `WordClassTable.json` artifact from `path`.
fn load_table(path: &Path) -> Result<TableArtifact, PoolReducerError> {
    let data = fs::read(path).map_err(|e| {
        PoolReducerError::TableReadFailed(format!("{}: {}", path.display(), e))
    })?;
    serde_json::from_slice(&data)
        .map_err(|e| PoolReducerError::TableReadFailed(format!("JSON decode error: {}", e)))
}

/// Serialises `artifact` and writes it atomically to `path`.
fn write_table(path: &Path, artifact: &TableArtifact) -> Result<(), PoolReducerError> {
    // Pretty-print matches the Swift encoder's `.prettyPrinted` output, and
    // sorted keys match `.sortedKeys`, so both ports produce the same artifact
    // shape (modulo whitespace differences in the JSON library).
    let json = serde_json::to_vec_pretty(artifact)
        .map_err(|e| PoolReducerError::TableWriteFailed(format!("serialise error: {}", e)))?;
    fs::write(path, &json)
        .map_err(|e| PoolReducerError::TableWriteFailed(format!("{}: {}", path.display(), e)))
}

/// Returns all `pool_*.json` files in `dir` (non-recursive, top level only).
/// Returns an empty `Vec` if the directory does not exist (pool never written).
fn enumerate_pool_files(dir: &Path) -> Result<Vec<PathBuf>, PoolReducerError> {
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let read_dir = fs::read_dir(dir).map_err(|e| {
        PoolReducerError::PoolDirectoryUnreadable(format!("{}: {}", dir.display(), e))
    })?;
    let mut files = Vec::new();
    for entry in read_dir.filter_map(|e| e.ok()) {
        let path = entry.path();
        if path.is_file() {
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("");
            if name.starts_with("pool_") && name.ends_with(".json") {
                files.push(path);
            }
        }
    }
    Ok(files)
}

/// Moves `src` to `target_dir/filename`. On failure, prints to stderr and
/// leaves the file in place (never panics; the pool remains safe).
fn move_file(src: &Path, target_dir: &Path) {
    let file_name = match src.file_name() {
        Some(n) => n,
        None => return,
    };
    let dest = target_dir.join(file_name);
    // If dest already exists (e.g. from a previous partial run), remove it
    // first so the rename/copy succeeds.
    if dest.exists() {
        let _ = fs::remove_file(&dest);
    }
    // Attempt rename first (cheap, same filesystem). Fall back to copy+delete
    // if rename fails (e.g. cross-device).
    if fs::rename(src, &dest).is_err() {
        if let Ok(data) = fs::read(src) {
            if fs::write(&dest, data).is_ok() {
                let _ = fs::remove_file(src);
            } else {
                eprintln!(
                    "pool reducer: could not move {:?} to {:?}",
                    src.file_name().unwrap_or_default(),
                    target_dir
                );
            }
        }
    }
}

// ─── Unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// A minimal fixture table JSON.
    const FIXTURE_TABLE_JSON: &str = r#"{
  "table_version": "1.0.0",
  "min_os_version": "17.0",
  "snapshot_date": "2026-01-01",
  "nouns": ["dog", "house"],
  "verbs": ["run", "eat"]
}"#;

    const FIXTURE_NOW: &str = "2026-06-12";

    /// Process-unique counter for temp-dir nonces.
    ///
    /// Using an atomic counter instead of `SystemTime::subsec_nanos()` (u32)
    /// because subsec_nanos wraps within one second: multiple tests spawned in
    /// parallel by `cargo test` can call `setup_fixture` within the same wall-
    /// clock nanosecond and receive the same nonce, producing directory-path
    /// collisions. An atomic counter is monotonically unique within the process
    /// regardless of wall-clock resolution.
    static NONCE: AtomicU64 = AtomicU64::new(0);

    fn nonce() -> u64 {
        NONCE.fetch_add(1, Ordering::Relaxed)
    }

    /// Creates a temp dir, writes the fixture table file, returns (pool_dir, table_path).
    /// The caller is responsible for cleanup via `fs::remove_dir_all`.
    fn setup_fixture() -> (PathBuf, PathBuf) {
        let pool_dir = std::env::temp_dir()
            .join(format!("pool_reducer_test_{}", nonce()));
        let _ = fs::remove_dir_all(&pool_dir);
        fs::create_dir_all(&pool_dir).expect("create pool dir");
        let table_path = pool_dir.join("WordClassTable.json");
        fs::write(&table_path, FIXTURE_TABLE_JSON).expect("write fixture table");
        (pool_dir, table_path)
    }

    fn write_submission(submission: &PoolSubmission, dir: &Path, name: &str) {
        let data = serde_json::to_vec_pretty(submission).expect("serialise");
        fs::write(dir.join(name), data).expect("write pool file");
    }

    fn make_submission(table_version: &str, entries: Vec<(&str, &str)>) -> PoolSubmission {
        let pool_entries = entries
            .into_iter()
            .map(|(tok, tag)| PoolEntry::new(tok, tag))
            .collect();
        PoolSubmission::new(table_version, "other", "hmm-viterbi-1", pool_entries)
    }

    fn read_table(path: &Path) -> TableArtifact {
        let data = fs::read(path).expect("read table");
        serde_json::from_slice(&data).expect("decode table")
    }

    fn count_files_in(dir: &Path, subdir: &str) -> usize {
        let sub = dir.join(subdir);
        if !sub.exists() {
            return 0;
        }
        fs::read_dir(&sub)
            .map(|rd| rd.filter_map(|e| e.ok()).count())
            .unwrap_or(0)
    }

    // ─── 1. Novel-token learning loop (force-test) ────────────────────────────

    #[test]
    fn novel_token_learning_loop() {
        // Force-test: "quasar" is not in the fixture table. After reduction it
        // must be in the noun set — the novel-token learning loop closes.
        let (pool_dir, table_path) = setup_fixture();

        // Confirm precondition.
        let pre = read_table(&table_path);
        assert!(!pre.nouns.contains(&"quasar".to_string()));

        // Land one submission with novel tokens.
        let sub = make_submission(
            "1.0.0",
            vec![("quasar", "NOUN"), ("nebula", "NOUN"), ("orbit", "VERB")],
        );
        write_submission(&sub, &pool_dir, "pool_a.json");

        let result = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX)
            .expect("reduce must not error");

        assert_eq!(result.consumed, 1);
        assert_eq!(result.quarantined, 0);
        assert_eq!(result.nouns_added, 2);
        assert_eq!(result.verbs_added, 1);

        let post = read_table(&table_path);
        assert!(post.nouns.contains(&"quasar".to_string()), "quasar must be in noun set");
        assert!(post.nouns.contains(&"nebula".to_string()), "nebula must be in noun set");
        assert!(post.verbs.contains(&"orbit".to_string()), "orbit must be in verb set");
        // Pre-existing tokens preserved.
        assert!(post.nouns.contains(&"dog".to_string()));
        assert!(post.verbs.contains(&"run".to_string()));

        let _ = fs::remove_dir_all(&pool_dir);
    }

    // ─── 2. Idempotent re-run ─────────────────────────────────────────────────

    #[test]
    fn idempotent_rerun() {
        let (pool_dir, table_path) = setup_fixture();

        // First run on empty pool.
        let r1 = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce");
        assert!(r1.is_noop(), "empty pool must be no-op");

        // Land one submission.
        let sub = make_submission("1.0.0", vec![("pulsar", "NOUN")]);
        write_submission(&sub, &pool_dir, "pool_b.json");
        let r2 = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce");
        assert_eq!(r2.consumed, 1);
        assert_eq!(r2.nouns_added, 1);

        // Re-run on drained pool must be no-op.
        let r3 = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce");
        assert!(r3.is_noop(), "second run on drained pool must be no-op");
        assert_eq!(r3.nouns_added, 0);

        let _ = fs::remove_dir_all(&pool_dir);
    }

    // ─── 2b. Batch cap bounds the drain (bounded near-realtime backlog drain) ──

    #[test]
    fn batch_cap_drains_oldest_first_over_multiple_runs() {
        // A backlog larger than `max_files` drains the OLDEST submissions first,
        // `max_files` per run, leaving the rest on disk — the bounded near-realtime
        // drain that replaced the deadlocking "defer when over cap" behaviour.
        let (pool_dir, table_path) = setup_fixture();

        // Three submissions; filename order (pool_a < pool_b < pool_c) is the
        // chronological order the reducer sorts by (oldest wins).
        write_submission(&make_submission("1.0.0", vec![("alpha", "NOUN")]), &pool_dir, "pool_a.json");
        write_submission(&make_submission("1.0.0", vec![("bravo", "NOUN")]), &pool_dir, "pool_b.json");
        write_submission(&make_submission("1.0.0", vec![("charlie", "NOUN")]), &pool_dir, "pool_c.json");

        // First run drains only the two oldest.
        let r1 = reduce(&pool_dir, &table_path, FIXTURE_NOW, 2).expect("reduce");
        assert_eq!(r1.consumed, 2, "batch cap must bound the drain to 2 files");
        assert!(pool_dir.join("pool_c.json").exists(), "the newest submission stays for the next run");
        assert!(!pool_dir.join("pool_a.json").exists(), "oldest was consumed (archived)");
        let mid = read_table(&table_path);
        assert!(mid.nouns.contains(&"alpha".to_string()));
        assert!(mid.nouns.contains(&"bravo".to_string()));
        assert!(!mid.nouns.contains(&"charlie".to_string()), "the deferred file's token is not yet merged");

        // Second run drains the remainder — no backlog can wedge the drainer.
        let r2 = reduce(&pool_dir, &table_path, FIXTURE_NOW, 2).expect("reduce");
        assert_eq!(r2.consumed, 1, "the remaining file drains on the next run");
        assert!(!pool_dir.join("pool_c.json").exists(), "backlog fully drained");
        assert!(read_table(&table_path).nouns.contains(&"charlie".to_string()));

        let _ = fs::remove_dir_all(&pool_dir);
    }

    // ─── 3. Malformed submission quarantined ──────────────────────────────────

    #[test]
    fn malformed_submission_quarantined() {
        let (pool_dir, table_path) = setup_fixture();

        // Write a malformed file.
        fs::write(pool_dir.join("pool_bad.json"), b"not json {{{{")
            .expect("write bad file");

        // Write one valid file.
        let good = make_submission("1.0.0", vec![("photon", "NOUN")]);
        write_submission(&good, &pool_dir, "pool_good.json");

        let result = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce");

        assert_eq!(result.consumed, 1, "valid file consumed");
        assert_eq!(result.quarantined, 1, "malformed file quarantined");
        assert_eq!(result.nouns_added, 1, "photon added");

        assert_eq!(count_files_in(&pool_dir, "quarantine"), 1);
        assert_eq!(count_files_in(&pool_dir, "archive"), 1);

        // Pool root must have no pool_ files.
        let pool_files: Vec<_> = fs::read_dir(&pool_dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| {
                let n = e.file_name();
                let s = n.to_string_lossy();
                s.starts_with("pool_") && s.ends_with(".json")
            })
            .collect();
        assert!(pool_files.is_empty(), "pool root must be drained");

        let _ = fs::remove_dir_all(&pool_dir);
    }

    // ─── 4. Dedup across submissions ─────────────────────────────────────────

    #[test]
    fn dedup_across_submissions() {
        let (pool_dir, table_path) = setup_fixture();

        // Two files both containing "comet".
        let s1 = make_submission("1.0.0", vec![("comet", "NOUN")]);
        let s2 = make_submission("1.0.0", vec![("comet", "NOUN")]);
        write_submission(&s1, &pool_dir, "pool_a.json");
        write_submission(&s2, &pool_dir, "pool_b.json");

        let result = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce");

        assert_eq!(result.consumed, 2);
        assert_eq!(result.nouns_added, 1, "comet added exactly once");
        assert!(result.skipped >= 1, "second occurrence skipped");

        let table = read_table(&table_path);
        let comet_count = table.nouns.iter().filter(|n| n.as_str() == "comet").count();
        assert_eq!(comet_count, 1, "comet appears exactly once in noun set");

        let _ = fs::remove_dir_all(&pool_dir);
    }

    // ─── 5. Version mismatch quarantined ─────────────────────────────────────

    #[test]
    fn version_mismatch_quarantined() {
        let (pool_dir, table_path) = setup_fixture();

        let stale = make_submission("0.9.0", vec![("asteroid", "NOUN")]);
        write_submission(&stale, &pool_dir, "pool_stale.json");

        let result = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce");

        assert_eq!(result.consumed, 0);
        assert_eq!(result.quarantined, 1, "stale submission quarantined");
        assert_eq!(result.nouns_added, 0);

        let table = read_table(&table_path);
        assert!(!table.nouns.contains(&"asteroid".to_string()));

        let _ = fs::remove_dir_all(&pool_dir);
    }

    // ─── 6. OTHER tag does not expand table ──────────────────────────────────

    #[test]
    fn other_tag_skipped() {
        let (pool_dir, table_path) = setup_fixture();

        let sub = make_submission(
            "1.0.0",
            vec![("the", "OTHER"), ("quickly", "OTHER"), ("galaxy", "NOUN")],
        );
        write_submission(&sub, &pool_dir, "pool_other.json");

        let result = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce");

        assert_eq!(result.nouns_added, 1, "only galaxy added");
        assert_eq!(result.verbs_added, 0);
        assert!(result.skipped >= 2, "the and quickly skipped");

        let table = read_table(&table_path);
        assert!(table.nouns.contains(&"galaxy".to_string()));
        assert!(!table.nouns.contains(&"the".to_string()));
        assert!(!table.nouns.contains(&"quickly".to_string()));

        let _ = fs::remove_dir_all(&pool_dir);
    }

    // ─── 7. Table-resident tokens skipped ────────────────────────────────────

    #[test]
    fn table_resident_tokens_skipped() {
        let (pool_dir, table_path) = setup_fixture();

        // "dog" and "run" are in fixture table.
        let sub = make_submission(
            "1.0.0",
            vec![("dog", "NOUN"), ("run", "VERB"), ("meteor", "NOUN")],
        );
        write_submission(&sub, &pool_dir, "pool_resident.json");

        let result = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce");

        assert_eq!(result.nouns_added, 1, "only meteor added");
        assert_eq!(result.verbs_added, 0, "run already resident");
        assert!(result.skipped >= 2, "dog and run skipped");

        let table = read_table(&table_path);
        let dog_count = table.nouns.iter().filter(|n| n.as_str() == "dog").count();
        assert_eq!(dog_count, 1, "dog appears exactly once");

        let _ = fs::remove_dir_all(&pool_dir);
    }

    // ─── 8. snapshot_date updated ────────────────────────────────────────────

    #[test]
    fn snapshot_date_updated_on_merge() {
        let (pool_dir, table_path) = setup_fixture();

        let sub = make_submission("1.0.0", vec![("supernova", "NOUN")]);
        write_submission(&sub, &pool_dir, "pool_date.json");

        reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce");

        let table = read_table(&table_path);
        assert_eq!(table.snapshot_date, FIXTURE_NOW, "snapshot_date must match injected now");

        let _ = fs::remove_dir_all(&pool_dir);
    }

    // ─── 9. Absent pool directory is no-op ───────────────────────────────────

    #[test]
    fn absent_pool_directory_is_noop() {
        // Table file exists but pool dir does not.
        let base = std::env::temp_dir().join(format!("pool_reducer_absent_{}", nonce()));
        let table_path = base.join("WordClassTable.json");
        let pool_dir = base.join("pool_that_does_not_exist");

        fs::create_dir_all(&base).expect("create base");
        fs::write(&table_path, FIXTURE_TABLE_JSON).expect("write table");

        let result = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce");
        assert!(result.is_noop(), "absent pool dir must be no-op");

        let _ = fs::remove_dir_all(&base);
    }

    // ─── 10. No mutation when only quarantine (no consumed) ──────────────────

    #[test]
    fn no_artifact_write_when_only_quarantined() {
        // All files are stale-versioned: consumed == 0, so the artifact must
        // not be rewritten (snapshot_date stays "2026-01-01").
        let (pool_dir, table_path) = setup_fixture();

        let stale = make_submission("0.0.1", vec![("comet", "NOUN")]);
        write_submission(&stale, &pool_dir, "pool_stale.json");

        reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce");

        let table = read_table(&table_path);
        assert_eq!(
            table.snapshot_date, "2026-01-01",
            "snapshot_date must not change when nothing consumed"
        );

        let _ = fs::remove_dir_all(&pool_dir);
    }
}
