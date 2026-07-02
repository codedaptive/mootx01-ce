// pool_reducer_conflict_tests.rs — Integration force-tests for the
// PoolReducer merge-conflict policy (cookbook §10; LATTICELIB_INTERFACE
// "Merge rules" / LWW-style first-occurrence-wins).
//
// These tests assert the FORMAL conflict-resolution policy of the pool
// reducer through the PUBLIC crate API only (`lattice_lib::pool_reducer::reduce`,
// `PoolReduceResult`, `PoolSubmission`, `PoolEntry`). They mirror, case for
// case, the Swift force-tests in PoolReducerTests.swift so both ports assert
// the SAME documented outcomes (Swift/Rust parity).
//
// Policy under test (run-global first-occurrence-wins):
//   - Files are processed in filename-chronological order (lexicographic by
//     file name, which is chronological by the submitter's epoch-ms prefix).
//   - The FIRST occurrence of a lowercased token across the whole run wins;
//     its tag is fixed at that point. Later occurrences (even with a different
//     tag) are skipped duplicates — never double-counted, never re-tagged.
//   - Within a single file, entry order decides first-occurrence.
//   - A token already resident in the bundled/seed table is never reclassified.
//   - Only NOUN/VERB tags expand the table.
//
// The reducer's TableArtifact type is private, so these integration tests
// re-read the on-disk WordClassTable.json as a serde_json::Value to inspect
// the noun/verb sets — the same public artifact WordClassTable::loadBundled
// consumes.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use lattice_lib::novel_token_cache::{PoolEntry, PoolSubmission};
use lattice_lib::pool_reducer::reduce;

// ─── Fixtures / helpers ─────────────────────────────────────────────────────

/// A minimal fixture table JSON — mirrors the Swift `fixtureTableJSON`.
const FIXTURE_TABLE_JSON: &str = r#"{
  "table_version": "1.0.0",
  "min_os_version": "17.0",
  "snapshot_date": "2026-01-01",
  "nouns": ["dog", "house"],
  "verbs": ["run", "eat"]
}"#;

/// Deterministic injected `now` — mirrors the Swift `fixtureNow` (2026-06-12).
const FIXTURE_NOW: &str = "2026-06-12";

/// Unique suffix from SystemTime nanoseconds to keep temp dirs isolated.
fn nonce() -> u128 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

/// Creates a temp dir, writes the fixture table file, returns (pool_dir, table_path).
fn setup_fixture(label: &str) -> (PathBuf, PathBuf) {
    let pool_dir =
        std::env::temp_dir().join(format!("pool_reducer_conflict_{}_{}", label, nonce()));
    let _ = fs::remove_dir_all(&pool_dir);
    fs::create_dir_all(&pool_dir).expect("create pool dir");
    let table_path = pool_dir.join("WordClassTable.json");
    fs::write(&table_path, FIXTURE_TABLE_JSON).expect("write fixture table");
    (pool_dir, table_path)
}

fn write_submission(submission: &PoolSubmission, dir: &Path, name: &str) {
    let data = serde_json::to_vec_pretty(submission).expect("serialise submission");
    fs::write(dir.join(name), data).expect("write pool file");
}

fn make_submission(table_version: &str, entries: Vec<(&str, &str)>) -> PoolSubmission {
    let pool_entries = entries
        .into_iter()
        .map(|(tok, tag)| PoolEntry::new(tok, tag))
        .collect();
    PoolSubmission::new(table_version, "apple", "15.0.0", pool_entries)
}

/// Reads the on-disk artifact and returns its noun list (lowercased strings).
/// The reducer's TableArtifact type is private; we parse the public JSON.
fn read_nouns(path: &Path) -> Vec<String> {
    read_string_array(path, "nouns")
}

fn read_verbs(path: &Path) -> Vec<String> {
    read_string_array(path, "verbs")
}

