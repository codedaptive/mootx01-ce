//! Content-boundary, schema-profile, and checkpoint coverage
//! (GLK shared-content 1.1, P1). Rust twin of the Swift
//! `CorpusContentBoundaryTests`.
//!
//! The conformance harness below is THE source/store contract: it runs
//! against the standalone `CorpusDocumentStore` AND against an in-memory
//! test adapter shaped like GLK's Drawer-backed adapter — both must
//! satisfy identical semantics.

use corpus_kit::{
    attached_declaration, attached_excluded_tables, content_digest, standalone_declaration,
    CorpusContentChange, CorpusContentChangeBatch, CorpusContentConfiguration, CorpusContentId,
    CorpusContentRecord, CorpusContentSource, CorpusContentStore, CorpusDocumentStore,
    CorpusIndexState, CorpusIndexStateStore, CorpusIndexUnitPolicy, CorpusKitError,
    CorpusOperatingMode,
};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{
    BackendConfiguration, EstateConfiguration, SqliteStorage, Storage,
};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

const NOW: i64 = 1_700_000_000_000;

fn in_memory_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

// ── In-memory adapter (the GLK-adapter stand-in) ─────────────────────────

#[derive(Default)]
struct AdapterState {
    records: BTreeMap<CorpusContentId, CorpusContentRecord>,
    journal: Vec<(i64, CorpusContentChange)>,
    next_seq: i64,
}

struct InMemoryContentAdapter {
    state: Mutex<AdapterState>,
}

impl InMemoryContentAdapter {
    fn new() -> Self {
        InMemoryContentAdapter {
            state: Mutex::new(AdapterState {
                next_seq: 1,
                ..Default::default()
            }),
        }
    }
}

impl CorpusContentSource for InMemoryContentAdapter {
    fn record(&self, id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
        Ok(self.state.lock().unwrap().records.get(id).cloned())
    }

    fn changes(
        &self,
        cursor: Option<&str>,
        limit: usize,
    ) -> Result<CorpusContentChangeBatch, CorpusKitError> {
        if limit == 0 {
            return Ok(CorpusContentChangeBatch::empty());
        }
        let after: i64 = cursor.and_then(|c| c.parse().ok()).unwrap_or(0);
        let state = self.state.lock().unwrap();
        let page: Vec<(i64, CorpusContentChange)> = state
            .journal
            .iter()
            .filter(|(seq, _)| *seq > after)
            .take(limit)
            .cloned()
            .collect();
        if page.is_empty() {
            return Ok(CorpusContentChangeBatch::empty());
        }
        Ok(CorpusContentChangeBatch {
            next_cursor: Some(page.last().unwrap().0.to_string()),
            changes: page.into_iter().map(|(_, c)| c).collect(),
        })
    }

    fn active_content_ids(&self) -> Result<Vec<CorpusContentId>, CorpusKitError> {
        Ok(self.state.lock().unwrap().records.keys().cloned().collect())
    }
}

impl CorpusContentStore for InMemoryContentAdapter {
    fn put(
        &self,
        text: &str,
        id: &str,
        _now_millis: i64,
    ) -> Result<CorpusContentRecord, CorpusKitError> {
        let digest = content_digest(text);
        let mut state = self.state.lock().unwrap();
        if let Some(existing) = state.records.get(id).cloned() {
            if existing.digest == digest {
                return Ok(existing);
            }
            let bumped = CorpusContentRecord {
                id: id.to_string(),
                revision: existing.revision + 1,
                digest: digest.clone(),
                text: text.to_string(),
            };
            state.records.insert(id.to_string(), bumped.clone());
            let seq = state.next_seq;
            state.journal.push((
                seq,
                CorpusContentChange::Upsert {
                    id: id.to_string(),
                    revision: bumped.revision,
                    digest,
                },
            ));
            state.next_seq += 1;
            return Ok(bumped);
        }
        let fresh = CorpusContentRecord {
            id: id.to_string(),
            revision: 1,
            digest: digest.clone(),
            text: text.to_string(),
        };
        state.records.insert(id.to_string(), fresh.clone());
        let seq = state.next_seq;
        state.journal.push((
            seq,
            CorpusContentChange::Upsert {
                id: id.to_string(),
                revision: 1,
                digest,
            },
        ));
        state.next_seq += 1;
        Ok(fresh)
    }

