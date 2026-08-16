//! corpus_counts_flush_preservation_tests.rs — MG-02 regression coverage for the
//! sentinel-preserving flush guard in `persist_counts_into`.
//!
//! ## What this suite pins
//!
//! After the upgrade migration writes the empty-blob sentinel into
//! `corpus_provider_counts.counts`, the reindex path calls:
//!   1. `persist_counts_into` (flush the in-memory accumulator)
//!   2. `restore_counts_into` (check whether anything is stored)
//!
//! Step 1 runs BEFORE step 2 (see CorpusKit.swift:1990 / corpus.rs:2395). At that
//! point the in-memory accumulator is empty — nothing has been trained since the
//! migration. Without the flush guard, step 1 serialises a valid-but-empty
//! accumulator blob over the sentinel, erasing the "rebuild from zero" signal.
//! Step 2 then finds a non-sentinel blob, returns `Ok(true)`, and the caller
//! guard cannot fire — a zero-vocabulary basis is published over the trained basis
//! the migration deliberately preserved.
//!
//! The flush guard (added in MG-02) prevents this: when the provider's
//! `counts_vocabulary_size() == 0` AND the stored row carries the sentinel, the
//! flush returns `Ok(())` without touching storage.
//!
//! Suite:
//!   FP1 — flush preservation: empty accumulator + sentinel row → counts still
//!          empty afterwards. FAILS pre-fix; PASSES post-fix.
//!   FP2 — flush still writes: non-empty accumulator + sentinel row → counts
//!          overwritten (sentinel gone). PASSES both pre-fix and post-fix.
//!   FP3 — anchors survive suppressed flush: doc_count and vocab_size in the
//!          stored row are unchanged after a suppressed write. FAILS pre-fix
//!          (the un-guarded flush overwrites them with the caller's values);
//!          PASSES post-fix.
//!
//! All tests use InMemory storage (no migration ladder needed; only the row shapes
//! the upgrade produces). This file does not touch any .swift file — a parallel
//! Swift suite (CorpusCountsSentinelContractTests.swift) owns the Swift gates
//! for the same contract.

use corpus_kit::corpus_provider_counts_store::{
    CorpusProviderCountsStore, INVALIDATED_COUNTS_SENTINEL,
};
use corpus_kit::TrainableEmbeddingBasis;
use corpus_kit_providers::RandomIndexingProvider;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
use persistence_kit::types::TypedValue;
use std::collections::BTreeMap;
use std::sync::Arc;
use uuid::Uuid;

// ─── Epoch constant ──────────────────────────────────────────────────────────

/// Epoch-seconds for counts rows. Never SystemTime::now() (determinism mandate).
const NOW_SECS: i64 = 1_755_500_000;

// ─── Storage helper ──────────────────────────────────────────────────────────

/// Open an InMemory storage instance and initialise it with the v4 CorpusKit
/// counts schema. Mirrors the `open_in_memory` helper in
/// `corpus_counts_blob_sentinel_tests.rs` so the two suites use identical
/// scaffolding and cannot diverge on the storage setup.
fn open_in_memory() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let st: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    st.migrate(&CorpusProviderCountsStore::schema_declaration())
        .expect("schema migration must succeed on InMemory storage");
    st
}

// ─── Seeding helpers ─────────────────────────────────────────────────────────

/// Write a `corpus_provider_counts` row shaped exactly like a post-migration row:
///   counts     = the sentinel (empty blob)
///   doc_count  = `doc_count`  (monotone anchor preserved by migration)
///   vocab_size = `vocab_size` (monotone anchor preserved by migration)
///
/// The constant `INVALIDATED_COUNTS_SENTINEL` ties this seed to the same
/// predicate the guard reads, so any sentinel-format change is a single-site
/// edit and the test tracks it automatically.
fn seed_sentinel_row(st: &Arc<dyn Storage>, doc_count: i64, vocab_size: i64) {
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("model_id".into(), TypedValue::Text("random-indexing-v1".into()));
    values.insert("model_version".into(), TypedValue::Text("1.1.0".into()));
    // Empty blob — the migration-invalidation sentinel. Pairs with
    // `is_invalidated_counts` on the read side so neither end can interpret
    // a different shape without both changing.
    values.insert(
        "counts".into(),
        TypedValue::Blob(INVALIDATED_COUNTS_SENTINEL.to_vec()),
    );
    values.insert("doc_count".into(), TypedValue::Int(doc_count));
    values.insert("vocab_size".into(), TypedValue::Int(vocab_size));
    values.insert("updated_at".into(), TypedValue::Timestamp(NOW_SECS));
    st.row_store()
        .upsert(
            "corpus_provider_counts",
            values,
            &["model_id".into(), "model_version".into()],
        )
        .expect("upsert sentinel counts row");
}

