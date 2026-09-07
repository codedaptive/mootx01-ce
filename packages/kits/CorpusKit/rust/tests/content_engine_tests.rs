//! Canonical-ID engine coverage (GLK shared-content 1.1, P2).
//! Rust twin of the Swift `CorpusContentEngineTests`.

use corpus_kit::corpus_provider_counts_store::{CorpusProviderCountsStore, PersistedCountsReference};
use corpus_kit::{
    content_digest, ContentIndexJob, CorpusContentChange, CorpusContentConfiguration,
    CorpusContentEngine, CorpusContentId, CorpusContentRecord, CorpusContentSource,
    CorpusContentStore, CorpusDocumentStore, CorpusIndexStateStore, CorpusIndexUnitPolicy,
    CorpusKitError, CorpusOperatingMode, CorpusPathReason, EmbeddingModelConfig,
    TrainingPathDecision,
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

    /// Wait until the blocked record's `record()` call has entered the blocking
    /// section. Returns `true` if the block was entered before the deadline, or
    /// `false` if the 10-second timeout expired. Callers must assert the return
    /// value with a descriptive message so a hang surfaces as a test failure
    /// rather than an indefinite suite stall.
    fn wait_until_blocked(&self) -> bool {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        let mut state = self.state.lock().unwrap();
        while !state.block_entered {
            let now = std::time::Instant::now();
            if now >= deadline {
                return false;
            }
            let remaining = deadline - now;
            let (guard, timed_out) = self.condition.wait_timeout(state, remaining).unwrap();
            state = guard;
            if timed_out.timed_out() {
                return false;
            }
        }
        true
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

impl synapsekit::EmbeddingProvider for ReindexConcurrencyProvider {
    fn model_id(&self) -> &str {
        "reindex-concurrency-probe"
    }

    fn model_version(&self) -> &str {
        "1.0.0"
    }

    fn embed(&self, _text: &str) -> Result<engram_lib::Engram, synapsekit::SynapseKitError> {
        Ok(engram_lib::Engram::ZERO)
    }

    fn embed_pair(
        &self,
        _text: &str,
    ) -> Result<(engram_lib::Engram, Vec<f32>), synapsekit::SynapseKitError> {
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
        dense_composition_text: None,
        ssc_facts: None, // supplied by GLK layer (schema 19)
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
    assert!(
        source.wait_until_blocked(),
        "provider_publication_preserves_post_snapshot_admission: timed out waiting for \
         retrain thread to block on anchor record fetch"
    );

    let late_text = "post snapshot vocabulary";
    let late = CorpusContentRecord {
        id: "late".into(),
        revision: 1,
        digest: content_digest(late_text),
        text: late_text.into(),
        dense_composition_text: None,
        ssc_facts: None, // supplied by GLK layer (schema 19)
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
        dense_composition_text: None,
        ssc_facts: None, // supplied by GLK layer (schema 19)
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
        dense_composition_text: None,
        ssc_facts: None, // supplied by GLK layer (schema 19)
    };
    source.add(pending.clone());

    source.block_next_record(&anchor.id);
    let retraining_engine = Arc::clone(&engine);
    let retrain = std::thread::spawn(move || {
        retraining_engine
            .train_trainable_slots(NOW + 1, true)
            .expect("force retrain");
    });
    assert!(
        source.wait_until_blocked(),
        "provider_publication_does_not_refold_pre_snapshot_pending_admission: timed out \
         waiting for retrain thread to block on anchor record fetch"
    );
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
        dense_composition_text: None,
        ssc_facts: None, // supplied by GLK layer (schema 19)
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
                dense_composition_text: None,
                ssc_facts: None, // supplied by GLK layer (schema 19)
            },
            CorpusContentRecord {
                id: "drawer-b".into(),
                revision: 1,
                digest: content_digest(text_b),
                text: text_b.into(),
                dense_composition_text: None,
                ssc_facts: None, // supplied by GLK layer (schema 19)
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
                dense_composition_text: None,
                ssc_facts: None, // supplied by GLK layer (schema 19)
            },
            CorpusContentRecord {
                id: "drawer-b".into(),
                revision: 1,
                digest: content_digest("beta provider coverage"),
                text: "beta provider coverage".into(),
                dense_composition_text: None,
                ssc_facts: None, // supplied by GLK layer (schema 19)
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
    let claims = synapsekit::VectorRepresentationClaims::new(Arc::clone(&storage));
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

    let claims = synapsekit::VectorRepresentationClaims::new(storage);
    let claimed = claims.claims(corpus_kit::CLAIMS_CONSUMER).unwrap();
    assert!(claimed.contains(&synapsekit::VectorRepresentationKey::new(
        "corpus-deterministic-v1",
        "1.0.0",
        0
    )));
    // The whole-record float lane (vector_index 1) is claimed only when the
    // sidecar build writes it (CLAIMED_LANES).
    let float_lane = synapsekit::VectorRepresentationKey::new("corpus-deterministic-v1", "1.0.0", 1);
    assert_eq!(
        claimed.contains(&float_lane),
        cfg!(feature = "whole-record-dense"),
        "lane 1 is claimed exactly in the whole-record-dense build"
    );
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

// ── Part 3 gate tests: training-path decision seam ───────────────────────────
//
// These tests exercise the counts path / corpus path dispatch added in
// CORPUS-INCREMENTAL-01 Part 3. They use the `training_path_decisions()`
// seam getter to assert the branch taken, without re-reading corpus text.

// A source backed by a shared mutable map; tests mutate it to add/remove records.
//
// `fetch_count` is an atomic counter incremented on every `record()` call.
// Tests that measure the F-1 two-directional gate use `reset_fetch_count()`
// immediately before the train call under observation, then read `fetch_count()`
// afterwards to verify that exactly the expected number of bodies were paged.
struct MutableSource {
    records: Mutex<BTreeMap<String, CorpusContentRecord>>,
    fetch_count: AtomicUsize,
}

// The counter and remove helpers serve the dense-families trainable-slot
// tests; the default build compiles them without a caller.
#[cfg_attr(not(feature = "dense-families"), allow(dead_code))]
impl MutableSource {
    fn new() -> Arc<Self> {
        Arc::new(Self { records: Mutex::new(BTreeMap::new()), fetch_count: AtomicUsize::new(0) })
    }

    /// Returns the total number of `record()` calls since the last reset.
    fn fetch_count(&self) -> usize {
        self.fetch_count.load(Ordering::SeqCst)
    }

    /// Resets the fetch counter to zero. Call immediately before the train
    /// call under measurement so only that call's body-page traffic is counted.
    fn reset_fetch_count(&self) {
        self.fetch_count.store(0, Ordering::SeqCst);
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
                ssc_facts: None, // supplied by GLK layer (schema 19)
            },
        );
    }

    fn remove(&self, id: &str) {
        self.records.lock().unwrap().remove(id);
    }
}

impl CorpusContentSource for MutableSource {
    fn record(&self, id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
        // Increment on every body-fetch so tests can measure source traffic.
        self.fetch_count.fetch_add(1, Ordering::SeqCst);
        Ok(self.records.lock().unwrap().get(id).cloned())
    }

    fn changes(
        &self,
        _cursor: Option<&str>,
        _limit: usize,
    ) -> Result<corpus_kit::CorpusContentChangeBatch, CorpusKitError> {
        Ok(corpus_kit::CorpusContentChangeBatch::empty())
    }

    fn active_content_ids(&self) -> Result<Vec<CorpusContentId>, CorpusKitError> {
        let r = self.records.lock().unwrap();
        let mut ids: Vec<String> = r.keys().cloned().collect();
        ids.sort();
        Ok(ids)
    }
}

// A source that always returns None for record() — simulates a dead source.
// Used by the dense-families trainable-slot tests only.
#[cfg_attr(not(feature = "dense-families"), allow(dead_code))]
struct NilSource {
    ids: Vec<String>,
}

impl CorpusContentSource for NilSource {
    fn record(&self, _id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
        Ok(None)
    }

    fn changes(
        &self,
        _cursor: Option<&str>,
        _limit: usize,
    ) -> Result<corpus_kit::CorpusContentChangeBatch, CorpusKitError> {
        Ok(corpus_kit::CorpusContentChangeBatch::empty())
    }

    fn active_content_ids(&self) -> Result<Vec<CorpusContentId>, CorpusKitError> {
        Ok(self.ids.clone())
    }
}

#[cfg(feature = "dense-families")]
fn ppmi_config() -> EmbeddingModelConfig {
    use corpus_kit_providers::PpmiProvider;
    EmbeddingModelConfig::Ppmi { provider: Box::new(PpmiProvider::new()) }
}

fn ri_config() -> EmbeddingModelConfig {
    use corpus_kit_providers::RandomIndexingProvider;
    EmbeddingModelConfig::RandomIndexing { provider: Box::new(RandomIndexingProvider::new()) }
}

fn open_attached_engine(
    storage: &Arc<dyn Storage>,
    source: Arc<dyn CorpusContentSource>,
    models: Vec<EmbeddingModelConfig>,
) -> CorpusContentEngine {
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .unwrap();
    storage
        .migrate(&corpus_kit::attached_declaration())
        .expect("migrate attached");
    CorpusContentEngine::open(Arc::clone(storage), config, source, models).expect("open engine")
}

/// G-5a: PPMI delta-fold positive.
///
/// After an initial full train, one pending reference is introduced and the
/// second `train_trainable_slots` call (with force=true, as the drift gate
/// does) must take the counts path (CountsDeltaFold { folded: 1 }), without
/// re-training from corpus text.
// PPMI is a dark dense family (contract sheet §13); the trainable-slot
// path it exercises runs only under the dense-families feature.
#[cfg(feature = "dense-families")]
#[test]
fn g5a_ppmi_counts_path_delta_fold_positive() {
    let storage = in_memory_storage();
    let source = MutableSource::new();

    // Seed three base documents.
    source.put("doc-a", "the quick brown fox");
    source.put("doc-b", "jumps over the lazy dog");
    source.put("doc-c", "rust ownership and memory safety");

    let engine = open_attached_engine(
        &storage,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        vec![ppmi_config()],
    );

    // First train: no existing basis → corpus path (FirstTrain). force=false is
    // fine here because an untrained slot always routes to corpus path regardless.
    engine.train_trainable_slots(NOW, false).expect("first train");
    let decisions = engine.training_path_decisions();
    assert_eq!(
        decisions.get("ppmi-v1"),
        Some(&TrainingPathDecision::Corpus(CorpusPathReason::FirstTrain)),
        "first train must be corpus path (FirstTrain — no persisted basis)"
    );

    // Add a fourth document to the source and insert a pending reference row.
    // The pending ref simulates what the queue batch-commit path writes when a
    // new document is admitted between publications.
    source.put("doc-d", "concurrency channels and locks");
    let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
    let row_store = storage.row_store();
    counts_store
        .upsert_reference_into(
            &PersistedCountsReference {
                model_id: "ppmi-v1".into(),
                model_version: "1.1.0".into(),
                content_id: "doc-d".into(),
                revision: 1,
                digest: content_digest("concurrency channels and locks"),
                updated_at_secs: NOW / 1000,
                is_subsumed: false,
                growth_term_digests: Vec::new(),
            },
            &row_store,
        )
        .expect("insert pending ref");

    // Second train: force=true (drift gate). Basis exists, PPMI fold-safe,
    // population matches (3+1=4). Expected: counts path with folded=1.
    //
    // F-1 two-directional gate: reset the fetch counter immediately before
    // this train call so only the counts-path body-page traffic is measured.
    source.reset_fetch_count();
    engine.train_trainable_slots(NOW, true).expect("second train");
    let decisions = engine.training_path_decisions();
    assert_eq!(
        decisions.get("ppmi-v1"),
        Some(&TrainingPathDecision::CountsDeltaFold { folded: 1 }),
        "second train (force=true) must be counts delta-fold path with folded=1"
    );
    // F-1 two-directional gate: bodies paged must equal the folded pending count
    // (or zero on restore) — measured, not inferred.
    // One pending ref (doc-d) was inserted, so exactly 1 record fetch is expected.
    assert_eq!(
        source.fetch_count(),
        1,
        "F-1 two-directional gate: bodies paged must equal the folded pending count (or zero on restore) — measured, not inferred"
    );
}

/// G-5a-RI: RI behavior on the training-path dispatch.
///
/// RI reports `counts_delta_fold_safe()=false` because its f32 running sums
/// are not commutative. The dispatch (force=true, as the drift gate does) must
/// record DeltaNotFoldSafe and fall through to the corpus path, NOT the
/// delta-fold path.
#[test]
fn g5a_ri_counts_path_delta_not_fold_safe() {
    let storage = in_memory_storage();
    let source = MutableSource::new();
    source.put("doc-a", "the quick brown fox");
    source.put("doc-b", "jumps over the lazy dog");

    let engine = open_attached_engine(
        &storage,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        vec![ri_config()],
    );

    // First train: corpus path (FirstTrain — no persisted basis).
    engine.train_trainable_slots(NOW, false).expect("first train");

    // Add a document and a pending ref.
    source.put("doc-c", "rust concurrency primitives");
    let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
    let row_store = storage.row_store();
    counts_store
        .upsert_reference_into(
            &PersistedCountsReference {
                model_id: "random-indexing-v1".into(),
                model_version: "1.1.0".into(),
                content_id: "doc-c".into(),
                revision: 1,
                digest: content_digest("rust concurrency primitives"),
                updated_at_secs: NOW / 1000,
                is_subsumed: false,
                growth_term_digests: Vec::new(),
            },
            &row_store,
        )
        .expect("insert pending ref");

    // Second train: force=true (drift gate). RI → DeltaNotFoldSafe (corpus path).
    engine.train_trainable_slots(NOW, true).expect("second train");
    let decisions = engine.training_path_decisions();
    assert_eq!(
        decisions.get("random-indexing-v1"),
        Some(&TrainingPathDecision::Corpus(CorpusPathReason::DeltaNotFoldSafe)),
        "RI must always take corpus path (DeltaNotFoldSafe)"
    );
}

/// G-5b: negative case — population mismatch drives corpus path.
///
/// When the corpus size changes (a document is removed) and the drift gate
/// triggers a retrain (force=true), the counts path guard detects
/// basisRow.trainedChunkCount + pending.len() ≠ all_ids.len() and records
/// PopulationMismatch, falling through to corpus path.
// PPMI is a dark dense family (contract sheet §13); the trainable-slot
// path it exercises runs only under the dense-families feature.
#[cfg(feature = "dense-families")]
#[test]
fn g5b_population_mismatch_drives_corpus_path() {
    let storage = in_memory_storage();
    let source = MutableSource::new();
    source.put("doc-a", "first document content");
    source.put("doc-b", "second document content");
    source.put("doc-c", "third document content");

    let engine = open_attached_engine(
        &storage,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        vec![ppmi_config()],
    );

    // First train: corpus path (FirstTrain — no persisted basis).
    // basis records trainedChunkCount=3.
    engine.train_trainable_slots(NOW, false).expect("first train");

    // Remove one document: now all_ids.len()=2, but basisRow.trainedChunkCount=3
    // and pending=0 → 3+0 ≠ 2 → PopulationMismatch.
    source.remove("doc-c");

    // force=true: drift gate triggered; basis exists, so we attempt counts path.
    engine.train_trainable_slots(NOW, true).expect("second train after remove");
    let decisions = engine.training_path_decisions();
    assert_eq!(
        decisions.get("ppmi-v1"),
        Some(&TrainingPathDecision::Corpus(CorpusPathReason::PopulationMismatch)),
        "removed document must produce PopulationMismatch"
    );
}

/// G-5c: non-force call on a trained slot records NOTHING in the seam.
///
/// Skip semantics restored: a non-force train_trainable_slots call on a slot
/// whose basis digest is not empty (already trained) must NOT touch the counts
/// path or the corpus path — the decision seam must be empty (absent) for that
/// model. The drift gate owns WHEN a retrain happens.
// PPMI is a dark dense family (contract sheet §13); the trainable-slot
// path it exercises runs only under the dense-families feature.
#[cfg(feature = "dense-families")]
#[test]
fn g5c_non_force_trained_slot_skip_records_nothing() {
    let storage = in_memory_storage();
    let source = MutableSource::new();
    source.put("doc-a", "the quick brown fox");
    source.put("doc-b", "jumps over the lazy dog");

    let engine = open_attached_engine(
        &storage,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        vec![ppmi_config()],
    );

    // First train: corpus path (FirstTrain).
    engine.train_trainable_slots(NOW, false).expect("first train");

    // Second call: non-force, slot is already trained → skip.
    engine.train_trainable_slots(NOW, false).expect("non-force on trained slot");
    let decisions = engine.training_path_decisions();
    assert!(
        decisions.get("ppmi-v1").is_none(),
        "non-force call on trained slot must record nothing in the decision seam (skip semantics)"
    );
}

/// G-5d: force call on a trained slot with no pending refs → CountsRestore.
///
/// When force=true is called (drift gate or migration rebuild) and the slot is
/// already trained with no pending delta refs, the counts path runs its full
/// publication (restore both instances, fold nothing, finalize, publish), bumps
/// the generation counter, and records CountsRestore. Zero text paging.
// PPMI is a dark dense family (contract sheet §13); the trainable-slot
// path it exercises runs only under the dense-families feature.
#[cfg(feature = "dense-families")]
#[test]
fn g5d_force_trained_slot_no_pending_records_counts_restore() {
    let storage = in_memory_storage();
    let source = MutableSource::new();
    source.put("doc-a", "the quick brown fox");
    source.put("doc-b", "jumps over the lazy dog");

    let engine = open_attached_engine(
        &storage,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        vec![ppmi_config()],
    );

    // First train: corpus path (FirstTrain), establishes basis and counts.
    engine.train_trainable_slots(NOW, false).expect("first train");

    // No pending refs added — force=true triggers migration-rebuild path.
    // All guards pass (basis exists, PPMI fold-safe, population exact: 2+0=2).
    //
    // F-1 two-directional gate: reset the fetch counter immediately before
    // this train call so only the restore-path body-page traffic is measured.
    source.reset_fetch_count();
    engine.train_trainable_slots(NOW, true).expect("force retrain no pending");
    let decisions = engine.training_path_decisions();
    assert_eq!(
        decisions.get("ppmi-v1"),
        Some(&TrainingPathDecision::CountsRestore),
        "force retrain with no pending refs must record CountsRestore"
    );
    // F-1 two-directional gate: bodies paged must equal the folded pending count
    // (or zero on restore) — measured, not inferred.
    // CountsRestore reconstructs from persisted counts only — no source fetches.
    assert_eq!(
        source.fetch_count(),
        0,
        "F-1 two-directional gate: bodies paged must equal the folded pending count (or zero on restore) — measured, not inferred"
    );
}

/// G-6a: skipped-ID sentinel is durable after training.
///
/// When `source.record()` returns None for an active ID during training,
/// the corpus path must upsert a non-subsumed sentinel row
/// (revision=0, digest="") after delete-all-references. This test confirms
/// the sentinel row exists in the store after training completes.
// PPMI is a dark dense family (contract sheet §13); the trainable-slot
// path it exercises runs only under the dense-families feature.
#[cfg(feature = "dense-families")]
#[test]
fn g6a_skipped_id_sentinel_is_durable_after_training() {
    let storage = in_memory_storage();
    // Use a static source with one valid record and one whose `record()` always
    // returns None. We simulate this by using a NilSource for the engine but
    // exposing one "active" ID that will resolve to nil.
    let source = Arc::new(NilSource {
        ids: vec!["doc-ghost".to_string()],
    });

    let engine = open_attached_engine(
        &storage,
        source as Arc<dyn CorpusContentSource>,
        vec![ppmi_config()],
    );

    // Train: doc-ghost resolves to nil → logged as skipped, sentinel upserted.
    engine.train_trainable_slots(NOW, false).expect("train with ghost id");

    // Verify the sentinel row exists: non-subsumed, revision=0, digest="".
    let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
    let refs = counts_store
        .references("ppmi-v1", "1.1.0")
        .expect("load references");
    let sentinel = refs.iter().find(|r| r.content_id == "doc-ghost");
    assert!(
        sentinel.is_some(),
        "sentinel row must exist for skipped ID 'doc-ghost'"
    );
    let s = sentinel.unwrap();
    assert!(
        !s.is_subsumed,
        "sentinel must be non-subsumed (admission-check gate)"
    );
    assert_eq!(s.revision, 0, "sentinel revision must be 0");
    assert_eq!(s.digest, "", "sentinel digest must be empty string");
}

/// G-6f: sentinel safety — a sentinel row with revision=0 and digest="" does
/// NOT satisfy the admission digest-equality check. This test confirms that
/// the sentinel's fields are distinct from any live content record's digest.
///
/// The admission check compares `reference.digest == record.digest`. A real
/// record always has a non-empty SHA-256 hex digest. A sentinel has digest="".
/// This structural test verifies the invariant without running the admission
/// path (which is engine-internal), relying on the content_digest function
/// always returning a non-empty hex string.
#[test]
fn g6f_sentinel_fields_cannot_satisfy_admission_digest_equality() {
    // Sentinel values.
    let sentinel_revision: i64 = 0;
    let sentinel_digest = "";

    // Any real content record digest is non-empty hex.
    let live_digest = content_digest("some real document text");
    assert!(!live_digest.is_empty(), "live digest must be non-empty");
    assert_ne!(
        sentinel_digest, live_digest.as_str(),
        "sentinel digest must not equal any live content digest"
    );

    // Revision=0 is not a valid positive revision.
    assert_eq!(sentinel_revision, 0, "sentinel revision is zero");
    // Any real record would have revision >= 1.
    let live_revision: i64 = 1;
    assert_ne!(
        sentinel_revision, live_revision,
        "sentinel revision must differ from live record revision"
    );
}

// ── G-5a-ENTRY: production entry point drives the decision seam ─────────────

/// G-5a-ENTRY: the attached engine's public reindex entry records CountsDeltaFold.
///
/// The drift trigger calls `engine.reindex(now_millis)`, which internally calls
/// `train_trainable_slots(force: true)`. This test drives the production entry
/// (reindex) rather than train_trainable_slots directly, verifying the recorded
/// decision is CountsDeltaFold(n) when a pending ref exists.
// PPMI is a dark dense family (contract sheet §13); the trainable-slot
// path it exercises runs only under the dense-families feature.
#[cfg(feature = "dense-families")]
#[test]
fn g5a_entry_attached_reindex_records_counts_delta_fold() {
    let storage = in_memory_storage();
    let source = MutableSource::new();

    // Seed two base documents.
    source.put("doc-a", "the quick brown fox");
    source.put("doc-b", "jumps over the lazy dog");

    let engine = open_attached_engine(
        &storage,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        vec![ppmi_config()],
    );

    // First train via the public entry: internally calls train_trainable_slots.
    // No basis → FirstTrain (corpus path).
    engine.reindex(NOW).expect("first reindex via production entry");
    let decisions = engine.training_path_decisions();
    assert_eq!(
        decisions.get("ppmi-v1"),
        Some(&TrainingPathDecision::Corpus(CorpusPathReason::FirstTrain)),
        "first reindex must record FirstTrain via production entry"
    );

    // Add a third document and insert a pending reference row.
    source.put("doc-c", "concurrency channels and locks");
    let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
    let row_store = storage.row_store();
    counts_store
        .upsert_reference_into(
            &PersistedCountsReference {
                model_id: "ppmi-v1".into(),
                model_version: "1.1.0".into(),
                content_id: "doc-c".into(),
                revision: 1,
                digest: content_digest("concurrency channels and locks"),
                updated_at_secs: NOW / 1000,
                is_subsumed: false,
                growth_term_digests: Vec::new(),
            },
            &row_store,
        )
        .expect("insert pending ref for doc-c");

    // Second reindex via the production entry: basis exists, PPMI fold-safe,
    // population matches (2+1=3). The production entry invokes
    // train_trainable_slots(force: true) internally — exactly as the drift
    // trigger does. Expected: counts path with folded=1.
    //
    // NOTE: reindex() also re-embeds all corpus content after training (it calls
    // index_whole_content_batch for every active ID). The re-embed phase fetches
    // each record from source, so total fetch count = folded_refs + re-embed_reads.
    // The decision seam (CountsDeltaFold) is the authoritative gate; fetch count
    // is not asserted here because reindex() intentionally reads all content for
    // the re-embed pass — only train_trainable_slots alone skips corpus reads on
    // the counts path (F-1 gate, verified by g5a_ppmi_counts_path_delta_fold_positive).
    engine.reindex(NOW + 1).expect("second reindex via production entry");
    let decisions = engine.training_path_decisions();
    assert_eq!(
        decisions.get("ppmi-v1"),
        Some(&TrainingPathDecision::CountsDeltaFold { folded: 1 }),
        "second reindex (via production entry) must record CountsDeltaFold {{ folded: 1 }}"
    );
}

// ── F-10: counts-path publication twin ──────────────────────────────────────

/// F-10: counts-path publication preserves post-publication admission.
///
/// The CORPUS-path race test `provider_publication_preserves_post_snapshot_admission`
/// proves that a record admitted DURING publication (post-snapshot) survives.
/// This is the COUNTS-PATH twin proving the same property.
///
/// Proof shape: NON-INTERLEAVING (lock-quoting).
///
/// The counts path (both CountsDeltaFold and CountsRestore) holds the engine's
/// `counts_commit_lock` for its ENTIRE duration. The lock is acquired at the
/// very top of `train_trainable_slots` in content_engine.rs:
///
///   let _commit_guard = self
///       .counts_commit_lock
///       .lock()
///       .map_err(|_| CorpusKitError::StoreUnavailable("counts commit lock poisoned".into()))?;
///
/// This is the SAME lock that `batch_commit` (the admission path) acquires
/// before writing reference rows. Therefore NO admission can interleave with
/// the counts-path publication: the two operations are strictly serialized by
/// `counts_commit_lock`. The counts path DOES call `source.record()` once per
/// pending reference during a CountsDeltaFold (the measured bodies-paged gate in
/// g5a asserts exactly that count) — but those fetches happen INSIDE
/// `counts_commit_lock`, so no admission can interleave with them, and this
/// harness's source has no blocking hook to suspend a fetch mid-flight. Hence
/// the sequential proof below rather than an interleaved one.
///
/// We prove the property sequentially: publication completes, then we insert a
/// new reference row (simulating a post-publication admission), and assert that
/// row EXISTS and is non-subsumed (pending, not folded by the just-completed
/// publication). We then assert a subsequent force retrain delta-folds it.
// PPMI is a dark dense family (contract sheet §13); the trainable-slot
// path it exercises runs only under the dense-families feature.
#[cfg(feature = "dense-families")]
#[test]
fn f10_counts_path_publication_preserves_post_publication_admission() {
    let storage = in_memory_storage();
    let source = MutableSource::new();
    source.put("doc-a", "the quick brown fox");
    source.put("doc-b", "jumps over the lazy dog");

    let engine = open_attached_engine(
        &storage,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        vec![ppmi_config()],
    );

    // First train: corpus path (FirstTrain), establishes basis and counts.
    engine.train_trainable_slots(NOW, false).expect("first train");

    // Set up CountsDeltaFold: add doc-c with a pending ref.
    source.put("doc-c", "rust ownership channels locks");
    let counts_store = CorpusProviderCountsStore::new(Arc::clone(&storage));
    let row_store = storage.row_store();
    counts_store
        .upsert_reference_into(
            &PersistedCountsReference {
                model_id: "ppmi-v1".into(),
                model_version: "1.1.0".into(),
                content_id: "doc-c".into(),
                revision: 1,
                digest: content_digest("rust ownership channels locks"),
                updated_at_secs: NOW / 1000,
                is_subsumed: false,
                growth_term_digests: Vec::new(),
            },
            &row_store,
        )
        .expect("insert doc-c pending ref");

    // Counts-path publication: folds doc-c (CountsDeltaFold { folded: 1 }).
    // The engine holds counts_commit_lock for the entirety of this call —
    // see the lock acquisition in content_engine.rs::train_trainable_slots
    // quoted in this test's doc comment. No admission can interleave.
    engine.train_trainable_slots(NOW + 1, true).expect("counts delta fold");
    assert_eq!(
        engine.training_path_decisions().get("ppmi-v1"),
        Some(&TrainingPathDecision::CountsDeltaFold { folded: 1 }),
        "F-10 setup: counts path must delta-fold doc-c"
    );

    // Post-publication admission: insert doc-d's reference row AFTER the
    // counts-path publication completed and the lock was released.
    // This simulates a record admitted immediately after a counts-path
    // publication burst — the admission arrives after the publication window.
    source.put("doc-d", "concurrency mutex condvar thread");
    counts_store
        .upsert_reference_into(
            &PersistedCountsReference {
                model_id: "ppmi-v1".into(),
                model_version: "1.1.0".into(),
                content_id: "doc-d".into(),
                revision: 1,
                digest: content_digest("concurrency mutex condvar thread"),
                updated_at_secs: (NOW + 2) / 1000,
                is_subsumed: false,
                growth_term_digests: Vec::new(),
            },
            &row_store,
        )
        .expect("insert doc-d post-publication ref");

    // Assert: doc-d's reference row EXISTS and is non-subsumed (pending).
    // The counts path's per-ref delete removed ONLY doc-c (the folded ref).
    // doc-d was admitted after the publication lock was released — its row
    // was never touched by the publication and must survive intact.
    let doc_d_ref = counts_store
        .reference_for("ppmi-v1", "1.1.0", "doc-d")
        .expect("load doc-d reference")
        .expect("doc-d reference must exist — post-publication admission must survive");
    assert!(
        !doc_d_ref.is_subsumed,
        "doc-d ref must be non-subsumed (pending): the counts path deletes ONLY the \
         refs it folded (doc-c), not all refs — doc-d was admitted post-publication"
    );
    assert_eq!(
        doc_d_ref.digest,
        content_digest("concurrency mutex condvar thread"),
        "doc-d ref digest must match the admitted record"
    );

    // Assert: a subsequent force retrain delta-folds doc-d (the pending ref),
    // proving the post-publication admission is correctly picked up next cycle.
    engine.train_trainable_slots(NOW + 2, true).expect("second counts fold");
    assert_eq!(
        engine.training_path_decisions().get("ppmi-v1"),
        Some(&TrainingPathDecision::CountsDeltaFold { folded: 1 }),
        "F-10: subsequent retrain must delta-fold doc-d (the post-publication admission)"
    );
}

// ── G-5d: coverage consequence of identical-digest countsRestore ─────────────

/// G-5d: after a countsRestore publication, existing coverage survives in the
/// side table (corpus_provider_coverage), keyed by (model_id, basis_digest).
///
/// CountsRestore restores the same counts → same serialized basis bytes →
/// same basis_digest. The coverage side table is keyed by (content_id,
/// model_id, basis_digest). Since the digest is unchanged, existing coverage
/// rows survive and covered_count returns the same value as before.
///
/// Two facts, both stated here per reviewer requirement:
///   (i)  Migration repair relies on the basis-generation bump (which
///        CountsRestore does trigger — the generation counter increments after
///        any training job) to invalidate the content-row BITMAP coverage
///        (is_fully_covered checks generation equality, not just the side
///        table). This bitmap-based invalidation is what causes the re-embed
///        path to fire when reindex() re-embeds all content. The side table
///        (authoritative) survives; the per-row generation stamp goes stale,
///        making the bitmap fast-path show rows as uncovered.
///   (ii) Therefore a no-op reindex (CountsRestore + no content changes)
///        re-embeds the corpus via the direct reindex() path — which always
///        re-embeds all content regardless of coverage status. This matches
///        the PRE-mission corpus-path behavior for a no-op force reindex (not
///        a regression introduced by the counts path). Optimizing the no-op
///        reindex to skip re-embed when the side-table coverage is complete is
///        a named follow-up for Bob; it is out of this mission's scope.
// PPMI is a dark dense family (contract sheet §13); the trainable-slot
// path it exercises runs only under the dense-families feature.
#[cfg(feature = "dense-families")]
#[test]
fn g5d_counts_restore_coverage_survives_in_side_table() {
    use persistence_kit::{TypedValue, Column, StoragePredicate};

    let storage = in_memory_storage();
    let source = MutableSource::new();
    source.put("doc-a", "the quick brown fox");
    source.put("doc-b", "jumps over the lazy dog");

    let engine = open_attached_engine(
        &storage,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        vec![ppmi_config()],
    );

    // First train (FirstTrain): establishes the basis and counts. Captures the
    // basis_digest before CountsRestore so we can compare after.
    engine.train_trainable_slots(NOW, false).expect("first train");
    let generations_before = engine.provider_generations();
    let (model_id, digest_before) = generations_before
        .into_iter()
        .find(|(m, _)| m == "ppmi-v1")
        .expect("ppmi-v1 slot must exist");
    assert!(!digest_before.is_empty(), "basis_digest must be non-empty after first train");

    // Insert synthetic coverage rows for both docs directly into the side table.
    // CorpusProviderCoverageStore is not a public API; we write the rows via the
    // storage row_store so the test does not depend on internal kit structure.
    // The table schema: (content_id TEXT, model_id TEXT, basis_digest TEXT,
    //                    updated_at TIMESTAMP) — primary key (content_id, model_id).
    let row_store = storage.row_store();
    for doc_id in &["doc-a", "doc-b"] {
        let mut values = std::collections::BTreeMap::new();
        values.insert("content_id".into(), TypedValue::Text(doc_id.to_string()));
        values.insert("model_id".into(), TypedValue::Text(model_id.clone()));
        values.insert("basis_digest".into(), TypedValue::Text(digest_before.clone()));
        values.insert("updated_at".into(), TypedValue::Timestamp(NOW));
        row_store
            .upsert(
                "corpus_provider_coverage",
                values,
                &["content_id".to_string(), "model_id".to_string()],
            )
            .expect("insert synthetic coverage row");
    }

    // Verify coverage is readable by the engine.
    let pre_restore = engine.covered_count("ppmi-v1")
        .expect("covered_count must not error")
        .expect("ppmi-v1 must be a registered slot");
    assert_eq!(
        pre_restore, 2,
        "both docs must be covered (in side table) before CountsRestore"
    );

    // CountsRestore: no pending refs → same counts → same serialized basis →
    // same basis_digest. Generation counter is bumped after any training job.
    engine.train_trainable_slots(NOW + 1, true).expect("force retrain CountsRestore");
    assert_eq!(
        engine.training_path_decisions().get("ppmi-v1"),
        Some(&TrainingPathDecision::CountsRestore),
        "no-pending force retrain must record CountsRestore"
    );

    // Assert: basis_digest is UNCHANGED after CountsRestore (same bytes →
    // same digest). This is the structural invariant that makes coverage survive.
    let generations_after = engine.provider_generations();
    let (_, digest_after) = generations_after
        .into_iter()
        .find(|(m, _)| m == "ppmi-v1")
        .expect("ppmi-v1 slot must still exist");
    assert_eq!(
        digest_after, digest_before,
        "CountsRestore must produce the same basis_digest (same counts → same basis bytes)"
    );

    // Assert: coverage SURVIVES in the side table. The digest is identical →
    // corpus_provider_coverage rows with (model_id, basis_digest) are still
    // matched by covered_count. The side-table key is (content_id, model_id,
    // basis_digest); generation is NOT part of the side-table key.
    let post_restore = engine.covered_count("ppmi-v1")
        .expect("covered_count must not error")
        .expect("ppmi-v1 must still be registered");
    assert_eq!(
        post_restore, pre_restore,
        "coverage_store must survive CountsRestore: identical digest → side-table rows \
         remain valid; generation bump only stales the content-row bitmap fast path \
         (is_fully_covered uses generation equality), not the authoritative side table \
         (covered_count queries by (model_id, basis_digest) only)"
    );

    // Structural assertion: the coverage rows are still present with the original
    // digest (not cleared or overwritten by CountsRestore).
    let coverage_rows = row_store
        .query(
            "corpus_provider_coverage",
            Some(&StoragePredicate::Eq(
                Column::new("corpus_provider_coverage", "model_id"),
                TypedValue::Text(model_id.clone()),
            )),
            &[],
            None,
            None,
        )
        .expect("query corpus_provider_coverage");
    let surviving_digests: Vec<_> = coverage_rows
        .iter()
        .filter_map(|row| match row.get("basis_digest") {
            Some(TypedValue::Text(d)) => Some(d.clone()),
            _ => None,
        })
        .collect();
    assert!(
        surviving_digests.iter().all(|d| d == &digest_before),
        "all surviving coverage rows must carry the original basis_digest — \
         CountsRestore must not clear or rewrite the side table"
    );
}