    fn remove(&self, id: &str, _now_millis: i64) -> Result<(), CorpusKitError> {
        let mut state = self.state.lock().unwrap();
        let Some(existing) = state.records.remove(id) else {
            return Ok(());
        };
        let seq = state.next_seq;
        state.journal.push((
            seq,
            CorpusContentChange::Remove {
                id: id.to_string(),
                revision: existing.revision,
            },
        ));
        state.next_seq += 1;
        Ok(())
    }
}

// ── The conformance harness ──────────────────────────────────────────────

fn exercise_content_store_conformance(store: &dyn CorpusContentStore) {
    // 1. Fresh put → revision 1, correct digest, verbatim text back.
    let text_a1 = "The first canonical document.";
    let rec_a1 = store.put(text_a1, "doc-a", NOW).expect("put a1");
    assert_eq!(rec_a1.revision, 1);
    assert_eq!(rec_a1.digest, content_digest(text_a1));
    assert_eq!(store.record("doc-a").unwrap(), Some(rec_a1.clone()));

    // 2. Idempotent re-put: identical text → same record, NO new change.
    let rec_a1_again = store.put(text_a1, "doc-a", NOW).expect("re-put a1");
    assert_eq!(rec_a1_again, rec_a1);
    assert_eq!(store.changes(None, 100).unwrap().changes.len(), 1);

    // 3. Changed text → revision bump + new digest + journaled upsert.
    let text_a2 = "The first canonical document, revised.";
    let rec_a2 = store.put(text_a2, "doc-a", NOW).expect("put a2");
    assert_eq!(rec_a2.revision, 2);
    assert_ne!(rec_a2.digest, rec_a1.digest);

    // A second document for enumeration/pagination coverage.
    store.put("A second document.", "doc-b", NOW).expect("put b");
    assert_eq!(store.active_content_ids().unwrap(), vec!["doc-a", "doc-b"]);

    // 4. Remove → record gone, remove change carries the removed revision.
    store.remove("doc-b", NOW).expect("remove b");
    assert_eq!(store.record("doc-b").unwrap(), None);
    assert_eq!(store.active_content_ids().unwrap(), vec!["doc-a"]);
    store.remove("doc-b", NOW).expect("remove absent is no-op");

    // 5. Feed contents in order.
    let all = store.changes(None, 100).unwrap();
    assert_eq!(
        all.changes,
        vec![
            CorpusContentChange::Upsert {
                id: "doc-a".into(),
                revision: 1,
                digest: rec_a1.digest.clone()
            },
            CorpusContentChange::Upsert {
                id: "doc-a".into(),
                revision: 2,
                digest: rec_a2.digest.clone()
            },
            CorpusContentChange::Upsert {
                id: "doc-b".into(),
                revision: 1,
                digest: content_digest("A second document.")
            },
            CorpusContentChange::Remove {
                id: "doc-b".into(),
                revision: 1
            },
        ]
    );

    // 6. Cursor pagination: limit-1 pages walk the same feed; re-reading a
    //    cursor is stable; the final cursor yields an empty batch.
    let mut cursor: Option<String> = None;
    let mut paged: Vec<CorpusContentChange> = Vec::new();
    for _ in 0..4 {
        let page = store.changes(cursor.as_deref(), 1).unwrap();
        assert_eq!(page.changes.len(), 1);
        let reread = store.changes(cursor.as_deref(), 1).unwrap();
        assert_eq!(reread, page);
        paged.extend(page.changes.clone());
        cursor = page.next_cursor;
    }
    assert_eq!(paged, all.changes);
    assert_eq!(
        store.changes(cursor.as_deref(), 1).unwrap(),
        CorpusContentChangeBatch::empty()
    );

    // 7. Digests are digests, never content.
    for change in &all.changes {
        if let CorpusContentChange::Upsert { digest, .. } = change {
            assert_eq!(digest.len(), 64);
            assert!(digest.chars().all(|c| c.is_ascii_hexdigit()));
        }
    }
}

