//! counts_integrity_runner_tests.rs — proves the counts-integrity invariants
//! CAN fail. Rust twin of `CountsIntegrityRunnerFalsificationTests.swift`.
//!
//! A conformance runner nobody has seen fail is a claim, not a gate. Four
//! missions each shipped a defect a coherence check would have caught, and each
//! shipped it past a green suite — so a runner added now must demonstrate that
//! it DETECTS the row states those defects produced.
//!
//! Each invariant gets a PAIR:
//!
//!   *_is_caught     builds the violating row state and asserts the check
//!                   returns a violation. Weaken the invariant and this goes red.
//!   *_clean_passes  runs the same check on a coherent store and asserts
//!                   silence. This is the half that catches an invariant
//!                   asserting something trivially true — one that fired on
//!                   everything would satisfy the first and fail this.
//!
//! Violating states are built from ROWS rather than by reverting production
//! code, so these are permanent rather than a one-off experiment.
//!
//! InMemory storage throughout: every invariant is a property of row shapes,
//! not of a backend. Backend agreement is PersistenceKit's conformance rig.

mod common;

use common::counts_integrity::{
    assert_integrity, invalidated_counts_has_no_surviving_term_rows,
    reference_rows_have_live_counts_row, term_dictionary_has_no_orphan_model_bits,
    term_payload_matches_dictionary, verify_integrity,
};
use corpus_kit::corpus_provider_counts_store::{
    CorpusProviderCountsStore, INVALIDATED_COUNTS_SENTINEL,
};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
use persistence_kit::types::TypedValue;
use std::collections::BTreeMap;
use std::sync::Arc;
use uuid::Uuid;

/// Epoch-seconds for counts rows. Never SystemTime::now() (determinism mandate).
const NOW_SECS: i64 = 1_755_500_000;

const MODEL_ID: &str = "random-indexing-v1";
const MODEL_VERSION: &str = "1.1.0";

/// Registry integer for `nmf-v1` — a real registry entry, so the bit under test
/// is one the store could actually assign rather than a value it would reject.
const NMF_BIT: i64 = 3;

fn open_in_memory() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let st: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    st.migrate(&CorpusProviderCountsStore::schema_declaration())
        .expect("schema migration must succeed on InMemory storage");
    st
}

fn seed_counts_row(st: &Arc<dyn Storage>, counts: Vec<u8>) {
    let mut v: BTreeMap<String, TypedValue> = BTreeMap::new();
    v.insert("model_id".into(), TypedValue::Text(MODEL_ID.into()));
    v.insert("model_version".into(), TypedValue::Text(MODEL_VERSION.into()));
    v.insert("counts".into(), TypedValue::Blob(counts));
    v.insert("doc_count".into(), TypedValue::Int(1));
    v.insert("vocab_size".into(), TypedValue::Int(1));
    v.insert("updated_at".into(), TypedValue::Timestamp(NOW_SECS));
    st.row_store()
        .upsert(
            "corpus_provider_counts",
            v,
            &["model_id".into(), "model_version".into()],
        )
        .expect("upsert counts row");
}

fn seed_reference_row(st: &Arc<dyn Storage>, content_id: &str) {
    let mut v: BTreeMap<String, TypedValue> = BTreeMap::new();
    v.insert("model_id".into(), TypedValue::Text(MODEL_ID.into()));
    v.insert("model_version".into(), TypedValue::Text(MODEL_VERSION.into()));
    v.insert("content_id".into(), TypedValue::Text(content_id.into()));
    v.insert("revision".into(), TypedValue::Int(1));
    v.insert("digest".into(), TypedValue::Text("d1".into()));
    v.insert("updated_at".into(), TypedValue::Timestamp(NOW_SECS));
    st.row_store()
        .upsert(
            "corpus_provider_count_references",
            v,
            &[
                "model_id".into(),
                "model_version".into(),
                "content_id".into(),
            ],
        )
        .expect("upsert reference row");
}

fn seed_dictionary_row(st: &Arc<dyn Storage>, term_id: i64, term: &str, models: i64) {
    let mut v: BTreeMap<String, TypedValue> = BTreeMap::new();
    v.insert("term_id".into(), TypedValue::Int(term_id));
    v.insert("term".into(), TypedValue::Text(term.into()));
    v.insert("models".into(), TypedValue::Int(models));
    st.row_store()
        .upsert("corpus_provider_term_dictionary", v, &["term_id".into()])
        .expect("upsert dictionary row");
}

