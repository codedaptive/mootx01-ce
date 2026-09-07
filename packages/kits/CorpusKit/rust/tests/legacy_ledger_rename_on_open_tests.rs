//! Rust twin of Swift `LegacyLedgerRenameOnOpenTests.swift`.
//!
//! The standalone constructors (`Corpus::open` and `CorpusContentEngine::open`)
//! move the vector tier's schema-version ledger rows from their former kit ids
//! (VectorKit / VectorKitClaims) to the current ids before they migrate the
//! SynapseKit declarations, so a populated estate a pre-rename runtime left
//! behind opens without replaying the vector ladder.
//!
//! Pinned regression (identical fixture in the Swift twin): ledger row
//! `VectorKit` v6 plus one `vectors` row at generation 3 → after a standalone
//! open the row is still at generation 3 and the ledger carries one row for
//! the store, under `SynapseKit` (v6; nothing under `VectorKit`).
//!
//! Tests:
//!   1. `Corpus::open` on that SQLite estate.
//!   2. `CorpusContentEngine::open` (standalone) on that estate, which also
//!      moves the claims ledger row `VectorKitClaims` v1 → `SynapseKitClaims` v1.
//!   3. Rows under both ids (the same fixture plus `SynapseKit` v6 and
//!      `SynapseKitClaims` v1 rows): both constructors open, every ledger row
//!      is left as it is with its version, and the row stays at generation 3.

use corpus_kit::{
    Corpus, CorpusContentConfiguration, CorpusContentEngine, CorpusContentSource,
    CorpusDocumentStore, CorpusIndexUnitPolicy, CorpusOperatingMode, EmbeddingModelConfig,
};
use persistence_kit::{
    BackendConfiguration, EstateConfiguration, SchemaDeclaration, SqliteStorage, Storage,
    TypedValue,
};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use synapsekit::{VectorRepresentationClaims, VectorStore};
use uuid::Uuid;

const NOW: i64 = 1_756_000_000_000;

struct TempDir(PathBuf);
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn seed_ledger(storage: &dyn Storage, kit_id: &str, version: i32) {
    storage
        .migrate(&SchemaDeclaration::new(kit_id, version, vec![]))
        .expect("seed ledger row");
}

fn version(storage: &dyn Storage, kit_id: &str) -> i32 {
    storage
        .current_schema_version_for(kit_id)
        .expect("ledger version")
}

/// The row count of `vectors` and the generation of its first row (-1 when absent).
fn vector_state(storage: &dyn Storage) -> (usize, i64) {
    let vectors = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .expect("query vectors");
    let generation = match vectors.first().and_then(|r| r.get("generation")) {
        Some(TypedValue::Int(v)) => *v,
        _ => -1,
    };
    (vectors.len(), generation)
}

/// A SQLite estate a pre-rename runtime left behind: the vector tables at
/// their current layout recorded under the OLD ledger ids (store v6, claims
/// v1) and one `vectors` row at generation 3.
fn legacy_sqlite_estate() -> (Arc<dyn Storage>, TempDir) {
    let dir = std::env::temp_dir().join(format!("corpuskit-ledger-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let path = dir.join("estate.sqlite").to_string_lossy().into_owned();
    let storage: Arc<dyn Storage> = Arc::new(
        SqliteStorage::new(EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path,
                busy_timeout_secs: 5.0,
            },
        ))
        .expect("open sqlite"),
    );

    let current = VectorStore::schema_declaration();
    let legacy = SchemaDeclaration {
        kit_id: VectorStore::FORMER_KIT_IDS[0].to_string(),
        ..current.clone()
    };
    storage.migrate(&legacy).expect("legacy vector schema");
    let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
    row.insert("id".into(), TypedValue::Uuid(Uuid::new_v4()));
    row.insert("item_id".into(), TypedValue::Text("item-1".into()));
    row.insert("vector_index".into(), TypedValue::Int(0));
    row.insert("model_id".into(), TypedValue::Text("model-1".into()));
    row.insert("model_version".into(), TypedValue::Text("1".into()));
    row.insert("kind".into(), TypedValue::Int(0));
    row.insert("dim".into(), TypedValue::Int(256));
    row.insert("payload".into(), TypedValue::Blob(vec![0xA5; 32]));
    row.insert("scale".into(), TypedValue::Null);
    row.insert("filed_at".into(), TypedValue::Timestamp(NOW));
    row.insert("ext".into(), TypedValue::Null);
    row.insert("generation".into(), TypedValue::Int(3));
    storage
        .row_store()
        .insert("vectors", row)
        .expect("insert vector row");

    let claims = VectorRepresentationClaims::schema_declaration();
    let legacy_claims = SchemaDeclaration {
        kit_id: VectorRepresentationClaims::FORMER_KIT_IDS[0].to_string(),
        ..claims
    };
    storage.migrate(&legacy_claims).expect("legacy claims schema");
    (storage, TempDir(dir))
}

