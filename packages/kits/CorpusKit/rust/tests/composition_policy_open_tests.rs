//! Open-time composition-policy mismatch: the recorded-vs-configured scan in
//! `CorpusIndexStateStore` and its surfacing at `CorpusContentEngine::open`.
//! Rust twin of the Swift `IndexCompositionPolicyMismatchTests` suite, plus
//! the engine-level refuse / `reindex_pending` skip and the cross-port pin of
//! the error detail string.

use corpus_kit::index_composition_policy::IndexCompositionPolicy;
use corpus_kit::index_state_operational::{INDEX_BIT_LEXICALLY_INDEXED, INDEX_BIT_REMOVED};
use corpus_kit::{
    content_digest, CorpusContentConfiguration, CorpusContentEngine, CorpusContentSource,
    CorpusDocumentStore, CorpusIndexState, CorpusIndexStateStore, CorpusIndexUnitPolicy,
    CorpusKitError, CorpusOperatingMode, EmbeddingModelConfig,
};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use std::sync::Arc;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000_000;
/// The feed-cursor sentinel row id exactly as the engine writes it.
const FEED_CURSOR_ROW_ID: &str = "\u{1F}feed";

fn in_memory_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

/// A checkpoint store over fresh storage with only its own schema applied.
fn store() -> (CorpusIndexStateStore, Arc<dyn Storage>) {
    let storage = in_memory_storage();
    storage
        .migrate(&CorpusIndexStateStore::schema_declaration())
        .expect("migrate corpus_index_state");
    (CorpusIndexStateStore::new(Arc::clone(&storage)), storage)
}

fn row(id: &str, policy_id: &str, bitmap: i64) -> CorpusIndexState {
    CorpusIndexState {
        content_id: id.to_string(),
        revision: 1,
        digest: content_digest(id),
        index_version: 1,
        applied_cursor: None,
        updated_at_millis: NOW,
        operational_bitmap: bitmap,
        composition_policy_id: policy_id.to_string(),
    }
}

/// An active, lexically-indexed row written under `policy_id`.
fn active_row(id: &str, policy_id: &str) -> CorpusIndexState {
    row(id, policy_id, INDEX_BIT_LEXICALLY_INDEXED)
}

// MARK: - CorpusIndexStateStore::mismatched_composition_policy

#[test]
fn fresh_estate_never_mismatches() {
    let (store, _storage) = store();
    assert_eq!(
        store
            .mismatched_composition_policy(&IndexCompositionPolicy::both_adornments().id())
            .expect("scan"),
        None
    );
}

#[test]
fn rows_stamped_with_the_configured_policy_agree() {
    let (store, _storage) = store();
    let id = IndexCompositionPolicy::lexical_adornments().id();
    store.advance(&active_row("d1", &id)).expect("advance");
    store.advance(&active_row("d2", &id)).expect("advance");
    assert_eq!(store.mismatched_composition_policy(&id).expect("scan"), None);
}

#[test]
fn a_row_stamped_under_another_policy_is_reported() {
    let (store, _storage) = store();
    store
        .advance(&active_row("d1", &IndexCompositionPolicy::current().id()))
        .expect("advance");
    store
        .advance(&active_row("d2", &IndexCompositionPolicy::dense_adornments().id()))
        .expect("advance");
    assert_eq!(
        store
            .mismatched_composition_policy(&IndexCompositionPolicy::current().id())
            .expect("scan"),
        Some(IndexCompositionPolicy::dense_adornments().id())
    );
}

#[test]
fn rows_with_an_empty_policy_read_as_current() {
    let (store, _storage) = store();
    store.advance(&active_row("d1", "")).expect("advance");
    // Configured current(): the legacy row agrees.
    assert_eq!(
        store
            .mismatched_composition_policy(&IndexCompositionPolicy::current().id())
            .expect("scan"),
        None
    );
    // Configured anything else: the legacy row is reported as current().
    assert_eq!(
        store
            .mismatched_composition_policy(&IndexCompositionPolicy::both_adornments().id())
            .expect("scan"),
        Some(IndexCompositionPolicy::current().id())
    );
}

#[test]
fn removed_and_never_indexed_rows_do_not_participate() {
    let (store, _storage) = store();
    let other = IndexCompositionPolicy::both_adornments().id();
    // Never lexically indexed (bitmap 0): ignored.
    store.advance(&row("d1", &other, 0)).expect("advance");
    // Indexed then removed: ignored.
    store
        .advance(&row("d2", &other, INDEX_BIT_LEXICALLY_INDEXED | INDEX_BIT_REMOVED))
        .expect("advance");
    assert_eq!(
        store
            .mismatched_composition_policy(&IndexCompositionPolicy::current().id())
            .expect("scan"),
        None
    );
}

