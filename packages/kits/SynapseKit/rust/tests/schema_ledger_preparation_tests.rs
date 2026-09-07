//! Rust twin of Swift `SchemaLedgerPreparationTests.swift`.
//!
//! `VectorStore::prepare_schema_ledger` and
//! `VectorRepresentationClaims::prepare_schema_ledger` move the vector tier's
//! schema-version ledger rows from their former kit ids (VectorKit /
//! VectorKitClaims) to the current ids before the ladder runs.
//!
//! Tests:
//!   1. The constants: the current id is the declared kit id and the former
//!      ids are the pinned rename pair (identical literal in the Swift twin).
//!   2. Fresh storage: no row under either id, prepare is a no-op and creates
//!      nothing.
//!   3. Legacy row: a `VectorKit` v6 row moves to `SynapseKit` at v6 and the
//!      old id has no row; the claims ledger does the same for v1.
//!   4. Rows under both ids (the generation-3 SQLite fixture of §5 plus a
//!      `SynapseKit` v6 row): prepare returns `Ok`, both rows stay with their
//!      versions, and prepare + migrate keeps the row at generation 3. The
//!      claims ledger likewise passes with both its rows left in place.
//!   5. SQLite estate a pre-rename runtime left behind (ledger row `VectorKit`
//!      v6, one `vectors` row at generation 3): prepare + migrate keeps the
//!      row at generation 3 and the ledger carries one row, under `SynapseKit`.
//!      Control: migrate without prepare replays the ladder and folds the
//!      generation to 0 (the failure the preparation exists to prevent).

use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{
    BackendConfiguration, EstateConfiguration, SchemaDeclaration, SqliteStorage, Storage,
    TypedValue,
};
use std::collections::BTreeMap;
use std::sync::Arc;
use synapsekit::{VectorRepresentationClaims, VectorStore};
use uuid::Uuid;

const NOW: i64 = 1_756_000_000_000;

/// Record a schema-version ledger row for `kit_id` at `version` without
/// declaring any table: the row a store leaves behind when it opens an estate.
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

fn in_memory() -> Arc<dyn Storage> {
    Arc::new(InMemoryStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::InMemory,
    )))
}

// §1 Constants
#[test]
fn constants_pin_the_rename_pair() {
    assert_eq!(VectorStore::KIT_ID, "SynapseKit");
    assert_eq!(VectorStore::schema_declaration().kit_id, VectorStore::KIT_ID);
    assert_eq!(VectorStore::FORMER_KIT_IDS, &["VectorKit"]);
    assert_eq!(VectorRepresentationClaims::KIT_ID, "SynapseKitClaims");
    assert_eq!(
        VectorRepresentationClaims::schema_declaration().kit_id,
        VectorRepresentationClaims::KIT_ID
    );
    assert_eq!(
        VectorRepresentationClaims::FORMER_KIT_IDS,
        &["VectorKitClaims"]
    );
}

// §2 Fresh storage
#[test]
fn fresh_storage_is_a_no_op() {
    let storage = in_memory();
    VectorStore::prepare_schema_ledger(storage.as_ref()).expect("prepare store");
    VectorRepresentationClaims::prepare_schema_ledger(storage.as_ref()).expect("prepare claims");
    assert_eq!(version(storage.as_ref(), VectorStore::KIT_ID), 0);
    assert_eq!(version(storage.as_ref(), "VectorKit"), 0);
    assert_eq!(version(storage.as_ref(), VectorRepresentationClaims::KIT_ID), 0);
    assert_eq!(version(storage.as_ref(), "VectorKitClaims"), 0);
}

// §3 Legacy rows move
#[test]
fn legacy_rows_move_to_the_current_ids() {
    let storage = in_memory();
    seed_ledger(storage.as_ref(), "VectorKit", 6);
    seed_ledger(storage.as_ref(), "VectorKitClaims", 1);

    VectorStore::prepare_schema_ledger(storage.as_ref()).expect("prepare store");
    VectorRepresentationClaims::prepare_schema_ledger(storage.as_ref()).expect("prepare claims");

    assert_eq!(version(storage.as_ref(), VectorStore::KIT_ID), 6);
    assert_eq!(version(storage.as_ref(), "VectorKit"), 0);
    assert_eq!(version(storage.as_ref(), VectorRepresentationClaims::KIT_ID), 1);
    assert_eq!(version(storage.as_ref(), "VectorKitClaims"), 0);

    // A second call finds nothing to move and changes nothing.
    VectorStore::prepare_schema_ledger(storage.as_ref()).expect("second prepare");
    assert_eq!(version(storage.as_ref(), VectorStore::KIT_ID), 6);
}

