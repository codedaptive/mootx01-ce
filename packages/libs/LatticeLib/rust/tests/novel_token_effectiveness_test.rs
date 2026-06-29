// novel_token_effectiveness_test.rs — Force-tests for novel-token learning
//
// Port of NovelTokenEffectivenessTests.swift. Proves the novel-token learning
// loop is EFFECTIVE end-to-end (cookbook §1.3/§2.2/§10).
//
// LOOP EDGES:
//
//   WRITE EDGE: pool submission JSON written directly via `write_pool_file`
//               (these are force-tests; threshold accumulation via
//               NovelTokenCache is exercised separately) → pool_reduce seeds
//               writable artifact + merges token → artifact updated.
//
//   READ EDGE:  on the NEXT process load, `load_with_precedence` checks the
//               writable artifact first → previously-novel token is table-resident
//               → word_class fast path returns its class.
//
// These tests cover the CROSS-RELOAD read edge: the READ EDGE is exercised by
// calling `load_with_precedence` directly against the writable artifact path
// (simulating a fresh-process load). Live in-session swap is a separate, shipped
// path (`swap_global_table`), covered by live_table_swap_test.rs; the
// cross-reload read tested here is its own still-valid path, not a substitute
// for it.
//
// Force-test contract (mission spec):
//   - novel token absent from bundled table (precondition).
//   - pool submission → reduce → seeds-if-absent + merges + writes artifact.
//   - load_with_precedence on artifact path → token NOW classified (learned).
//   - writable artifact seeded when absent (no TableReadFailed).
//   - bundled fallback when no writable artifact.
//   - idempotent re-reduce.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use lattice_lib::{
    pool_reduce, table_load_with_precedence, BUNDLED_TABLE_JSON,
    novel_token_cache::{PoolEntry, PoolSubmission},
};
use serde::{Deserialize, Serialize};

// ─── Shared fixture table schema ─────────────────────────────────────────────

/// Minimal on-disk representation used by both pool_reducer and these tests.
#[derive(Debug, Serialize, Deserialize)]
struct TableArtifact {
    table_version: String,
    min_os_version: String,
    snapshot_date: String,
    nouns: Vec<String>,
    verbs: Vec<String>,
}

fn read_table(path: &Path) -> TableArtifact {
    let data = fs::read(path).expect("read table");
    serde_json::from_slice(&data).expect("decode table")
}

/// Process-unique counter for temp-dir nonces.
///
/// Using an atomic counter instead of SystemTime nanoseconds because the wall
/// clock resolution is not guaranteed to be sub-nanosecond across all CI
/// targets. An atomic counter is monotonically unique within the process
/// regardless of timer resolution, eliminating any temp-dir collision when
/// tests run in parallel.
static NONCE: AtomicU64 = AtomicU64::new(0);

fn nonce() -> u64 {
    NONCE.fetch_add(1, Ordering::Relaxed)
}

/// Creates a temp directory, writes no table (absent = fresh), returns (pool_dir, artifact_path).
/// Caller must call `fs::remove_dir_all` on the returned base.
fn setup_fresh() -> (PathBuf, PathBuf) {
    let base = std::env::temp_dir().join(format!("lattice_eff_{}", nonce()));
    let _ = fs::remove_dir_all(&base);
    fs::create_dir_all(&base).expect("create base");
    let pool_dir = base.join("pool");
    let artifact_path = base.join("WordClassTable.json");
    (pool_dir, artifact_path)
}

/// Writes a pool submission JSON file to `dir` with the given name.
fn write_pool_file(dir: &Path, name: &str, entries: Vec<(&str, &str)>, table_version: &str) {
    fs::create_dir_all(dir).expect("create pool dir");
    let pool_entries: Vec<PoolEntry> = entries
        .into_iter()
        .map(|(tok, tag)| PoolEntry::new(tok, tag))
        .collect();
    let sub = PoolSubmission::new(table_version, "other", "hmm-viterbi-1", pool_entries);
    let data = serde_json::to_vec_pretty(&sub).expect("serialise submission");
    fs::write(dir.join(name), &data).expect("write pool file");
}

/// Parses the bundled table to get its version string.
fn bundled_table_version() -> String {
    let t: TableArtifact = serde_json::from_slice(BUNDLED_TABLE_JSON).expect("parse bundled");
    t.table_version
}

// ─── Tests ───────────────────────────────────────────────────────────────────

