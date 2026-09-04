//! shadow_swap_corpus_tests.rs
//!
//! Rust twin of ShadowSwapCorpusTests.swift (VEC-SHADOWSWAP-01 UNIT D).
//!
//! Three scenarios mirroring the Swift suite (c1–c3):
//!
//!   c1. Two consecutive reindex passes on a corpus with a trainable RI slot:
//!       (a) first reindex trains, writes gen-1 vectors, publishes serving_gen=1;
//!       (b) second reindex writes gen-2 vectors, publishes serving_gen=2, and
//!           leaves gen-1 rows on-disk as pending-reclaim (total = 12 rows).
//!
//!       Why two passes: index_content skips RI vectors while the slot has no
//!       persisted basis (not yet trained). The first reindex trains the basis
//!       and writes gen-1 vectors; the second performs the full superseded-
//!       generation cycle.
//!
//!   c2. BM25 recall-unchanged at engine level: the same keyword query before
//!       and after reindex returns the same item set. The swap replaces vector
//!       representations without disturbing the inverted index.
//!
//!   c3. Reindex failure path: when the content source fails mid-reindex
//!       (after begin_shadow_generation but before publish_shadow_generation),
//!       the error propagates and the previously published generation continues
//!       serving (serving_generation stays at the prior value).
//!
//! Storage: on-disk SQLite (RAII temp dir) — the same backend production uses.
//! InMemoryStorage hides SQLite round-trip decode bugs and is not used here.

