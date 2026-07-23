//! Canonical-ID engine coverage (GLK shared-content 1.1, P2).
//! Rust twin of the Swift `CorpusContentEngineTests`.

use corpus_kit::corpus_provider_counts_store::CorpusProviderCountsStore;
use corpus_kit::{
    content_digest, ContentIndexJob, CorpusContentChange, CorpusContentConfiguration,
    CorpusContentEngine, CorpusContentId, CorpusContentRecord, CorpusContentSource,
    CorpusContentStore, CorpusDocumentStore, CorpusIndexStateStore, CorpusIndexUnitPolicy,
    CorpusKitError, CorpusOperatingMode, EmbeddingModelConfig,
};
use persistence_kit::database_inventory::capture_inventory;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::SqliteStorage;
use persistence_kit::{
    BackendConfiguration, Column, EstateConfiguration, Storage, StoragePredicate, TypedValue,
};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000_000;

#[derive(Default)]
struct ReindexConcurrencyProbe {
    active: AtomicUsize,
    peak: AtomicUsize,
}

impl ReindexConcurrencyProbe {
    fn enter(&self) {
        let active = self.active.fetch_add(1, Ordering::SeqCst) + 1;
        self.peak.fetch_max(active, Ordering::SeqCst);
    }

    fn leave(&self) {
        self.active.fetch_sub(1, Ordering::SeqCst);
    }
}

struct ReindexConcurrencyProvider {
    probe: Arc<ReindexConcurrencyProbe>,
}

struct PublicationRaceState {
    records: BTreeMap<String, CorpusContentRecord>,
    blocked_id: Option<String>,
    block_entered: bool,
    released: bool,
}

struct PublicationRaceSource {
    state: Mutex<PublicationRaceState>,
    condition: Condvar,
}

impl PublicationRaceSource {
    fn new(records: Vec<CorpusContentRecord>) -> Self {
        Self {
            state: Mutex::new(PublicationRaceState {
                records: records
                    .into_iter()
                    .map(|record| (record.id.clone(), record))
                    .collect(),
                blocked_id: None,
                block_entered: false,
                released: false,
            }),
            condition: Condvar::new(),
        }
    }

    fn add(&self, record: CorpusContentRecord) {
        self.state
            .lock()
            .unwrap()
            .records
            .insert(record.id.clone(), record);
    }

    fn block_next_record(&self, id: &str) {
        let mut state = self.state.lock().unwrap();
        state.blocked_id = Some(id.to_string());
        state.block_entered = false;
        state.released = false;
    }

    fn wait_until_blocked(&self) {
        let mut state = self.state.lock().unwrap();
        while !state.block_entered {
            state = self.condition.wait(state).unwrap();
        }
    }

    fn release_blocked_record(&self) {
        self.state.lock().unwrap().released = true;
        self.condition.notify_all();
    }
}

impl CorpusContentSource for PublicationRaceSource {
    fn record(&self, id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
        let mut state = self.state.lock().unwrap();
        if state.blocked_id.as_deref() == Some(id) {
            state.blocked_id = None;
            state.block_entered = true;
            self.condition.notify_all();
            while !state.released {
                state = self.condition.wait(state).unwrap();
            }
        }
        Ok(state.records.get(id).cloned())
    }

    fn changes(
        &self,
        _cursor: Option<&str>,
        _limit: usize,
    ) -> Result<corpus_kit::CorpusContentChangeBatch, CorpusKitError> {
        Ok(corpus_kit::CorpusContentChangeBatch::empty())
    }

    fn active_content_ids(&self) -> Result<Vec<CorpusContentId>, CorpusKitError> {
        Ok(self.state.lock().unwrap().records.keys().cloned().collect())
    }
}

impl vectorkit::EmbeddingProvider for ReindexConcurrencyProvider {
    fn model_id(&self) -> &str {
        "reindex-concurrency-probe"
    }

    fn model_version(&self) -> &str {
        "1.0.0"
    }

    fn embed(&self, _text: &str) -> Result<engram_lib::Engram, vectorkit::VectorKitError> {
        Ok(engram_lib::Engram::ZERO)
    }