// ─── FP1: flush preservation ─────────────────────────────────────────────────

/// FP1 — flush preservation: when the in-memory accumulator is empty
/// (`counts_vocabulary_size() == 0`) and the stored row carries the sentinel,
/// `persist_counts_into` must return `Ok(())` without writing to storage, so the
/// sentinel is still in the `counts` column afterwards.
///
/// Why this must FAIL pre-fix: without the guard, `persist_counts_into`
/// immediately falls through to `provider.decompose_counts()`. For
/// `RandomIndexingProvider`, this returns a valid-but-empty header blob (non-empty
/// bytes with a proper magic + empty term map), which is written via `upsert_into`.
/// The next `store.load()` then returns a non-empty counts blob, and
/// `is_invalidated_counts` returns `false` — the sentinel is gone.
///
/// Why this PASSES post-fix: the guard checks `counts_vocabulary_size() == 0` first
/// (in-memory, no I/O), then loads the stored row and checks `is_invalidated_counts`.
/// Both conditions hold, so the function returns early without touching storage.
#[test]
fn fp1_empty_accumulator_does_not_overwrite_sentinel() {
    let st = open_in_memory();
    // Seed: one counts row exactly as the migration leaves it.
    // doc_count=42, vocab_size=17 are the monotone anchors the migration preserves.
    seed_sentinel_row(&st, 42, 17);

    // The row store that both the flush guard and the post-call load will read
    // through. Passing the same Arc satisfies the brief's requirement: "make sure
    // your gate passes the same row store it later reads through."
    let row_store = st.row_store();
    let store = CorpusProviderCountsStore::new(st.clone());

    // Provider is untrained: counts_vocabulary_size() == 0.
    let provider = RandomIndexingProvider::new();
    assert_eq!(
        provider.counts_vocabulary_size(),
        0,
        "pre-condition: fresh RandomIndexingProvider must have zero vocabulary"
    );

    // Call persist_counts_into through the caller-supplied row store, exactly as
    // the reindex path does before calling restore_counts_into.
    // document_count=0, vocab_size=0 are what the reindex path passes for an
    // empty accumulator; using values different from the seeded anchors (42, 17)
    // makes FP3 sensitive to whether the write actually happened.
    store
        .persist_counts_into(
            &provider as &dyn TrainableEmbeddingBasis,
            "random-indexing-v1",
            "1.1.0",
            0,        // document_count (caller's value — must NOT land if guard fires)
            0,        // vocab_size     (caller's value — must NOT land if guard fires)
            NOW_SECS,
            &row_store,
        )
        .expect("persist_counts_into must not error");

    // Load the row back and assert the sentinel is still there.
    let loaded = store
        .load("random-indexing-v1", "1.1.0")
        .expect("load must succeed")
        .expect("row must be present after sentinel seed");

    // Post-fix: counts is still empty — the guard suppressed the write.
    // Pre-fix:  counts is a non-empty valid-empty-state blob from decompose_counts —
    //           the sentinel was overwritten and this assertion fails.
    assert!(
        loaded.counts.is_empty(),
        "persist_counts_into with an empty accumulator must NOT overwrite the migration sentinel; \
         counts must still be empty (is_invalidated_counts == true) so that the subsequent \
         restore_counts_into returns Ok(false) and the reindex guard can fire"
    );
}

// ─── FP2: flush still writes when there is something to write ─────────────────

