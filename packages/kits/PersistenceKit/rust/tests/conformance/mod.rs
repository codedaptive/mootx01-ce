// Backend-agnostic conformance suite — the Rust port of Swift's
// Tests/PersistenceKitConformance/ConformanceRunner.swift. Every backend
// produces identical observable results for the same fixture sequence.
//
// Each backend test target supplies a factory `Fn() -> Box<dyn Storage>`
// (a fresh, unopened storage) and calls `run_all(name, factory)`.
//
// Scope note: the Swift runner has nine groups. Two are intentionally
// omitted here:
//   - vector  — VectorIndex (sqlite-vec) is deferred to a follow-on; the
//               Rust backends ship a placeholder VectorIndex in Phase 1.
//   - transaction — the Rust `Storage` trait has no `transaction` method
//               (pre-existing gap vs. Swift), so there is nothing to drive.
// The remaining seven groups (schema, row, predicate, blob, audit,
// generated-column, append-only) are the Phase-1 parity gate.

#![allow(dead_code)] // each backend test binary uses a subset of helpers

use std::collections::BTreeMap;
use persistence_kit::{
    AuditEvent, Column, ColumnDeclaration, ColumnType, DistanceMetric, GeneratedColumn,
    GeneratedExpression, IndexDeclaration, OrderClause, OrderDirection, SchemaDeclaration, Storage,
    StorageError, StoragePredicate, TableDeclaration, TypedValue,
};
use substrate_types::hlc::HLC;
use uuid::Uuid;

pub type Factory = Box<dyn Fn() -> Box<dyn Storage>>;

fn test_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "ConformanceTestKit",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::bitmap("flags"),
                ColumnDeclaration::text("name"),
                ColumnDeclaration::int("count"),
                ColumnDeclaration::timestamp("created"),
                ColumnDeclaration::bool_col("active").nullable(),
                ColumnDeclaration::float("score").nullable(),
            ],
            vec!["id".to_string()],
        )],
    )
}

fn generated_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "ConformanceGeneratedKit",
        1,
        vec![TableDeclaration::new(
            "gen_items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::bitmap("flags"),
                ColumnDeclaration::text("name"),
            ],
            vec!["id".to_string()],
        )
        .with_generated_columns(vec![
            GeneratedColumn::new(
                "low_nibble",
                ColumnType::Int,
                GeneratedExpression::BitAnd(
                    Box::new(GeneratedExpression::Column("flags".into())),
                    Box::new(GeneratedExpression::Literal(0x0F)),
                ),
            ),
            GeneratedColumn::new(
                "high_nibble",
                ColumnType::Int,
                GeneratedExpression::BitAnd(
                    Box::new(GeneratedExpression::ShiftRight(
                        Box::new(GeneratedExpression::Column("flags".into())),
                        4,
                    )),
                    Box::new(GeneratedExpression::Literal(0x0F)),
                ),
            ),
            GeneratedColumn::new(
                "has_bit7",
                ColumnType::Bool,
                GeneratedExpression::NotEqual(
                    Box::new(GeneratedExpression::BitAnd(
                        Box::new(GeneratedExpression::Column("flags".into())),
                        Box::new(GeneratedExpression::Literal(0x80)),
                    )),
                    Box::new(GeneratedExpression::Literal(0)),
                ),
            ),
        ])],
    )
    .with_indices(vec![IndexDeclaration::new(
        "idx_gen_low",
        "gen_items",
        vec!["low_nibble".to_string()],
    )])
}

fn append_only_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "ConformanceAppendOnlyKit",
        1,
        vec![TableDeclaration::new(
            "ledger",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("entry"),
                ColumnDeclaration::int("amount"),
            ],
            vec!["id".to_string()],
        )
        .append_only()],
    )
}

/// Run every Phase-1 conformance group against a backend. Panics (fails
/// the test) on the first mismatch, tagging the backend name.
pub fn run_all(backend: &str, factory: &Factory) {
    schema_fixtures(backend, factory);
    row_fixtures(backend, factory);
    predicate_fixtures(backend, factory);
    blob_fixtures(backend, factory);
    audit_fixtures(backend, factory);
    generated_column_fixtures(backend, factory);
    append_only_fixtures(backend, factory);
}

