//! Canonical-ID engine coverage (GLK shared-content 1.1, P2).
//! Rust twin of the Swift `CorpusContentEngineTests`.

use corpus_kit::{
    content_digest, ContentIndexJob, CorpusContentChange, CorpusContentConfiguration,
    CorpusContentEngine, CorpusContentId, CorpusContentRecord, CorpusContentSource,
    CorpusContentStore, CorpusDocumentStore, CorpusIndexStateStore, CorpusIndexUnitPolicy,
    CorpusKitError, CorpusOperatingMode, EmbeddingModelConfig,
};
use persistence_kit::database_inventory::capture_inventory;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage, TypedValue};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000_000;

fn in_memory_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

fn make_standalone(
    index_unit: CorpusIndexUnitPolicy,
) -> (CorpusContentEngine, Arc<CorpusDocumentStore>, Arc<dyn Storage>) {
    let storage = in_memory_storage();
    let config =
        CorpusContentConfiguration::new(CorpusOperatingMode::Standalone, index_unit).unwrap();
    storage
        .migrate(&corpus_kit::standalone_declaration(matches!(
            index_unit,
            CorpusIndexUnitPolicy::TokenBudgetedPassages { .. }
        )))
        .expect("migrate standalone profile");
    let store = Arc::new(CorpusDocumentStore::new(Arc::clone(&storage)));
    let engine = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        Arc::clone(&store) as Arc<dyn CorpusContentSource>,
        vec![EmbeddingModelConfig::Deterministic],
    )
    .expect("open engine");
    (engine, store, storage)
}