    fn embed_pair(
        &self,
        _text: &str,
    ) -> Result<(engram_lib::Engram, Vec<f32>), vectorkit::VectorKitError> {
        self.probe.enter();
        std::thread::sleep(Duration::from_millis(20));
        self.probe.leave();
        Ok((engram_lib::Engram::ZERO, vec![1.0]))
    }
}

fn in_memory_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

fn make_standalone(
    index_unit: CorpusIndexUnitPolicy,
) -> (
    CorpusContentEngine,
    Arc<CorpusDocumentStore>,
    Arc<dyn Storage>,
) {
    let storage = in_memory_storage();
    let config =
        CorpusContentConfiguration::new(CorpusOperatingMode::Standalone, index_unit).unwrap();
    #[cfg(feature = "standalone-passages")]
    let passages = matches!(index_unit, CorpusIndexUnitPolicy::TokenWindows { .. });
    #[cfg(not(feature = "standalone-passages"))]
    let passages = false;
    storage
        .migrate(&corpus_kit::standalone_declaration(passages))
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
    let expected: BTreeSet<String> = ["drawer-moon", "drawer-rust"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(item_ids(&storage, "vectors", "item_id"), expected);

    // No legacy copy lane exists in this estate.
    assert!(storage.row_store().count("chunks", None).is_err());

    // Recall returns the content ID directly; BM25 frontier too.
    let hits = engine.recall("moon landing", 10).unwrap();
    assert_eq!(hits.first().map(|h| h.id.as_str()), Some("drawer-moon"));
    assert!(hits.first().unwrap().evidence.is_none());
    let keyword = engine.bm25_top_k("ownership isolates", 5).unwrap();
    assert_eq!(
        keyword.first().map(|(id, _)| id.as_str()),
        Some("drawer-rust")
    );

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
fn direct_revisions_use_the_same_restart_stable_counts_admission() {
    use corpus_kit_providers::RandomIndexingProvider;

    let storage = in_memory_storage();
    storage
        .migrate(&corpus_kit::standalone_declaration(false))
        .expect("content schema");
    let source = Arc::new(CorpusDocumentStore::new(Arc::clone(&storage)));
    source
        .put("direct training anchor", "anchor", NOW)
        .expect("put anchor");
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .expect("configuration");
    let models = || {
        vec![EmbeddingModelConfig::RandomIndexing {
            provider: Box::new(RandomIndexingProvider::new()),
        }]
    };
    let engine = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        models(),
    )
    .expect("engine");
    engine
        .train_trainable_slots(NOW, false)
        .expect("train anchor");

    let first = source
        .put("direct firstnovel", "direct", NOW + 1)
        .expect("put first revision");
    engine
        .apply_change(
            &CorpusContentChange::Upsert {
                id: first.id,
                revision: first.revision,
                digest: first.digest,
            },
            Some("direct-1"),
            NOW + 1,
        )
        .expect("apply first revision");
    let first_anchor = engine.maintained_vocab_anchor();

    let second = source
        .put(
            "direct firstnovel secondnovel",
            "direct",
            NOW + 2,
        )
        .expect("put second revision");
    engine
        .apply_change(
            &CorpusContentChange::Upsert {
                id: second.id,
                revision: second.revision,
                digest: second.digest,
            },
            Some("direct-2"),
            NOW + 2,
        )
        .expect("apply second revision");
    let second_anchor = engine.maintained_vocab_anchor();
    assert!(second_anchor > first_anchor);
    assert_eq!(engine.maintained_document_count(), 2);

    let reopened = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        models(),
    )
    .expect("reopen engine");
    assert_eq!(reopened.maintained_vocab_anchor(), second_anchor);
    assert_eq!(reopened.maintained_document_count(), 2);

    let third = source
        .put(
            "direct firstnovel secondnovel thirdnovel",
            "direct",
            NOW + 3,
        )
        .expect("put third revision");
    reopened
        .apply_change(
            &CorpusContentChange::Upsert {
                id: third.id,
                revision: third.revision,
                digest: third.digest,
            },
            Some("direct-3"),
            NOW + 3,
        )
        .expect("apply third revision");
    let third_anchor = reopened.maintained_vocab_anchor();
    assert!(third_anchor > second_anchor);

    let reopened_again = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        source as Arc<dyn CorpusContentSource>,
        models(),
    )
    .expect("reopen engine again");
    assert_eq!(reopened_again.maintained_vocab_anchor(), third_anchor);
    assert_eq!(reopened_again.maintained_document_count(), 2);
}