fn read_string_array(path: &Path, key: &str) -> Vec<String> {
    let data = fs::read(path).expect("read table");
    let value: serde_json::Value = serde_json::from_slice(&data).expect("decode table json");
    value[key]
        .as_array()
        .expect("array")
        .iter()
        .map(|v| v.as_str().expect("string").to_string())
        .collect()
}

// ─── 1. Same token NOUN in earlier file, VERB in later file (cross-file) ─────

#[test]
fn same_token_noun_and_verb_across_files() {
    // Run-global first-occurrence-wins, files processed in filename-chronological
    // order. "spark" is NOUN in the earlier-named file (pool_a) and VERB in the
    // later-named file (pool_b). pool_a sorts before pool_b, so the NOUN
    // occurrence is seen first and wins; the later VERB occurrence is a skipped
    // duplicate. The token is added exactly once and lands only in the noun set.
    let (pool_dir, table_path) = setup_fixture("noun_verb_conflict");

    let file_a = make_submission("1.0.0", vec![("spark", "NOUN")]);
    let file_b = make_submission("1.0.0", vec![("spark", "VERB")]);
    // pool_a < pool_b lexicographically → pool_a processed first.
    write_submission(&file_a, &pool_dir, "pool_a.json");
    write_submission(&file_b, &pool_dir, "pool_b.json");

    let result = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce must not error");

    // Same outcomes as the Swift test (parity).
    assert_eq!(result.consumed, 2, "both files consumed");
    assert_eq!(
        result.nouns_added, 1,
        "spark added exactly once, as a noun (earlier file wins)"
    );
    assert_eq!(
        result.verbs_added, 0,
        "later-file VERB occurrence does not expand the verb set"
    );
    assert_eq!(
        result.skipped, 1,
        "later-file VERB occurrence of spark is a skipped duplicate"
    );

    // Winning tag is pinned: spark in noun set, NOT verb set.
    let nouns = read_nouns(&table_path);
    let verbs = read_verbs(&table_path);
    assert!(
        nouns.contains(&"spark".to_string()),
        "spark must be in the noun set (NOUN tag from pool_a wins)"
    );
    assert!(
        !verbs.contains(&"spark".to_string()),
        "spark must NOT be in the verb set (VERB tag from pool_b loses)"
    );
    // Not double-counted.
    let spark_count = nouns.iter().filter(|n| n.as_str() == "spark").count();
    assert_eq!(spark_count, 1, "spark appears exactly once in the noun set");

    let _ = fs::remove_dir_all(&pool_dir);
}

// ─── 2. Same token twice within one file (intra-file) ────────────────────────

#[test]
fn same_token_twice_in_one_file() {
    // First-occurrence-wins applies within a single file's entry order.
    // "quasar" appears twice in one submission: first NOUN, then VERB. The
    // first (NOUN) occurrence wins; the second (VERB) is a skipped duplicate.
    // Exactly one table entry results, in the noun set, with no duplicate.
    let (pool_dir, table_path) = setup_fixture("intra_file_conflict");

    let submission = make_submission(
        "1.0.0",
        vec![("quasar", "NOUN"), ("quasar", "VERB")],
    );
    write_submission(&submission, &pool_dir, "pool_intra.json");

    let result = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce must not error");

    assert_eq!(result.consumed, 1, "single file consumed");
    assert_eq!(
        result.nouns_added, 1,
        "quasar added exactly once, as a noun (first occurrence wins)"
    );
    assert_eq!(
        result.verbs_added, 0,
        "second (VERB) occurrence does not expand the verb set"
    );
    assert_eq!(
        result.skipped, 1,
        "second occurrence of quasar within the file is a skipped duplicate"
    );

    let nouns = read_nouns(&table_path);
    let verbs = read_verbs(&table_path);
    assert!(
        nouns.contains(&"quasar".to_string()),
        "quasar must be in the noun set (first NOUN occurrence wins)"
    );
    assert!(
        !verbs.contains(&"quasar".to_string()),
        "quasar must NOT be in the verb set"
    );
    let quasar_count = nouns.iter().filter(|n| n.as_str() == "quasar").count();
    assert_eq!(
        quasar_count, 1,
        "quasar appears exactly once — no duplicate table entry"
    );

    let _ = fs::remove_dir_all(&pool_dir);
}