fn item_ids(storage: &Arc<dyn Storage>, table: &str, column: &str) -> BTreeSet<String> {
    let rows = storage
        .row_store()
        .query(table, None, &[], None, None)
        .expect("query");
    rows.iter()
        .filter_map(|row| match row.get(column) {
            Some(TypedValue::Text(v)) => Some(v.clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn derived_keys_are_canonical_content_ids() {
    let (engine, store, storage) = make_standalone(CorpusIndexUnitPolicy::WholeContent);
    store
        .put("The moon landing was in 1969.", "drawer-moon", NOW)
        .unwrap();
    store
        .put("Rust ownership isolates state.", "drawer-rust", NOW)
        .unwrap();
    engine.index_content("drawer-moon", NOW).unwrap();
    engine.index_content("drawer-rust", NOW).unwrap();

    // Vector rows are keyed by the content IDs THEMSELVES. (The Rust BM25
    // sidecar lives in a private connection; identity there is proved via
    // recall below.)
    let expected: BTreeSet<String> =
        ["drawer-moon", "drawer-rust"].iter().map(|s| s.to_string()).collect();
    assert_eq!(item_ids(&storage, "vectors", "item_id"), expected);

    // No legacy copy lane exists in this estate.
    assert!(storage.row_store().count("chunks", None).is_err());

    // Recall returns the content ID directly; BM25 frontier too.
    let hits = engine.recall("moon landing", 10).unwrap();
    assert_eq!(hits.first().map(|h| h.id.as_str()), Some("drawer-moon"));
    assert!(hits.first().unwrap().evidence.is_none());
    let keyword = engine.bm25_top_k("ownership isolates", 5).unwrap();
    assert_eq!(keyword.first().map(|(id, _)| id.as_str()), Some("drawer-rust"));

    let indexed: Vec<CorpusContentId> = engine.indexed_content_ids().unwrap();
    assert_eq!(indexed, vec!["drawer-moon", "drawer-rust"]);
}

#[test]
fn stale_job_is_rejected_without_checkpoint_advance() {
    let (engine, store, storage) = make_standalone(CorpusIndexUnitPolicy::WholeContent);
    let rev1 = store.put("First revision.", "drawer-1", NOW).unwrap();
    engine
        .apply_change(
            &CorpusContentChange::Upsert {
                id: "drawer-1".into(),
                revision: rev1.revision,
                digest: rev1.digest.clone(),
            },
            Some("1"),
            NOW,
        )
        .unwrap();

    let rev2 = store.put("Second revision.", "drawer-1", NOW).unwrap();

    // Replaying the rev-1 job is stale: rejected, checkpoint + cursor stay.
    let result = engine.apply_change(
        &CorpusContentChange::Upsert {
            id: "drawer-1".into(),
            revision: rev1.revision,
            digest: rev1.digest.clone(),
        },
        Some("9"),
        NOW,
    );
    assert!(matches!(result, Err(CorpusKitError::StaleRevision(_))));
    let checkpoint = CorpusIndexStateStore::new(Arc::clone(&storage))
        .state("drawer-1")
        .unwrap()
        .unwrap();
    assert_eq!(checkpoint.revision, rev1.revision);
    assert_eq!(engine.applied_feed_cursor().unwrap(), Some("1".to_string()));

    // The rev-2 job applies cleanly.
    engine
        .apply_change(
            &CorpusContentChange::Upsert {
                id: "drawer-1".into(),
                revision: rev2.revision,
                digest: rev2.digest.clone(),
            },
            Some("2"),
            NOW,
        )
        .unwrap();
    let checkpoint = CorpusIndexStateStore::new(Arc::clone(&storage))
        .state("drawer-1")
        .unwrap()
        .unwrap();
    assert_eq!(checkpoint.revision, rev2.revision);
    assert_eq!(checkpoint.digest, rev2.digest);
    assert_eq!(engine.applied_feed_cursor().unwrap(), Some("2".to_string()));
}

#[test]
fn replaying_the_same_revision_changes_no_derived_bytes() {
    let (engine, store, storage) = make_standalone(CorpusIndexUnitPolicy::WholeContent);
    let rec = store.put("Idempotent content.", "drawer-i", NOW).unwrap();
    let change = CorpusContentChange::Upsert {
        id: "drawer-i".into(),
        revision: rec.revision,
        digest: rec.digest.clone(),
    };
    engine.apply_change(&change, Some("1"), NOW).unwrap();
    let tables = ["vectors", "corpus_index_state"];
    let before = capture_inventory(&storage, &tables, &BTreeMap::new()).unwrap();
    engine.apply_change(&change, Some("1"), NOW).unwrap();
    let after = capture_inventory(&storage, &tables, &BTreeMap::new()).unwrap();
    assert_eq!(before, after);
}

#[test]
fn remove_clears_derived_state_and_records_cursor() {
    let (engine, store, storage) = make_standalone(CorpusIndexUnitPolicy::WholeContent);
    let rec = store.put("Removable content.", "drawer-r", NOW).unwrap();
    engine
        .apply_change(
            &CorpusContentChange::Upsert {
                id: "drawer-r".into(),
                revision: rec.revision,
                digest: rec.digest.clone(),
            },
            Some("1"),
            NOW,
        )
        .unwrap();
    store.remove("drawer-r", NOW).unwrap();
    engine
        .apply_change(
            &CorpusContentChange::Remove {
                id: "drawer-r".into(),
                revision: rec.revision,
            },
            Some("2"),
            NOW,
        )
        .unwrap();

    assert!(item_ids(&storage, "vectors", "item_id").is_empty());
    assert!(engine.indexed_content_ids().unwrap().is_empty());
    assert_eq!(engine.applied_feed_cursor().unwrap(), Some("2".to_string()));
    assert!(engine.recall("removable content", 10).unwrap().is_empty());
}

#[test]
fn job_payload_carries_no_text_and_matches_swift_wire_form() {
    let (engine, store, _storage) = make_standalone(CorpusIndexUnitPolicy::WholeContent);
    let rec = store.put("Job-driven content.", "drawer-q", NOW).unwrap();
    let job = ContentIndexJob::from_change(
        &CorpusContentChange::Upsert {
            id: "drawer-q".into(),
            revision: rec.revision,
            digest: rec.digest.clone(),
        },
        Some("7".to_string()),
    );
    let payload = serde_json::to_string(&job).unwrap();
    assert!(!payload.contains("Job-driven content"));
    assert!(payload.contains("\"contentID\":\"drawer-q\""));
    assert!(payload.contains("\"kind\":\"upsert\""));

    let decoded: ContentIndexJob = serde_json::from_str(&payload).unwrap();
    engine.process_job(&decoded, NOW).unwrap();
    assert_eq!(engine.indexed_content_ids().unwrap(), vec!["drawer-q"]);
    let hits = engine.recall("job-driven", 10).unwrap();
    assert_eq!(hits.first().map(|h| h.id.as_str()), Some("drawer-q"));
}

#[test]
fn passage_mode_indexes_ranges_and_aggregates_to_content_id() {
    let (engine, store, storage) = make_standalone(
        CorpusIndexUnitPolicy::TokenBudgetedPassages { token_budget: 6 },
    );
    let text = "alpha beta gamma delta epsilon zeta \
                eta theta iota kappa lambda mu \
                nu xi omicron";
    let rec = store.put(text, "doc-p", NOW).unwrap();
    engine
        .apply_change(
            &CorpusContentChange::Upsert {
                id: "doc-p".into(),
                revision: rec.revision,
                digest: rec.digest.clone(),
            },
            Some("1"),
            NOW,
        )
        .unwrap();

    // Range rows exist, hold NO text, and are revision-bound.
    let rows = storage
        .row_store()
        .query("corpus_passages", None, &[], None, None)
        .unwrap();
    assert_eq!(rows.len(), 3);
    for row in &rows {
        assert!(row.get("text").is_none());
        if let Some(TypedValue::Int(revision)) = row.get("revision") {
            assert_eq!(*revision, rec.revision);
        }
    }

    // Derived vector keys are passage keys that parse back to the ID
    // (three distinct passage keys; each carries binary + float lanes).
    let vec_keys = item_ids(&storage, "vectors", "item_id");
    assert_eq!(vec_keys.len(), 3);
    for key in &vec_keys {
        assert_eq!(corpus_kit::content_id_from_item_key(key), "doc-p");
    }

    // Recall aggregates to ONE hit with content identity + evidence.
    let hits = engine.recall("lambda mu", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].id, "doc-p");
    let evidence = hits[0].evidence.clone().expect("passage evidence");
    let excerpt = &text.as_bytes()[evidence.utf8_start..evidence.utf8_start + evidence.utf8_length];
    assert!(String::from_utf8_lossy(excerpt).contains("lambda"));

    // Changed text replaces the passage set — no stale revision-1 keys.
    let rec2 = store.put("totally new words here", "doc-p", NOW).unwrap();
    engine
        .apply_change(
            &CorpusContentChange::Upsert {
                id: "doc-p".into(),
                revision: rec2.revision,
                digest: rec2.digest.clone(),
            },
            Some("2"),
            NOW,
        )
        .unwrap();
    let fresh = item_ids(&storage, "vectors", "item_id");
    for key in &fresh {
        assert!(key.contains(&format!("\u{1F}{}\u{1F}", rec2.revision)));
    }
}

/// Static attached-source stand-in.
struct StaticContentSource {
    records: Vec<CorpusContentRecord>,
}

impl CorpusContentSource for StaticContentSource {
    fn record(
        &self,
        id: &str,
    ) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
        Ok(self.records.iter().find(|r| r.id == id).cloned())
    }

    fn changes(
        &self,
        _cursor: Option<&str>,
        _limit: usize,
    ) -> Result<corpus_kit::CorpusContentChangeBatch, CorpusKitError> {
        Ok(corpus_kit::CorpusContentChangeBatch::empty())
    }

    fn active_content_ids(&self) -> Result<Vec<CorpusContentId>, CorpusKitError> {
        let mut ids: Vec<String> = self.records.iter().map(|r| r.id.clone()).collect();
        ids.sort();
        Ok(ids)
    }
}

#[test]
fn attached_engine_opens_without_content_tables_and_returns_drawer_ids() {
    let storage = in_memory_storage();
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .unwrap();
    let text_a = "Attached drawer content about llamas.";
    let text_b = "Another drawer about compilers.";
    let source = Arc::new(StaticContentSource {
        records: vec![
            CorpusContentRecord {
                id: "drawer-a".into(),
                revision: 1,
                digest: content_digest(text_a),
                text: text_a.into(),
            },
            CorpusContentRecord {
                id: "drawer-b".into(),
                revision: 1,
                digest: content_digest(text_b),
                text: text_b.into(),
            },
        ],
    });
    let engine = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        source,
        vec![EmbeddingModelConfig::Deterministic],
    )
    .unwrap();
    engine.index_content("drawer-a", NOW).unwrap();
    engine.index_content("drawer-b", NOW).unwrap();

    for table in ["corpus_documents", "chunks", "corpus_metadata", "corpus_passages"] {
        assert!(
            storage.row_store().count(table, None).is_err(),
            "attached estate must not contain {table}"
        );
    }
    let hits = engine.recall("llamas", 10).unwrap();
    assert_eq!(hits.first().map(|h| h.id.as_str()), Some("drawer-a"));
}

#[test]
fn engine_claims_its_representations() {
    let (engine, store, storage) = make_standalone(CorpusIndexUnitPolicy::WholeContent);
    store.put("Claimed content.", "drawer-c", NOW).unwrap();
    engine.index_content("drawer-c", NOW).unwrap();

    let claims = vectorkit::VectorRepresentationClaims::new(storage);
    let claimed = claims.claims(corpus_kit::CLAIMS_CONSUMER).unwrap();
    assert!(claimed.contains(&vectorkit::VectorRepresentationKey::new(
        "corpus-deterministic-v1",
        "1.0.0",
        0
    )));
    assert!(claimed.contains(&vectorkit::VectorRepresentationKey::new(
        "corpus-deterministic-v1",
        "1.0.0",
        1
    )));
}

#[test]
fn reindex_reindexes_every_active_content_row() {
    let (engine, store, storage) = make_standalone(CorpusIndexUnitPolicy::WholeContent);
    store.put("Alpha doc.", "a", NOW).unwrap();
    store.put("Beta doc.", "b", NOW).unwrap();
    engine.reindex(NOW).unwrap();
    assert_eq!(engine.indexed_content_ids().unwrap(), vec!["a", "b"]);

    // Forced rewrite churns surrogate vector ids; logical bytes identical.
    let mut exclusions: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    exclusions.insert(
        "vectors".to_string(),
        ["id"].iter().map(|s| s.to_string()).collect(),
    );
    let before = capture_inventory(&storage, &["vectors"], &exclusions).unwrap();
    engine.reindex(NOW).unwrap();
    let after = capture_inventory(&storage, &["vectors"], &exclusions).unwrap();
    assert_eq!(before, after);
}
