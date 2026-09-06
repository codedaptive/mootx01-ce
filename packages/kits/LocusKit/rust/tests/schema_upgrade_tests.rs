//! The single v10 → v19 hop (ENCODER_RERANK_CONTRACT §12) against a
//! schema-10 SQLite file. Twin of Swift `SchemaUpgradeTests`.
//!
//! The fixture is built here from the CE v1.0.37 declaration shape (schema
//! 10: no subject trio, no kg_facts identity trio, no operationalAND, none
//! of the v16–v18 objects), stamped 10 in the ledger by opening it with a
//! version-10 declaration. Opening it again with the current LocusKit
//! schema must land at 19 with `encoder_models`, `ssc_facts` and the
//! surviving v11–v15 deltas present, and none of the retired objects.
//!
//! Failure modes pinned:
//!   1. The ladder silently re-appearing: a `distilled` column or an
//!      `adornments` table after the hop.
//!   2. A missing surviving delta: `subject`, `addedBy`, `operationalAND`.
//!   3. The refusal gate: `upgrade_path` for 18 and 11 is `Unsupported`.

use locus_kit::schema::{self, SchemaUpgradePath, SCHEMA_VERSION};
use persistence_kit::predicate::StoragePredicate;
use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use persistence_kit::sqlite::SqliteStorage;
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration};
use persistence_kit::types::TypedValue;
use persistence_kit::Storage;
use std::collections::BTreeMap;
use std::sync::Arc;
use uuid::Uuid;

struct TempDb {
    path: String,
}

impl TempDb {
    fn new() -> Self {
        let name = format!("locus_schema_upgrade_{}.db", Uuid::new_v4().simple());
        TempDb { path: std::env::temp_dir().join(name).to_string_lossy().into_owned() }
    }
}

impl Drop for TempDb {
    fn drop(&mut self) {
        for suffix in &["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{}", self.path, suffix));
        }
    }
}

fn open(path: &str) -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite { path: path.to_string(), busy_timeout_secs: 5.0 },
    );
    Arc::new(SqliteStorage::new(config).expect("sqlite storage"))
}

fn table(name: &str, columns: Vec<ColumnDeclaration>, pk: &[&str]) -> TableDeclaration {
    TableDeclaration {
        name: name.to_string(),
        columns,
        primary_key: pk.iter().map(|s| s.to_string()).collect(),
        unique_constraints: Vec::new(),
        generated_columns: Vec::new(),
        append_only: false,
        hashable: false,
    }
}

/// The schema-10 shape of the tables the hop touches (CE v1.0.37
/// `LocusKitSchema.swift`): drawers through `content_fingerprint`,
/// kg_facts without the identity trio, container_fingerprints without
/// `operationalAND`.
fn schema_10() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "LocusKit",
        10,
        vec![
            table(
                "drawers",
                vec![
                    ColumnDeclaration::text("id"),
                    ColumnDeclaration::text("content"),
                    ColumnDeclaration::text("parent_node_id"),
                    ColumnDeclaration::text("sourceFile").nullable(),
                    ColumnDeclaration::int("chunkIndex").nullable(),
                    ColumnDeclaration::text("addedBy"),
                    ColumnDeclaration::timestamp("filedAt"),
                    ColumnDeclaration::timestamp("eventTime").nullable(),
                    ColumnDeclaration::text("embeddingModelID"),
                    ColumnDeclaration::timestamp("tombstonedAt").nullable(),
                    ColumnDeclaration::text("removedByBatch").nullable(),
                    ColumnDeclaration::bitmap("provenance"),
                    ColumnDeclaration::bitmap("adjectiveBitmap"),
                    ColumnDeclaration::bitmap("operationalBitmap"),
                    ColumnDeclaration::text("lineageID"),
                    ColumnDeclaration::text("udcCode"),
                    ColumnDeclaration::text("udcFacets").nullable(),
                    ColumnDeclaration::text("wikidataQID").nullable(),
                    ColumnDeclaration::text("wikidataQidsSecondary").nullable(),
                    ColumnDeclaration::json("ext").nullable(),
                    ColumnDeclaration::text("keyID").nullable(),
                    ColumnDeclaration::blob("content_hash").nullable(),
                    ColumnDeclaration::blob("content_fingerprint").nullable(),
                ],
                &["id"],
            ),
            table(
                "kg_facts",
                vec![
                    ColumnDeclaration::text("id"),
                    ColumnDeclaration::text("subject"),
                    ColumnDeclaration::text("predicate"),
                    ColumnDeclaration::text("object"),
                    ColumnDeclaration::text("sourceDrawerID"),
                    ColumnDeclaration::bitmap("adjectiveBitmap"),
                    ColumnDeclaration::bitmap("operationalBitmap"),
                    ColumnDeclaration::bitmap("provenanceBitmap"),
                    ColumnDeclaration::timestamp("filedAt"),
                    ColumnDeclaration::json("ext").nullable(),
                ],
                &["id"],
            ),
            table(
                "container_fingerprints",
                vec![
                    ColumnDeclaration::text("wing"),
                    ColumnDeclaration::text("room"),
                    ColumnDeclaration::bitmap("adjectiveOR"),
                    ColumnDeclaration::bitmap("operationalOR"),
                    ColumnDeclaration::bitmap("provenanceOR"),
                    ColumnDeclaration::timestamp("updatedAt"),
                ],
                &["wing", "room"],
            ),
        ],
    )
}