#[test]
fn direct_checkpoint_failure_rolls_back_counts_admission() {
    use corpus_kit_providers::RandomIndexingProvider;

    let root = std::env::temp_dir().join(format!(
        "corpus-direct-atomic-{}",
        Uuid::new_v4().simple()
    ));
    std::fs::create_dir_all(&root).expect("create scratch directory");
    let path = root.join("estate.sqlite");
    let storage: Arc<dyn Storage> = Arc::new(
        SqliteStorage::new(EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path.to_string_lossy().into_owned(),
                busy_timeout_secs: 5.0,
            },
        ))
        .expect("open SQLite storage"),
    );
    storage
        .migrate(&CorpusDocumentStore::schema_declaration())
        .expect("document schema");
    let source = Arc::new(CorpusDocumentStore::new(Arc::clone(&storage)));
    source
        .put("direct atomic anchor", "anchor", NOW)
        .expect("put anchor");
    let configuration = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .expect("configuration");
    let models = || {
        vec![EmbeddingModelConfig::RandomIndexing {
            provider: Box::new(RandomIndexingProvider::new()),
        }]
    };
    let engine = CorpusContentEngine::open(
        Arc::clone(&storage),
        configuration,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        models(),
    )
    .expect("open engine");
    engine
        .train_trainable_slots(NOW, false)
        .expect("train anchor");

    let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
    let before = counts_store
        .load("random-indexing-v1", "1.1.0")
        .expect("load counts")
        .expect("counts row");
    let revision = source
        .put(
            "direct atomic novel vocabulary",
            "direct-atomic",
            NOW + 1,
        )
        .expect("put direct revision");

    rusqlite::Connection::open(&path)
        .expect("open trigger connection")
        .execute_batch(
            "CREATE TRIGGER fail_direct_checkpoint \
             BEFORE INSERT ON corpus_index_state \
             BEGIN SELECT RAISE(ABORT, 'injected direct checkpoint failure'); END;",
        )
        .expect("install checkpoint trigger");
    let result = engine.apply_change(
        &CorpusContentChange::Upsert {
            id: revision.id.clone(),
            revision: revision.revision,
            digest: revision.digest.clone(),
        },
        Some("direct-atomic-1"),
        NOW + 1,
    );
    assert!(result.is_err(), "checkpoint trigger must fail direct apply");

    let after_failure = counts_store
        .load("random-indexing-v1", "1.1.0")
        .expect("load counts after failure")
        .expect("counts row after failure");
    assert_eq!(after_failure.document_count, before.document_count);
    assert_eq!(after_failure.vocab_size, before.vocab_size);
    assert_eq!(
        counts_store
            .references("random-indexing-v1", "1.1.0")
            .expect("load references")
            .into_iter()
            .filter(|reference| !reference.is_subsumed)
            .count(),
        0
    );
    assert!(
        CorpusIndexStateStore::new(Arc::clone(&storage))
            .state(&revision.id)
            .expect("load failed checkpoint")
            .is_none()
    );

    rusqlite::Connection::open(&path)
        .expect("open trigger cleanup connection")
        .execute_batch("DROP TRIGGER fail_direct_checkpoint;")
        .expect("drop checkpoint trigger");
    engine
        .apply_change(
            &CorpusContentChange::Upsert {
                id: revision.id.clone(),
                revision: revision.revision,
                digest: revision.digest.clone(),
            },
            Some("direct-atomic-1"),
            NOW + 1,
        )
        .expect("retry direct apply");
    let after_retry = counts_store
        .load("random-indexing-v1", "1.1.0")
        .expect("load counts after retry")
        .expect("counts row after retry");
    assert_eq!(after_retry.document_count, before.document_count + 1);
    assert_eq!(
        counts_store
            .references("random-indexing-v1", "1.1.0")
            .expect("load retry references")
            .into_iter()
            .filter(|reference| !reference.is_subsumed)
            .count(),
        1
    );
    assert_eq!(
        CorpusIndexStateStore::new(Arc::clone(&storage))
            .state(&revision.id)
            .expect("load retry checkpoint")
            .map(|state| state.digest),
        Some(revision.digest)
    );

    drop(engine);
    drop(source);
    drop(storage);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn provider_publication_preserves_post_snapshot_admission() {
    use corpus_kit_providers::RandomIndexingProvider;

    let storage = in_memory_storage();
    let anchor_text = "publication anchor";
    let anchor = CorpusContentRecord {
        id: "anchor".into(),
        revision: 1,
        digest: content_digest(anchor_text),
        text: anchor_text.into(),
    };
    let source = Arc::new(PublicationRaceSource::new(vec![anchor.clone()]));
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .expect("configuration");
    let engine = Arc::new(
        CorpusContentEngine::open(
            Arc::clone(&storage),
            config,
            Arc::clone(&source) as Arc<dyn CorpusContentSource>,
            vec![EmbeddingModelConfig::RandomIndexing {
                provider: Box::new(RandomIndexingProvider::new()),
            }],
        )
        .expect("open engine"),
    );
    engine
        .train_trainable_slots(NOW, false)
        .expect("train anchor");

    source.block_next_record(&anchor.id);
    let retraining_engine = Arc::clone(&engine);
    let retrain = std::thread::spawn(move || {
        retraining_engine
            .train_trainable_slots(NOW + 1, true)
            .expect("force retrain");
    });
    source.wait_until_blocked();

    let late_text = "post snapshot vocabulary";
    let late = CorpusContentRecord {
        id: "late".into(),
        revision: 1,
        digest: content_digest(late_text),
        text: late_text.into(),
    };
    source.add(late.clone());
    let admission_engine = Arc::clone(&engine);
    let admission = std::thread::spawn(move || {
        admission_engine
            .apply_change(
                &CorpusContentChange::Upsert {
                    id: late.id,
                    revision: late.revision,
                    digest: late.digest,
                },
                None,
                NOW + 1,
            )
            .expect("apply post-snapshot admission");
    });
    std::thread::sleep(Duration::from_millis(50));
    source.release_blocked_record();
    retrain.join().expect("join retrain");
    admission.join().expect("join admission");

    let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
    let after = counts_store
        .load("random-indexing-v1", "1.1.0")
        .expect("load counts")
        .expect("counts row");
    assert_eq!(after.document_count, 2);
    assert_eq!(
        counts_store
            .reference_for("random-indexing-v1", "1.1.0", "late")
            .expect("load late reference")
            .map(|reference| reference.digest),
        Some(content_digest(late_text))
    );
}

