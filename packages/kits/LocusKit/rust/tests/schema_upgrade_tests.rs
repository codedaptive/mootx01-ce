//! The v10 → v19 → v20 ladder against a
//! schema-10 SQLite file. Twin of Swift `SchemaUpgradeTests`.
//!
//! The fixture is built here from the CE v1.0.37 declaration shape (schema
//! 10: no subject trio, no kg_facts identity trio, no operationalAND, none
//! of the v16–v18 objects), stamped 10 in the ledger by opening it with a
//! version-10 declaration. Opening it again with the current LocusKit
//! schema must land at 20 with both model registries, `ssc_facts`, the
//! surviving v11–v15 deltas, and none of the retired objects.
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

/// The schema-19 shape of the tables the v19 → v20 hop modifies: drawers with
/// the v12 subject trio and the v19 ssc_facts column; kg_facts with the v13
/// identity trio but none of the v20 extraction columns. Used to prove the hop
/// preserves pre-existing rows and stamps declared defaults on all twelve new
/// columns.
fn schema_19() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "LocusKit",
        19,
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
                    // v12: subject trio added by the v10 → v19 hop.
                    ColumnDeclaration::text("subject").nullable(),
                    ColumnDeclaration::text("subject_pipeline_version").nullable(),
                    ColumnDeclaration::timestamp("subject_at").nullable(),
                    // v19: enrichment column added by the v10 → v19 hop.
                    ColumnDeclaration::text("ssc_facts").nullable(),
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
                    // v13: identity trio added by the v10 → v19 hop.
                    ColumnDeclaration::text("addedBy"),
                    ColumnDeclaration::text("foreignSourceKey"),
                    ColumnDeclaration::text("foreignRecordID"),
                ],
                &["id"],
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
fn schema_10_estate_lands_at_20_with_only_surviving_deltas() {
    let db = TempDb::new();
    {
        let storage = open(&db.path);
        storage.open(&schema_10()).expect("stamp schema 10");
        assert_eq!(storage.current_schema_version_for("LocusKit").unwrap(), 10);
        storage.close().unwrap();
    }
    let storage = open(&db.path);
    storage.open(&schema::schema()).expect("open at 20");
    assert_eq!(storage.current_schema_version_for("LocusKit").unwrap(), SCHEMA_VERSION);
    assert_eq!(SCHEMA_VERSION, 20);

    // v19 additions.
    assert!(columns_exist(&storage, "encoder_models", &["model_id", "is_active"]), "encoder_models present");
    assert!(columns_exist(&storage, "drawers", &["ssc_facts"]), "ssc_facts present");
    assert!(columns_exist(&storage, "fact_extractor_models", &["recipe_id", "is_active"]));
    assert!(columns_exist(&storage, "kg_facts", &[
        "evidenceQuote", "evidenceStart", "evidenceEnd", "sourceDigest",
        "extractorProviderID", "extractorModelID", "searchProjection", "searchProjectionVersion",
    ]));
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
fn schema_19_populated_estate_lands_at_20_preserving_data() {
    let db = TempDb::new();
    let drawer_id = "d-v19-1";
    let fact_id   = "f-v19-1";

    // 1. Stamp at schema 19 and insert one row in each table using only the v19
    //    columns — the twelve v20 extraction columns do not exist yet.
    {
        let storage = open(&db.path);
        storage.open(&schema_19()).expect("stamp schema 19");
        assert_eq!(storage.current_schema_version_for("LocusKit").unwrap(), 19);

        let mut drawer: BTreeMap<String, TypedValue> = BTreeMap::new();
        drawer.insert("id".into(), TypedValue::Text(drawer_id.into()));
        drawer.insert("content".into(), TypedValue::Text("v19 drawer".into()));
        drawer.insert("parent_node_id".into(), TypedValue::Text("n1".into()));
        drawer.insert("addedBy".into(), TypedValue::Text("test".into()));
        drawer.insert("filedAt".into(), TypedValue::Text("2024-01-01T00:00:00Z".into()));
        drawer.insert("embeddingModelID".into(), TypedValue::Text("t1".into()));
        drawer.insert("provenance".into(), TypedValue::Int(0));
        drawer.insert("adjectiveBitmap".into(), TypedValue::Int(0));
        drawer.insert("operationalBitmap".into(), TypedValue::Int(0));
        drawer.insert("lineageID".into(), TypedValue::Text(String::new()));
        drawer.insert("udcCode".into(), TypedValue::Text(String::new()));
        storage.row_store().insert("drawers", drawer).expect("insert drawer");

        let mut fact: BTreeMap<String, TypedValue> = BTreeMap::new();
        fact.insert("id".into(), TypedValue::Text(fact_id.into()));
        fact.insert("subject".into(), TypedValue::Text("sky".into()));
        fact.insert("predicate".into(), TypedValue::Text("is".into()));
        fact.insert("object".into(), TypedValue::Text("blue".into()));
        fact.insert("sourceDrawerID".into(), TypedValue::Text(drawer_id.into()));
        fact.insert("adjectiveBitmap".into(), TypedValue::Int(0));
        fact.insert("operationalBitmap".into(), TypedValue::Int(0));
        fact.insert("provenanceBitmap".into(), TypedValue::Int(0));
        fact.insert("filedAt".into(), TypedValue::Text("2024-01-01T00:00:00Z".into()));
        fact.insert("addedBy".into(), TypedValue::Text(String::new()));
        fact.insert("foreignSourceKey".into(), TypedValue::Text(String::new()));
        fact.insert("foreignRecordID".into(), TypedValue::Text(String::new()));
        storage.row_store().insert("kg_facts", fact).expect("insert kg_fact");

        // Confirm both rows landed before the hop.
        assert_eq!(
            storage.row_store().query("drawers", None, &[], None, None).unwrap().len(), 1,
            "drawer count before hop"
        );
        assert_eq!(
            storage.row_store().query("kg_facts", None, &[], None, None).unwrap().len(), 1,
            "fact count before hop"
        );
        storage.close().unwrap();
    }

    // 2. Confirm the upgrade path routes v19 — the same decision the upgrade
    //    command makes before opening the schema.
    assert_eq!(schema::upgrade_path(19), SchemaUpgradePath::Upgrade { from: 19 });

    // 3. Reopen through the full schema: applies the v19 → v20 hop.
    let storage = open(&db.path);
    storage.open(&schema::schema()).expect("open at 20");

    // a. Schema version is 20 after the hop.
    assert_eq!(storage.current_schema_version_for("LocusKit").unwrap(), SCHEMA_VERSION);
    assert_eq!(SCHEMA_VERSION, 20);

    // b. Both pre-existing rows survived the hop unchanged in count.
    let all_drawers = storage.row_store().query("drawers", None, &[], None, None).unwrap();
    let all_facts   = storage.row_store().query("kg_facts", None, &[], None, None).unwrap();
    assert_eq!(all_drawers.len(), 1, "drawer count after hop");
    assert_eq!(all_facts.len(),   1, "fact count after hop");

    // c. All twelve new kg_facts extraction columns carry their declared defaults
    //    on the pre-existing row.
    let row = &all_facts[0];
    // Text columns: declared DEFAULT ''.
    assert_eq!(row.get("evidenceQuote"),           Some(&TypedValue::Text(String::new())), "evidenceQuote default");
    assert_eq!(row.get("sourceDigest"),            Some(&TypedValue::Text(String::new())), "sourceDigest default");
    assert_eq!(row.get("extractorProviderID"),     Some(&TypedValue::Text(String::new())), "extractorProviderID default");
    assert_eq!(row.get("extractorModelID"),        Some(&TypedValue::Text(String::new())), "extractorModelID default");
    assert_eq!(row.get("extractorModelVersion"),   Some(&TypedValue::Text(String::new())), "extractorModelVersion default");
    assert_eq!(row.get("extractionSchemaVersion"), Some(&TypedValue::Text(String::new())), "extractionSchemaVersion default");
    assert_eq!(row.get("searchProjection"),        Some(&TypedValue::Text(String::new())), "searchProjection default");
    assert_eq!(row.get("searchProjectionVersion"), Some(&TypedValue::Text(String::new())), "searchProjectionVersion default");
    // Int columns: declared DEFAULT -1.
    assert_eq!(row.get("evidenceStart"),       Some(&TypedValue::Int(-1)), "evidenceStart default");
    assert_eq!(row.get("evidenceEnd"),         Some(&TypedValue::Int(-1)), "evidenceEnd default");
    assert_eq!(row.get("evidenceStartUTF8Byte"), Some(&TypedValue::Int(-1)), "evidenceStartUTF8Byte default");
    assert_eq!(row.get("evidenceEndUTF8Byte"), Some(&TypedValue::Int(-1)), "evidenceEndUTF8Byte default");

    // d. fact_extractor_models was created by the hop and holds zero rows.
    assert!(
        columns_exist(&storage, "fact_extractor_models", &["recipe_id", "is_active"]),
        "fact_extractor_models must exist after hop"
    );
    assert_eq!(
        storage.row_store().query("fact_extractor_models", None, &[], None, None).unwrap().len(),
        0,
        "fact_extractor_models must be empty"
    );

    // e. A value written at v19 into an existing column reads back unchanged.
    assert_eq!(row.get("predicate"), Some(&TypedValue::Text("is".into())), "predicate preserved after hop");

    storage.close().unwrap();
}

#[test]
fn upgrade_path_refuses_every_version_but_fresh_floor_and_current() {
    assert_eq!(schema::upgrade_path(0), SchemaUpgradePath::Fresh);
    assert_eq!(schema::upgrade_path(10), SchemaUpgradePath::Upgrade { from: 10 });
    assert_eq!(schema::upgrade_path(19), SchemaUpgradePath::Upgrade { from: 19 });
    assert_eq!(schema::upgrade_path(20), SchemaUpgradePath::Current);
    for found in [1, 9, 11, 15, 18, 21] {
        assert_eq!(schema::upgrade_path(found), SchemaUpgradePath::Unsupported { found });
    }
}