/// 1. End-to-end: novel token learned — submit → reduce → reload → classified
#[test]
fn end_to_end_novel_token_learned() {
    let (pool_dir, artifact_path) = setup_fresh();
    let base = artifact_path.parent().unwrap().to_path_buf();
    defer_cleanup(&base, || {
        // precondition: "quasar" must not be in the bundled table.
        let bundled: TableArtifact = serde_json::from_slice(BUNDLED_TABLE_JSON)
            .expect("parse bundled table");
        assert!(
            !bundled.nouns.contains(&"quasar".to_string()),
            "precondition: quasar absent from bundled nouns"
        );
        assert!(
            !bundled.verbs.contains(&"quasar".to_string()),
            "precondition: quasar absent from bundled verbs"
        );

        // No artifact yet.
        assert!(!artifact_path.exists(), "precondition: no artifact file");

        // Write pool submission containing "quasar" as NOUN.
        let tv = bundled_table_version();
        write_pool_file(
            &pool_dir,
            "pool_e2e_001.json",
            vec![("quasar", "NOUN"), ("nebula", "NOUN"), ("photon", "NOUN")],
            &tv,
        );

        // Reduce: seeds artifact + merges tokens.
        let result = pool_reduce(&pool_dir, &artifact_path, "2026-06-12")
            .expect("pool_reduce must not error");

        assert_eq!(result.consumed, 1, "file consumed");
        assert_eq!(result.quarantined, 0, "no quarantine");
        assert_eq!(result.nouns_added, 3, "quasar + nebula + photon merged");
        assert_eq!(result.verbs_added, 0);

        // Writable artifact must exist after reduce.
        assert!(artifact_path.exists(), "writable artifact must exist after reduce");

        // RELOAD: load with precedence from the artifact path.
        // This simulates a new process calling load_with_precedence at startup.
        let cache = table_load_with_precedence(&artifact_path)
            .expect("load_with_precedence must return a cache");

        // Effectiveness proof: previously-novel tokens are now table-resident.
        assert!(
            cache.noun_set.contains("quasar"),
            "quasar must be classified as noun from merged table (learned)"
        );
        assert!(
            cache.noun_set.contains("nebula"),
            "nebula must be classified as noun from merged table"
        );
        assert!(
            cache.noun_set.contains("photon"),
            "photon must be classified as noun from merged table"
        );

        // Preservation: bundled tokens must still be present.
        for noun in &bundled.nouns {
            assert!(
                cache.noun_set.contains(noun.as_str()),
                "bundled noun '{}' must be preserved in merged table",
                noun
            );
        }
        for verb in &bundled.verbs {
            assert!(
                cache.verb_set.contains(verb.as_str()),
                "bundled verb '{}' must be preserved in merged table",
                verb
            );
        }
    });
}

/// 2. Seed-if-absent: first reduce creates writable artifact from bundled bytes
#[test]
fn seed_if_absent_creates_artifact() {
    let (pool_dir, artifact_path) = setup_fresh();
    let base = artifact_path.parent().unwrap().to_path_buf();
    defer_cleanup(&base, || {
        let tv = bundled_table_version();

        // Pool submission so reduce has something to do.
        write_pool_file(&pool_dir, "pool_seed.json", vec![("magnetar", "NOUN")], &tv);

        // Confirm artifact is absent before reduce.
        assert!(!artifact_path.exists(), "precondition: no artifact before reduce");

        let result = pool_reduce(&pool_dir, &artifact_path, "2026-06-12")
            .expect("reduce must not error (seed-if-absent must succeed)");

        // Must not have returned TableReadFailed.
        assert_eq!(result.consumed, 1, "file consumed after seed");
        assert_eq!(result.nouns_added, 1, "magnetar merged");

        // Artifact must now contain all bundled tokens + magnetar.
        let merged = read_table(&artifact_path);
        assert!(
            merged.nouns.contains(&"magnetar".to_string()),
            "magnetar must be in merged artifact"
        );
        assert_eq!(merged.table_version, tv, "table_version preserved");
    });
}

/// 3. Load precedence: load_with_precedence returns writable artifact when present
#[test]
fn load_precedence_writable_first() {
    let (_, artifact_path) = setup_fresh();
    let base = artifact_path.parent().unwrap().to_path_buf();
    defer_cleanup(&base, || {
        let bundled: TableArtifact = serde_json::from_slice(BUNDLED_TABLE_JSON).unwrap();

        // "xenolith" must not be in the bundled table.
        assert!(
            !bundled.nouns.contains(&"xenolith".to_string()),
            "precondition: xenolith absent from bundled table"
        );

        // Write a mock merged artifact that contains "xenolith".
        let modified = TableArtifact {
            table_version: bundled.table_version.clone(),
            min_os_version: bundled.min_os_version.clone(),
            snapshot_date: "2099-01-01".to_string(),
            nouns: {
                let mut n = bundled.nouns.clone();
                n.push("xenolith".to_string());
                n.sort();
                n
            },
            verbs: bundled.verbs.clone(),
        };
        let data = serde_json::to_vec_pretty(&modified).unwrap();
        fs::write(&artifact_path, &data).expect("write mock artifact");

        // load_with_precedence must return the writable (modified) artifact.
        let cache = table_load_with_precedence(&artifact_path)
            .expect("load_with_precedence must return a cache");

        assert!(
            cache.noun_set.contains("xenolith"),
            "writable artifact's novel token must be present when loaded"
        );
    });
}