/// Vector fixtures — separate from run_all (not every backend ships
/// VectorIndex yet). Backends that do (InMemory, Postgres+pgvector) call it
/// explicitly. Mirrors the Swift vectorFixtures group.
pub fn vector_fixtures(backend: &str, factory: &Factory) {
    let storage = factory();
    storage.open(&test_schema()).expect("open");
    let idx = storage.vector_index();

    let k1 = Uuid::new_v4();
    let k2 = Uuid::new_v4();
    let k3 = Uuid::new_v4();
    let k4 = Uuid::new_v4();
    idx.add(k1, &[1.0, 0.0, 0.0], BTreeMap::new()).unwrap();
    idx.add(k2, &[0.0, 1.0, 0.0], BTreeMap::new()).unwrap();
    idx.add(k3, &[0.95, 0.05, 0.0], BTreeMap::new()).unwrap();
    idx.add(k4, &[0.0, 0.0, 1.0], BTreeMap::new()).unwrap();

    assert_eq!(idx.count().unwrap(), 4, "{backend}: vector count");

    let top = idx.knn(&[1.0, 0.0, 0.0], 2, DistanceMetric::L2, None, None).unwrap();
    assert_eq!(top.len(), 2, "{backend}: kNN returns k results");
    assert_eq!(top[0].key, k1, "{backend}: exact match first");
    assert_eq!(top[1].key, k3, "{backend}: near match second");

    idx.delete(k1).unwrap();
    assert_eq!(idx.count().unwrap(), 3, "{backend}: count after delete");

    storage.close().unwrap();
}

fn schema_fixtures(backend: &str, factory: &Factory) {
    let storage = factory();
    storage.open(&test_schema()).expect("open");
    assert_eq!(
        storage.current_schema_version().unwrap(),
        1,
        "{backend}: schema version after open"
    );
    storage.close().unwrap();
}

fn row_fixtures(backend: &str, factory: &Factory) {
    let storage = factory();
    storage.open(&test_schema()).expect("open");
    let rows = storage.row_store();

    for i in 0..10i64 {
        let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
        row.insert("id".into(), TypedValue::Uuid(Uuid::new_v4()));
        row.insert("flags".into(), TypedValue::Bitmap(i & 0x0F));
        row.insert("name".into(), TypedValue::Text(format!("item-{i}")));
        row.insert("count".into(), TypedValue::Int(i * 10));
        row.insert("created".into(), TypedValue::Timestamp(1_700_000_000 + i));
        row.insert("active".into(), TypedValue::Bool(i % 2 == 0));
        row.insert("score".into(), TypedValue::Float(i as f64 * 1.5));
        rows.insert("items", row).unwrap();
    }

    assert_eq!(rows.count("items", None).unwrap(), 10, "{backend}: count after 10 inserts");

    let active = rows
        .count(
            "items",
            Some(&StoragePredicate::Eq(Column::new("items", "active"), TypedValue::Bool(true))),
        )
        .unwrap();
    assert_eq!(active, 5, "{backend}: active=true count");

    let ordered = rows
        .query(
            "items",
            None,
            &[OrderClause::new(Column::new("items", "count"), OrderDirection::Ascending)],
            Some(3),
            None,
        )
        .unwrap();
    assert_eq!(ordered.len(), 3, "{backend}: limit honored");
    assert_eq!(ordered[0].get("count"), Some(&TypedValue::Int(0)), "{backend}: ascending order");
    assert_eq!(ordered[2].get("count"), Some(&TypedValue::Int(20)), "{backend}: ascending tail");

    storage.close().unwrap();
}