#[test]
fn the_feed_cursor_sentinel_row_is_skipped_by_id() {
    let (store, _storage) = store();
    // The sentinel is skipped by its id before any bitmap filter: even a
    // sentinel row carrying the indexed bit and the empty (current) policy
    // must not be reported against a non-current configuration.
    store
        .advance(&row(FEED_CURSOR_ROW_ID, "", INDEX_BIT_LEXICALLY_INDEXED))
        .expect("advance");
    assert_eq!(
        store
            .mismatched_composition_policy(&IndexCompositionPolicy::both_adornments().id())
            .expect("scan"),
        None
    );
}

#[test]
fn the_first_disagreeing_id_in_content_id_order_is_reported() {
    let (store, _storage) = store();
    store
        .advance(&active_row("d1", &IndexCompositionPolicy::current().id()))
        .expect("advance");
    store
        .advance(&active_row("d3", &IndexCompositionPolicy::both_adornments().id()))
        .expect("advance");
    store
        .advance(&active_row("d2", &IndexCompositionPolicy::dense_adornments().id()))
        .expect("advance");
    assert_eq!(
        store
            .mismatched_composition_policy(&IndexCompositionPolicy::current().id())
            .expect("scan"),
        Some(IndexCompositionPolicy::dense_adornments().id())
    );
}

// MARK: - CorpusContentEngine::open

/// Standalone storage whose checkpoint table already holds one active row
/// written under `current()`.
fn storage_with_current_row() -> Arc<dyn Storage> {
    let (store, storage) = store();
    store
        .advance(&active_row("d1", &IndexCompositionPolicy::current().id()))
        .expect("advance");
    storage
        .migrate(&CorpusDocumentStore::schema_declaration())
        .expect("migrate documents");
    storage
}

fn open_standalone(
    storage: &Arc<dyn Storage>,
    policy: IndexCompositionPolicy,
    reindex_pending: bool,
) -> Result<CorpusContentEngine, CorpusKitError> {
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Standalone,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .expect("configuration")
    .with_composition_policy(policy);
    let documents = Arc::new(CorpusDocumentStore::new(Arc::clone(storage)));
    CorpusContentEngine::open(
        Arc::clone(storage),
        config,
        documents as Arc<dyn CorpusContentSource>,
        vec![EmbeddingModelConfig::Deterministic],
        reindex_pending,
    )
}

#[test]
fn open_refuses_rows_built_under_another_policy_with_the_exact_detail() {
    let storage = storage_with_current_row();
    let err = open_standalone(&storage, IndexCompositionPolicy::lexical_adornments(), false)
        .err()
        .expect("open must refuse");
    // The detail string is byte-identical to the Swift engine's
    // `compositionPolicyMismatch` associated value for the same pair.
    assert_eq!(
        err,
        CorpusKitError::CompositionPolicyMismatch(
            "recorded=lex=original;dense=distilled;configured=lex=originalPlusAdornments;dense=distilled"
                .to_string()
        )
    );
    assert_eq!(
        err.to_string(),
        "composition policy mismatch: recorded=lex=original;dense=distilled;configured=lex=originalPlusAdornments;dense=distilled"
    );
}

#[test]
fn open_serves_rows_built_under_the_configured_policy() {
    let storage = storage_with_current_row();
    let engine = open_standalone(&storage, IndexCompositionPolicy::current(), false)
        .expect("agreeing rows open");
    assert_eq!(engine.composition_policy(), IndexCompositionPolicy::current());
}

#[test]
fn open_with_reindex_pending_skips_the_check() {
    let storage = storage_with_current_row();
    let engine = open_standalone(&storage, IndexCompositionPolicy::lexical_adornments(), true)
        .expect("rebuild-committed open");
    assert_eq!(engine.composition_policy(), IndexCompositionPolicy::lexical_adornments());
    // The skip changes nothing on disk: a plain reopen still refuses until
    // the committed rebuild rewrites the rows.
    drop(engine);
    assert!(matches!(
        open_standalone(&storage, IndexCompositionPolicy::lexical_adornments(), false),
        Err(CorpusKitError::CompositionPolicyMismatch(_))
    ));
}
