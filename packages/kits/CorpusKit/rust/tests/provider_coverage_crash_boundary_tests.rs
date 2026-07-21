// provider_coverage_crash_boundary_tests.rs
//
// Rust twin of Swift `ProviderCoverageCrashBoundaryTests.swift` — crash-
// boundary coverage for the corrective pass's provider machinery: streamed
// training with atomic basis+counts commits, per-provider coverage rows as
// the backfill's resume authority, digest-mismatch re-coverage, provider
// addition to an already-indexed estate, and claim-aware shared-vector
// ownership on remove/destroy.

use corpus_kit::content_engine::CorpusContentEngine;
use corpus_kit::corpus::EmbeddingModelConfig;
use corpus_kit::basis_store::BasisStore;
use corpus_kit::corpus_provider_counts_store::CorpusProviderCountsStore;
use corpus_kit_providers::{PpmiProvider, RandomIndexingProvider};
use persistence_kit::{
    BackendConfiguration, Column, EstateConfiguration, SqliteStorage, Storage, StoragePredicate,
    TypedValue,
};
use std::collections::BTreeMap;
use std::sync::Arc;
use uuid::Uuid;
use vectorkit::{VectorRepresentationClaims, VectorRepresentationKey};

const NOW: i64 = 1_700_000_000_000;

