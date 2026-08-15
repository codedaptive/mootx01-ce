//! corpus_counts_blob_sentinel_tests.rs — MG-01 regression coverage for the
//! migration counts blob sentinel contract.
//!
//! The upgrade migration (`corpus_counts_migration_core` in upgrade.rs) writes
//! an empty blob (`TypedValue::Blob(vec![])`) into `corpus_provider_counts.counts`
//! for every row while preserving the monotone anchors (`doc_count` / `vocab_size`).
//! Before MG-01, `restore_counts_into` treated that empty blob as a decode
//! attempt and forwarded it to the provider's `BasisReader::expect_magic`, which
//! rejects an empty slice with `DecodingFailure`. The corrected contract defines
//! the empty blob as an `INVALIDATED_COUNTS_SENTINEL` and intercepts it before any
//! provider is called, returning `Ok(false)` — "nothing stored, start from zero".
//!
//! Suite:
//!   T1 — sentinel recovery, no v4 term rows, no v3 vocab rows
//!   T2 — sentinel recovery with surviving v4 term rows (the migration leaves them)
//!   T3 — no-weakening guard: a valid non-empty blob still restores (returns Ok(true))
//!   T4 — non-empty but undecodable blob still propagates DecodingFailure (loud failure
//!         is intentional — see BRR §2 residual risk note)
//!
//! All tests use InMemory storage: the sentinel path requires no migration ladder,
//! only the row shapes the upgrade produces. File-backed SQLite is exercised by
//! corpus_counts_migration_convergence_tests.rs and corpus_basis_persistence_tests.rs.

use corpus_kit::corpus_provider_counts_store::{
    CorpusProviderCountsStore, INVALIDATED_COUNTS_SENTINEL, is_invalidated_counts,
};
use corpus_kit::CorpusKitError;
use corpus_kit_providers::RandomIndexingProvider;
use corpus_kit::TrainableEmbeddingBasis;
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
/// counts schema. Sufficient for all sentinel tests — no migration ladder needed.
fn open_in_memory() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let st: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    st.migrate(&CorpusProviderCountsStore::schema_declaration())
        .expect("schema migration must succeed on InMemory storage");
    st
}

// ─── Seeding helpers ─────────────────────────────────────────────────────────

