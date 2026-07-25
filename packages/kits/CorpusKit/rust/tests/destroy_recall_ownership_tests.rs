// destroy_recall_ownership_tests.rs
//
// Ownership-scoped legacy teardown (GLK shared-content 1.1, P5) — Rust
// twin of Swift `DestroyRecallOwnershipTests.swift`.
//
// `Corpus::destroy_recall_index()` on SHARED storage must delete exactly
// the corpus's own vector rows (its chunk IDs under its held models) and
// leave every row other lanes wrote — same model or different model —
// byte-identically intact. The broad whole-table teardown
// (`destroy_all_vectors`) is reserved for the whole-estate destruction
// path in the GLK EstateCoordinator and must never run on this path.

use corpus_kit::corpus::{Corpus, EmbeddingModelConfig};
use engram_lib::Engram;
use vectorkit::VectorStore;
use persistence_kit::database_inventory::canonical_value_encoding;
use persistence_kit::{
    BackendConfiguration, EstateConfiguration, SqliteStorage, Storage, TypedValue,
};
use std::collections::BTreeMap;
use std::sync::Arc;
use uuid::Uuid;

struct TempDir(std::path::PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn make_storage() -> (Arc<dyn Storage>, TempDir) {
    let dir = std::env::temp_dir().join(format!("corpuskit-ownership-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("scratch dir");
    let path = dir.join("estate.sqlite3").to_string_lossy().into_owned();
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path,
            busy_timeout_secs: 5.0,
        },
    );
    let storage: Arc<dyn Storage> = Arc::new(SqliteStorage::new(config).expect("open sqlite"));
    (storage, TempDir(dir))
}

/// Canonical map of every vectors-table row: "model|item|index" → payload
/// encoding. Payload bytes are the collateral-mutation detector.
fn vector_rows(storage: &Arc<dyn Storage>) -> BTreeMap<String, String> {
    let rows = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .expect("query vectors");
    let mut out = BTreeMap::new();
    for row in rows {
        if let (Some(TypedValue::Text(item)), Some(vi), Some(TypedValue::Text(model))) =
            (row.get("item_id"), row.get("vector_index"), row.get("model_id"))
        {
            let key = format!("{model}|{item}|{}", canonical_value_encoding(vi));
            let payload = row
                .get("payload")
                .map(canonical_value_encoding)
                .unwrap_or_default();
            out.insert(key, payload);
        }
    }
    out
}

#[test]
fn destroy_recall_index_leaves_foreign_vectors_intact() {
    let (storage, _tmp) = make_storage();
    let corpus =
        Corpus::open(Arc::clone(&storage), EmbeddingModelConfig::Deterministic).expect("corpus");
    corpus
        .ingest(
            "The corpus indexes this sentence about engines.",
            "doc-1",
            1_700_000_000_000,
        )
        .expect("ingest doc-1");
    corpus
        .ingest(
            "A second sentence about animals and pets.",
            "doc-2",
            1_700_000_000_000,
        )
        .expect("ingest doc-2");

    // Plant FOREIGN rows directly in the shared vectors table: another
    // lane's item under the corpus's OWN model, and another lane's item
    // under a different model. Neither belongs to the corpus; both must
    // survive the teardown byte-identically.
    let foreign_store = VectorStore::open(Arc::clone(&storage)).expect("vector store");
    let engram = Engram::new(11, 22, 33, 44);
    foreign_store
        .add_vector(
            "drawer-foreign-1",
            &engram,
            "corpus-deterministic-v1",
            "1.0.0",
            1_700_000_000,
        )
        .expect("plant foreign 1");
    foreign_store
        .add_vector(
            "drawer-foreign-2",
            &engram,
            "other-lane-model",
            "1.0.0",
            1_700_000_000,
        )
        .expect("plant foreign 2");

    let before = vector_rows(&storage);
    let foreign_keys: Vec<String> = before
        .keys()
        .filter(|k| k.contains("drawer-foreign"))
        .cloned()
        .collect();
    assert_eq!(foreign_keys.len(), 2);
    // The corpus really has rows of its own to delete.
    assert!(before.len() > 2);

    corpus.destroy_recall_index().expect("destroy recall index");

    let after = vector_rows(&storage);
    // Exactly the two foreign rows survive, byte-identical.
    assert_eq!(after.len(), 2, "only foreign rows must survive: {after:?}");
    for key in &foreign_keys {
        assert_eq!(after.get(key), before.get(key));
    }
}