use corpus_kit::{
    CorpusContentConfiguration, CorpusContentEngine, CorpusContentId,
    CorpusContentRecord, CorpusContentSource, CorpusContentChangeBatch, CorpusKitError,
    CorpusOperatingMode, CorpusIndexUnitPolicy, EmbeddingModelConfig,
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

/// Deterministic epoch-millis shared across all tests. Never SystemTime::now().
const NOW_MILLIS: i64 = 1_755_000_000_000;

/// Model ID for the RandomIndexing slot (must match what the provider returns).
const RI_MODEL_ID: &str = "random-indexing-v1";

// ── RAII temp dir ──────────────────────────────────────────────────────────

/// RAII guard: removes the temp directory on drop.
struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Create a per-test temp dir and return `(storage, _guard)`.
/// The SQLite file lives at `<tmpdir>/shadow-swap-<uuid>.sqlite3`.
fn make_scratch_storage() -> (Arc<dyn Storage>, TempDir) {
    let dir = std::env::temp_dir().join(format!("shadow-swap-rs-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    let path = dir
        .join(format!("shadow-swap-{}.sqlite3", Uuid::new_v4()))
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

/// `CorpusContentSource` backed by an in-memory map.
/// Can be armed to fail on the next `record()` call (simulates a mid-reindex
/// source failure, producing the c3 scenario).
struct FaultSource {
    records: Mutex<BTreeMap<String, CorpusContentRecord>>,
    /// When true, the next `record()` call returns `Err` and resets the flag.
    fail_on_next_record: AtomicBool,
}

impl FaultSource {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            records: Mutex::new(BTreeMap::new()),
            fail_on_next_record: AtomicBool::new(false),
        })
    }

    /// Insert or replace a record. Revision is always 1 (tests don't exercise
    /// revision tracking; only the digest matters for coverage idempotence).
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

    /// Arm the source to fail on the next `record()` call. The flag is
    /// single-use (reset on consumption).
    fn arm_fault(&self) {
        self.fail_on_next_record.store(true, Ordering::SeqCst);
    }
}

impl CorpusContentSource for FaultSource {
    fn record(&self, id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
        // Consume the fault flag atomically: if armed, fail once and disarm.
        if self.fail_on_next_record.swap(false, Ordering::SeqCst) {
            return Err(CorpusKitError::StoreUnavailable(
                "FaultSource: forced record() failure for c3 test".into(),
            ));
        }
        Ok(self.records.lock().unwrap().get(id).cloned())
    }

    fn changes(
        &self,
        _cursor: Option<&str>,
        _limit: usize,
    ) -> Result<CorpusContentChangeBatch, CorpusKitError> {
        // Reindex tests go through active_content_ids + record(), not the feed.
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

/// Read `serving_generation` for `model_id` from the `vector_generations` table.
/// Returns `None` when no registry row exists (canonical initial state — no swap
/// has occurred yet).
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

/// Count ALL rows in `vectors` for `model_id`, regardless of generation.
/// Includes both serving and pending-reclaim rows.
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

/// Build a `CorpusContentEngine` in standalone whole-content mode with one
/// RandomIndexing (trainable) slot over a custom `FaultSource`.
fn make_ri_engine(
    storage: Arc<dyn Storage>,
    source: Arc<FaultSource>,
) -> CorpusContentEngine {
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Standalone,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .expect("RI engine configuration");

    CorpusContentEngine::open(
        storage,
        config,
        source as Arc<dyn CorpusContentSource>,
        vec![EmbeddingModelConfig::RandomIndexing {
            provider: Box::new(RandomIndexingProvider::new()),
        }],
        false,
    )
    .expect("RI engine open")
}

// ── c1: generation advance + pending-reclaim accumulation ──────────────────

/// Two consecutive reindex passes on a corpus with a trainable RI slot:
///
/// Pass 1 (first reindex): the engine has no persisted basis yet, so
/// index_content skips RI vectors. reindex trains the basis (force=true),
/// opens a shadow at gen 1, writes 6 rows (3 items × 2 lanes: binary +
/// float), and publishes. Result: serving_gen=1, 6 serving rows.
///
/// Pass 2 (second reindex): basis is persisted. reindex opens a shadow at
/// gen 2, writes 6 new rows, and publishes. The 6 gen-1 rows are marked
/// pending-reclaim. Total rows = 12.
///
/// Mirrors Swift c1.
#[test]
fn c1_two_reindex_passes_advance_generation_and_leave_reclaim_rows() {
    let (storage, _guard) = make_scratch_storage();
    let source = FaultSource::new();
    source.put("item-1", "the quick brown fox jumped over the lazy dog");
    source.put("item-2", "machine learning and natural language processing");
    source.put("item-3", "cats and dogs are common household pets");

    let engine = make_ri_engine(Arc::clone(&storage), Arc::clone(&source));

    // ── Pass 1: first shadow swap — trains basis, writes gen-1 vectors ──
    engine.reindex(NOW_MILLIS).expect("pass 1 reindex");

    let gen1 = serving_generation(&*storage, RI_MODEL_ID);
    assert_eq!(
        gen1,
        Some(1),
        "c1 pass1: serving_generation must be 1 after first reindex (shadow gen 1 published)"
    );

    // In standalone mode the RI slot writes both a binary row (vector_index=0)
    // and a float row (vector_index=1) per item. 3 items × 2 lanes = 6 rows.
    // No prior gen-0 RI rows existed (index_content skips untrained slots), so
    // all 6 rows are serving gen-1 with nothing pending-reclaim.
    let rows1 = vector_row_count(&*storage, RI_MODEL_ID);
    assert_eq!(
        rows1, 6,
        "c1 pass1: 6 gen-1 serving rows (2 lanes × 3 items); no prior RI rows to pend-reclaim"
    );

    // ── Pass 2: second shadow swap — gen-1 rows become pending-reclaim ──
    engine.reindex(NOW_MILLIS).expect("pass 2 reindex");

    let gen2 = serving_generation(&*storage, RI_MODEL_ID);
    assert_eq!(gen2, Some(2), "c1 pass2: serving_generation must be 2 after second reindex");

    // 6 gen-1 rows marked pending-reclaim + 6 gen-2 serving rows = 12 total.
    let rows2 = vector_row_count(&*storage, RI_MODEL_ID);
    assert_eq!(
        rows2, 12,
        "c1 pass2: 12 total rows — 6 gen-1 pending-reclaim + 6 gen-2 serving"
    );
}

// ── c2: BM25 recall stable across reindex ──────────────────────────────────

/// BM25 lexical recall is unaffected by the shadow swap. The same keyword
/// query before and after reindex must return the same item set. The swap
/// replaces vector representations only — the inverted index is rebuilt from
/// the same text, so BM25 coverage is unchanged.
///
/// Mirrors Swift c2.
#[test]
fn c2_bm25_recall_unchanged_after_reindex() {
    let (storage, _guard) = make_scratch_storage();
    let source = FaultSource::new();
    source.put("recall-a", "the quick brown fox jumps over");
    source.put("recall-b", "lazy dog and sunshine in the yard");
    source.put("recall-c", "birds fly high in the morning sky");

    let engine = make_ri_engine(Arc::clone(&storage), Arc::clone(&source));

    // Index each item before reindex — populates BM25 inverted index.
    engine.index_content("recall-a", NOW_MILLIS).expect("index recall-a");
    engine.index_content("recall-b", NOW_MILLIS).expect("index recall-b");
    engine.index_content("recall-c", NOW_MILLIS).expect("index recall-c");

    // Recall before reindex: BM25 is populated by index_content.
    let before: Vec<String> = engine
        .bm25_top_k_by_source("fox", 10)
        .into_iter()
        .map(|(id, _)| id)
        .collect();
    assert!(
        before.contains(&"recall-a".to_string()),
        "c2: 'fox' must find recall-a before reindex (BM25 in place)"
    );

    // Run the shadow swap.
    engine.reindex(NOW_MILLIS).expect("reindex");

    // Recall after reindex — BM25 is rebuilt from the same text; must find the
    // same items.
    let after: Vec<String> = engine
        .bm25_top_k_by_source("fox", 10)
        .into_iter()
        .map(|(id, _)| id)
        .collect();

    let before_set: std::collections::HashSet<_> = before.into_iter().collect();
    let after_set: std::collections::HashSet<_> = after.into_iter().collect();
    assert_eq!(
        after_set, before_set,
        "c2: BM25 recall set must be identical before and after the shadow swap reindex"
    );
}

// ── c3: failure during reindex leaves prior generation serving ─────────────

/// After one successful reindex (serving_gen=1), arming the source to fail
/// causes the second reindex to fail after begin_shadow_generation but before
/// publish_shadow_generation. The error propagates and serving_generation
/// remains at 1 — the old generation is intact.
///
/// The failure fires inside train_trainable_slots (which calls source.record()
/// for each content ID), which is called after begin_shadow_generation in the
/// new reindex flow. This verifies that publish_shadow_generation is the only
/// commit point: a failure between begin and publish leaves the estate safe.
///
/// Mirrors Swift c3.
#[test]
fn c3_reindex_failure_leaves_old_generation_serving() {
    let (storage, _guard) = make_scratch_storage();
    let source = FaultSource::new();
    source.put("stable-1", "the universe is expanding outward");
    source.put("stable-2", "black holes bend spacetime significantly");

    let engine = make_ri_engine(Arc::clone(&storage), Arc::clone(&source));

    // First reindex succeeds — establishes serving_gen=1.
    engine.reindex(NOW_MILLIS).expect("first reindex");
    let gen_after_first = serving_generation(&*storage, RI_MODEL_ID);
    assert_eq!(
        gen_after_first,
        Some(1),
        "c3: serving_generation is 1 after first successful reindex"
    );

    // Arm the source to fail on the next record() call. This fires inside
    // train_trainable_slots (called after begin_shadow_generation), causing
    // the second reindex to abort before publish_shadow_generation.
    source.arm_fault();

    // Second reindex must propagate the source error.
    let result = engine.reindex(NOW_MILLIS);
    assert!(
        result.is_err(),
        "c3: second reindex must fail when the source returns an error"
    );

    // serving_generation must remain 1 — the prior generation is intact.
    let gen_after_fail = serving_generation(&*storage, RI_MODEL_ID);
    assert_eq!(
        gen_after_fail,
        Some(1),
        "c3: serving_generation must remain 1 when second reindex fails before publish_shadow_generation"
    );
}