fn seed_payload_row(st: &Arc<dyn Storage>, model_id: i64, term_id: i64) {
    let mut v: BTreeMap<String, TypedValue> = BTreeMap::new();
    v.insert("model_id".into(), TypedValue::Int(model_id));
    v.insert("term_id".into(), TypedValue::Int(term_id));
    v.insert("vector".into(), TypedValue::Blob(vec![1u8; 8]));
    st.row_store()
        .upsert(
            "corpus_provider_term_payload",
            v,
            &["model_id".into(), "term_id".into()],
        )
        .expect("upsert payload row");
}

fn seed_vocab_row(st: &Arc<dyn Storage>, term: &str) {
    let mut v: BTreeMap<String, TypedValue> = BTreeMap::new();
    v.insert("model_id".into(), TypedValue::Text(MODEL_ID.into()));
    v.insert("model_version".into(), TypedValue::Text(MODEL_VERSION.into()));
    v.insert("term".into(), TypedValue::Text(term.into()));
    v.insert("vector".into(), TypedValue::Blob(vec![7u8; 8]));
    st.row_store()
        .upsert(
            "corpus_provider_vocab",
            v,
            &["model_id".into(), "model_version".into(), "term".into()],
        )
        .expect("upsert vocab row");
}

// ─── I-1 stranded reference ──────────────────────────────────────────────────

/// The CT-02 residual as row state: a reference naming a provider generation
/// whose counts row is gone. Before that fix, `remove_content` produced exactly
/// this and the population guard read 50 + 2 = 52 against a store holding 51.
#[test]
fn i1_stranded_reference_is_caught() {
    let st = open_in_memory();
    seed_counts_row(&st, vec![0x01]);
    seed_reference_row(&st, "doc-1");
    st.row_store()
        .delete(
            "corpus_provider_counts",
            &persistence_kit::predicate::StoragePredicate::IsTrue,
        )
        .expect("delete counts row");

    let v = reference_rows_have_live_counts_row(&st, "i1-broken");
    assert_eq!(v.len(), 1, "I-1 must report the stranded reference: {v:?}");
    assert!(v[0].contains("doc-1"), "violation must name the content: {v:?}");
}

#[test]
fn i1_clean_passes() {
    let st = open_in_memory();
    seed_counts_row(&st, vec![0x01]);
    seed_reference_row(&st, "doc-1");

    assert!(
        reference_rows_have_live_counts_row(&st, "i1-clean").is_empty(),
        "I-1 must stay silent when every reference has a counts row"
    );
}

// ─── I-2 dictionary bit with no payload ──────────────────────────────────────

/// CT-02's shape: a term whose mask still claims a model with no payload rows
/// at all — the dictionary outliving what it describes.
#[test]
fn i2_orphan_model_bit_is_caught() {
    let st = open_in_memory();
    seed_dictionary_row(&st, 1, "stranded", 1i64 << NMF_BIT);

    let v = term_dictionary_has_no_orphan_model_bits(&st, "i2-broken");
    assert_eq!(v.len(), 1, "I-2 must report the orphan model bit: {v:?}");
    assert!(v[0].contains("stranded"), "violation must name the term: {v:?}");
}

/// A ZERO mask is deliberately legal — a name no model currently claims, which
/// `clear_term_payloads` produces and the next persist re-sets. If I-2 ever
/// starts firing on it, this catches the over-reach.
#[test]
fn i2_clean_passes() {
    let st = open_in_memory();
    seed_dictionary_row(&st, 1, "unclaimed", 0);
    seed_dictionary_row(&st, 2, "claimed", 1i64 << NMF_BIT);
    seed_payload_row(&st, NMF_BIT, 2);

    assert!(
        term_dictionary_has_no_orphan_model_bits(&st, "i2-clean").is_empty(),
        "I-2 must accept a zero mask and a bit backed by payload"
    );
}

// ─── I-3 payload the dictionary cannot reach ─────────────────────────────────

/// A payload row nothing can reach: no dictionary row maps a term string to
/// this `term_id`, so the bytes are resident and unqueryable.
#[test]
fn i3_payload_without_dictionary_entry_is_caught() {
    let st = open_in_memory();
    seed_payload_row(&st, NMF_BIT, 99);

    let v = term_payload_matches_dictionary(&st, "i3-broken");
    assert_eq!(v.len(), 1, "I-3 must report the undescribed payload: {v:?}");
    assert!(v[0].contains("99"), "violation must name the term_id: {v:?}");
}

