// As-of temporal query tests for the InMemory backend.
// Part 1: gate is ON — .AsOf returns FeatureGated; .Present and
// None behave identically to the standard query.

use persistence_kit::{
    inmemory::InMemoryStorage, ColumnDeclaration, ColumnRole,
    SchemaDeclaration, Storage, StorageError, StorageRow, TableDeclaration, TypedValue,
};
use std::collections::BTreeMap;
use substrate_types::hlc::HLC;
use substrate_types::AsOfCoordinate;
use uuid::Uuid;

fn make_storage() -> InMemoryStorage {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    let schema = SchemaDeclaration::new(
        "AsOfTestKit",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("row_id"),
                ColumnDeclaration::text("content"),
                ColumnDeclaration::hlc("created_hlc"),
                ColumnDeclaration::hlc("tombstoned_hlc").nullable(),
            ],
            vec!["row_id".to_string()],
        )],
    );
    storage.open(&schema).expect("open");
    storage
}

fn item_row(id: Uuid, content: &str, hlc: HLC) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("row_id".into(), TypedValue::Uuid(id));
    m.insert("content".into(), TypedValue::Text(content.into()));
    m.insert("created_hlc".into(), TypedValue::Hlc(hlc));
    m
}

// ── Gate tests ──────────────────────────────────────────────────

#[test]
fn as_of_query_returns_feature_gated() {
    let s = make_storage();
    let rs = s.row_store();
    let hlc = HLC::new(1000, 0, 1);
    let result = rs.query_as_of(
        "items",
        None,
        &[],
        None,
        None,
        Some(AsOfCoordinate::AsOf(hlc)),
    );
    assert!(result.is_err());
    match result.unwrap_err() {
        StorageError::FeatureGated { feature } => {
            assert_eq!(feature, "asOfQuery");
        }
        other => panic!("expected FeatureGated, got {:?}", other),
    }
}

#[test]
fn as_of_projected_query_returns_feature_gated() {
    let s = make_storage();
    let rs = s.row_store();
    let hlc = HLC::new(1000, 0, 1);
    let result = rs.query_projected_as_of(
        "items",
        &["row_id", "content"],
        None,
        &[],
        None,
        None,
        Some(AsOfCoordinate::AsOf(hlc)),
    );
    assert!(result.is_err());
    match result.unwrap_err() {
        StorageError::FeatureGated { feature } => {
            assert_eq!(feature, "asOfQuery");
        }
        other => panic!("expected FeatureGated, got {:?}", other),
    }
}

#[test]
fn as_of_skip_corrupt_query_returns_feature_gated() {
    let s = make_storage();
    let rs = s.row_store();
    let hlc = HLC::new(1000, 0, 1);
    let result = rs.query_skip_corrupt_as_of(
        "items",
        None,
        &[],
        None,
        None,
        Some(AsOfCoordinate::AsOf(hlc)),
    );
    assert!(result.is_err());
    match result.unwrap_err() {
        StorageError::FeatureGated { feature } => {
            assert_eq!(feature, "asOfQuery");
        }
        other => panic!("expected FeatureGated, got {:?}", other),
    }
}

// ── Present / None passthrough tests ────────────────────────────

#[test]
fn present_query_behaves_like_standard_query() {
    let s = make_storage();
    let rs = s.row_store();
    let id = Uuid::new_v4();
    let hlc = HLC::new(500, 0, 1);
    rs.insert("items", item_row(id, "hello", hlc))
        .expect("insert");

    let rows = rs
        .query_as_of("items", None, &[], None, None, Some(AsOfCoordinate::Present))
        .expect("present query");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].get("content"), Some(&TypedValue::Text("hello".into())));
}

#[test]
fn none_as_of_query_behaves_like_standard_query() {
    let s = make_storage();
    let rs = s.row_store();
    let id = Uuid::new_v4();
    let hlc = HLC::new(500, 0, 1);
    rs.insert("items", item_row(id, "world", hlc))
        .expect("insert");

    let nil_rows = rs
        .query_as_of("items", None, &[], None, None, None)
        .expect("nil query");
    assert_eq!(nil_rows.len(), 1);
    assert_eq!(nil_rows[0].get("content"), Some(&TypedValue::Text("world".into())));

    let standard_rows = rs
        .query("items", None, &[], None, None)
        .expect("standard query");
    assert_eq!(standard_rows.len(), nil_rows.len());
}