/// FP2 — flush still writes: when the provider has accumulated vocabulary
/// (`counts_vocabulary_size() > 0`), `persist_counts_into` must write normally
/// even though a sentinel row exists in storage. The guard must be narrow.
///
/// This test PASSES both pre-fix and post-fix. It is a structural no-weakening
/// gate: if it begins failing after the sentinel-flush fix, the guard is too
/// broad and is swallowing legitimate flushes.
///
/// Scenario: after the migration, the estate immediately ingests new content.
/// The accumulator now has vocabulary. The flush must land and overwrite the
/// sentinel with real counts, so the restore path will decode the live state.
#[test]
fn fp2_non_empty_accumulator_overwrites_sentinel() {
    let st = open_in_memory();
    // Seed the sentinel row. The guard will check this row, but the non-zero
    // vocabulary size must prevent the early return.
    seed_sentinel_row(&st, 10, 5);

    let row_store = st.row_store();
    let store = CorpusProviderCountsStore::new(st.clone());

    // Accumulate vocabulary so counts_vocabulary_size() > 0.
    let mut provider = RandomIndexingProvider::new();
    // add_to_counts folds text into the maintained counts accumulator, building
    // vocabulary. Even a single call produces a non-zero vocabulary for RI.
    provider.add_to_counts("the quick brown fox jumps over the lazy dog");
    let voc = provider.counts_vocabulary_size();
    assert!(
        voc > 0,
        "pre-condition: provider must have non-zero vocabulary after add_to_counts; got {voc}"
    );

    store
        .persist_counts_into(
            &provider as &dyn TrainableEmbeddingBasis,
            "random-indexing-v1",
            "1.1.0",
            1,        // document_count — one doc ingested
            voc,      // vocab_size — matches the accumulator's current size
            NOW_SECS,
            &row_store,
        )
        .expect("persist_counts_into must not error");

    let loaded = store
        .load("random-indexing-v1", "1.1.0")
        .expect("load must succeed")
        .expect("row must be present");

    // The flush must have landed: counts is non-empty and the sentinel is gone.
    // Passes pre-fix (no guard, write always happens) and post-fix (guard's
    // vocabulary-size branch is false, write proceeds).
    assert!(
        !loaded.counts.is_empty(),
        "persist_counts_into with a non-empty accumulator must overwrite the sentinel; \
         the guard must fire ONLY when vocabulary is empty, never when it carries state"
    );
    assert_eq!(
        loaded.document_count, 1,
        "document_count must be updated to the caller's value after a successful flush"
    );
    assert_eq!(
        loaded.vocab_size, voc,
        "vocab_size must be updated to the caller's value after a successful flush"
    );
}

// ─── FP3: anchors survive the suppressed flush ────────────────────────────────

/// FP3 — anchors survive: when the flush guard suppresses the write, the
/// `doc_count` and `vocab_size` anchors in the stored row must remain exactly as
/// the migration left them.
///
/// Why this matters: `doc_count` and `vocab_size` are the monotone anchors the
/// migration is contractually required to preserve. If the guard fires but
/// somehow partial metadata is written — or the guard fails to fire pre-fix and
/// the caller's zero values land — the anchors are destroyed.
///
/// Why this FAILS pre-fix: without the guard, persist_counts_into calls
/// upsert_into with document_count=0 and vocab_size=0 (the empty-accumulator
/// values we pass). The row is updated with those zeros, destroying the anchors
/// the migration preserved. The assertion on loaded.document_count == 42 fails.
///
/// Why this PASSES post-fix: the guard returns early, so upsert_into is never
/// called. The stored row's doc_count and vocab_size remain at the seeded values.
#[test]
fn fp3_anchors_survive_suppressed_flush() {
    let st = open_in_memory();
    // Seed with distinctive anchor values (42, 17) so any overwrite with the
    // accumulator's zero values is immediately visible.
    seed_sentinel_row(&st, 42, 17);

    let row_store = st.row_store();
    let store = CorpusProviderCountsStore::new(st.clone());

    let provider = RandomIndexingProvider::new();
    assert_eq!(
        provider.counts_vocabulary_size(),
        0,
        "pre-condition: fresh provider must have zero vocabulary"
    );

    // Call with document_count=0, vocab_size=0 — what an empty-accumulator flush
    // would write. If the guard fires correctly, these values never reach storage.
    store
        .persist_counts_into(
            &provider as &dyn TrainableEmbeddingBasis,
            "random-indexing-v1",
            "1.1.0",
            0,        // would destroy the anchor if written
            0,        // would destroy the anchor if written
            NOW_SECS,
            &row_store,
        )
        .expect("persist_counts_into must not error");

    let loaded = store
        .load("random-indexing-v1", "1.1.0")
        .expect("load must succeed")
        .expect("row must be present");

    // doc_count and vocab_size must be exactly the seeded values.
    // Post-fix: guard fired, no upsert, anchors unchanged. Assertions pass.
    // Pre-fix:  upsert ran with (0, 0), anchors destroyed. Assertions fail.
    assert_eq!(
        loaded.document_count, 42,
        "doc_count must remain 42 after a suppressed flush; \
         the guard must not allow the caller's zero doc_count to overwrite the migration anchor"
    );
    assert_eq!(
        loaded.vocab_size, 17,
        "vocab_size must remain 17 after a suppressed flush; \
         the guard must not allow the caller's zero vocab_size to overwrite the migration anchor"
    );
    // Confirm the sentinel itself is also intact (belt-and-suspenders with FP1).
    assert!(
        loaded.counts.is_empty(),
        "counts must still be the sentinel (empty) after a suppressed flush"
    );
}
