// live_table_swap_test.rs
//
// Force-tests for the LIVE ATOMIC WordClassTable swap (cookbook §1.3/§2.2),
// Rust port. Proves IN-SESSION learning: in ONE running process the public
// `word_class` surface adopts a merged table WITHOUT a restart, via
// `swap_global_table`. Distinct from the cross-RELOAD test in
// novel_token_effectiveness_test.rs.
//
// Determinism: tagging is deterministic given (input, table-version). A swap
// advances the version (`table_version`); within a version classification is
// stable.
//
// NOTE: these tests mutate the PROCESS-GLOBAL live table, so the suite is
// inherently shared state. Each test restores the bundled table at the end, and
// the assertions tolerate a non-zero starting version (another test may have
// swapped first) by checking the DELTA, never an absolute version.

use std::collections::HashSet;
use std::sync::{Arc, Barrier, Mutex, OnceLock};
use std::thread;

use lattice_lib::{
    global_table, swap_global_table, table_version, word_class, BUNDLED_TABLE_JSON,
    WordClassTableCache,
};
use lattice_lib::WordClass;

/// Serializes these tests against each other. They all mutate the PROCESS-GLOBAL
/// live table + version, so the version-DELTA assertions require exclusive
/// access for the duration of each test (Rust runs tests in parallel by
/// default). Held for the whole test body.
fn test_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// A token NOT in the bundled table and NOT tagged Noun/Verb by the HMM for its
/// bare form — so `word_class` returns Other until the table learns it.
const NOVEL_TOKEN: &str = "qx7zglyph";

/// Build a cache = the current live table PLUS `extra_noun`.
fn table_plus_noun(extra_noun: &str) -> WordClassTableCache {
    let current = global_table();
    let mut noun_set: HashSet<String> = current.noun_set.iter().cloned().collect();
    noun_set.insert(extra_noun.to_string());
    let verb_set: HashSet<String> = current.verb_set.iter().cloned().collect();
    WordClassTableCache { noun_set, verb_set }
}

/// Restore the bundled (pristine) table as the live snapshot.
fn restore_bundled() {
    if let Some(bundled) = WordClassTableCache::from_json(BUNDLED_TABLE_JSON) {
        swap_global_table(bundled);
    }
}

#[test]
fn in_session_learning_via_swap() {
    let _g = test_lock().lock().unwrap_or_else(|e| e.into_inner());
    restore_bundled();

    // Baseline: the novel token is NOT a table noun.
    let before = word_class(NOVEL_TOKEN);
    assert_ne!(
        before,
        WordClass::Noun,
        "precondition: novel token must not be a table noun before the swap"
    );
    let version_before = table_version();

    // LIVE SWAP: publish a snapshot containing the novel token as a noun.
    swap_global_table(table_plus_noun(NOVEL_TOKEN));

    // The SAME live surface now classifies the token from the table — the
    // in-session learning proof (no process restart).
    let after = word_class(NOVEL_TOKEN);
    assert_eq!(
        after,
        WordClass::Noun,
        "in-session: word_class must classify the merged token from the table"
    );
    assert_eq!(
        table_version(),
        version_before + 1,
        "swap must advance the version by exactly one"
    );

    restore_bundled();
}

#[test]
fn swap_advances_version_deterministically() {
    let _g = test_lock().lock().unwrap_or_else(|e| e.into_inner());
    let v0 = table_version();
    swap_global_table((*global_table()).clone());
    let v1 = table_version();
    swap_global_table((*global_table()).clone());
    let v2 = table_version();
    assert_eq!(v1, v0 + 1);
    assert_eq!(v2, v0 + 2);

    // Within a fixed version, classification is stable (deterministic).
    let a = word_class("dinner");
    let b = word_class("dinner");
    assert_eq!(a, b);
}

#[test]
fn concurrent_reads_during_swap_no_torn_read() {
    let _g = test_lock().lock().unwrap_or_else(|e| e.into_inner());
    restore_bundled();
    let learned = table_plus_noun(NOVEL_TOKEN);

    // Hammer `word_class` from many threads while swappers flip the table back
    // and forth. A torn read would surface as a panic or a value that is neither
    // the pre- nor the post-swap classification. The only legal results for the
    // novel token are Other (pre) or Noun (post).
    let barrier = Arc::new(Barrier::new(10));
    let mut handles = Vec::new();

    // 8 readers.
    for _ in 0..8 {
        let b = Arc::clone(&barrier);
        handles.push(thread::spawn(move || {
            b.wait();
            for _ in 0..5_000 {
                let wc = word_class(NOVEL_TOKEN);
                assert!(
                    wc == WordClass::Other || wc == WordClass::Noun,
                    "torn read: classification must be the whole pre- or post-swap value, got {wc:?}"
                );
                // An always-present bundled token must never be lost mid-swap.
                assert_eq!(word_class("dinner"), WordClass::Noun);
            }
        }));
    }
    // 2 swappers.
    for s in 0..2 {
        let b = Arc::clone(&barrier);
        let learned = learned.clone();
        handles.push(thread::spawn(move || {
            b.wait();
            for i in 0..1_000 {
                if (i + s) % 2 == 0 {
                    swap_global_table(learned.clone());
                } else if let Some(bundled) = WordClassTableCache::from_json(BUNDLED_TABLE_JSON) {
                    swap_global_table(bundled);
                }
            }
        }));
    }

    for h in handles {
        h.join().expect("worker thread must not panic (no torn read)");
    }

    restore_bundled();
}
