// kg_fact_search_projection_backfill_gateway_tests.rs
//
// Gate C: kg_fact_search_projection_backfill_gateway injects the real
// FactSearchProjection constants. After the gateway runs, the stored
// search_projection must equal FactSearchProjection::build(s,p,o,&[]) and
// the stored search_projection_version must equal FactSearchProjection::VERSION
// (the constant, not a string literal).
//
// Discrimination: temporarily replacing FactSearchProjection::VERSION in
// kg_fact_search_projection_backfill_gateway.rs with a wrong string makes the
// search_projection_version assertion fail (red). Restoring it returns green.
//
// Swift twin: GeniusLocusKitTests/KGFactSearchProjectionBackfillGatewayTests.swift.

use std::collections::BTreeMap;
use std::sync::Arc;

use fact_extraction_kit::FactSearchProjection;
use genius_locus_kit::kg_fact_search_projection_backfill_gateway;
use locus_kit::{
    drawer_operational::DrawerFeatureFlags,
    schema,
};
use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use persistence_kit::sqlite::SqliteStorage;
use persistence_kit::storage::{BackendConfiguration, EstateConfiguration};
use persistence_kit::types::TypedValue;
use persistence_kit::Storage;
use uuid::Uuid;

/// Temporary SQLite database that cleans up its file (and WAL/SHM sidecars)
/// on drop. Mirrors the TempDb helper in locus-kit's schema_upgrade_tests.rs.
struct TempDb {
    path: String,
}

impl TempDb {
    fn new() -> Self {
        let name = format!("glk_gateway_{}.db", Uuid::new_v4().simple());
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

/// Open a PersistenceKit SQLiteStorage at the given path.
fn open(path: &str) -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite { path: path.to_string(), busy_timeout_secs: 5.0 },
    );
    Arc::new(SqliteStorage::new(config).expect("sqlite storage"))
}

