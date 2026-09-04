//! reindex_abort_path_tests.rs
//!
//! SS-01 Unit C — reindex abort path, Rust port.
//!
//! Discriminating tests for the abort fix in ContentEngine::reindex: when a
//! reindex fails between begin_shadow_generation and publish_shadow_generation,
//! abandon_shadow_generation must be called before propagating the error so no
//! vectors are stranded in a generation that will never become visible.
//!
//! Test inventory (mirrors ReindexAbortPathTests.swift):
//!
//!   c4a. Error propagates — the caller receives the original Err, not Ok.
//!
//!   c4b. No leftover 'building' state — after a failed reindex, the
//!        vector_generations registry must NOT show shadow_state = 'building'.
//!        Pre-fix, shadow_state is 'building'; this assertion fails.
//!        Post-fix, abandon_shadow_generation clears shadow_state to NULL.
//!
//!   c4c. Serving generation intact — serving_generation remains at its prior
//!        value; the old generation keeps serving.
//!
//!   c4d. No stranded shadow vectors — vector count for the model is unchanged.
//!        Failure during train_trainable_slots (before the write pass) means no
//!        shadow vectors were written; count stays at 6 (3 items × 2 lanes).
//!
//! Seam used: a CorpusContentSource implementation that returns Err on the Nth
//! call to record(). No production code is modified to make this testable.
//!
//! Storage: on-disk SQLite (RAII temp dir) — the same backend production uses.

use corpus_kit::{
    CorpusContentChangeBatch, CorpusContentConfiguration, CorpusContentEngine,
    CorpusContentId, CorpusContentRecord, CorpusContentSource, CorpusIndexUnitPolicy,
    CorpusKitError, CorpusOperatingMode, EmbeddingModelConfig,
};
use corpus_kit::content_digest;
use corpus_kit_providers::RandomIndexingProvider;
use persistence_kit::{
    BackendConfiguration, Column, EstateConfiguration, SqliteStorage, Storage,
    StoragePredicate, TypedValue,
};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicBool, Ordering};
use uuid::Uuid;

// ── Constants ──────────────────────────────────────────────────────────────

const NOW_MILLIS: i64 = 1_755_100_000_000;
const RI_MODEL_ID: &str = "random-indexing-v1";

// ── RAII temp dir ──────────────────────────────────────────────────────────

struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn make_scratch_storage() -> (Arc<dyn Storage>, TempDir) {
    let dir = std::env::temp_dir().join(format!("reindex-abort-rs-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    let path = dir
        .join(format!("reindex-abort-{}.sqlite3", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned();
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite { path, busy_timeout_secs: 5.0 },
    );
    let storage: Arc<dyn Storage> =
        Arc::new(SqliteStorage::new(config).expect("open SQLite storage"));
    (storage, TempDir(dir))
}

// ── FaultSource ─────────────────────────────────────────────────────────────

/// CorpusContentSource that can be armed to fail on the next record() call.
struct FaultSource {
    records: Mutex<BTreeMap<String, CorpusContentRecord>>,
    /// When true, the next record() call returns Err and resets the flag.
    fail_on_next_record: AtomicBool,
}

impl FaultSource {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            records: Mutex::new(BTreeMap::new()),
            fail_on_next_record: AtomicBool::new(false),
        })
    }

    fn put(&self, id: &str, text: &str) {
        let mut r = self.records.lock().unwrap();
        r.insert(
            id.to_string(),
            CorpusContentRecord {
                id: id.to_string(),
                revision: 1,
                digest: content_digest(text),
                text: text.to_string(),
                dense_composition_text: None,
            },
        );
    }

    /// Arm: the next record() call will return Err (single-use).
    fn arm_fault(&self) {
        self.fail_on_next_record.store(true, Ordering::SeqCst);
    }
}

impl CorpusContentSource for FaultSource {
    fn record(&self, id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
        if self.fail_on_next_record.swap(false, Ordering::SeqCst) {
            return Err(CorpusKitError::StoreUnavailable(
                "FaultSource: forced record() failure for abort path test".into(),
            ));
        }
        Ok(self.records.lock().unwrap().get(id).cloned())
    }

    fn changes(
        &self,
        _cursor: Option<&str>,
        _limit: usize,
    ) -> Result<CorpusContentChangeBatch, CorpusKitError> {
        Ok(CorpusContentChangeBatch::empty())
    }

    fn active_content_ids(&self) -> Result<Vec<CorpusContentId>, CorpusKitError> {
        let r = self.records.lock().unwrap();
        let mut ids: Vec<String> = r.keys().cloned().collect();
        ids.sort();
        Ok(ids)
    }
}

// ── Storage inspection helpers ──────────────────────────────────────────────

/// Read shadow_state for model_id from vector_generations. Returns None when
/// no row exists or when shadow_state is SQL NULL.
fn shadow_state(storage: &dyn Storage, model_id: &str) -> Option<String> {
    let rows = storage
        .row_store()
        .query(
            "vector_generations",
            Some(&StoragePredicate::Eq(
                Column::new("vector_generations", "model_id"),
                TypedValue::Text(model_id.to_string()),
            )),
            &[],
            Some(1),
            None,
        )
        .expect("query vector_generations");
    let row = rows.first()?;
    match row.get("shadow_state") {
        Some(TypedValue::Text(s)) => Some(s.clone()),
        _ => None,  // NULL or absent: shadow_state has been cleared
    }
}