#[test]
fn present_projected_query_passes_through() {
    let s = make_storage();
    let rs = s.row_store();
    let id = Uuid::new_v4();
    let hlc = HLC::new(500, 0, 1);
    rs.insert("items", item_row(id, "projected", hlc))
        .expect("insert");

    let rows = rs
        .query_projected_as_of(
            "items",
            &["row_id"],
            None,
            &[],
            None,
            None,
            Some(AsOfCoordinate::Present),
        )
        .expect("present projected query");
    assert_eq!(rows.len(), 1);
}

// ── Part 2: ColumnRole metadata + temporal filter conformance ───

fn make_temporal_storage() -> InMemoryStorage {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    let schema = SchemaDeclaration::new(
        "TemporalTestKit",
        1,
        vec![TableDeclaration::new(
            "nodes",
            vec![
                ColumnDeclaration::uuid("node_id"),
                ColumnDeclaration::text("payload"),
                ColumnDeclaration::created_hlc("created_hlc"),
                ColumnDeclaration::tombstoned_hlc("tombstoned_hlc"),
            ],
            vec!["node_id".to_string()],
        )],
    );
    storage.open(&schema).expect("open");
    storage
}

fn temporal_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "TemporalTestKit",
        1,
        vec![TableDeclaration::new(
            "nodes",
            vec![
                ColumnDeclaration::uuid("node_id"),
                ColumnDeclaration::text("payload"),
                ColumnDeclaration::created_hlc("created_hlc"),
                ColumnDeclaration::tombstoned_hlc("tombstoned_hlc"),
            ],
            vec!["node_id".to_string()],
        )],
    )
}

fn node_row(id: Uuid, payload: &str, created: HLC) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("node_id".into(), TypedValue::Uuid(id));
    m.insert("payload".into(), TypedValue::Text(payload.into()));
    m.insert("created_hlc".into(), TypedValue::Hlc(created));
    m
}

fn node_row_tombstoned(
    id: Uuid,
    payload: &str,
    created: HLC,
    tombstoned: HLC,
) -> BTreeMap<String, TypedValue> {
    let mut m = node_row(id, payload, created);
    m.insert("tombstoned_hlc".into(), TypedValue::Hlc(tombstoned));
    m
}

/// Temporal filter applied to query results using ColumnRole
/// metadata. This is the filter logic for when the gate lifts.
fn filter_as_of(rows: &[StorageRow], at: &HLC, table: &TableDeclaration) -> Vec<StorageRow> {
    let created_col = match table.created_hlc_column() {
        Some(c) => c,
        None => return rows.to_vec(),
    };
    let tomb_col = table.tombstoned_hlc_column();

    rows.iter()
        .filter(|row| {
            let created = match row.get(created_col) {
                Some(TypedValue::Hlc(h)) => h,
                _ => return false,
            };
            if created > at {
                return false;
            }
            if let Some(tc) = tomb_col {
                if let Some(TypedValue::Hlc(tombstoned)) = row.get(tc) {
                    return tombstoned > at;
                }
            }
            true
        })
        .cloned()
        .collect()
}

// ── Schema metadata tests ───────────────────────────────────────

#[test]
fn column_role_created_hlc_is_set() {
    let schema = temporal_schema();
    assert_eq!(schema.tables[0].created_hlc_column(), Some("created_hlc"));
}

#[test]
fn column_role_tombstoned_hlc_is_set() {
    let schema = temporal_schema();
    assert_eq!(
        schema.tables[0].tombstoned_hlc_column(),
        Some("tombstoned_hlc")
    );
}

#[test]
fn supports_as_of_filter_is_true() {
    let schema = temporal_schema();
    assert!(schema.tables[0].supports_as_of_filter());
}

#[test]
fn table_without_roles_does_not_support_as_of() {
    let schema = SchemaDeclaration::new(
        "PlainKit",
        1,
        vec![TableDeclaration::new(
            "plain",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::hlc("some_hlc"),
            ],
            vec!["id".to_string()],
        )],
    );
    assert!(!schema.tables[0].supports_as_of_filter());
    assert_eq!(schema.tables[0].created_hlc_column(), None);
}

#[test]
fn created_hlc_convenience_is_not_nullable() {
    let col = ColumnDeclaration::created_hlc("c");
    assert_eq!(col.role, Some(ColumnRole::CreatedHlc));
    assert!(!col.nullable);
}