// §4 Conflict warns and leaves both rows
#[test]
fn rows_under_both_ids_warn_and_are_left_in_place() {
    // Pinned fixture (identical in the Swift twin and the CorpusKit pair):
    // `VectorKit` v6 with one `vectors` row at generation 3, plus a
    // `SynapseKit` v6 ledger row. Prepare returns `Ok`, both ledger rows keep
    // their versions, and migrate under the current id finds its ladder
    // position there — the row stays at generation 3.
    let conflicted = sqlite_vector_state_after_migrate(true, true);
    assert_eq!(
        conflicted,
        VectorState {
            rows: 1,
            generation: 3,
            new_version: VectorStore::schema_declaration().version,
            old_version: VectorStore::schema_declaration().version,
        }
    );

    // The claims ledger applies the same policy.
    let storage = in_memory();
    seed_ledger(storage.as_ref(), "VectorKitClaims", 1);
    seed_ledger(storage.as_ref(), VectorRepresentationClaims::KIT_ID, 1);
    VectorRepresentationClaims::prepare_schema_ledger(storage.as_ref())
        .expect("conflicted claims ledger still prepares");
    assert_eq!(version(storage.as_ref(), "VectorKitClaims"), 1);
    assert_eq!(version(storage.as_ref(), VectorRepresentationClaims::KIT_ID), 1);
}

// §5 SQLite: the ladder does not replay after preparation

#[derive(Debug, PartialEq, Eq)]
struct VectorState {
    rows: usize,
    generation: i64,
    new_version: i32,
    old_version: i32,
}

/// Build a SQLite estate a pre-rename runtime left behind: the vector tables
/// at their current layout under the OLD ledger id, one `vectors` row at
/// generation 3. With `seed_current_id_row` a ledger row under the NEW id at
/// the current version is added as well (the conflicted ledger). Then
/// (optionally) prepare the ledger, apply the current declaration, and report
/// the row count, that row's generation, and the ledger versions under the
/// NEW and the OLD id.
fn sqlite_vector_state_after_migrate(prepare_first: bool, seed_current_id_row: bool) -> VectorState {
    let dir = std::env::temp_dir().join(format!("synapsekit-ledger-{}", Uuid::new_v4()));
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

    if seed_current_id_row {
        seed_ledger(storage.as_ref(), VectorStore::KIT_ID, current.version);
    }
    if prepare_first {
        VectorStore::prepare_schema_ledger(storage.as_ref()).expect("prepare");
    }
    storage.migrate(&current).expect("current vector schema");
    let vectors = storage
        .row_store()
        .query("vectors", None, &[], None, None)
        .expect("query vectors");
    let generation = match vectors.first().and_then(|r| r.get("generation")) {
        Some(TypedValue::Int(v)) => *v,
        _ => -1,
    };
    let state = VectorState {
        rows: vectors.len(),
        generation,
        new_version: version(storage.as_ref(), VectorStore::KIT_ID),
        old_version: version(storage.as_ref(), VectorStore::FORMER_KIT_IDS[0]),
    };
    storage.close().expect("close");
    let _ = std::fs::remove_dir_all(&dir);
    state
}

#[test]
fn prepared_sqlite_estate_keeps_its_generation() {
    let prepared = sqlite_vector_state_after_migrate(true, false);
    assert_eq!(
        prepared,
        VectorState {
            rows: 1,
            generation: 3,
            new_version: VectorStore::schema_declaration().version,
            old_version: 0,
        }
    );
}

#[test]
fn unprepared_sqlite_estate_replays_and_folds_generation_to_zero() {
    // Control: the failure the preparation exists to prevent, observed.
    let replayed = sqlite_vector_state_after_migrate(false, false);
    assert_eq!(
        replayed,
        VectorState {
            rows: 1,
            generation: 0,
            new_version: VectorStore::schema_declaration().version,
            old_version: VectorStore::schema_declaration().version,
        }
    );
}