#[test]
fn provider_publication_does_not_refold_pre_snapshot_pending_admission() {
    use corpus_kit_providers::RandomIndexingProvider;

    let storage = in_memory_storage();
    let anchor_text = "publication anchor";
    let anchor = CorpusContentRecord {
        id: "anchor".into(),
        revision: 1,
        digest: content_digest(anchor_text),
        text: anchor_text.into(),
    };
    let source = Arc::new(PublicationRaceSource::new(vec![anchor.clone()]));
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .expect("configuration");
    let engine = Arc::new(
        CorpusContentEngine::open(
            Arc::clone(&storage),
            config,
            Arc::clone(&source) as Arc<dyn CorpusContentSource>,
            vec![EmbeddingModelConfig::RandomIndexing {
                provider: Box::new(RandomIndexingProvider::new()),
            }],
        )
        .expect("open engine"),
    );
    engine
        .train_trainable_slots(NOW, false)
        .expect("train anchor");
    engine
        .apply_change(
            &CorpusContentChange::Upsert {
                id: anchor.id.clone(),
                revision: anchor.revision,
                digest: anchor.digest.clone(),
            },
            None,
            NOW,
        )
        .expect("checkpoint anchor");

    let pending_text = "pre snapshot pending vocabulary";
    let pending = CorpusContentRecord {
        id: "pending".into(),
        revision: 1,
        digest: content_digest(pending_text),
        text: pending_text.into(),
    };
    source.add(pending.clone());

    source.block_next_record(&anchor.id);
    let retraining_engine = Arc::clone(&engine);
    let retrain = std::thread::spawn(move || {
        retraining_engine
            .train_trainable_slots(NOW + 1, true)
            .expect("force retrain");
    });
    source.wait_until_blocked();
    let admission_engine = Arc::clone(&engine);
    let pending_for_admission = pending.clone();
    let admission = std::thread::spawn(move || {
        admission_engine
            .apply_change(
                &CorpusContentChange::Upsert {
                    id: pending_for_admission.id,
                    revision: pending_for_admission.revision,
                    digest: pending_for_admission.digest,
                },
                None,
                NOW + 1,
            )
            .expect("apply pre-snapshot pending admission");
    });
    std::thread::sleep(Duration::from_millis(50));
    source.release_blocked_record();
    retrain.join().expect("join retrain");
    admission.join().expect("join admission");

    let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
    let after = counts_store
        .load("random-indexing-v1", "1.1.0")
        .expect("load counts")
        .expect("counts row");
    assert_eq!(after.document_count, 2);
    assert_eq!(
        counts_store
            .reference_for("random-indexing-v1", "1.1.0", &pending.id)
            .expect("load pending reference"),
        None
    );
    assert_eq!(
        CorpusIndexStateStore::new(Arc::clone(&storage))
            .state(&pending.id)
            .expect("load pending checkpoint")
            .map(|state| state.digest),
        Some(pending.digest)
    );

    let reopened = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        source as Arc<dyn CorpusContentSource>,
        vec![EmbeddingModelConfig::RandomIndexing {
            provider: Box::new(RandomIndexingProvider::new()),
        }],
    )
    .expect("reopen engine");
    assert_eq!(reopened.maintained_document_count(), 2);
}

