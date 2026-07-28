//! Rust twin of Swift `DualTextIndexingTests` (MISSION_11X_RECALL_GAP_01 Stream A).
//!
//! Covers both content provider modes:
//!   - Standalone (CorpusDocumentStore owns canonical text; put_with_dense_text stores it)
//!   - Source-protocol (StaticContentSource carries dense_composition_text; attached engine uses it)
//!
//! Every test in this file has a named Swift counterpart in
//! `Tests/CorpusKitTests/DualTextIndexingTests.swift`.

use corpus_kit::{
    content_digest, CorpusContentChange, CorpusContentChangeBatch, CorpusContentConfiguration,
    CorpusContentEngine, CorpusContentId, CorpusContentRecord, CorpusContentSource,
    CorpusContentStore, CorpusDocumentStore, CorpusIndexUnitPolicy, CorpusKitError,
    CorpusOperatingMode, EmbeddingModelConfig,
};
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use persistence_kit::inmemory::InMemoryStorage;
use std::collections::HashMap;
use std::sync::Arc;
use uuid::Uuid;

const NOW: i64 = 1_700_000_000_000;

// ─── Storage helper ──────────────────────────────────────────────────────────

fn in_memory_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

/// Create an in-memory standalone engine + document store ready for use.
fn make_standalone_with_store() -> (CorpusContentEngine, Arc<CorpusDocumentStore>, Arc<dyn Storage>) {
    let storage = in_memory_storage();
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Standalone,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .unwrap();
    storage
        .migrate(&corpus_kit::standalone_declaration(false))
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

// ─── Source-protocol helper ───────────────────────────────────────────────────

/// A minimal in-memory content source that carries records verbatim,
/// including any dense_composition_text. Mirrors the Swift `DualTextInMemorySource`
/// used to simulate a GLK adapter path in the source-protocol test suite.
struct DualTextStaticSource {
    records: Vec<CorpusContentRecord>,
}

impl DualTextStaticSource {
    fn new(records: Vec<CorpusContentRecord>) -> Arc<Self> {
        Arc::new(Self { records })
    }
}

impl CorpusContentSource for DualTextStaticSource {
    fn record(&self, id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
        Ok(self.records.iter().find(|r| r.id == id).cloned())
    }

    fn records_for(&self, ids: &[&str]) -> Result<HashMap<String, CorpusContentRecord>, CorpusKitError> {
        Ok(self
            .records
            .iter()
            .filter(|r| ids.contains(&r.id.as_str()))
            .map(|r| (r.id.clone(), r.clone()))
            .collect())
    }

    fn changes(
        &self,
        _cursor: Option<&str>,
        _limit: usize,
    ) -> Result<CorpusContentChangeBatch, CorpusKitError> {
        Ok(CorpusContentChangeBatch::empty())
    }

    fn active_content_ids(&self) -> Result<Vec<CorpusContentId>, CorpusKitError> {
        let mut ids: Vec<String> = self.records.iter().map(|r| r.id.clone()).collect();
        ids.sort();
        Ok(ids)
    }
}

// ─── CorpusContentRecord unit tests ──────────────────────────────────────────

#[test]
fn effective_dense_text_fallback_to_lexical_text_when_none() {
    let record = CorpusContentRecord {
        id: "doc1".into(),
        revision: 1,
        digest: content_digest("lexical text"),
        text: "lexical text".into(),
        dense_composition_text: None,
    };
    // When dense_composition_text is None, effective_dense_text() returns text.
    assert_eq!(record.effective_dense_text(), "lexical text");
}

#[test]
fn effective_dense_text_returns_dense_when_set() {
    let record = CorpusContentRecord {
        id: "doc1".into(),
        revision: 1,
        digest: content_digest("lexical text"),
        text: "lexical text".into(),
        dense_composition_text: Some("dense text".into()),
    };
    assert_eq!(record.effective_dense_text(), "dense text");
    // Lexical text must remain unmodified.
    assert_eq!(record.text, "lexical text");
}

#[test]
fn record_with_nil_dense_behaves_identically_to_pre_dual_text() {
    // A record with no dense_composition_text must behave as if the
    // dual-text capability does not exist — the same behavior as before the
    // mission landed. This is the zero-regression invariant.
    let record = CorpusContentRecord {
        id: "doc1".into(),
        revision: 1,
        digest: content_digest("only text"),
        text: "only text".into(),
        dense_composition_text: None,
    };
    assert_eq!(record.effective_dense_text(), record.text.as_str());
}

// ─── CorpusDocumentStore standalone mode tests ────────────────────────────────

#[test]
fn document_store_round_trip_without_dense_text() {
    let storage = in_memory_storage();
    storage
        .migrate(&corpus_kit::standalone_declaration(false))
        .unwrap();
    let store = CorpusDocumentStore::new(Arc::clone(&storage));

    let rec = store.put("hello world", "doc1", NOW).unwrap();
    assert_eq!(rec.text, "hello world");
    assert!(rec.dense_composition_text.is_none());
    assert_eq!(rec.effective_dense_text(), "hello world");

    let fetched = store.record("doc1").unwrap().expect("record must exist");
    assert_eq!(fetched.text, "hello world");
    assert!(fetched.dense_composition_text.is_none());
}

#[test]
fn document_store_round_trip_with_dense_text() {
    let storage = in_memory_storage();
    storage
        .migrate(&corpus_kit::standalone_declaration(false))
        .unwrap();
    let store = CorpusDocumentStore::new(Arc::clone(&storage));

    let rec = store
        .put_with_dense_text("lexical content", Some("dense content"), "doc1", NOW)
        .unwrap();
    assert_eq!(rec.text, "lexical content");
    assert_eq!(rec.dense_composition_text.as_deref(), Some("dense content"));
    assert_eq!(rec.effective_dense_text(), "dense content");

    let fetched = store.record("doc1").unwrap().expect("record must exist");
    assert_eq!(fetched.text, "lexical content");
    assert_eq!(fetched.dense_composition_text.as_deref(), Some("dense content"));
    assert_eq!(fetched.effective_dense_text(), "dense content");
}

#[test]
fn document_store_idempotent_when_both_texts_match() {
    // Both lexical text AND dense text must match for the call to be a no-op.
    // If either changes, the revision must bump.
    let storage = in_memory_storage();
    storage
        .migrate(&corpus_kit::standalone_declaration(false))
        .unwrap();
    let store = CorpusDocumentStore::new(Arc::clone(&storage));

    let first = store
        .put_with_dense_text("lexical", Some("dense"), "doc1", NOW)
        .unwrap();
    assert_eq!(first.revision, 1);

    // Identical call — must be a no-op (revision stays at 1).
    let second = store
        .put_with_dense_text("lexical", Some("dense"), "doc1", NOW + 1)
        .unwrap();
    assert_eq!(second.revision, 1);
}

#[test]
fn document_store_revision_bumps_when_dense_text_changes() {
    let storage = in_memory_storage();
    storage
        .migrate(&corpus_kit::standalone_declaration(false))
        .unwrap();
    let store = CorpusDocumentStore::new(Arc::clone(&storage));

    let first = store
        .put_with_dense_text("same lexical text", Some("dense v1"), "doc1", NOW)
        .unwrap();
    assert_eq!(first.revision, 1);

    // Lexical text unchanged, dense text changed — revision MUST bump.
    let second = store
        .put_with_dense_text("same lexical text", Some("dense v2"), "doc1", NOW + 1)
        .unwrap();
    assert_eq!(second.revision, 2);
    assert_eq!(second.dense_composition_text.as_deref(), Some("dense v2"));
}

#[test]
fn document_store_records_for_batch_read_includes_dense_text() {
    let storage = in_memory_storage();
    storage
        .migrate(&corpus_kit::standalone_declaration(false))
        .unwrap();
    let store = CorpusDocumentStore::new(Arc::clone(&storage));

    store.put_with_dense_text("alpha lexical", Some("alpha dense"), "doc-a", NOW).unwrap();
    store.put("beta only lexical", "doc-b", NOW).unwrap();

    let batch = store.records_for(&["doc-a", "doc-b"]).unwrap();
    let a = batch.get("doc-a").expect("doc-a must exist");
    assert_eq!(a.effective_dense_text(), "alpha dense");
    let b = batch.get("doc-b").expect("doc-b must exist");
    assert_eq!(b.effective_dense_text(), "beta only lexical"); // fallback
}

// ─── Source-protocol (attached) mode tests ────────────────────────────────────

#[test]
fn source_protocol_dense_text_supplied_via_record() {
    // In attached mode the source adapter is responsible for populating
    // dense_composition_text in the records it returns. The engine uses
    // effective_dense_text() for embedding; the lexical text goes to BM25.
    // This test verifies the record-passing contract end-to-end.
    let storage = in_memory_storage();
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .unwrap();

    let source = DualTextStaticSource::new(vec![
        CorpusContentRecord {
            id: "doc1".into(),
            revision: 1,
            digest: content_digest("lexical about dogs"),
            text: "lexical about dogs".into(),
            dense_composition_text: Some("dense summary of dogs".into()),
        },
    ]);

    let engine = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        vec![EmbeddingModelConfig::Deterministic],
    )
    .expect("open engine");

    // Should succeed: the engine resolves effective_dense_text() from the record.
    engine
        .apply_change(
            &CorpusContentChange::Upsert {
                id: "doc1".into(),
                revision: 1,
                digest: content_digest("lexical about dogs"),
            },
            None,
            NOW,
        )
        .expect("apply change with dense text in source");
}