/// The subtler case: the dictionary knows the term but does not set THIS
/// model's bit. The payload is still unreachable through it.
#[test]
fn i3_dictionary_missing_model_bit_is_caught() {
    let st = open_in_memory();
    seed_dictionary_row(&st, 7, "mismatched", 1i64 << 1); // claims ppmi-v1 only
    seed_payload_row(&st, NMF_BIT, 7); // payload written for nmf-v1

    let v = term_payload_matches_dictionary(&st, "i3-mismatch");
    assert_eq!(v.len(), 1, "I-3 must report the unset model bit: {v:?}");
}

#[test]
fn i3_clean_passes() {
    let st = open_in_memory();
    seed_dictionary_row(&st, 7, "agreed", 1i64 << NMF_BIT);
    seed_payload_row(&st, NMF_BIT, 7);

    assert!(
        term_payload_matches_dictionary(&st, "i3-clean").is_empty(),
        "I-3 must stay silent when payload and dictionary agree"
    );
}

// ─── I-4 sentinel with surviving v3 vocab rows ───────────────────────────────

/// The MG-01/m2 case: a generation carrying the invalidation sentinel that
/// still has v3 vocab rows. The migration deletes every one of them
/// (upgrade.rs, "legacy vocab rows must be gone"), so their survival
/// contradicts the migration's own contract — and a restore would find and use
/// them, which is what the sentinel exists to prevent.
#[test]
fn i4_sentinel_with_surviving_vocab_rows_is_caught() {
    let st = open_in_memory();
    seed_vocab_row(&st, "survivor");
    seed_counts_row(&st, INVALIDATED_COUNTS_SENTINEL.to_vec());

    let v = invalidated_counts_has_no_surviving_term_rows(&st, "i4-broken");
    assert_eq!(v.len(), 1, "I-4 must report the surviving vocab row: {v:?}");
    assert!(v[0].contains(MODEL_ID), "violation must name the provider: {v:?}");
}

/// A populated blob with vocab rows is an ordinary trained generation.
#[test]
fn i4_clean_passes() {
    let st = open_in_memory();
    seed_vocab_row(&st, "ordinary");
    seed_counts_row(&st, vec![0x01, 0x02]);

    assert!(
        invalidated_counts_has_no_surviving_term_rows(&st, "i4-clean").is_empty(),
        "I-4 must stay silent on a populated counts blob"
    );
}

/// Surviving v4 term rows alongside the sentinel are LEGAL — the migration
/// leaves them deliberately (T2 of corpus_counts_blob_sentinel_tests.rs).
/// Widening I-4 to v4 would fail on a correctly migrated estate, so this test
/// pins the boundary rather than the behaviour.
#[test]
fn i4_does_not_fire_on_surviving_v4_term_rows() {
    let st = open_in_memory();
    seed_dictionary_row(&st, 1, "kept", 1i64 << NMF_BIT);
    seed_payload_row(&st, NMF_BIT, 1);
    seed_counts_row(&st, INVALIDATED_COUNTS_SENTINEL.to_vec());

    assert!(
        invalidated_counts_has_no_surviving_term_rows(&st, "i4-v4").is_empty(),
        "I-4 is scoped to the v3 vocab table; v4 term rows survive the migration by design"
    );
}

// ─── Whole-set smoke ─────────────────────────────────────────────────────────

/// An empty store satisfies every invariant vacuously. Without this, a runner
/// that panicked on the state every test starts from would make every call site
/// look broken.
#[test]
fn empty_store_is_coherent() {
    let st = open_in_memory();
    let v = verify_integrity(&st, "empty");
    assert!(v.is_empty(), "an empty store must be coherent: {v:?}");
}

/// Exercises `assert_integrity` — the entry point mutating tests actually call
/// — on a coherent store carrying every table's rows. `verify_integrity` being
/// green does not prove its panicking wrapper is, and an untested wrapper is
/// the one every future call site depends on.
#[test]
fn assert_integrity_accepts_a_fully_populated_coherent_store() {
    let st = open_in_memory();
    seed_counts_row(&st, vec![0x01]);
    seed_reference_row(&st, "doc-1");
    seed_dictionary_row(&st, 1, "coherent", 1i64 << NMF_BIT);
    seed_payload_row(&st, NMF_BIT, 1);
    seed_vocab_row(&st, "coherent");

    assert_integrity(&st, "fully-populated");
}
