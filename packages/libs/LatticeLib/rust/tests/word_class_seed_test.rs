// word_class_seed_test.rs — Rust-leg parity for the curated WordClassTable
// pristine seed (table_version 1.1.0, snapshot_date 2026-07-04).
//
// Mirrors Tests/LatticeLibTests/WordClassSeedTests.swift. There is only ONE
// physical WordClassTable.json (Sources/LatticeLib/Resources/WordClassTable.json);
// `word_class_table::BUNDLED_TABLE_JSON` embeds it at compile time via
// `include_bytes!` at the identical relative path Swift's `Bundle.module`
// resolves to, so there is no second copy to keep in sync — this file exists
// to PROVE that single-artifact parity holds (same counts, same fast-path
// routing, same ambiguous-word absence) rather than to maintain a duplicate.
//
// Process-global-state note: cargo runs each test *file* as its own process,
// so SHARED_NOVEL_CACHE and GLOBAL_TABLE here are isolated from every OTHER
// test file. Within THIS file, #[test] fns may still run concurrently
// (cargo's default), so any test that reads/writes those two process
// globals holds `test_lock()` for its duration — the same pattern
// live_table_swap_test.rs uses.

use std::collections::HashSet;
use std::sync::{Mutex, OnceLock};

use lattice_lib::word_class_table::WordClassTableCache;
use lattice_lib::{
    pool_reduce, swap_global_table, word_class, PoolEntry, PoolSubmission, WordClass,
    BUNDLED_TABLE_JSON, SHARED_NOVEL_CACHE,
};

fn test_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

const ORIGINAL_NOUNS: &[&str] = &[
    "dinner", "wife", "husband", "carburetor", "computer", "science", "programming",
    "chemistry", "dog", "house", "car", "water", "music", "teacher", "garden", "book",
    "phone", "city", "river", "mountain", "run",
];
const ORIGINAL_VERBS: &[&str] = &[
    "run", "compile", "encode", "eat", "write", "read", "drive", "walk", "think",
    "build", "classify", "resolve", "tag", "sing", "cook", "drink", "teach", "plant",
];

fn bundled() -> WordClassTableCache {
    WordClassTableCache::from_json(BUNDLED_TABLE_JSON).expect("bundled table must parse")
}

/// Re-parse the raw JSON directly (not through WordClassTableCache, which
/// only exposes the noun/verb HashSets) to check `table_version` /
/// `snapshot_date` and raw counts including duplicates.
#[derive(serde::Deserialize)]
struct RawTable {
    table_version: String,
    snapshot_date: String,
    nouns: Vec<String>,
    verbs: Vec<String>,
}

fn raw_bundled() -> RawTable {
    serde_json::from_slice(BUNDLED_TABLE_JSON).expect("bundled table must parse as RawTable")
}

// MARK: - 1. Artifact counts (parity with Swift's bundledSeedLoadsWithShippedCounts)

#[test]
fn bundled_seed_loads_with_shipped_counts() {
    let table = raw_bundled();
    assert_eq!(table.table_version, "1.1.0");
    assert_eq!(table.snapshot_date, "2026-07-04");

    // 466 nouns / 426 verbs -- identical counts to the Swift-side pinned
    // assertion (WordClassSeedTests.bundledSeedLoadsWithShippedCounts).
    // Verb count dropped from 428: Wave 6 Adams finding removed "solder"
    // and "weld" from the seed (noun/verb homographs; moved to the
    // ambiguous-word guard's exclusion list below).
    assert_eq!(table.nouns.len(), 466, "noun count drifted from the shipped seed");
    assert_eq!(table.verbs.len(), 426, "verb count drifted from the shipped seed");

    let noun_set: HashSet<&String> = table.nouns.iter().collect();
    let verb_set: HashSet<&String> = table.verbs.iter().collect();
    assert_eq!(noun_set.len(), table.nouns.len(), "duplicate noun entries");
    assert_eq!(verb_set.len(), table.verbs.len(), "duplicate verb entries");
}

#[test]
fn pre_existing_v0_8_entries_preserved() {
    let cache = bundled();
    for noun in ORIGINAL_NOUNS {
        assert!(cache.noun_set.contains(*noun), "pre-existing noun '{noun}' must be preserved");
    }
    for verb in ORIGINAL_VERBS {
        assert!(cache.verb_set.contains(*verb), "pre-existing verb '{verb}' must be preserved");
    }
}

// MARK: - 2. Routing proof -- seeded tokens never reach the HMM

#[test]
fn newly_seeded_noun_uses_fast_path() {
    let _guard = test_lock().lock().unwrap();

    // Publish the bundled table into the live process-global holder so this
    // assertion is independent of any writable artifact a prior local run
    // may have left on disk (writable-artifact precedence, cookbook §1.3/§2.2)
    // -- same rationale as the Swift-side WordClassTableCache.swap call.
    swap_global_table(bundled());

    let before = SHARED_NOVEL_CACHE.get().map(|c| c.count()).unwrap_or(0);
    let result = word_class("astronaut");
    let after = SHARED_NOVEL_CACHE.get().map(|c| c.count()).unwrap_or(0);

    assert_eq!(result, WordClass::Noun);
    assert_eq!(after, before, "table-resident token must not touch SHARED_NOVEL_CACHE; before={before} after={after}");
}