/// True when every column exists on `table`. Probed with an UPDATE whose
/// predicate never matches: SQLite reads an unknown double-quoted identifier
/// in a SELECT as a string literal and returns rows, so a projected read
/// cannot tell a missing column apart; an UPDATE target must be a real column
/// ("no such column") and the table must exist ("no such table").
fn columns_exist(storage: &Arc<dyn Storage>, table: &str, columns: &[&str]) -> bool {
    let values: BTreeMap<String, TypedValue> = columns
        .iter()
        .map(|c| (c.to_string(), TypedValue::Null))
        .collect();
    storage
        .row_store()
        .update(table, values, &StoragePredicate::IsFalse)
        .is_ok()
}

#[test]
fn schema_10_estate_lands_at_19_with_only_surviving_deltas() {
    let db = TempDb::new();
    {
        let storage = open(&db.path);
        storage.open(&schema_10()).expect("stamp schema 10");
        assert_eq!(storage.current_schema_version_for("LocusKit").unwrap(), 10);
        storage.close().unwrap();
    }
    let storage = open(&db.path);
    storage.open(&schema::schema()).expect("open at 19");
    assert_eq!(storage.current_schema_version_for("LocusKit").unwrap(), SCHEMA_VERSION);
    assert_eq!(SCHEMA_VERSION, 19);

    // v19 additions.
    assert!(columns_exist(&storage, "encoder_models", &["model_id", "is_active"]), "encoder_models present");
    assert!(columns_exist(&storage, "drawers", &["ssc_facts"]), "ssc_facts present");
    // Surviving v11–v15 deltas.
    assert!(columns_exist(&storage, "drawers", &["subject", "subject_pipeline_version", "subject_at"]));
    assert!(columns_exist(&storage, "kg_facts", &["addedBy", "foreignSourceKey", "foreignRecordID"]));
    assert!(columns_exist(&storage, "container_fingerprints", &["operationalAND"]));
    assert!(columns_exist(&storage, "recall_trace", &["door", "composition", "laneRanks"]));
    // Retired objects never created.
    assert!(!columns_exist(&storage, "drawers", &["distilled"]), "distilled must not appear");
    assert!(!columns_exist(&storage, "drawers", &["distilled_source_digest"]));
    assert!(!columns_exist(&storage, "drawers", &["adornment"]));
    assert!(!columns_exist(&storage, "adornments", &["drawer_id"]), "adornments table must not appear");
    assert!(!columns_exist(&storage, "adornment_minters", &["id"]), "adornment_minters must not appear");
    storage.close().unwrap();
}

#[test]
fn upgrade_path_refuses_every_version_but_fresh_floor_and_current() {
    assert_eq!(schema::upgrade_path(0), SchemaUpgradePath::Fresh);
    assert_eq!(schema::upgrade_path(10), SchemaUpgradePath::Upgrade { from: 10 });
    assert_eq!(schema::upgrade_path(19), SchemaUpgradePath::Current);
    for found in [1, 9, 11, 15, 18, 20] {
        assert_eq!(schema::upgrade_path(found), SchemaUpgradePath::Unsupported { found });
    }
}