fn predicate_fixtures(backend: &str, factory: &Factory) {
    let storage = factory();
    storage.open(&test_schema()).expect("open");
    let rows = storage.row_store();

    for bits in [0x01i64, 0x03, 0x07, 0x0F, 0x10, 0x80] {
        let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
        row.insert("id".into(), TypedValue::Uuid(Uuid::new_v4()));
        row.insert("flags".into(), TypedValue::Bitmap(bits));
        row.insert("name".into(), TypedValue::Text(format!("bits_{bits}")));
        row.insert("count".into(), TypedValue::Int(bits));
        row.insert("created".into(), TypedValue::Timestamp(1_700_000_000));
        rows.insert("items", row).unwrap();
    }

    let col = Column::new("items", "flags");
    let count_col = Column::new("items", "count");
    let c = |p: StoragePredicate| rows.count("items", Some(&p)).unwrap();

    assert_eq!(c(StoragePredicate::BitmaskAll { column: col.clone(), mask: 0x01 }), 4, "{backend}: bitmaskAll 0x01");
    assert_eq!(c(StoragePredicate::BitmaskAll { column: col.clone(), mask: 0x07 }), 2, "{backend}: bitmaskAll 0x07");
    assert_eq!(c(StoragePredicate::BitmaskAny { column: col.clone(), mask: 0x90 }), 2, "{backend}: bitmaskAny 0x90");
    assert_eq!(c(StoragePredicate::BitmaskNone { column: col.clone(), mask: 0xF0 }), 4, "{backend}: bitmaskNone 0xF0");
    assert_eq!(c(StoragePredicate::BitwiseEq { column: col.clone(), expected: 0x03, mask: 0x0F }), 1, "{backend}: bitwiseEq 0x03");

    assert_eq!(
        c(StoragePredicate::And(vec![
            StoragePredicate::BitmaskAll { column: col.clone(), mask: 0x01 },
            StoragePredicate::BitmaskNone { column: col.clone(), mask: 0xF0 },
        ])),
        4,
        "{backend}: AND combination"
    );
    assert_eq!(
        c(StoragePredicate::Or(vec![
            StoragePredicate::Eq(col.clone(), TypedValue::Bitmap(0x10)),
            StoragePredicate::Eq(col.clone(), TypedValue::Bitmap(0x80)),
        ])),
        2,
        "{backend}: OR combination"
    );
    assert_eq!(
        c(StoragePredicate::Not(Box::new(StoragePredicate::BitmaskAll { column: col.clone(), mask: 0x01 }))),
        2,
        "{backend}: NOT combination"
    );
    assert_eq!(c(StoragePredicate::Gt(count_col, TypedValue::Int(10))), 3, "{backend}: count > 10");
    assert_eq!(
        c(StoragePredicate::In(col, vec![TypedValue::Bitmap(0x01), TypedValue::Bitmap(0x80)])),
        2,
        "{backend}: IN"
    );

    storage.close().unwrap();
}

fn blob_fixtures(backend: &str, factory: &Factory) {
    let storage = factory();
    storage.open(&test_schema()).expect("open");
    let blobs = storage.blob_store();

    let payload: Vec<u8> = vec![0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE];
    blobs.put("test/binary", &payload).unwrap();
    assert_eq!(blobs.get("test/binary").unwrap(), Some(payload), "{backend}: blob round-trip");
    assert!(blobs.exists("test/binary").unwrap(), "{backend}: blob exists after put");
    assert_eq!(blobs.size("test/binary").unwrap(), Some(8), "{backend}: blob size");
    blobs.delete("test/binary").unwrap();
    assert!(!blobs.exists("test/binary").unwrap(), "{backend}: blob gone after delete");
    assert_eq!(blobs.get("nonexistent").unwrap(), None, "{backend}: missing blob returns None");

    storage.close().unwrap();
}

fn audit_fixtures(backend: &str, factory: &Factory) {
    let storage = factory();
    storage.open(&test_schema()).expect("open");
    let log = storage.audit_log();

    let estate = Uuid::new_v4();
    let row_a = Uuid::new_v4();
    let row_b = Uuid::new_v4();

    let mut events = Vec::new();
    for i in 0..5i64 {
        let row_id = if i % 2 == 0 { row_a } else { row_b };
        events.push(AuditEvent {
            event_id: Uuid::new_v4(),
            estate_uuid: estate,
            row_id,
            hlc: HLC { physical_time: 1_700_000_000 + i, logical_count: 0, node_id: 1 },
            verb: "capture".into(),
            before_adjective: None,
            before_operational: None,
            before_provenance: None,
            after_adjective: i,
            after_operational: 0,
            after_provenance: 0,
            before_lattice_anchor: None,
            after_lattice_anchor: 0,
            actor: "test".into(),
        });
    }

    log.append_batch(events.clone()).unwrap();
    assert_eq!(log.count().unwrap(), 5, "{backend}: audit count after batch");

    // Idempotence on (event_id, hlc).
    log.append_batch(events).unwrap();
    assert_eq!(log.count().unwrap(), 5, "{backend}: audit idempotent on (event_id, hlc)");

    let row_a_events = log.events_for_row(row_a).unwrap();
    assert_eq!(row_a_events.len(), 3, "{backend}: rowA has 3 events (i=0,2,4)");
    for w in row_a_events.windows(2) {
        assert!(w[0].hlc.physical_time < w[1].hlc.physical_time, "{backend}: events ordered by HLC");
    }

    let mid = HLC { physical_time: 1_700_000_002, logical_count: 0, node_id: 1 };
    let after = log.iterate(Some(mid), None, 100).unwrap();
    assert_eq!(after.len(), 2, "{backend}: iterate after HLC=2 → events 3,4");

    storage.close().unwrap();
}

