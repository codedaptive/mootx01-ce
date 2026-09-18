// reindex_stale_vector_cleanup_tests.rs
//
// Finding B — Rust port: `Corpus::reindex` must prune stale vector rows for
// removed sources under non-trainable slot model IDs.
//
// Non-trainable slots (Deterministic, FDC) are skipped in Phase 2's re-embed
// loop because their vectors are basis-invariant and re-embedding is wasted
// work. This skip means `replace_model_vectors` — which clears a model's
// entire vector set before re-inserting only the active chunks — never runs
// for those slots. Without an explicit cleanup pass, vectors written for a
// source before it was removed can survive a full reindex indefinitely,
// breaking the hard-delete contract for the non-trainable lane.
//
// Test approach (a): DIFFERING SLOT SET ACROSS OPENS (production-reachable).
//   1. Open corpus with non-trainable slot only → ingest doc A.
//      Vectors for doc A's chunks are written under the non-trainable model_id.
//   2. Reopen with trainable slot only → remove doc A.
//      `remove()` fans out only over HELD model IDs; the trainable slot's
//      model_id is the only one held. No trainable vectors exist (the first
//      open had no trainable slot), so the inner `delete_all_vectors` is a
//      no-op. The non-trainable vectors survive. The source is added to
//      removed_sources.
//   3. Reopen with BOTH slots → reindex.
//      After the fix: the cleanup pass reads removed_sources, enumerates
//      doc A's chunks, and deletes vectors under the non-trainable model_id.
//      After reindex: zero vector rows for doc A's chunks under the non-
//      trainable model_id.
//
// Also includes a regression guard for Finding A: after
// `destroy_recall_index`, both `corpus_provider_term_dictionary` and
// `corpus_provider_term_payload` must be empty (closed by commit bbe3c7c52).

use corpus_kit::{Corpus, EmbeddingModelConfig};
use corpus_kit_providers::RandomIndexingProvider;
use persistence_kit::database_inventory::canonical_value_encoding;
use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage, TypedValue};
use std::collections::BTreeMap;
use std::sync::Arc;
use uuid::Uuid;

// ── Helpers ──────────────────────────────────────────────────────────────────