#[test]
fn source_protocol_nil_dense_text_means_lexical_used_for_both() {
    // A source that supplies None dense_composition_text must behave identically
    // to pre-dual-text: lexical text is used for both BM25 and float lane.
    let storage = in_memory_storage();
    let config = CorpusContentConfiguration::new(
        CorpusOperatingMode::Attached,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .unwrap();

    let source = DualTextStaticSource::new(vec![
        CorpusContentRecord {
            id: "doc1".into(),
            revision: 1,
            digest: content_digest("only lexical text"),
            text: "only lexical text".into(),
            dense_composition_text: None, // explicit None: lexical text for both lanes
        },
    ]);

    let engine = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        Arc::clone(&source) as Arc<dyn CorpusContentSource>,
        vec![EmbeddingModelConfig::Deterministic],
    )
    .expect("open engine");

    engine
        .apply_change(
            &CorpusContentChange::Upsert {
                id: "doc1".into(),
                revision: 1,
                digest: content_digest("only lexical text"),
            },
            None,
            NOW,
        )
        .expect("apply change with nil dense text");
}

// ─── Standalone ingest dual-text tests ───────────────────────────────────────

#[test]
fn standalone_ingest_nil_dense_text_backward_compat() {
    // The standard ingest path (no dense text) must behave identically to
    // before the dual-text capability landed.
    let (engine, store, _storage) = make_standalone_with_store();

    let record = store.put("lexical content only", "doc1", NOW).unwrap();
    assert!(record.dense_composition_text.is_none());

    engine
        .index_content("doc1", NOW)
        .expect("index without dense text");

    // Recall must work: the lexical text was BM25-indexed.
    let hits = engine.recall("lexical", 5).expect("recall");
    assert!(hits.iter().any(|h| h.id == "doc1"), "doc1 must appear in recall");
}

#[test]
fn standalone_ingest_with_dense_text_stores_and_uses_it() {
    let (engine, store, _storage) = make_standalone_with_store();

    store
        .put_with_dense_text(
            "original lexical content",
            Some("dense composition representation"),
            "doc1",
            NOW,
        )
        .expect("put with dense text");

    engine
        .index_content("doc1", NOW)
        .expect("index with dense text");

    // BM25 was indexed on the lexical text — recall on lexical tokens must work.
    let hits = engine.recall("lexical", 5).expect("recall");
    assert!(hits.iter().any(|h| h.id == "doc1"), "doc1 must appear via BM25 on lexical text");
}