/// Read serving_generation for model_id. Returns None when no registry row exists.
fn serving_generation(storage: &dyn Storage, model_id: &str) -> Option<i64> {
    let rows = storage
        .row_store()
        .query(
            "vector_generations",
            Some(&StoragePredicate::Eq(
                Column::new("vector_generations", "model_id"),
                TypedValue::Text(model_id.to_string()),
            )),
            &[],
            Some(1),
            None,
        )
        .expect("query vector_generations");
    let row = rows.first()?;
    match row.get("serving_generation") {
        Some(TypedValue::Int(v)) => Some(*v),
        Some(TypedValue::Text(s)) => s.parse().ok(),
        _ => None,
    }
}

/// Count ALL rows in vectors for model_id, regardless of generation.
fn vector_row_count(storage: &dyn Storage, model_id: &str) -> usize {
    storage
        .row_store()
        .query(
            "vectors",
            Some(&StoragePredicate::Eq(
                Column::new("vectors", "model_id"),
                TypedValue::Text(model_id.to_string()),
            )),
            &[],
            None,
            None,
        )
        .expect("query vectors")
        .len()
}

// ── Engine factory ──────────────────────────────────────────────────────────

fn make_abort_test_engine(
    storage: Arc<dyn Storage>,
    source: Arc<FaultSource>,
) -> CorpusContentEngine {
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Standalone,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .expect("abort test engine configuration");

    CorpusContentEngine::open(
        storage,
        config,
        source as Arc<dyn CorpusContentSource>,
        vec![EmbeddingModelConfig::RandomIndexing {
            provider: Box::new(RandomIndexingProvider::new()),
        }],
        false,
    )
    .expect("abort test engine open")
}

// ── c4: all four assertions ──────────────────────────────────────────────────

/// Scenario: first reindex succeeds (serving_gen=1, 6 vectors). Then the
/// source is armed to throw on the next record() call, so the second reindex
/// fails inside train_trainable_slots (after begin_shadow_generation, before
/// any shadow vectors are written, and before publish_shadow_generation).
///
/// Expected state after the failed second reindex:
///
///   c4a: the error propagates — reindex returns Err, not Ok.
///
///   c4b: shadow_state is NOT 'building'. Pre-fix, the registry row is left
///        with shadow_state='building', so this assertion FAILS before the
///        C2 fix is applied. Post-fix, abandon_shadow_generation sets
///        shadow_state to NULL.
///
///   c4c: serving_generation remains 1 — old generation still serves.
///
///   c4d: vector count remains 6 — no vectors stranded at shadow generation.
///
/// This test FAILS on the current code (pre-fix c4b), demonstrating the bug:
/// shadow_state='building' is the orphaned third state the governing invariant
/// forbids.
#[test]
fn c4_failed_reindex_abandons_orphaned_shadow() {
    let (storage, _guard) = make_scratch_storage();
    let source = FaultSource::new();
    source.put("doc-1", "the quick brown fox jumps over the lazy dog");
    source.put("doc-2", "machine learning and natural language processing");
    source.put("doc-3", "cats and dogs are common household pets");

    let engine = make_abort_test_engine(Arc::clone(&storage), Arc::clone(&source));

    // ── First reindex: success — establishes serving_gen=1, 6 vectors ────────
    engine.reindex(NOW_MILLIS).expect("first reindex");

    let gen1 = serving_generation(&*storage, RI_MODEL_ID);
    assert_eq!(gen1, Some(1), "setup: serving_generation must be 1 after first reindex");

    let count_after_first = vector_row_count(&*storage, RI_MODEL_ID);
    assert_eq!(count_after_first, 6, "setup: 6 vectors after first reindex (3 items × 2 lanes)");

    // ── Arm fault: next record() call throws ─────────────────────────────────
    // This fires inside train_trainable_slots on the second reindex, which runs
    // after begin_shadow_generation. The shadow is open (shadow_state='building')
    // when the error propagates.
    source.arm_fault();

    // ── Second reindex: must return Err (c4a) ────────────────────────────────
    // Pre-fix: leaves shadow_state='building' in the registry.
    // Post-fix: abandon_shadow_generation is called, shadow_state cleared.
    let result = engine.reindex(NOW_MILLIS);
    assert!(
        result.is_err(),
        "c4a: second reindex must return Err when the source fails"
    );

    // ── c4b: shadow_state must NOT be 'building' ─────────────────────────────
    // Before the fix, shadow_state='building' and this assertion FAILS, which
    // demonstrates the bug. After the fix, shadow_state is NULL (None here).
    let state = shadow_state(&*storage, RI_MODEL_ID);
    assert_ne!(
        state.as_deref(),
        Some("building"),
        "c4b: shadow_state must not be 'building' after a failed reindex — \
         pre-fix this was 'building' (orphaned third state). Got: {:?}",
        state
    );

    // ── c4c: serving_generation unchanged — old generation still serves ───────
    let gen_after_fail = serving_generation(&*storage, RI_MODEL_ID);
    assert_eq!(
        gen_after_fail,
        Some(1),
        "c4c: serving_generation must remain 1 when second reindex fails before publish"
    );

    // ── c4d: vector count unchanged — no vectors stranded at shadow gen ────────
    let count_after_fail = vector_row_count(&*storage, RI_MODEL_ID);
    assert_eq!(
        count_after_fail, 6,
        "c4d: vector count must remain 6 — no shadow vectors stranded at invisible generation"
    );
}