fn make_table(name: &str, columns: Vec<ColumnDeclaration>, pk: &[&str]) -> TableDeclaration {
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

/// Schema-19 shape of drawers + kg_facts, WITHOUT the v20 extraction columns.
/// Mirrors the private schema_19() in locus-kit's schema_upgrade_tests.rs.
/// Redeclared here because that function is in a separate test binary and
/// cannot be imported.
fn schema_19() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "LocusKit",
        19,
        vec![
            make_table(
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
                    // v19: enrichment column.
                    ColumnDeclaration::text("ssc_facts").nullable(),
                ],
                &["id"],
            ),
            make_table(
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

// Gate C: the gateway injects the real FactSearchProjection constants —
// not a test double and not a string literal. After the gateway runs:
//   - stored search_projection == FactSearchProjection::build(s,p,o,&[])
//   - stored search_projection_version == FactSearchProjection::VERSION
//
// Both assertions reference Rust constants, so a wrong injection is caught
// immediately without any change to the test file.
//
// Discrimination: changing FactSearchProjection::VERSION in
// kg_fact_search_projection_backfill_gateway.rs to any wrong string makes
// the search_projection_version assert_eq! fail (red). Restoring it returns
// the test to green.
#[test]
fn gate_c_search_projection_gateway() {
    let db = TempDb::new();
    let drawer_id = "d-gateway";
    let fact_id = "f-gateway";
    let subject = "Jack";
    let predicate = "birthday";
    let object = "June";

    // 1. Stamp at schema 19 and insert one drawer + one fact.
    //    The kg_facts row has no searchProjection columns — they don't exist
    //    yet in the schema-19 shape.
    {
        let storage = open(&db.path);
        storage.open(&schema_19()).expect("stamp schema 19");

        let mut drawer_row: BTreeMap<String, TypedValue> = BTreeMap::new();
        drawer_row.insert("id".into(), TypedValue::Text(drawer_id.into()));
        drawer_row.insert("content".into(), TypedValue::Text("Jack's birthday is in June.".into()));
        drawer_row.insert("parent_node_id".into(), TypedValue::Text("n1".into()));
        drawer_row.insert("addedBy".into(), TypedValue::Text("test".into()));
        drawer_row.insert("filedAt".into(), TypedValue::Text("2024-01-01T00:00:00Z".into()));
        drawer_row.insert("embeddingModelID".into(), TypedValue::Text("t1".into()));
        drawer_row.insert("provenance".into(), TypedValue::Int(0));
        drawer_row.insert("adjectiveBitmap".into(), TypedValue::Int(0));
        drawer_row.insert("operationalBitmap".into(), TypedValue::Int(DrawerFeatureFlags::FACTS_EXTRACTED));
        drawer_row.insert("lineageID".into(), TypedValue::Text(String::new()));
        drawer_row.insert("udcCode".into(), TypedValue::Text(String::new()));
        storage.row_store().insert("drawers", drawer_row).expect("insert drawer");

        let mut fact_row: BTreeMap<String, TypedValue> = BTreeMap::new();
        fact_row.insert("id".into(), TypedValue::Text(fact_id.into()));
        fact_row.insert("subject".into(), TypedValue::Text(subject.into()));
        fact_row.insert("predicate".into(), TypedValue::Text(predicate.into()));
        fact_row.insert("object".into(), TypedValue::Text(object.into()));
        fact_row.insert("sourceDrawerID".into(), TypedValue::Text(drawer_id.into()));
        fact_row.insert("adjectiveBitmap".into(), TypedValue::Int(0));
        fact_row.insert("operationalBitmap".into(), TypedValue::Int(0));
        fact_row.insert("provenanceBitmap".into(), TypedValue::Int(0));
        fact_row.insert("filedAt".into(), TypedValue::Text("2024-01-01T00:00:00Z".into()));
        fact_row.insert("addedBy".into(), TypedValue::Text(String::new()));
        fact_row.insert("foreignSourceKey".into(), TypedValue::Text(String::new()));
        fact_row.insert("foreignRecordID".into(), TypedValue::Text(String::new()));
        storage.row_store().insert("kg_facts", fact_row).expect("insert fact");

        storage.close().unwrap();
    }

    // 2. Reopen through the full schema (applies the v19 → v20 hop).
    //    The hop adds search_projection and search_projection_version columns
    //    to kg_facts with DEFAULT '' on all pre-existing rows.
    let storage = open(&db.path);
    storage.open(&schema::schema()).expect("open at v20");

    // 3. Pre-state: both new columns carry the schema DEFAULT ('').
    let rows_before = storage.row_store().query("kg_facts", None, &[], None, None).unwrap();
    assert_eq!(rows_before.len(), 1, "one fact before gateway");
    assert_eq!(
        rows_before[0].get("searchProjection"),
        Some(&TypedValue::Text(String::new())),
        "searchProjection must be empty before the gateway runs"
    );
    assert_eq!(
        rows_before[0].get("searchProjectionVersion"),
        Some(&TypedValue::Text(String::new())),
        "searchProjectionVersion must be empty before the gateway runs"
    );

    // 4. Run the gateway. It injects FactSearchProjection::build and
    //    FactSearchProjection::VERSION — not a test double.
    let report = kg_fact_search_projection_backfill_gateway::run(&*storage)
        .expect("gateway run");
    assert_eq!(report.scanned, 1, "gateway must scan the one unprojected fact");
    assert_eq!(report.updated, 1, "gateway must update the one unprojected fact");

    // 5. Post-state: stored values match the real constants.
    //    References to Rust constants, not string literals — a wrong injection
    //    in the gateway is caught without touching this file.
    let rows_after = storage.row_store().query("kg_facts", None, &[], None, None).unwrap();
    assert_eq!(rows_after.len(), 1, "fact count unchanged after gateway");
    let row = &rows_after[0];
    let expected_projection = FactSearchProjection::build(subject, predicate, object, &[]);
    assert_eq!(
        row.get("searchProjection"),
        Some(&TypedValue::Text(expected_projection.clone())),
        "searchProjection must equal FactSearchProjection::build(s,p,o,&[])"
    );
    assert_eq!(
        row.get("searchProjectionVersion"),
        Some(&TypedValue::Text(FactSearchProjection::VERSION.into())),
        "searchProjectionVersion must equal FactSearchProjection::VERSION (the constant)"
    );

    storage.close().unwrap();
}