#[test]
fn provider_publication_marker_survives_reopen_before_admission() {
    use corpus_kit_providers::RandomIndexingProvider;

    let storage = in_memory_storage();
    let text = "published before delayed admission";
    let pending = CorpusContentRecord {
        id: "pending-reopen".into(),
        revision: 1,
        digest: content_digest(text),
        text: text.into(),
    };
    let source = Arc::new(PublicationRaceSource::new(vec![pending.clone()]));
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .expect("configuration");
    let models = || {
        vec![EmbeddingModelConfig::RandomIndexing {
            provider: Box::new(RandomIndexingProvider::new()),
        }]
    };
    let engine = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        models(),
    )
    .expect("open engine");
    engine
        .train_trainable_slots(NOW, false)
        .expect("publish pending content");
    engine
        .persist_counts_snapshot(NOW + 1)
        .expect("compact counts while marker is pending");

    let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
    assert_eq!(
        counts_store
            .reference_for("random-indexing-v1", "1.1.0", &pending.id)
            .expect("load marker")
            .map(|reference| reference.is_subsumed),
        Some(true)
    );

    let reopened = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        models(),
    )
    .expect("reopen engine");
    reopened
        .apply_change(
            &CorpusContentChange::Upsert {
                id: pending.id.clone(),
                revision: pending.revision,
                digest: pending.digest.clone(),
            },
            None,
            NOW + 2,
        )
        .expect("apply delayed admission after reopen");

    let after = counts_store
        .load("random-indexing-v1", "1.1.0")
        .expect("load counts")
        .expect("counts row");
    assert_eq!(after.document_count, 1);
    assert_eq!(
        counts_store
            .reference_for("random-indexing-v1", "1.1.0", &pending.id)
            .expect("load consumed marker"),
        None
    );
    assert_eq!(reopened.maintained_document_count(), 1);
}