#[test]
fn tombstoned_hlc_convenience_is_nullable() {
    let col = ColumnDeclaration::tombstoned_hlc("t");
    assert_eq!(col.role, Some(ColumnRole::TombstonedHlc));
    assert!(col.nullable);
}

// ── Temporal filter conformance ─────────────────────────────────

#[test]
fn temporal_filter_includes_row_created_before_t() {
    let s = make_temporal_storage();
    let rs = s.row_store();
    let id = Uuid::new_v4();
    rs.insert("nodes", node_row(id, "visible", HLC::new(100, 0, 1)))
        .expect("insert");

    let all = rs.query("nodes", None, &[], None, None).expect("query");
    let schema = temporal_schema();
    let at = HLC::new(200, 0, 1);
    let filtered = filter_as_of(&all, &at, &schema.tables[0]);
    assert_eq!(filtered.len(), 1);
    assert_eq!(
        filtered[0].get("payload"),
        Some(&TypedValue::Text("visible".into()))
    );
}

#[test]
fn temporal_filter_excludes_row_created_after_t() {
    let s = make_temporal_storage();
    let rs = s.row_store();
    rs.insert("nodes", node_row(Uuid::new_v4(), "future", HLC::new(300, 0, 1)))
        .expect("insert");

    let all = rs.query("nodes", None, &[], None, None).expect("query");
    let schema = temporal_schema();
    let at = HLC::new(200, 0, 1);
    let filtered = filter_as_of(&all, &at, &schema.tables[0]);
    assert!(filtered.is_empty());
}

#[test]
fn temporal_filter_excludes_tombstoned_row_before_t() {
    let s = make_temporal_storage();
    let rs = s.row_store();
    rs.insert(
        "nodes",
        node_row_tombstoned(Uuid::new_v4(), "deleted", HLC::new(100, 0, 1), HLC::new(150, 0, 1)),
    )
    .expect("insert");

    let all = rs.query("nodes", None, &[], None, None).expect("query");
    let schema = temporal_schema();
    let at = HLC::new(200, 0, 1);
    let filtered = filter_as_of(&all, &at, &schema.tables[0]);
    assert!(filtered.is_empty());
}

#[test]
fn temporal_filter_includes_row_not_yet_tombstoned_at_t() {
    let s = make_temporal_storage();
    let rs = s.row_store();
    rs.insert(
        "nodes",
        node_row_tombstoned(
            Uuid::new_v4(),
            "alive-at-200",
            HLC::new(100, 0, 1),
            HLC::new(300, 0, 1),
        ),
    )
    .expect("insert");

    let all = rs.query("nodes", None, &[], None, None).expect("query");
    let schema = temporal_schema();
    let at = HLC::new(200, 0, 1);
    let filtered = filter_as_of(&all, &at, &schema.tables[0]);
    assert_eq!(filtered.len(), 1);
    assert_eq!(
        filtered[0].get("payload"),
        Some(&TypedValue::Text("alive-at-200".into()))
    );
}

#[test]
fn temporal_filter_multiple_rows_correct_slice() {
    let s = make_temporal_storage();
    let rs = s.row_store();

    // Row A: created=100, no tombstone → visible at T=250
    rs.insert("nodes", node_row(Uuid::new_v4(), "A-live", HLC::new(100, 0, 1)))
        .expect("insert A");

    // Row B: created=100, tombstoned=200 → NOT visible at T=250
    rs.insert(
        "nodes",
        node_row_tombstoned(Uuid::new_v4(), "B-dead", HLC::new(100, 0, 1), HLC::new(200, 0, 1)),
    )
    .expect("insert B");

    // Row C: created=300, no tombstone → NOT visible at T=250
    rs.insert("nodes", node_row(Uuid::new_v4(), "C-future", HLC::new(300, 0, 1)))
        .expect("insert C");

    let all = rs.query("nodes", None, &[], None, None).expect("query");
    assert_eq!(all.len(), 3);

    let schema = temporal_schema();
    let at = HLC::new(250, 0, 1);
    let filtered = filter_as_of(&all, &at, &schema.tables[0]);
    assert_eq!(filtered.len(), 1);
    assert_eq!(
        filtered[0].get("payload"),
        Some(&TypedValue::Text("A-live".into()))
    );
}