fn generated_column_fixtures(backend: &str, factory: &Factory) {
    let storage = factory();
    storage.open(&generated_schema()).expect("open");
    let rows = storage.row_store();

    let gen_row = |id: Uuid, flags: i64, name: &str| {
        let mut m = BTreeMap::new();
        m.insert("id".to_string(), TypedValue::Uuid(id));
        m.insert("flags".to_string(), TypedValue::Bitmap(flags));
        m.insert("name".to_string(), TypedValue::Text(name.into()));
        m
    };
    let by_id = |id: Uuid| StoragePredicate::Eq(Column::new("gen_items", "id"), TypedValue::Uuid(id));

    let id_a = Uuid::new_v4(); // 0xA5 = 1010_0101: low=0x5, high=0xA, bit7 set
    let id_b = Uuid::new_v4(); // 0x42 = 0100_0010: low=0x2, high=0x4, bit7 clear
    rows.insert("gen_items", gen_row(id_a, 0xA5, "a")).unwrap();
    rows.insert("gen_items", gen_row(id_b, 0x42, "b")).unwrap();

    let rows_a = rows.query("gen_items", Some(&by_id(id_a)), &[], None, None).unwrap();
    assert_eq!(rows_a.len(), 1, "{backend}: generated row A present");
    assert_eq!(rows_a[0].get("low_nibble"), Some(&TypedValue::Int(0x5)), "{backend}: low_nibble of 0xA5");
    assert_eq!(rows_a[0].get("high_nibble"), Some(&TypedValue::Int(0xA)), "{backend}: high_nibble of 0xA5");
    assert_eq!(rows_a[0].get("has_bit7"), Some(&TypedValue::Bool(true)), "{backend}: has_bit7 of 0xA5");

    let rows_b = rows.query("gen_items", Some(&by_id(id_b)), &[], None, None).unwrap();
    assert_eq!(rows_b[0].get("low_nibble"), Some(&TypedValue::Int(0x2)), "{backend}: low_nibble of 0x42");
    assert_eq!(rows_b[0].get("has_bit7"), Some(&TypedValue::Bool(false)), "{backend}: has_bit7 of 0x42");

    let low_is_five = rows
        .count("gen_items", Some(&StoragePredicate::Eq(Column::new("gen_items", "low_nibble"), TypedValue::Int(0x5))))
        .unwrap();
    assert_eq!(low_is_five, 1, "{backend}: filter on generated column");

    // Updating the source column recomputes the generated value.
    let mut upd = BTreeMap::new();
    upd.insert("flags".to_string(), TypedValue::Bitmap(0x0F));
    rows.update("gen_items", upd, &by_id(id_b)).unwrap();
    let rows_b2 = rows.query("gen_items", Some(&by_id(id_b)), &[], None, None).unwrap();
    assert_eq!(rows_b2[0].get("low_nibble"), Some(&TypedValue::Int(0xF)), "{backend}: generated recomputed on update");
    assert_eq!(rows_b2[0].get("has_bit7"), Some(&TypedValue::Bool(false)), "{backend}: bit7 clear after 0x0F");

    storage.close().unwrap();
}

fn append_only_fixtures(backend: &str, factory: &Factory) {
    let storage = factory();
    storage.open(&append_only_schema()).expect("open");
    let rows = storage.row_store();

    let ledger_row = |id: Uuid, entry: &str, amount: i64| {
        let mut m = BTreeMap::new();
        m.insert("id".to_string(), TypedValue::Uuid(id));
        m.insert("entry".to_string(), TypedValue::Text(entry.into()));
        m.insert("amount".to_string(), TypedValue::Int(amount));
        m
    };
    let by_id = |id: Uuid| StoragePredicate::Eq(Column::new("ledger", "id"), TypedValue::Uuid(id));

    let id1 = Uuid::new_v4();
    let id2 = Uuid::new_v4();
    rows.insert("ledger", ledger_row(id1, "first", 100)).unwrap();
    rows.insert("ledger", ledger_row(id2, "second", 200)).unwrap();

    let mut upd = BTreeMap::new();
    upd.insert("amount".to_string(), TypedValue::Int(999));
    assert!(
        matches!(rows.update("ledger", upd, &by_id(id1)), Err(StorageError::AppendOnlyViolation { .. })),
        "{backend}: UPDATE rejected on append-only table"
    );
    assert!(
        matches!(rows.delete("ledger", &by_id(id1)), Err(StorageError::AppendOnlyViolation { .. })),
        "{backend}: DELETE rejected on append-only table"
    );

    assert_eq!(rows.count("ledger", None).unwrap(), 2, "{backend}: append-only rows intact");
    let first = rows.query("ledger", Some(&by_id(id1)), &[], None, None).unwrap();
    assert_eq!(first[0].get("amount"), Some(&TypedValue::Int(100)), "{backend}: original value unchanged");

    storage.close().unwrap();
}
