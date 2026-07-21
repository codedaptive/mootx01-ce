//! Characterization of the CURRENT (pre-cutover) Corpus engine
//! (GLK shared-content 1.1, P0). Rust twin of the Swift
//! `SharedContentCharacterizationTests`.
//!
//! These tests document — as executable fact — exactly where today's
//! engine creates the second content projection the 1.1 mission removes:
//! verbatim text copies in `chunks`, unconditional `Chunker` invocation,
//! chunk-UUID identity in every recall lane (requiring the chunk→source
//! translation join), and the unscoped `destroy_recall_index` teardown.
//!
//! Tests marked CURRENT-BEHAVIOR are expected to be updated or retired
//! WITH the phase that changes the behavior — each documents a defect the
//! mission corrects, not a contract to keep.

use corpus_kit::{Corpus, EmbeddingModelConfig};
use intellectus_lib::Intellectus;
use persistence_kit::database_inventory::capture_inventory;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage, TypedValue};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, OnceLock};
use uuid::Uuid;

static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poison) => poison.into_inner(),
    }
}

fn make_corpus_with_storage() -> (Corpus, Arc<dyn Storage>) {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    let corpus = Corpus::open(Arc::clone(&storage), EmbeddingModelConfig::Deterministic)
        .expect("Corpus::open must succeed");
    (corpus, storage)
}

const NOW_MILLIS: i64 = 1_700_000_000_000;

// ── 1. Verbatim text copy ────────────────────────────────────────────────

#[test]
fn ingest_copies_verbatim_text_into_chunk_rows() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let (corpus, storage) = make_corpus_with_storage();
    let text = "The drawer is the canonical content row in a GLK estate.";
    corpus.ingest(text, "drawer-1", NOW_MILLIS).expect("ingest");

    let rows = storage
        .row_store()
        .query("chunks", None, &[], None, None)
        .expect("query chunks");
    assert_eq!(rows.len(), 1);
    // CURRENT-BEHAVIOR: the verbatim source text is duplicated into the
    // chunks table — the second content projection.
    match rows[0].get("text") {
        Some(TypedValue::Text(stored)) => assert_eq!(stored, text),
        other => panic!("chunk row has no text column: {other:?}"),
    }

    // The copy is rooted through corpus_metadata (a per-source Merkle root
    // over the COPIED text, parallel to the Drawer root).
    let metadata_count = storage
        .row_store()
        .count("corpus_metadata", None)
        .expect("count corpus_metadata");
    assert_eq!(metadata_count, 1);
}

// ── 2. Chunker on the default path ───────────────────────────────────────

#[test]
fn chunker_splits_long_documents_into_chunk_rows() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let (corpus, storage) = make_corpus_with_storage();
    let text = "Chunking splits long documents into overlapping windows. ".repeat(70);
    corpus
        .ingest(&text, "drawer-long", NOW_MILLIS)
        .expect("ingest");

    let rows = storage
        .row_store()
        .query("chunks", None, &[], None, None)
        .expect("query chunks");
    // CURRENT-BEHAVIOR: passage production is unconditional — there is no
    // whole-content mode.
    assert!(rows.len() > 1, "expected multiple chunks, got {}", rows.len());

    let mut offsets = BTreeSet::new();
    for row in &rows {
        if let Some(TypedValue::Int(offset)) = row.get("start_offset") {
            offsets.insert(*offset);
        }
    }
    assert!(offsets.contains(&0));
    assert_eq!(offsets.len(), rows.len(), "chunk offsets must be distinct");
}

// ── 3. Chunk-UUID identity lane + translation join ───────────────────────