struct TempDir(std::path::PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn scratch_storage() -> (Arc<dyn Storage>, TempDir) {
    let dir = std::env::temp_dir().join(format!("corpuskit-coverage-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("scratch dir");
    let path = dir.join("estate.sqlite3").to_string_lossy().into_owned();
    let storage: Arc<dyn Storage> = Arc::new(
        SqliteStorage::new(EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite { path, busy_timeout_secs: 5.0 },
        ))
        .expect("open sqlite"),
    );
    (storage, TempDir(dir))
}

fn ri() -> EmbeddingModelConfig {
    EmbeddingModelConfig::RandomIndexing { provider: Box::new(RandomIndexingProvider::new()) }
}

fn ppmi() -> EmbeddingModelConfig {
    EmbeddingModelConfig::Ppmi { provider: Box::new(PpmiProvider::new()) }
}

fn docs(engine: &CorpusContentEngine, count: usize) -> Result<(), corpus_kit::error::CorpusKitError> {
    for index in 0..count {
        engine.ingest(
            &format!("document {index} about signals lanes coverage and drawers"),
            &format!("doc-{index:03}"),
            NOW,
        )?;
    }
    Ok(())
}

fn basis_row(storage: &Arc<dyn Storage>, model_id: &str) -> Option<Vec<u8>> {
    BasisStore::new(Arc::clone(storage))
        .load(model_id, "1.0.0")
        .ok()
        .flatten()
        .map(|b| b.basis)
}

fn vector_bytes(storage: &Arc<dyn Storage>, model_id: &str) -> BTreeMap<String, Vec<u8>> {
    let rows = storage
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
        .expect("query vectors");
    let mut out = BTreeMap::new();
    for row in rows {
        if let (Some(TypedValue::Text(item)), Some(TypedValue::Int(lane)), Some(TypedValue::Blob(payload))) =
            (row.get("item_id"), row.get("vector_index"), row.get("payload"))
        {
            out.insert(format!("{item}|{lane}"), payload.clone());
        }
    }
    out
}

// ── 1+2. Training interruption before/after basis publication ───────────

#[test]
fn training_fault_before_commit_retrains_from_zero() {
    let (storage, _tmp) = scratch_storage();
    let engine =
        CorpusContentEngine::standalone_on(Arc::clone(&storage), vec![ri()]).expect("engine");
    engine.arm_train_fault_before_commit(Some("random-indexing-v1"));
    assert!(docs(&engine, 3).is_err(), "training fault must surface");
    assert!(basis_row(&storage, "random-indexing-v1").is_none());
    assert!(CorpusProviderCountsStore::new(Arc::clone(&storage))
        .load("random-indexing-v1", "1.0.0")
        .expect("counts load")
        .is_none());

    // Resume: retrains from zero, commits once, full coverage.
    docs(&engine, 3).expect("resume ingest");
    assert!(basis_row(&storage, "random-indexing-v1").is_some());
    assert!(CorpusProviderCountsStore::new(Arc::clone(&storage))
        .load("random-indexing-v1", "1.0.0")
        .expect("counts load")
        .is_some());
    assert_eq!(engine.covered_count("random-indexing-v1").expect("count"), Some(3));
}

#[test]
fn training_fault_after_commit_skips_committed_provider_on_resume() {
    let (storage, _tmp) = scratch_storage();
    let engine = CorpusContentEngine::standalone_on(Arc::clone(&storage), vec![ri(), ppmi()])
        .expect("engine");
    engine.arm_train_fault_after(Some("random-indexing-v1"));
    assert!(docs(&engine, 3).is_err());
    let ri_blob = basis_row(&storage, "random-indexing-v1").expect("RI committed");
    assert!(basis_row(&storage, "ppmi-v1").is_none());

    docs(&engine, 3).expect("resume ingest");
    assert_eq!(basis_row(&storage, "random-indexing-v1"), Some(ri_blob));
    assert!(basis_row(&storage, "ppmi-v1").is_some());
    assert_eq!(engine.covered_count("random-indexing-v1").expect("count"), Some(3));
    assert_eq!(engine.covered_count("ppmi-v1").expect("count"), Some(3));
}

// ── 3. Backfill interruption before/after vector-batch persistence ──────

#[test]
fn backfill_fault_after_vectors_resumes_without_loss_or_duplication() {
    let (storage, _tmp) = scratch_storage();
    let engine_a = CorpusContentEngine::standalone_on(
        Arc::clone(&storage),
        vec![EmbeddingModelConfig::Deterministic],
    )
    .expect("engine A");
    docs(&engine_a, 5).expect("ingest");

    // Reopen with an ADDED trainable provider.
    let engine_b = CorpusContentEngine::standalone_on(
        Arc::clone(&storage),
        vec![EmbeddingModelConfig::Deterministic, ri()],
    )
    .expect("engine B");
    engine_b.train_trainable_slots(NOW, false).expect("train");
    engine_b.arm_backfill_fault_hook(Some(Box::new(|phase, _| {
        if phase == "afterVectors" { Err("injected".to_string()) } else { Ok(()) }
    })));
    assert!(engine_b.backfill_provider_coverage(NOW, 2).is_err());
    engine_b.arm_backfill_fault_hook(None);
    let mid = engine_b.covered_count("random-indexing-v1").expect("count").unwrap_or(0);
    assert!(mid < 5);

    let before = vector_bytes(&storage, "random-indexing-v1");
    assert!(!before.is_empty(), "durable vectors lead coverage");

    let written = engine_b.backfill_provider_coverage(NOW, 2).expect("resume");
    assert_eq!(written, 5 - mid);
    assert_eq!(engine_b.covered_count("random-indexing-v1").expect("count"), Some(5));
    let after = vector_bytes(&storage, "random-indexing-v1");
    for (key, bytes) in &before {
        assert_eq!(after.get(key), Some(bytes), "replayed row {key} must be byte-identical");
    }
    assert_eq!(engine_b.backfill_provider_coverage(NOW, 500).expect("third"), 0);
}

#[test]
fn backfill_fault_after_coverage_is_already_durable() {
    let (storage, _tmp) = scratch_storage();
    let engine_a = CorpusContentEngine::standalone_on(
        Arc::clone(&storage),
        vec![EmbeddingModelConfig::Deterministic],
    )
    .expect("engine A");
    docs(&engine_a, 4).expect("ingest");
    let engine_b = CorpusContentEngine::standalone_on(
        Arc::clone(&storage),
        vec![EmbeddingModelConfig::Deterministic, ri()],
    )
    .expect("engine B");
    engine_b.train_trainable_slots(NOW, false).expect("train");
    engine_b.arm_backfill_fault_hook(Some(Box::new(|phase, batch| {
        if phase == "afterCoverage" && batch == 0 { Err("injected".to_string()) } else { Ok(()) }
    })));
    assert!(engine_b.backfill_provider_coverage(NOW, 2).is_err());
    engine_b.arm_backfill_fault_hook(None);
    assert_eq!(engine_b.covered_count("random-indexing-v1").expect("count"), Some(2));
    assert_eq!(engine_b.backfill_provider_coverage(NOW, 2).expect("resume"), 2);
    assert_eq!(engine_b.covered_count("random-indexing-v1").expect("count"), Some(4));
}

// ── 4+5. Coverage disagreement and basis-digest mismatch ────────────────

#[test]
fn lagging_and_mismatched_coverage_rows_are_healed_exactly() {
    let (storage, _tmp) = scratch_storage();
    let engine = CorpusContentEngine::standalone_on(
        Arc::clone(&storage),
        vec![EmbeddingModelConfig::Deterministic, ri()],
    )
    .expect("engine");
    docs(&engine, 4).expect("ingest");
    assert_eq!(engine.covered_count("random-indexing-v1").expect("count"), Some(4));

    // Lagging row: delete one coverage row.
    storage
        .row_store()
        .delete(
            "corpus_provider_coverage",
            &StoragePredicate::all(vec![
                StoragePredicate::Eq(
                    Column::new("corpus_provider_coverage", "content_id"),
                    TypedValue::Text("doc-001".to_string()),
                ),
                StoragePredicate::Eq(
                    Column::new("corpus_provider_coverage", "model_id"),
                    TypedValue::Text("random-indexing-v1".to_string()),
                ),
            ]),
        )
        .expect("delete");
    // Stale generation: tamper another row's digest.
    let mut values = BTreeMap::new();
    values.insert("content_id".into(), TypedValue::Text("doc-002".to_string()));
    values.insert("model_id".into(), TypedValue::Text("random-indexing-v1".to_string()));
    values.insert("basis_digest".into(), TypedValue::Text("stale-digest".to_string()));
    values.insert("updated_at".into(), TypedValue::Timestamp(NOW));
    storage
        .row_store()
        .upsert(
            "corpus_provider_coverage",
            values,
            &["content_id".to_string(), "model_id".to_string()],
        )
        .expect("tamper");

    assert_eq!(engine.backfill_provider_coverage(NOW, 500).expect("heal"), 2);
    assert_eq!(engine.covered_count("random-indexing-v1").expect("count"), Some(4));
    assert_eq!(engine.backfill_provider_coverage(NOW, 500).expect("idle"), 0);
}

// ── 7. Exact shared-vector ownership on remove/destroy ──────────────────

#[test]
fn shared_representation_survives_remove_and_destroy() {
    let (storage, _tmp) = scratch_storage();
    let engine = CorpusContentEngine::standalone_on(
        Arc::clone(&storage),
        vec![EmbeddingModelConfig::Deterministic],
    )
    .expect("engine");
    docs(&engine, 2).expect("ingest");

    let claims = VectorRepresentationClaims::new(Arc::clone(&storage));
    for lane in [0u32, 1u32] {
        claims
            .register_claim(
                "other-lane",
                &VectorRepresentationKey::new(
                    "corpus-deterministic-v1".to_string(),
                    "1.0.0".to_string(),
                    lane,
                ),
                NOW,
            )
            .expect("claim");
    }

    let before = vector_bytes(&storage, "corpus-deterministic-v1");
    assert!(!before.is_empty());

    engine.remove_content("doc-000").expect("remove");
    assert_eq!(vector_bytes(&storage, "corpus-deterministic-v1"), before);

    engine.destroy_recall_index().expect("destroy");
    assert_eq!(vector_bytes(&storage, "corpus-deterministic-v1"), before);

    for lane in [0u32, 1u32] {
        claims
            .release_claim(
                "other-lane",
                &VectorRepresentationKey::new(
                    "corpus-deterministic-v1".to_string(),
                    "1.0.0".to_string(),
                    lane,
                ),
            )
            .expect("release");
    }
    let engine_c = CorpusContentEngine::standalone_on(
        Arc::clone(&storage),
        vec![EmbeddingModelConfig::Deterministic],
    )
    .expect("engine C");
    docs(&engine_c, 2).expect("ingest");
    engine_c.destroy_recall_index().expect("destroy");
    assert!(vector_bytes(&storage, "corpus-deterministic-v1").is_empty());
}