/// 4. Bundled fallback: load_with_precedence falls back to bundled when no writable artifact
#[test]
fn load_precedence_falls_back_to_bundled() {
    let (_, artifact_path) = setup_fresh();
    let base = artifact_path.parent().unwrap().to_path_buf();
    defer_cleanup(&base, || {
        // No artifact at this path.
        assert!(!artifact_path.exists(), "precondition: no artifact");

        let cache = table_load_with_precedence(&artifact_path)
            .expect("load_with_precedence must return bundled table when no artifact");

        // Must have the bundled table's contents.
        let bundled: TableArtifact = serde_json::from_slice(BUNDLED_TABLE_JSON).unwrap();
        for noun in &bundled.nouns {
            assert!(
                cache.noun_set.contains(noun.as_str()),
                "bundled noun '{}' must be in fallback cache",
                noun
            );
        }
        for verb in &bundled.verbs {
            assert!(
                cache.verb_set.contains(verb.as_str()),
                "bundled verb '{}' must be in fallback cache",
                verb
            );
        }
    });
}

/// 5. Idempotent re-reduce: drained pool does not corrupt the artifact
#[test]
fn idempotent_re_reduce() {
    let (pool_dir, artifact_path) = setup_fresh();
    let base = artifact_path.parent().unwrap().to_path_buf();
    defer_cleanup(&base, || {
        let tv = bundled_table_version();

        // First reduce: seeds + merges.
        write_pool_file(&pool_dir, "pool_idem.json", vec![("pulsar", "NOUN")], &tv);
        let r1 = pool_reduce(&pool_dir, &artifact_path, "2026-06-12").expect("reduce");
        assert_eq!(r1.consumed, 1, "first reduce: file consumed");

        let after_first = read_table(&artifact_path);
        assert!(after_first.nouns.contains(&"pulsar".to_string()), "pulsar in table");

        // Second reduce on drained pool must be no-op.
        let r2 = pool_reduce(&pool_dir, &artifact_path, "2026-06-12").expect("reduce");
        assert!(r2.is_noop(), "second reduce on drained pool must be no-op");

        // Artifact must still contain prior learning.
        let after_second = read_table(&artifact_path);
        assert!(
            after_second.nouns.contains(&"pulsar".to_string()),
            "pulsar must still be in artifact after re-reduce"
        );
        assert_eq!(
            after_second.nouns.len(),
            after_first.nouns.len(),
            "no tokens added or removed on no-op re-reduce"
        );
    });
}

/// 6. word_class fast-path via pool → reduce → fresh table load → classified
#[test]
fn word_class_via_fresh_table_load() {
    let (pool_dir, artifact_path) = setup_fresh();
    let base = artifact_path.parent().unwrap().to_path_buf();
    defer_cleanup(&base, || {
        let tv = bundled_table_version();

        // "brachiosaurus" is comically unlikely to be in the bundled table.
        let bundled: TableArtifact = serde_json::from_slice(BUNDLED_TABLE_JSON).unwrap();
        assert!(
            !bundled.nouns.contains(&"brachiosaurus".to_string()),
            "precondition: brachiosaurus absent from bundled table"
        );

        // Submit it as a NOUN.
        write_pool_file(
            &pool_dir,
            "pool_wc.json",
            vec![("brachiosaurus", "NOUN")],
            &tv,
        );

        pool_reduce(&pool_dir, &artifact_path, "2026-06-12")
            .expect("reduce must succeed");

        // Simulate NEXT PROCESS LOAD: load merged table via load_with_precedence.
        let cache = table_load_with_precedence(&artifact_path)
            .expect("load_with_precedence must return cache");

        // wordClass logic: verb-first, then noun (matches word_class_table.rs WordClassTableCache::word_class).
        use lattice_lib::WordClass;
        let resolved = if cache.verb_set.contains("brachiosaurus") {
            WordClass::Verb
        } else if cache.noun_set.contains("brachiosaurus") {
            WordClass::Noun
        } else {
            WordClass::Other
        };

        assert_eq!(
            resolved,
            WordClass::Noun,
            "brachiosaurus must resolve to Noun from merged table on reload (learned)"
        );
    });
}

// ─── Defer-cleanup helper ─────────────────────────────────────────────────────

/// Runs `body` and removes `dir` regardless of whether `body` panics.
/// This keeps temp dirs clean even on test failure.
fn defer_cleanup<F: FnOnce() + std::panic::UnwindSafe>(dir: &PathBuf, body: F) {
    let result = std::panic::catch_unwind(body);
    let _ = fs::remove_dir_all(dir);
    if let Err(e) = result {
        std::panic::resume_unwind(e);
    }
}