#[test]
fn newly_seeded_verb_uses_fast_path() {
    let _guard = test_lock().lock().unwrap();
    swap_global_table(bundled());

    let before = SHARED_NOVEL_CACHE.get().map(|c| c.count()).unwrap_or(0);
    let result = word_class("clarify");
    let after = SHARED_NOVEL_CACHE.get().map(|c| c.count()).unwrap_or(0);

    assert_eq!(result, WordClass::Verb);
    assert_eq!(after, before, "table-resident token must not touch SHARED_NOVEL_CACHE; before={before} after={after}");
}

// MARK: - 3. Ambiguous-word / synthetic-fixture-word absence guards
// (mirrors WordClassSeedTests.ambiguousWordsAbsentFromSeed /
// syntheticFixtureWordsAbsentFromSeed -- see that file's doc comment for why
// each list entry is excluded)

#[test]
fn ambiguous_words_absent_from_seed() {
    let cache = bundled();
    let ambiguous_words = [
        "watch", "work", "place", "name", "light", "spring", "land", "park", "hand",
        "face", "head", "back", "cover", "order", "act", "play", "fish", "hunt",
        "guard", "host", "brief", "lift", "form", "shape", "style", "color", "paint",
        "stain", "spot", "mark", "brand", "label", "stamp", "seal", "sign", "note",
        "record", "report", "plan", "project", "process", "program", "format",
        "model", "pattern", "structure", "function", "target", "focus", "base",
        "source", "force", "charge", "balance", "profit", "value", "use", "need",
        "chair", "table", "desert", "harbor", "microwave", "sandwich", "swamp",
        "warehouse", "plateau", "referee", "quarterback", "snowboard", "skateboard",
        "buffalo", "monitor", "coach", "train", "author", "produce", "design",
        "estimate", "delegate", "coordinate", "moderate", "initiate", "affiliate",
        "subordinate", "aggregate",
        // Adams finding (Wave 6): "point" (a point / to point), "solder" (a
        // solder joint / to solder), and "weld" (a weld / to weld) were
        // missing from this guard. "solder" and "weld" were ALREADY present
        // in the shipped verbs table (a latent ambiguity this guard should
        // have caught) — removed from Resources/WordClassTable.json (the
        // single JSON both ports embed) as part of this fix.
        "point", "solder", "weld",
    ];
    let mut offenders: Vec<String> = Vec::new();
    for word in ambiguous_words {
        if cache.noun_set.contains(word) { offenders.push(format!("{word} (noun)")); }
        if cache.verb_set.contains(word) { offenders.push(format!("{word} (verb)")); }
    }
    assert!(offenders.is_empty(), "ambiguous word(s) present in the seed: {}", offenders.join(", "));
}

#[test]
fn synthetic_fixture_words_absent_from_seed() {
    let cache = bundled();
    let fixture_words = ["quasar", "nebula", "photon", "magnetar", "xenolith", "pulsar", "brachiosaurus"];
    let mut offenders: Vec<String> = Vec::new();
    for word in fixture_words {
        if cache.noun_set.contains(word) { offenders.push(format!("{word} (noun)")); }
        if cache.verb_set.contains(word) { offenders.push(format!("{word} (verb)")); }
    }
    assert!(offenders.is_empty(), "synthetic fixture word(s) leaked into the seed: {}", offenders.join(", "));
}

#[test]
fn curated_additions_do_not_overlap() {
    let table = raw_bundled();
    let original_nouns: HashSet<&str> = ORIGINAL_NOUNS.iter().copied().collect();
    let original_verbs: HashSet<&str> = ORIGINAL_VERBS.iter().copied().collect();

    let added_nouns: HashSet<&String> = table.nouns.iter()
        .filter(|n| !original_nouns.contains(n.as_str())).collect();
    let added_verbs: HashSet<&String> = table.verbs.iter()
        .filter(|v| !original_verbs.contains(v.as_str())).collect();

    let overlap: Vec<&&String> = added_nouns.intersection(&added_verbs).collect();
    assert!(overlap.is_empty(), "curated additions overlap noun/verb: {:?}", overlap);
}

// MARK: - 4. PoolReducer merge precedence over the larger seed

#[test]
fn pool_reducer_skips_table_resident_curated_addition() {
    let base = std::env::temp_dir().join(format!("lattice_seed_precedence_rs_{}", std::process::id()));
    let pool_dir = base.join("pool");
    let artifact_url = base.join("WordClassTable.json");
    std::fs::create_dir_all(&pool_dir).expect("create pool dir");

    let cache = bundled();
    assert!(cache.noun_set.contains("astronaut"), "astronaut must be a curated table-resident noun");

    let submission = PoolSubmission {
        table_version: raw_bundled().table_version,
        platform: "other".to_string(),
        tagger_version: "hmm-viterbi-3".to_string(),
        entries: vec![PoolEntry { token: "astronaut".to_string(), tag: "VERB".to_string() }],
    };
    let data = serde_json::to_vec(&submission).expect("encode submission");
    std::fs::write(pool_dir.join("pool_seed_precedence.json"), data).expect("write pool file");

    let result = pool_reduce(&pool_dir, &artifact_url, "2026-07-04", usize::MAX)
        .expect("reduce must succeed");

    assert_eq!(result.nouns_added, 0);
    assert_eq!(result.verbs_added, 0);

    let _ = std::fs::remove_dir_all(&base);
}