#[test]
fn recall_index_keys_are_chunk_uuids_requiring_translation() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let (corpus, storage) = make_corpus_with_storage();
    let source_id = "drawer-identity";
    corpus
        .ingest(
            "Identity crosses every lane as the drawer id.",
            source_id,
            NOW_MILLIS,
        )
        .expect("ingest");

    // Vector rows are keyed by chunk UUIDs, not the source ID. (The BM25
    // postings share the same chunk-UUID keying, but in the Rust port the
    // iix_* tables live in the InvertedIndexStore's PRIVATE connection —
    // not in the estate storage — so they are not inspectable here. That
    // sidecar-placement difference from Swift, where iix_* share the
    // estate file, is itself pre-cutover structure the P3 attached-profile
    // declaration must reconcile.)
    let vector_rows = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .expect("query vectors");
    assert!(!vector_rows.is_empty());
    let mut chunk_ids = Vec::new();
    for row in &vector_rows {
        if let Some(TypedValue::Text(item_id)) = row.get("item_id") {
            assert_ne!(item_id, source_id);
            let uuid = Uuid::parse_str(item_id).expect("vector item key is a chunk UUID");
            if !chunk_ids.contains(&uuid) {
                chunk_ids.push(uuid);
            }
        }
    }
    assert!(!chunk_ids.is_empty());

    // CURRENT-BEHAVIOR: hydrating a hit back to its Drawer requires the
    // chunk→source translation join.
    let translated = corpus.source_ids_for_chunks(&chunk_ids);
    let sources: BTreeSet<&String> = translated.values().collect();
    assert_eq!(sources.len(), 1);
    assert_eq!(*sources.iter().next().unwrap(), source_id);
}

// ── 4. Broad deletion in the lifecycle path ──────────────────────────────

#[test]
fn destroy_recall_index_deletes_unrelated_model_rows() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let (corpus, storage) = make_corpus_with_storage();
    corpus
        .ingest(
            "Corpus content whose derived rows may be destroyed.",
            "drawer-own",
            NOW_MILLIS,
        )
        .expect("ingest");

    // Seed a vector row under a model ID this corpus NEVER wrote — standing
    // in for another lane's representation in the shared estate storage.
    let unrelated = engram_lib::Engram::new(0x1111, 0x2222, 0x3333, 0x4444);
    corpus
        .shared_vector_store()
        .add_vector("drawer-own", &unrelated, "unrelated-lane-v1", "1.0.0", NOW_MILLIS)
        .expect("seed unrelated vector");

    corpus.destroy_recall_index().expect("destroy");

    // CURRENT-BEHAVIOR: the teardown is unscoped — the unrelated lane's row
    // is destroyed with the corpus's own rows. P5 makes this
    // ownership-aware via the representation manifest.
    let survivors = storage
        .row_store()
        .count("vectors", None)
        .expect("count vectors");
    assert_eq!(survivors, 0);
}

// ── 5. Inventory baseline over a deterministic build ─────────────────────

#[test]
fn inventory_baseline_identifies_every_derived_table() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    fn build() -> (Corpus, Arc<dyn Storage>) {
        let (corpus, storage) = make_corpus_with_storage();
        corpus
            .ingest("Alpha content for drawer one.", "drawer-1", NOW_MILLIS)
            .expect("ingest 1");
        corpus
            .ingest("Beta content for drawer two.", "drawer-2", NOW_MILLIS)
            .expect("ingest 2");
        (corpus, storage)
    }

    // hlc + created_at are wall-clock-stamped; exclude so the baseline is
    // comparable across capture instants.
    let mut exclusions: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    exclusions.insert(
        "chunks".to_string(),
        ["hlc", "created_at"].iter().map(|s| s.to_string()).collect(),
    );

    // NOTE: unlike Swift, the Rust port's iix_* BM25 tables live in the
    // InvertedIndexStore's PRIVATE connection, not the estate storage, so
    // the estate-level inventory here covers the content copy and vector
    // lane only.
    let (_corpus1, storage1) = build();
    let tables = ["chunks", "corpus_metadata", "vectors", "removed_sources"];
    let inventory = capture_inventory(&storage1, &tables, &exclusions).expect("inventory");
    let by_table: BTreeMap<&str, _> = inventory
        .iter()
        .map(|inv| (inv.table.as_str(), inv))
        .collect();
    assert_eq!(by_table["chunks"].row_count, 2);
    assert_eq!(by_table["corpus_metadata"].row_count, 2);
    // Binary engram row per chunk; the deterministic provider also stores a
    // float row per chunk (its float lane is live).
    assert_eq!(by_table["vectors"].row_count, 4);
    assert_eq!(by_table["removed_sources"].row_count, 0);

    // Determinism: an identical build in a fresh estate produces the SAME
    // folds for the content-addressed tables (timestamps excluded) — the
    // property migration baselines rely on.
    let (_corpus2, storage2) = build();
    let content_tables = ["chunks"];
    let inv1 = capture_inventory(&storage1, &content_tables, &exclusions).expect("inv1");
    let inv2 = capture_inventory(&storage2, &content_tables, &exclusions).expect("inv2");
    assert_eq!(inv1, inv2);
}