/// The legacy estate with a ledger row under each CURRENT id as well
/// (`SynapseKit` v6, `SynapseKitClaims` v1): the ledger a post-rename runtime
/// left behind when it opened the estate without the preparation. The
/// `vectors` row is still at generation 3.
fn conflicted_sqlite_estate() -> (Arc<dyn Storage>, TempDir) {
    let (storage, dir) = legacy_sqlite_estate();
    seed_ledger(
        storage.as_ref(),
        VectorStore::KIT_ID,
        VectorStore::schema_declaration().version,
    );
    seed_ledger(
        storage.as_ref(),
        VectorRepresentationClaims::KIT_ID,
        VectorRepresentationClaims::schema_declaration().version,
    );
    (storage, dir)
}

fn standalone_config() -> CorpusContentConfiguration {
    CorpusContentConfiguration::new(
        CorpusOperatingMode::Standalone,
        CorpusIndexUnitPolicy::WholeContent,
    )
    .expect("configuration")
}

// §1 Corpus::open
#[test]
fn corpus_open_keeps_generation_and_moves_the_ledger_row() {
    let (storage, _dir) = legacy_sqlite_estate();
    assert_eq!(version(storage.as_ref(), VectorStore::FORMER_KIT_IDS[0]), 6);

    let _corpus =
        Corpus::open(Arc::clone(&storage), EmbeddingModelConfig::Deterministic).expect("open");

    assert_eq!(vector_state(storage.as_ref()), (1, 3));
    assert_eq!(
        version(storage.as_ref(), VectorStore::KIT_ID),
        VectorStore::schema_declaration().version
    );
    assert_eq!(version(storage.as_ref(), VectorStore::FORMER_KIT_IDS[0]), 0);
}

// §2 CorpusContentEngine::open (standalone)
#[test]
fn content_engine_open_keeps_generation_and_moves_both_ledger_rows() {
    let (storage, _dir) = legacy_sqlite_estate();
    assert_eq!(
        version(storage.as_ref(), VectorRepresentationClaims::FORMER_KIT_IDS[0]),
        1
    );

    let store = Arc::new(CorpusDocumentStore::new(Arc::clone(&storage)));
    let _engine = CorpusContentEngine::open(
        Arc::clone(&storage),
        standalone_config(),
        store as Arc<dyn CorpusContentSource>,
        vec![EmbeddingModelConfig::Deterministic],
    )
    .expect("open engine");

    assert_eq!(vector_state(storage.as_ref()), (1, 3));
    assert_eq!(
        version(storage.as_ref(), VectorStore::KIT_ID),
        VectorStore::schema_declaration().version
    );
    assert_eq!(version(storage.as_ref(), VectorStore::FORMER_KIT_IDS[0]), 0);
    assert_eq!(
        version(storage.as_ref(), VectorRepresentationClaims::KIT_ID),
        VectorRepresentationClaims::schema_declaration().version
    );
    assert_eq!(
        version(storage.as_ref(), VectorRepresentationClaims::FORMER_KIT_IDS[0]),
        0
    );
}

// §3 Conflicted ledger opens and leaves both rows
#[test]
fn rows_under_both_ids_open_and_are_left_in_place() {
    // Corpus::open: the legacy fixture plus a `SynapseKit` v6 row.
    let (corpus_storage, _corpus_dir) = conflicted_sqlite_estate();
    let _corpus = Corpus::open(
        Arc::clone(&corpus_storage),
        EmbeddingModelConfig::Deterministic,
    )
    .expect("conflicted ledger still opens Corpus");
    assert_eq!(vector_state(corpus_storage.as_ref()), (1, 3));
    assert_eq!(
        version(corpus_storage.as_ref(), VectorStore::FORMER_KIT_IDS[0]),
        6
    );
    assert_eq!(version(corpus_storage.as_ref(), VectorStore::KIT_ID), 6);

    // CorpusContentEngine::open: the same fixture; the claims ledger is
    // conflicted too (`VectorKitClaims` v1 and `SynapseKitClaims` v1).
    let (engine_storage, _engine_dir) = conflicted_sqlite_estate();
    let store = Arc::new(CorpusDocumentStore::new(Arc::clone(&engine_storage)));
    let _engine = CorpusContentEngine::open(
        Arc::clone(&engine_storage),
        standalone_config(),
        store as Arc<dyn CorpusContentSource>,
        vec![EmbeddingModelConfig::Deterministic],
    )
    .expect("conflicted ledger still opens CorpusContentEngine");
    assert_eq!(vector_state(engine_storage.as_ref()), (1, 3));
    assert_eq!(
        version(engine_storage.as_ref(), VectorStore::FORMER_KIT_IDS[0]),
        6
    );
    assert_eq!(version(engine_storage.as_ref(), VectorStore::KIT_ID), 6);
    assert_eq!(
        version(
            engine_storage.as_ref(),
            VectorRepresentationClaims::FORMER_KIT_IDS[0]
        ),
        1
    );
    assert_eq!(
        version(engine_storage.as_ref(), VectorRepresentationClaims::KIT_ID),
        1
    );
}