#[test]
fn whole_content_reindex_uses_bounded_parallel_embedding_preparation() {
    let storage = in_memory_storage();
    storage
        .migrate(&corpus_kit::standalone_declaration(false))
        .expect("content schema");
    let source = Arc::new(CorpusDocumentStore::new(Arc::clone(&storage)));
    for index in 0..12 {
        source
            .put(
                &format!("parallel reindex content {index}"),
                &format!("parallel-{index}"),
                NOW,
            )
            .expect("put content");
    }
    let probe = Arc::new(ReindexConcurrencyProbe::default());
    let engine = CorpusContentEngine::open(
        Arc::clone(&storage),
        CorpusContentConfiguration::new(
            CorpusOperatingMode::Attached,
            CorpusIndexUnitPolicy::WholeContent,
        )
        .expect("configuration"),
        source as Arc<dyn CorpusContentSource>,
        vec![EmbeddingModelConfig::Fdc {
            provider: Box::new(ReindexConcurrencyProvider {
                probe: Arc::clone(&probe),
            }),
        }],
    )
    .expect("engine");

    engine.reindex(NOW).expect("reindex");

    let bound = std::thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(1);
    let peak = probe.peak.load(Ordering::SeqCst);
    assert!(peak <= bound, "peak {peak} exceeded worker bound {bound}");
    if bound > 1 {
        assert!(peak > 1, "parallel-capable host ran reindex serially");
    }
    assert_eq!(engine.indexed_content_ids().expect("indexed IDs").len(), 12);
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

#[cfg(feature = "standalone-passages")]
#[test]
fn passage_windows_use_token_overlap_deterministically() {
    let text = "one two three four five six seven";
    let ranges = corpus_kit::passage_ranges(text, 4, 2);
    let excerpts: Vec<&str> = ranges
        .iter()
        .map(|(start, length)| {
            std::str::from_utf8(&text.as_bytes()[*start..*start + *length]).unwrap()
        })
        .collect();
    assert_eq!(
        excerpts,
        vec!["one two three four", "three four five six", "five six seven"]
    );
}

#[cfg(feature = "standalone-passages")]
#[test]
fn passage_policy_is_bound_per_standalone_database() {
    let first = in_memory_storage();
    first
        .migrate(&corpus_kit::standalone_declaration(true))
        .unwrap();
    let first_authority = corpus_kit::CorpusIndexConfigurationStore::new(Arc::clone(&first));
    let first_policy = CorpusIndexUnitPolicy::TokenWindows {
        window_tokens: 512,
        overlap_tokens: 64,
    };
    first_authority.bind(first_policy).unwrap();
    first_authority.bind(first_policy).unwrap();
    assert_eq!(
        first_authority.fingerprint().unwrap().as_deref(),
        Some("token-windows-v1:corpus-alphanumeric-v1:512:64")
    );
    let mismatch = first_authority.bind(
        CorpusIndexUnitPolicy::TokenWindows {
            window_tokens: 256,
            overlap_tokens: 32,
        },
    );
    assert!(matches!(mismatch, Err(CorpusKitError::InvalidConfiguration(_))));

    let second = in_memory_storage();
    second
        .migrate(&corpus_kit::standalone_declaration(true))
        .unwrap();
    let second_authority = corpus_kit::CorpusIndexConfigurationStore::new(Arc::clone(&second));
    second_authority
        .bind(
            CorpusIndexUnitPolicy::TokenWindows {
                window_tokens: 256,
                overlap_tokens: 32,
            },
        )
        .unwrap();
    assert_eq!(
        second_authority.fingerprint().unwrap().as_deref(),
        Some("token-windows-v1:corpus-alphanumeric-v1:256:32")
    );

    // A pre-feature database with existing whole-content state cannot be
    // silently reinterpreted as passage-indexed.
    let existing = in_memory_storage();
    existing
        .migrate(&corpus_kit::standalone_declaration(true))
        .unwrap();
    let mut row = BTreeMap::new();
    row.insert("item_id".to_string(), TypedValue::Text("existing-doc".into()));
    row.insert("length".to_string(), TypedValue::Int(10));
    existing.row_store().insert("iix_doclens", row).unwrap();
    let existing_authority =
        corpus_kit::CorpusIndexConfigurationStore::new(Arc::clone(&existing));
    let result = existing_authority.bind(
        CorpusIndexUnitPolicy::TokenWindows {
            window_tokens: 128,
            overlap_tokens: 16,
        },
    );
    assert!(matches!(result, Err(CorpusKitError::InvalidConfiguration(_))));
}

#[cfg(feature = "standalone-passages")]
#[test]
fn passage_mode_indexes_ranges_and_aggregates_to_content_id() {
    let (engine, store, storage) = make_standalone(CorpusIndexUnitPolicy::TokenWindows {
        window_tokens: 6,
        overlap_tokens: 2,
    });
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
    assert_eq!(rows.len(), 4);
    for row in &rows {
        assert!(row.get("text").is_none());
        if let Some(TypedValue::Int(revision)) = row.get("revision") {
            assert_eq!(*revision, rec.revision);
        }
    }

    // Derived vector keys are passage keys that parse back to the ID
    // (four overlapping passage keys; each carries binary + float lanes).
    let vec_keys = item_ids(&storage, "vectors", "item_id");
    assert_eq!(vec_keys.len(), 4);
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
    fn record(&self, id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
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

    for table in [
        "corpus_documents",
        "chunks",
        "corpus_metadata",
        "corpus_passages",
    ] {
        assert!(
            storage.row_store().count(table, None).is_err(),
            "attached estate must not contain {table}"
        );
    }
    let hits = engine.recall("llamas", 10).unwrap();
    assert_eq!(hits.first().map(|h| h.id.as_str()), Some("drawer-a"));
}

#[test]
fn provider_addition_and_subtraction_reconcile_without_residue() {
    let storage = in_memory_storage();
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .unwrap();
    let source: Arc<dyn CorpusContentSource> = Arc::new(StaticContentSource {
        records: vec![
            CorpusContentRecord {
                id: "drawer-a".into(),
                revision: 1,
                digest: content_digest("alpha provider coverage"),
                text: "alpha provider coverage".into(),
            },
            CorpusContentRecord {
                id: "drawer-b".into(),
                revision: 1,
                digest: content_digest("beta provider coverage"),
                text: "beta provider coverage".into(),
            },
        ],
    });
    let small = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        Arc::clone(&source),
        vec![EmbeddingModelConfig::Deterministic],
    )
    .unwrap();
    small
        .index_content_structural_batch(&["drawer-a".into(), "drawer-b".into()], NOW)
        .unwrap();
    small.reconcile_configured_providers(NOW).unwrap();

    let big = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        Arc::clone(&source),
        vec![
            EmbeddingModelConfig::Deterministic,
            EmbeddingModelConfig::RandomIndexing {
                provider: Box::new(corpus_kit_providers::RandomIndexingProvider::new()),
            },
        ],
    )
    .unwrap();
    big.reconcile_configured_providers(NOW).unwrap();
    assert_eq!(big.covered_count("random-indexing-v1").unwrap(), Some(2));
    for table in ["corpus_provider_basis", "corpus_provider_counts"] {
        assert_eq!(
            storage
                .row_store()
                .count(
                    table,
                    Some(&StoragePredicate::Eq(
                        Column::new(table, "model_id"),
                        TypedValue::Text("random-indexing-v1".into()),
                    )),
                )
                .unwrap(),
            1,
        );
    }
    let maintained_anchor = big.maintained_vocab_anchor();
    assert!(maintained_anchor > 0);
    let reopened = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        Arc::clone(&source),
        vec![
            EmbeddingModelConfig::Deterministic,
            EmbeddingModelConfig::RandomIndexing {
                provider: Box::new(corpus_kit_providers::RandomIndexingProvider::new()),
            },
        ],
    )
    .unwrap();
    reopened.reconcile_configured_providers(NOW).unwrap();
    assert_eq!(reopened.maintained_vocab_anchor(), maintained_anchor);
    let before_retrain = reopened
        .provider_generations()
        .into_iter()
        .find(|(model_id, _)| model_id == "random-indexing-v1")
        .map(|(_, digest)| digest)
        .expect("persisted RI generation");
    let retrained = reopened
        .train_trainable_slots(NOW + 1, true)
        .expect("reopened engine must retain a trainable reconstruction witness");
    assert_eq!(
        retrained.get("random-indexing-v1"),
        Some(&before_retrain),
        "unchanged reopen + retrain must reproduce the persisted generation"
    );

    let removed = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        source,
        vec![EmbeddingModelConfig::Deterministic],
    )
    .unwrap();
    removed.reconcile_configured_providers(NOW).unwrap();
    for table in [
        "vectors",
        "corpus_provider_basis",
        "corpus_provider_counts",
        "corpus_provider_coverage",
    ] {
        assert_eq!(
            storage
                .row_store()
                .count(
                    table,
                    Some(&StoragePredicate::Eq(
                        Column::new(table, "model_id"),
                        TypedValue::Text("random-indexing-v1".into()),
                    )),
                )
                .unwrap(),
            0,
            "retired provider residue survived in {table}",
        );
    }
    let claims = vectorkit::VectorRepresentationClaims::new(Arc::clone(&storage));
    assert!(claims
        .claims(corpus_kit::CLAIMS_CONSUMER)
        .unwrap()
        .iter()
        .all(|key| key.model_id != "random-indexing-v1"));
    removed.reconcile_configured_providers(NOW).unwrap();
    assert_eq!(
        removed.covered_count("corpus-deterministic-v1").unwrap(),
        Some(2),
    );
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