// ── Suites ───────────────────────────────────────────────────────────────

#[test]
fn document_store_satisfies_the_content_store_contract() {
    let storage = in_memory_storage();
    storage
        .migrate(&CorpusDocumentStore::schema_declaration())
        .expect("migrate");
    let store = CorpusDocumentStore::new(storage);
    exercise_content_store_conformance(&store);
}

#[test]
fn in_memory_adapter_satisfies_the_content_store_contract() {
    let adapter = InMemoryContentAdapter::new();
    exercise_content_store_conformance(&adapter);
}

#[test]
fn document_store_survives_reopen_on_sqlite() {
    let dir = std::env::temp_dir();
    let path = dir.join(format!("corpuskit-docstore-{}.sqlite3", Uuid::new_v4()));
    let path_str = path.to_string_lossy().to_string();

    {
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path_str.clone(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage: Arc<dyn Storage> =
            Arc::new(SqliteStorage::new(config).expect("open sqlite"));
        storage
            .migrate(&CorpusDocumentStore::schema_declaration())
            .expect("migrate");
        let store = CorpusDocumentStore::new(storage);
        store
            .put("Persisted across reopen.", "doc-r", NOW)
            .expect("put");
    }

    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path_str.clone(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage: Arc<dyn Storage> =
        Arc::new(SqliteStorage::new(config).expect("reopen sqlite"));
    storage
        .migrate(&CorpusDocumentStore::schema_declaration())
        .expect("migrate");
    let store = CorpusDocumentStore::new(storage);
    assert_eq!(store.record("doc-r").unwrap().map(|r| r.revision), Some(1));
    store
        .put("Persisted across reopen, revised.", "doc-r", NOW)
        .expect("revise");
    let feed = store.changes(None, 10).unwrap();
    assert_eq!(
        feed.changes.iter().map(|c| c.revision()).collect::<Vec<_>>(),
        vec![1, 2]
    );
    let _ = std::fs::remove_file(&path);
}

// ── Operating-mode / index-unit validation ───────────────────────────────

#[test]
fn attached_mode_rejects_passage_configuration_before_writing() {
    let result = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::TokenBudgetedPassages { token_budget: 512 },
    );
    assert!(matches!(
        result,
        Err(CorpusKitError::AttachedModeViolation(_))
    ));
}

#[test]
fn non_positive_token_budget_is_rejected() {
    let result = CorpusContentConfiguration::new(
        CorpusOperatingMode::Standalone,
        CorpusIndexUnitPolicy::TokenBudgetedPassages { token_budget: 0 },
    );
    assert!(matches!(
        result,
        Err(CorpusKitError::InvalidConfiguration(_))
    ));
}

#[test]
fn valid_configurations_construct_and_gate_mutation() {
    let attached = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .expect("attached whole-content is valid");
    assert!(!attached.allows_content_mutation());

    let standalone = CorpusContentConfiguration::new(
        CorpusOperatingMode::Standalone,
        CorpusIndexUnitPolicy::TokenBudgetedPassages { token_budget: 512 },
    )
    .expect("standalone passages is valid");
    assert!(standalone.allows_content_mutation());
}

// ── Schema profiles ──────────────────────────────────────────────────────

#[test]
fn attached_profile_contains_no_canonical_content_table() {
    let declaration = attached_declaration();
    let names: std::collections::BTreeSet<&str> =
        declaration.tables.iter().map(|t| t.name.as_str()).collect();
    for excluded in attached_excluded_tables() {
        assert!(!names.contains(excluded), "attached profile leaks {excluded}");
    }
    let expected: std::collections::BTreeSet<&str> = [
        "corpus_index_state",
        "corpus_provider_coverage",
        "iix_termfreqs",
        "iix_doclens",
        "corpus_provider_basis",
        "corpus_provider_counts",
    ]
    .into_iter()
    .collect();
    assert_eq!(names, expected);
    for table in &declaration.tables {
        assert!(
            !table.columns.iter().any(|c| c.name == "text"),
            "attached table {} must not carry a text column",
            table.name
        );
    }
}

#[test]
fn standalone_profile_gates_passages_on_configuration() {
    let without: std::collections::BTreeSet<String> = standalone_declaration(false)
        .tables
        .iter()
        .map(|t| t.name.clone())
        .collect();
    assert!(without.contains("corpus_documents"));
    assert!(without.contains("corpus_index_state"));
    assert!(!without.contains("corpus_passages"));
    assert!(!without.contains("chunks"));
    assert!(!without.contains("corpus_metadata"));

    let with: std::collections::BTreeSet<String> = standalone_declaration(true)
        .tables
        .iter()
        .map(|t| t.name.clone())
        .collect();
    assert!(with.contains("corpus_passages"));
}

#[test]
fn attached_profile_opens_without_canonical_content_tables() {
    let storage = in_memory_storage();
    storage.migrate(&attached_declaration()).expect("migrate");
    let row_store = storage.row_store();
    assert_eq!(row_store.count("corpus_index_state", None).unwrap(), 0);
    assert_eq!(row_store.count("iix_termfreqs", None).unwrap(), 0);
    assert_eq!(row_store.count("corpus_provider_basis", None).unwrap(), 0);
    assert!(row_store.count("corpus_documents", None).is_err());
    assert!(row_store.count("chunks", None).is_err());
}

// ── Index-state checkpoint lane ──────────────────────────────────────────

#[test]
fn index_state_advance_read_clear_round_trip() {
    let storage = in_memory_storage();
    storage
        .migrate(&CorpusIndexStateStore::schema_declaration())
        .expect("migrate");
    let store = CorpusIndexStateStore::new(storage);

    let state = CorpusIndexState {
        content_id: "drawer-1".into(),
        revision: 3,
        digest: content_digest("x"),
        index_version: 1,
        applied_cursor: Some("42".into()),
        updated_at_millis: NOW,
    };
    store.advance(&state).expect("advance");
    store.advance(&state).expect("idempotent advance");
    assert_eq!(store.state("drawer-1").unwrap(), Some(state.clone()));

    store
        .advance(&CorpusIndexState {
            content_id: "drawer-2".into(),
            revision: 1,
            digest: content_digest("y"),
            index_version: 1,
            applied_cursor: None,
            updated_at_millis: NOW,
        })
        .expect("advance 2");
    assert_eq!(
        store
            .all_states()
            .unwrap()
            .iter()
            .map(|s| s.content_id.clone())
            .collect::<Vec<_>>(),
        vec!["drawer-1", "drawer-2"]
    );

    store.clear("drawer-1").expect("clear");
    assert_eq!(store.state("drawer-1").unwrap(), None);
    store.clear_all().expect("clear all");
    assert!(store.all_states().unwrap().is_empty());
}

#[test]
fn index_state_survives_reopen_on_sqlite() {
    let dir = std::env::temp_dir();
    let path = dir.join(format!("corpuskit-ixstate-{}.sqlite3", Uuid::new_v4()));
    let path_str = path.to_string_lossy().to_string();

    let state = CorpusIndexState {
        content_id: "drawer-1".into(),
        revision: 2,
        digest: content_digest("z"),
        index_version: 1,
        applied_cursor: None,
        updated_at_millis: NOW,
    };
    {
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: path_str.clone(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage: Arc<dyn Storage> =
            Arc::new(SqliteStorage::new(config).expect("open"));
        storage
            .migrate(&CorpusIndexStateStore::schema_declaration())
            .expect("migrate");
        CorpusIndexStateStore::new(storage)
            .advance(&state)
            .expect("advance");
    }
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path_str.clone(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage: Arc<dyn Storage> =
        Arc::new(SqliteStorage::new(config).expect("reopen"));
    storage
        .migrate(&CorpusIndexStateStore::schema_declaration())
        .expect("migrate");
    let reread = CorpusIndexStateStore::new(storage).state("drawer-1").unwrap();
    assert_eq!(reread, Some(state));
    let _ = std::fs::remove_file(&path);
}
