// Backend-agnostic conformance suite — the Rust version of Swift's
// Tests/PersistenceKitConformance/ConformanceRunner.swift. Every backend
// produces identical observable results for the same fixture sequence.
//
// Each backend test target supplies a factory `Fn() -> Box<dyn Storage>`
// (a fresh, unopened storage) and calls `run_all(name, factory)`.
//
// Scope note: the Swift runner has nine groups. `run_all` drives the eight
// backend-universal groups (schema, row, predicate, blob, audit,
// generated-column, append-only, transaction). The ninth — vector — is
// exposed separately via `vector_fixtures`. PersistenceKit owns no k-NN
// engine (ADR-008); `vector_fixtures` asserts the storage-ACCOMMODATION
// contract — every backend round-trips, bulk-hydrates, counts, and deletes
// vector-payload rows through the general RowStore surface.

#![allow(dead_code)] // each backend test binary uses a subset of helpers

use persistence_kit::{
    AuditEvent, Column, ColumnDeclaration, ColumnType, GeneratedColumn,
    GeneratedExpression, IndexDeclaration, IsolationLevel, Migration, OrderClause, OrderDirection,
    SchemaDeclaration, SchemaOperation, Storage, StorageError, StoragePredicate, TableDeclaration,
    TypedValue,
};
use std::collections::BTreeMap;
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
    fresh_open_add_column_idempotent_fixtures(backend, factory);
    row_fixtures(backend, factory);
    predicate_fixtures(backend, factory);
    blob_fixtures(backend, factory);
    audit_fixtures(backend, factory);
    generated_column_fixtures(backend, factory);
    append_only_fixtures(backend, factory);
    transaction_fixtures(backend, factory);
}

/// Transaction fixtures — a committed block persists its writes; a block that
/// returns `Err` rolls back, leaving the store untouched. Mirrors the Swift
/// transaction group's commit/rollback assertions. The block drives its
/// mutations through the `StorageTransaction` sub-stores (same session as the
/// open BEGIN…COMMIT bracket).
fn transaction_fixtures(backend: &str, factory: &Factory) {
    let storage = factory();
    storage.open(&test_schema()).expect("open");

    fn make_row(name: &str) -> BTreeMap<String, TypedValue> {
        let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
        row.insert("id".into(), TypedValue::Uuid(Uuid::new_v4()));
        row.insert("flags".into(), TypedValue::Bitmap(0));
        row.insert("name".into(), TypedValue::Text(name.into()));
        row.insert("count".into(), TypedValue::Int(1));
        row.insert("created".into(), TypedValue::Timestamp(1_700_000_000));
        row
    }

    // A committed transaction persists every write in the block.
    storage
        .transaction(IsolationLevel::Serializable, &mut |tx| {
            let rows = tx.row_store();
            rows.insert("items", make_row("committed-a"))?;
            rows.insert("items", make_row("committed-b"))?;
            Ok(())
        })
        .expect("commit");
    assert_eq!(
        storage.row_store().count("items", None).unwrap(),
        2,
        "{backend}: committed writes persist"
    );

    // A transaction whose block returns Err rolls back: its writes vanish and
    // the error propagates to the caller.
    let result = storage.transaction(IsolationLevel::Serializable, &mut |tx| {
        let rows = tx.row_store();
        rows.insert("items", make_row("rolled-back"))?;
        Err(StorageError::BackendError {
            underlying: "intentional rollback".into(),
        })
    });
    assert!(
        result.is_err(),
        "{backend}: rollback propagates the block error"
    );
    assert_eq!(
        storage.row_store().count("items", None).unwrap(),
        2,
        "{backend}: rolled-back writes are discarded"
    );

    storage.close().unwrap();
}