struct TempDir(std::path::PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn scratch_path() -> (String, TempDir) {
    let dir = std::env::temp_dir().join(format!("corpuskit-stale-vec-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("scratch dir");
    let path = dir.join("estate.sqlite3").to_string_lossy().into_owned();
    (path, TempDir(dir))
}

fn storage_at(path: &str) -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    Arc::new(SqliteStorage::new(config).expect("open sqlite"))
}

/// Returns every vector row keyed by "{model_id}|{item_id}|{vector_index}".
/// Used to assert presence / absence of rows under a specific model_id.
fn all_vector_rows(storage: &Arc<dyn Storage>) -> BTreeMap<String, ()> {
    let rows = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .expect("query vectors");
    let mut out = BTreeMap::new();
    for row in rows {
        if let (Some(TypedValue::Text(model)), Some(TypedValue::Text(item)), Some(vi)) = (
            row.get("model_id"),
            row.get("item_id"),
            row.get("vector_index"),
        ) {
            let key = format!("{model}|{item}|{}", canonical_value_encoding(vi));
            out.insert(key, ());
        }
    }
    out
}

/// All vector rows whose key starts with "{model_id}|".
fn vector_rows_for_model(storage: &Arc<dyn Storage>, model_id: &str) -> Vec<String> {
    all_vector_rows(storage)
        .into_keys()
        .filter(|k| k.starts_with(&format!("{model_id}|")))
        .collect()
}

/// Row count in a named table.
fn table_row_count(storage: &Arc<dyn Storage>, table: &str) -> usize {
    storage
        .row_store()
        .query(table, None, &[], None, None)
        .unwrap_or_default()
        .len()
}

// The Deterministic provider's stable model_id (corpus.rs:465).
const DETERMINISTIC_MODEL_ID: &str = "corpus-deterministic-v1";
const NOW_MILLIS: i64 = 1_700_000_000_000;

// ── Finding B — stale-vector cleanup for non-trainable slots ─────────────────

/// Reindex must prune vector rows for removed sources under non-trainable
/// slot model IDs, even when those rows survived `remove()` because the
/// non-trainable slot was not held at the time of removal.
///
/// Approach (a): differing slot set across three opens — production-reachable.
#[test]
fn reindex_prunes_stale_non_trainable_vectors_for_removed_sources() {
    let (path, _tmp) = scratch_path();

    // Step 1 — open with non-trainable slot only; ingest doc A.
    // Non-trainable vectors are written for doc A's chunks under DETERMINISTIC_MODEL_ID.
    {
        let corpus =
            Corpus::open(storage_at(&path), EmbeddingModelConfig::Deterministic).expect("open-1");
        corpus
            .ingest("The quick brown fox jumps over the lazy dog.", "doc-a", NOW_MILLIS)
            .expect("ingest doc-a");
    }

    // Verify vectors exist for doc A under the non-trainable model.
    {
        let storage = storage_at(&path);
        let rows = vector_rows_for_model(&storage, DETERMINISTIC_MODEL_ID);
        assert!(
            !rows.is_empty(),
            "precondition: non-trainable vectors must exist after ingest; got none"
        );
    }

    // Step 2 — open with trainable slot only; remove doc A.
    // `remove()` calls `delete_all_vectors` only for the HELD model_id (the
    // trainable slot). No trainable vectors were ever written (step 1 held no
    // trainable slot), so the inner delete is a no-op. The non-trainable vectors
    // survive. The source is recorded in removed_sources.
    {
        let corpus = Corpus::open_many(
            storage_at(&path),
            vec![EmbeddingModelConfig::RandomIndexing {
                provider: Box::new(RandomIndexingProvider::new()),
            }],
        )
        .expect("open-2-trainable-only");
        corpus.remove("doc-a").expect("remove doc-a");
    }

    // Precondition guard: non-trainable vectors must STILL be present at this
    // point (the bug's stale-row condition), so the test exercises the fix.
    {
        let storage = storage_at(&path);
        let rows = vector_rows_for_model(&storage, DETERMINISTIC_MODEL_ID);
        assert!(
            !rows.is_empty(),
            "precondition: non-trainable vectors must survive mismatched-slot remove; \
             got none — cannot verify reindex cleanup"
        );
    }

    // Step 3 — open with BOTH slots; reindex.
    // The fix's cleanup pass reads removed_sources, enumerates doc A's chunks,
    // and deletes their rows under DETERMINISTIC_MODEL_ID before the re-embed loop.
    {
        let corpus = Corpus::open_many(
            storage_at(&path),
            vec![
                EmbeddingModelConfig::RandomIndexing {
                    provider: Box::new(RandomIndexingProvider::new()),
                },
                EmbeddingModelConfig::Deterministic,
            ],
        )
        .expect("open-3-both");
        corpus.reindex(NOW_MILLIS).expect("reindex");
    }

    // Assert: after reindex, zero non-trainable vector rows remain for doc A.
    let storage = storage_at(&path);
    let rows_after = vector_rows_for_model(&storage, DETERMINISTIC_MODEL_ID);
    assert!(
        rows_after.is_empty(),
        "reindex must prune non-trainable vectors for removed sources; \
         {} row(s) remain: {:?}",
        rows_after.len(),
        rows_after,
    );
}

// ── Finding A regression guard ────────────────────────────────────────────────

/// After `destroy_recall_index`, both `corpus_provider_term_dictionary` and
/// `corpus_provider_term_payload` must be empty.
///
/// Closed by commit bbe3c7c52: `CorpusProviderCountsStore::delete_all` now
/// explicitly deletes both v4 term tables in addition to the v3 vocab table
/// and the two counts tables it already cleared. This test locks that fixed
/// behaviour in so a future edit cannot re-open the gap.
#[test]
fn destroy_recall_index_clears_term_dictionary_and_payload() {
    let (path, _tmp) = scratch_path();

    // Open with a trainable slot (PPMI uses CorpusProviderCountsStore) and
    // ingest a few documents so the counts / term tables are populated.
    // Deterministic is the easier single-slot path for term-table coverage:
    // even the counts-store schema is created on open_many for all slot types.
    {
        let corpus =
            Corpus::open(storage_at(&path), EmbeddingModelConfig::Deterministic).expect("open");
        corpus
            .ingest("Foxes are cunning animals.", "doc-1", NOW_MILLIS)
            .expect("ingest 1");
        corpus
            .ingest("Dogs are loyal companions.", "doc-2", NOW_MILLIS)
            .expect("ingest 2");
        // Reindex so counts / vocab accumulation runs.
        corpus.reindex(NOW_MILLIS).expect("reindex");
    }

    // Destroy recall index.
    {
        let corpus =
            Corpus::open(storage_at(&path), EmbeddingModelConfig::Deterministic).expect("open2");
        corpus.destroy_recall_index().expect("destroy_recall_index");
    }

    // Both v4 term tables must be empty after destroy.
    let storage = storage_at(&path);
    let dict_count = table_row_count(&storage, "corpus_provider_term_dictionary");
    let payload_count = table_row_count(&storage, "corpus_provider_term_payload");
    assert_eq!(
        dict_count,
        0,
        "corpus_provider_term_dictionary must be empty after destroy_recall_index; \
         found {dict_count} row(s)"
    );
    assert_eq!(
        payload_count,
        0,
        "corpus_provider_term_payload must be empty after destroy_recall_index; \
         found {payload_count} row(s)"
    );
}