// ─── 3. Older file vs newer file conflict (filename-chronological-first wins) ─

#[test]
fn older_file_wins_over_newer_file() {
    // Same token in an older-named and a newer-named file, with DIFFERENT tags
    // so the winner is observable. The older (filename-chronological-first) file
    // wins. Pool file names carry an ISO8601/epoch prefix; the lexicographically
    // smaller name is the older observation. "ripple" is NOUN in the older file
    // (2026-06-10) and VERB in the newer file (2026-06-11); the older NOUN wins.
    let (pool_dir, table_path) = setup_fixture("older_vs_newer");

    let older = make_submission("1.0.0", vec![("ripple", "NOUN")]);
    let newer = make_submission("1.0.0", vec![("ripple", "VERB")]);
    write_submission(&older, &pool_dir, "pool_2026-06-10_001.json");
    write_submission(&newer, &pool_dir, "pool_2026-06-11_001.json");

    let result = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce must not error");

    assert_eq!(result.consumed, 2, "both files consumed");
    assert_eq!(
        result.nouns_added, 1,
        "ripple added once, as a noun (older file wins)"
    );
    assert_eq!(
        result.verbs_added, 0,
        "newer-file VERB occurrence loses"
    );
    assert_eq!(result.skipped, 1, "newer occurrence is a skipped duplicate");

    let nouns = read_nouns(&table_path);
    let verbs = read_verbs(&table_path);
    assert!(
        nouns.contains(&"ripple".to_string()),
        "ripple must be in the noun set (older file's NOUN wins)"
    );
    assert!(
        !verbs.contains(&"ripple".to_string()),
        "ripple must NOT be in the verb set (newer file's VERB loses)"
    );

    let _ = fs::remove_dir_all(&pool_dir);
}

// ─── 4. Existing bundled/seed table token cannot be reclassified ─────────────

#[test]
fn table_resident_token_cannot_be_reclassified() {
    // "dog" is already a NOUN in the seed table. A submission tags it VERB.
    // The table-resident classification wins: "dog" is NOT reclassified into
    // the verb set and is NOT duplicated. (Mirrors the table-resident skip
    // policy; asserted here as an explicit no-reclassification conflict case.)
    let (pool_dir, table_path) = setup_fixture("no_reclassify");

    let submission = make_submission(
        "1.0.0",
        vec![("dog", "VERB"), ("meteor", "NOUN")],
    );
    write_submission(&submission, &pool_dir, "pool_reclassify.json");

    let result = reduce(&pool_dir, &table_path, FIXTURE_NOW, usize::MAX).expect("reduce must not error");

    // Only the genuinely-novel "meteor" expands the table.
    assert_eq!(result.nouns_added, 1, "only meteor added");
    assert_eq!(
        result.verbs_added, 0,
        "dog is table-resident; not reclassified into the verb set"
    );
    assert!(result.skipped >= 1, "dog counted as a skipped (resident) entry");

    let nouns = read_nouns(&table_path);
    let verbs = read_verbs(&table_path);
    // dog stays a NOUN, exactly once, and never becomes a verb.
    assert!(nouns.contains(&"dog".to_string()), "dog remains in the noun set");
    assert!(
        !verbs.contains(&"dog".to_string()),
        "dog must NOT be reclassified into the verb set"
    );
    let dog_count = nouns.iter().filter(|n| n.as_str() == "dog").count();
    assert_eq!(dog_count, 1, "dog appears exactly once — not duplicated");

    let _ = fs::remove_dir_all(&pool_dir);
}