/// Schema mirroring how VectorKit stores embeddings on a backend: a keyed row
/// with an opaque binary vector payload (`payload_binary`, e.g. a 32-byte
/// packed Engram/fingerprint) and a float32 payload (`payload_float32`, e.g. a
/// 384-d MiniLM embedding serialized to bytes). Plain BLOB columns —
/// PersistenceKit owns no vector engine.
fn vector_accommodation_schema() -> SchemaDeclaration {
    SchemaDeclaration::new(
        "ConformanceVectorAccommodationKit",
        1,
        vec![TableDeclaration::new(
            "vector_rows",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::blob("payload_binary"),
                ColumnDeclaration::blob("payload_float32"),
                ColumnDeclaration::text("model_id"),
                ColumnDeclaration::int("dim"),
            ],
            vec!["id".to_string()],
        )],
    )
}

/// Vector-storage accommodation guarantee (ADR-008). PersistenceKit owns no
/// k-NN engine; dense-embedding search lives in VectorKit. Every backend MUST
/// accommodate a vector workload's STORAGE needs through RowStore:
///   1. vector-payload row round-trip — 32-byte binary + 384-d float32 survive
///      insert→query byte-for-byte;
///   2. bulk hydration at scale — ≥1k vector rows load back fully;
///   3. count and delete over those rows.
/// Mirrors the Swift vectorFixtures group.
pub fn vector_fixtures(backend: &str, factory: &Factory) {
    let storage = factory();
    storage.open(&vector_accommodation_schema()).expect("open");
    let rows = storage.row_store();

    // (1) Vector-payload row round-trip.
    let binary_payload: Vec<u8> = (0..32u8).collect();
    let floats: Vec<f32> = (0..384).map(|i| i as f32 * 0.001 - 0.19).collect();
    let mut float_bytes: Vec<u8> = Vec::with_capacity(384 * 4);
    for f in &floats {
        float_bytes.extend_from_slice(&f.to_le_bytes());
    }

    let round_trip_id = Uuid::new_v4();
    let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
    row.insert("id".into(), TypedValue::Uuid(round_trip_id));
    row.insert("payload_binary".into(), TypedValue::Blob(binary_payload.clone()));
    row.insert("payload_float32".into(), TypedValue::Blob(float_bytes.clone()));
    row.insert("model_id".into(), TypedValue::Text("MiniLM-L6-v2".into()));
    row.insert("dim".into(), TypedValue::Int(384));
    rows.insert("vector_rows", row).unwrap();

    let fetched = rows
        .query(
            "vector_rows",
            Some(&StoragePredicate::Eq(
                Column::new("vector_rows", "id"),
                TypedValue::Uuid(round_trip_id),
            )),
            &[],
            None,
            None,
        )
        .unwrap();
    assert_eq!(fetched.len(), 1, "{backend}: vector-payload row present");
    assert_eq!(
        fetched[0].get("payload_binary"),
        Some(&TypedValue::Blob(binary_payload)),
        "{backend}: 32-byte binary vector payload round-trips byte-for-byte"
    );
    assert_eq!(
        fetched[0].get("payload_float32"),
        Some(&TypedValue::Blob(float_bytes.clone())),
        "{backend}: 384-d float32 vector payload round-trips byte-for-byte"
    );
    assert_eq!(
        fetched[0].get("dim"),
        Some(&TypedValue::Int(384)),
        "{backend}: vector dimensionality preserved"
    );

    // (2) Bulk hydration at scale: ≥1k vector rows load back fully.
    let bulk_count = 1_000usize;
    for i in 0..bulk_count {
        let payload: Vec<u8> = (0..32u8).map(|b| ((i + b as usize) & 0xFF) as u8).collect();
        let mut r: BTreeMap<String, TypedValue> = BTreeMap::new();
        r.insert("id".into(), TypedValue::Uuid(Uuid::new_v4()));
        r.insert("payload_binary".into(), TypedValue::Blob(payload));
        r.insert("payload_float32".into(), TypedValue::Blob(float_bytes.clone()));
        r.insert("model_id".into(), TypedValue::Text("MiniLM-L6-v2".into()));
        r.insert("dim".into(), TypedValue::Int(384));
        rows.insert("vector_rows", r).unwrap();
    }

    let hydrated = rows.query("vector_rows", None, &[], None, None).unwrap();
    assert_eq!(
        hydrated.len(),
        bulk_count + 1,
        "{backend}: bulk hydration returns all {} vector rows",
        bulk_count + 1
    );
    let widths_ok = hydrated.iter().all(|row| {
        matches!(row.get("payload_binary"), Some(TypedValue::Blob(b)) if b.len() == 32)
            && matches!(row.get("payload_float32"), Some(TypedValue::Blob(f)) if f.len() == 384 * 4)
    });
    assert!(
        widths_ok,
        "{backend}: every hydrated vector row preserves payload widths"
    );

    // (3) Count and delete.
    assert_eq!(
        rows.count("vector_rows", None).unwrap(),
        bulk_count + 1,
        "{backend}: vector-row count"
    );
    rows.delete(
        "vector_rows",
        &StoragePredicate::Eq(
            Column::new("vector_rows", "id"),
            TypedValue::Uuid(round_trip_id),
        ),
    )
    .unwrap();
    assert_eq!(
        rows.count("vector_rows", None).unwrap(),
        bulk_count,
        "{backend}: vector-row count after delete"
    );

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

/// Opening a FRESH store directly at a schema whose latest table already declares
/// the column an addColumn migration adds must succeed on every backend. The
/// emitter must treat addColumn idempotently (ADD COLUMN IF NOT EXISTS semantics),
/// mirroring CREATE TABLE IF NOT EXISTS. On SQLite the migration ops are not
/// replayed (tables are created at the latest schema), so the column is present
/// from the create; on InMemory the ops ARE replayed, so the addColumn must skip
/// the already-present column. Mirrors Swift `freshOpenAddColumnIdempotentFixtures`.
fn fresh_open_add_column_idempotent_fixtures(backend: &str, factory: &Factory) {
    let storage = factory();
    let schema_v2 = SchemaDeclaration::new(
        "ConformanceFreshAddColumn",
        2,
        vec![TableDeclaration::new(
            "fresh_items",
            // Latest schema already carries the column the migration adds.
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("name"),
                ColumnDeclaration::text("note").nullable(),
            ],
            vec!["id".to_string()],
        )],
    )
    .with_migrations(vec![Migration {
        from_version: 1,
        to_version: 2,
        operations: vec![SchemaOperation::AddColumn {
            table: "fresh_items".to_string(),
            column: ColumnDeclaration::text("note").nullable(),
        }],
    }]);
    // Direct open on a brand-new store — must succeed, not throw "duplicate column".
    storage.open(&schema_v2).expect("fresh open with addColumn migration must succeed");
    assert_eq!(
        storage.current_schema_version_for("ConformanceFreshAddColumn").unwrap(),
        2,
        "{backend}: fresh open with addColumn migration reaches version 2"
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

    assert_eq!(
        rows.count("items", None).unwrap(),
        10,
        "{backend}: count after 10 inserts"
    );

    let active = rows
        .count(
            "items",
            Some(&StoragePredicate::Eq(
                Column::new("items", "active"),
                TypedValue::Bool(true),
            )),
        )
        .unwrap();
    assert_eq!(active, 5, "{backend}: active=true count");

    let ordered = rows
        .query(
            "items",
            None,
            &[OrderClause::new(
                Column::new("items", "count"),
                OrderDirection::Ascending,
            )],
            Some(3),
            None,
        )
        .unwrap();
    assert_eq!(ordered.len(), 3, "{backend}: limit honored");
    assert_eq!(
        ordered[0].get("count"),
        Some(&TypedValue::Int(0)),
        "{backend}: ascending order"
    );
    assert_eq!(
        ordered[2].get("count"),
        Some(&TypedValue::Int(20)),
        "{backend}: ascending tail"
    );

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

    assert_eq!(
        c(StoragePredicate::BitmaskAll {
            column: col.clone(),
            mask: 0x01
        }),
        4,
        "{backend}: bitmaskAll 0x01"
    );
    assert_eq!(
        c(StoragePredicate::BitmaskAll {
            column: col.clone(),
            mask: 0x07
        }),
        2,
        "{backend}: bitmaskAll 0x07"
    );
    assert_eq!(
        c(StoragePredicate::BitmaskAny {
            column: col.clone(),
            mask: 0x90
        }),
        2,
        "{backend}: bitmaskAny 0x90"
    );
    assert_eq!(
        c(StoragePredicate::BitmaskNone {
            column: col.clone(),
            mask: 0xF0
        }),
        4,
        "{backend}: bitmaskNone 0xF0"
    );
    assert_eq!(
        c(StoragePredicate::BitwiseEq {
            column: col.clone(),
            expected: 0x03,
            mask: 0x0F
        }),
        1,
        "{backend}: bitwiseEq 0x03"
    );

    assert_eq!(
        c(StoragePredicate::And(vec![
            StoragePredicate::BitmaskAll {
                column: col.clone(),
                mask: 0x01
            },
            StoragePredicate::BitmaskNone {
                column: col.clone(),
                mask: 0xF0
            },
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
        c(StoragePredicate::Not(Box::new(
            StoragePredicate::BitmaskAll {
                column: col.clone(),
                mask: 0x01
            }
        ))),
        2,
        "{backend}: NOT combination"
    );
    assert_eq!(
        c(StoragePredicate::Gt(count_col, TypedValue::Int(10))),
        3,
        "{backend}: count > 10"
    );
    assert_eq!(
        c(StoragePredicate::In(
            col,
            vec![TypedValue::Bitmap(0x01), TypedValue::Bitmap(0x80)]
        )),
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
    assert_eq!(
        blobs.get("test/binary").unwrap(),
        Some(payload),
        "{backend}: blob round-trip"
    );
    assert!(
        blobs.exists("test/binary").unwrap(),
        "{backend}: blob exists after put"
    );
    assert_eq!(
        blobs.size("test/binary").unwrap(),
        Some(8),
        "{backend}: blob size"
    );
    blobs.delete("test/binary").unwrap();
    assert!(
        !blobs.exists("test/binary").unwrap(),
        "{backend}: blob gone after delete"
    );
    assert_eq!(
        blobs.get("nonexistent").unwrap(),
        None,
        "{backend}: missing blob returns None"
    );

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
            hlc: HLC {
                physical_time: 1_700_000_000 + i,
                logical_count: 0,
                node_id: 1,
            },
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
            reason: None,
        });
    }

    log.append_batch(events.clone()).unwrap();
    assert_eq!(
        log.count().unwrap(),
        5,
        "{backend}: audit count after batch"
    );

    // Idempotence on (event_id, hlc).
    log.append_batch(events).unwrap();
    assert_eq!(
        log.count().unwrap(),
        5,
        "{backend}: audit idempotent on (event_id, hlc)"
    );

    let row_a_events = log.events_for_row(row_a).unwrap();
    assert_eq!(
        row_a_events.len(),
        3,
        "{backend}: rowA has 3 events (i=0,2,4)"
    );
    for w in row_a_events.windows(2) {
        assert!(
            w[0].hlc.physical_time < w[1].hlc.physical_time,
            "{backend}: events ordered by HLC"
        );
    }

    let mid = HLC {
        physical_time: 1_700_000_002,
        logical_count: 0,
        node_id: 1,
    };
    let after = log.iterate(Some(mid), None, 100).unwrap();
    assert_eq!(
        after.len(),
        2,
        "{backend}: iterate after HLC=2 → events 3,4"
    );

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
    let by_id =
        |id: Uuid| StoragePredicate::Eq(Column::new("gen_items", "id"), TypedValue::Uuid(id));

    let id_a = Uuid::new_v4(); // 0xA5 = 1010_0101: low=0x5, high=0xA, bit7 set
    let id_b = Uuid::new_v4(); // 0x42 = 0100_0010: low=0x2, high=0x4, bit7 clear
    rows.insert("gen_items", gen_row(id_a, 0xA5, "a")).unwrap();
    rows.insert("gen_items", gen_row(id_b, 0x42, "b")).unwrap();

    let rows_a = rows
        .query("gen_items", Some(&by_id(id_a)), &[], None, None)
        .unwrap();
    assert_eq!(rows_a.len(), 1, "{backend}: generated row A present");
    assert_eq!(
        rows_a[0].get("low_nibble"),
        Some(&TypedValue::Int(0x5)),
        "{backend}: low_nibble of 0xA5"
    );
    assert_eq!(
        rows_a[0].get("high_nibble"),
        Some(&TypedValue::Int(0xA)),
        "{backend}: high_nibble of 0xA5"
    );
    assert_eq!(
        rows_a[0].get("has_bit7"),
        Some(&TypedValue::Bool(true)),
        "{backend}: has_bit7 of 0xA5"
    );

    let rows_b = rows
        .query("gen_items", Some(&by_id(id_b)), &[], None, None)
        .unwrap();
    assert_eq!(
        rows_b[0].get("low_nibble"),
        Some(&TypedValue::Int(0x2)),
        "{backend}: low_nibble of 0x42"
    );
    assert_eq!(
        rows_b[0].get("has_bit7"),
        Some(&TypedValue::Bool(false)),
        "{backend}: has_bit7 of 0x42"
    );

    let low_is_five = rows
        .count(
            "gen_items",
            Some(&StoragePredicate::Eq(
                Column::new("gen_items", "low_nibble"),
                TypedValue::Int(0x5),
            )),
        )
        .unwrap();
    assert_eq!(low_is_five, 1, "{backend}: filter on generated column");

    // Updating the source column recomputes the generated value.
    let mut upd = BTreeMap::new();
    upd.insert("flags".to_string(), TypedValue::Bitmap(0x0F));
    rows.update("gen_items", upd, &by_id(id_b)).unwrap();
    let rows_b2 = rows
        .query("gen_items", Some(&by_id(id_b)), &[], None, None)
        .unwrap();
    assert_eq!(
        rows_b2[0].get("low_nibble"),
        Some(&TypedValue::Int(0xF)),
        "{backend}: generated recomputed on update"
    );
    assert_eq!(
        rows_b2[0].get("has_bit7"),
        Some(&TypedValue::Bool(false)),
        "{backend}: bit7 clear after 0x0F"
    );

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
    rows.insert("ledger", ledger_row(id1, "first", 100))
        .unwrap();
    rows.insert("ledger", ledger_row(id2, "second", 200))
        .unwrap();

    let mut upd = BTreeMap::new();
    upd.insert("amount".to_string(), TypedValue::Int(999));
    assert!(
        matches!(
            rows.update("ledger", upd, &by_id(id1)),
            Err(StorageError::AppendOnlyViolation { .. })
        ),
        "{backend}: UPDATE rejected on append-only table"
    );
    assert!(
        matches!(
            rows.delete("ledger", &by_id(id1)),
            Err(StorageError::AppendOnlyViolation { .. })
        ),
        "{backend}: DELETE rejected on append-only table"
    );

    assert_eq!(
        rows.count("ledger", None).unwrap(),
        2,
        "{backend}: append-only rows intact"
    );
    let first = rows
        .query("ledger", Some(&by_id(id1)), &[], None, None)
        .unwrap();
    assert_eq!(
        first[0].get("amount"),
        Some(&TypedValue::Int(100)),
        "{backend}: original value unchanged"
    );

    storage.close().unwrap();
}