/// Write a `corpus_provider_counts` row shaped exactly like a post-migration row:
///   counts = the sentinel (empty blob, `vec![]`)
///   doc_count = `doc_count` (monotone anchor preserved by migration)
///   vocab_size = `vocab_size` (monotone anchor preserved by migration)
///
/// No vocab rows. No v4 term rows (unless the caller writes them separately).
fn seed_sentinel_counts_row(st: &Arc<dyn Storage>, doc_count: i64, vocab_size: i64) {
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("model_id".into(), TypedValue::Text("random-indexing-v1".into()));
    values.insert("model_version".into(), TypedValue::Text("1.1.0".into()));
    // The migration sentinel: an empty blob invalidates the opaque provider
    // counts without deleting the row (anchors must be preserved). Using the
    // shared INVALIDATED_COUNTS_SENTINEL constant pins both the migration writer
    // and this test to the same predicate so they cannot drift independently.
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

/// Write a `corpus_provider_counts` row with a valid, non-empty provider blob
/// produced by serialising an untrained `RandomIndexingProvider`. The blob
/// carries a valid magic header + zero-vocabulary state, so `restore_counts`
/// succeeds and returns an empty-but-present provider.
fn seed_valid_counts_row(st: &Arc<dyn Storage>) {
    // An untrained provider serializes a valid magic header + empty vocabulary.
    // The round-trip succeeds: restore_counts accepts it and leaves the provider
    // in the "no accumulated state" configuration, which is distinct from the
    // sentinel: the sentinel means "never had counts, rebuild from zero"; a zero
    // vocabulary means "was trained on an empty corpus".
    let provider = RandomIndexingProvider::new();
    let blob = provider.serialize_counts();
    assert!(
        !blob.is_empty(),
        "serialize_counts must produce a non-empty blob even for an untrained provider"
    );

    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("model_id".into(), TypedValue::Text("random-indexing-v1".into()));
    values.insert("model_version".into(), TypedValue::Text("1.1.0".into()));
    values.insert("counts".into(), TypedValue::Blob(blob));
    values.insert("doc_count".into(), TypedValue::Int(0));
    values.insert("vocab_size".into(), TypedValue::Int(0));
    values.insert("updated_at".into(), TypedValue::Timestamp(NOW_SECS));
    st.row_store()
        .upsert(
            "corpus_provider_counts",
            values,
            &["model_id".into(), "model_version".into()],
        )
        .expect("upsert valid counts row");
}

/// Write a `corpus_provider_counts` row with a non-empty but undecodable blob.
/// `b"not-a-valid-counts-blob"` carries no magic header, so every provider's
/// `BasisReader::expect_magic` rejects it.
fn seed_corrupt_counts_row(st: &Arc<dyn Storage>) {
    let blob = b"not-a-valid-counts-blob".to_vec();
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("model_id".into(), TypedValue::Text("random-indexing-v1".into()));
    values.insert("model_version".into(), TypedValue::Text("1.1.0".into()));
    values.insert("counts".into(), TypedValue::Blob(blob));
    values.insert("doc_count".into(), TypedValue::Int(0));
    values.insert("vocab_size".into(), TypedValue::Int(0));
    values.insert("updated_at".into(), TypedValue::Timestamp(NOW_SECS));
    st.row_store()
        .upsert(
            "corpus_provider_counts",
            values,
            &["model_id".into(), "model_version".into()],
        )
        .expect("upsert corrupt counts row");
}

// ─── T1: sentinel recovery, no term rows ─────────────────────────────────────

/// T1 — open-path sentinel recovery: an empty-blob post-migration counts row
/// with no v3 vocab rows and no v4 term rows returns `Ok(false)` from
/// `restore_counts_into`, indicating "nothing stored, start from zero".
///
/// Pre-fix: the empty blob reaches `provider.restore_counts(&[])`, which calls
/// `BasisReader::expect_magic` on an empty slice and returns
/// `Err(CorpusKitError::DecodingFailure(...))`.
///
/// Post-fix: `is_invalidated_counts` intercepts the sentinel before any provider
/// call; callers adopt the anchors from the row and start training from zero.
#[test]
fn t1_sentinel_recovery_no_term_rows() {
    let st = open_in_memory();
    // Seed: one counts row exactly as the migration leaves it.
    // doc_count=42, vocab_size=17 are the monotone anchors the migration preserves.
    seed_sentinel_counts_row(&st, 42, 17);

    let store = CorpusProviderCountsStore::new(st);
    let mut provider = RandomIndexingProvider::new();

    let result = store.restore_counts_into(
        &mut provider as &mut dyn TrainableEmbeddingBasis,
        "random-indexing-v1",
        "1.1.0",
    );

    // Post-fix: Ok(false) — sentinel detected, provider left untouched.
    // Pre-fix: Err(DecodingFailure) from BasisReader::expect_magic on empty slice.
    assert_eq!(
        result,
        Ok(false),
        "restore_counts_into must return Ok(false) for a sentinel (empty) counts blob, \
         not propagate DecodingFailure — the migration cannot synthesise a per-provider \
         header; the empty blob is the defined invalidation signal"
    );
    // The provider must be untouched: zero vocabulary, ready to train from zero.
    assert_eq!(
        provider.counts_vocabulary_size(),
        0,
        "provider vocabulary must be zero after a sentinel recovery (no counts transferred)"
    );
}

// ─── T2: sentinel recovery with surviving v4 term rows ───────────────────────

/// T2 — open-path sentinel recovery with v4 term residue: the migration does NOT
/// delete `corpus_provider_term_dictionary` / `corpus_provider_term_payload` rows
/// (BRR finding F2). When v4 term rows survive, `restore_counts_into` takes the
/// v4 branch and calls `restore_counts_from_parts(empty_header, terms)`. Every
/// provider's header decode starts with `BasisReader::expect_magic` on the empty
/// header, which fails identically to the direct `restore_counts(&[])` case.
///
/// Pre-fix: `Err(DecodingFailure)` from `restore_counts_from_parts(empty, terms)`.
/// Post-fix: `Ok(false)` — sentinel intercepts before the v4 branch is reached.
#[test]
fn t2_sentinel_recovery_with_v4_term_residue() {
    let st = open_in_memory();
    // Seed the sentinel counts row.
    seed_sentinel_counts_row(&st, 10, 5);

    // Seed surviving v4 term rows (simulates the migration leaving the v4 pair
    // intact — the migration's scope is the counts blob and vocab table only).
    // replace_term_payloads_into needs the row_store handle.
    let row_store = st.row_store();
    let store = CorpusProviderCountsStore::new(st.clone());
    let residue_terms: Vec<(String, Vec<u8>)> = vec![
        ("alpha".to_string(), vec![1u8; 8]),
        ("beta".to_string(), vec![2u8; 8]),
    ];
    store
        .replace_term_payloads_into("random-indexing-v1", &residue_terms, &row_store)
        .expect("seeding v4 term residue must succeed");

    // Verify the residue is actually present so the test covers the v4 branch.
    let loaded = store
        .load_term_payloads("random-indexing-v1")
        .expect("load_term_payloads");
    assert_eq!(
        loaded.len(),
        2,
        "two v4 term rows must be present before calling restore_counts_into"
    );

    let mut provider = RandomIndexingProvider::new();
    let result = store.restore_counts_into(
        &mut provider as &mut dyn TrainableEmbeddingBasis,
        "random-indexing-v1",
        "1.1.0",
    );

    // Post-fix: Ok(false) — sentinel detected before the v4 branch.
    // Pre-fix: Err(DecodingFailure) from restore_counts_from_parts(empty, terms).
    assert_eq!(
        result,
        Ok(false),
        "restore_counts_into must return Ok(false) even when v4 term rows survive the migration; \
         the sentinel check must fire before the v4 branch so the empty header never reaches \
         restore_counts_from_parts"
    );
    assert_eq!(
        provider.counts_vocabulary_size(),
        0,
        "provider vocabulary must be zero: sentinel recovery transfers no counts"
    );
}

// ─── T3: no-weakening guard ───────────────────────────────────────────────────

/// T3 — no-weakening guard: a valid, non-empty provider blob still restores and
/// returns `Ok(true)`. The sentinel check is narrow — it fires only on the empty
/// sentinel, never on real counts.
///
/// This test passes both pre-fix and post-fix. It is a structural gate: if it
/// begins failing after the sentinel fix, the fix is too broad and swallows
/// valid blobs.
#[test]
fn t3_valid_blob_still_restores() {
    let st = open_in_memory();
    seed_valid_counts_row(&st);

    let store = CorpusProviderCountsStore::new(st);
    let mut provider = RandomIndexingProvider::new();

    let result = store.restore_counts_into(
        &mut provider as &mut dyn TrainableEmbeddingBasis,
        "random-indexing-v1",
        "1.1.0",
    );

    // A valid blob must restore and return Ok(true) pre- and post-fix.
    // Failure here means the sentinel check is intercepting real counts.
    assert_eq!(
        result,
        Ok(true),
        "restore_counts_into must return Ok(true) for a valid non-empty provider blob; \
         the sentinel fix must not swallow real counts"
    );
}

// ─── T4: non-empty undecodable blob propagates DecodingFailure ───────────────

/// T4 — deliberate loud failure: a non-empty but undecodable blob still
/// propagates `CorpusKitError::DecodingFailure`. This behaviour is intentional
/// (BRR §2 residual risk). No known code path produces a non-empty undecodable
/// blob; if one were ever observed in the field, a loud error is the correct
/// response — swallowing it would convert genuine corruption into silent data loss.
///
/// This test pins the intentional loud-failure contract so nobody widens the
/// sentinel to cover non-empty blobs without a deliberate, reviewed decision.
/// It passes both pre-fix and post-fix.
#[test]
fn t4_non_empty_undecodable_blob_errors() {
    let st = open_in_memory();
    seed_corrupt_counts_row(&st);

    let store = CorpusProviderCountsStore::new(st);
    let mut provider = RandomIndexingProvider::new();

    let result = store.restore_counts_into(
        &mut provider as &mut dyn TrainableEmbeddingBasis,
        "random-indexing-v1",
        "1.1.0",
    );

    // Must propagate DecodingFailure, not Ok(false).
    assert!(
        matches!(result, Err(CorpusKitError::DecodingFailure(_))),
        "restore_counts_into must propagate DecodingFailure for a non-empty undecodable blob; \
         got {:?}",
        result
    );
}

// ─── Sentinel predicate self-check ───────────────────────────────────────────

/// Sanity-check that `INVALIDATED_COUNTS_SENTINEL` and `is_invalidated_counts`
/// are consistent with each other and with the migration's write pattern.
///
/// This test pins the shared contract so a future format change (e.g. a 4-byte
/// magic header on the sentinel) requires a deliberate, reviewed decision and
/// cannot happen silently.
#[test]
fn sentinel_predicate_is_consistent() {
    // The sentinel is the empty slice — migration writes TypedValue::Blob(vec![]).
    assert!(
        INVALIDATED_COUNTS_SENTINEL.is_empty(),
        "INVALIDATED_COUNTS_SENTINEL must be an empty slice (matches the migration's write)"
    );
    assert!(
        is_invalidated_counts(INVALIDATED_COUNTS_SENTINEL),
        "is_invalidated_counts(SENTINEL) must return true"
    );
    // Any non-empty slice is NOT the sentinel, including a one-byte slice.
    assert!(
        !is_invalidated_counts(&[0u8]),
        "is_invalidated_counts must return false for any non-empty byte slice"
    );
    assert!(
        !is_invalidated_counts(b"valid-header-magic"),
        "is_invalidated_counts must return false for a non-empty blob"
    );
}
