// In-memory backend tests for persistence-kit. Mirror of the Swift
// InMemoryStorage test surface: schema management, row CRUD,
// predicates, ordering, pagination, blob round-trip,
// audit log idempotence, observer notifications.

use persistence_kit::{
    inmemory::InMemoryStorage, AuditEvent, Column, ColumnDeclaration,
    IndexDeclaration, OrderClause, OrderDirection, SchemaDeclaration, Storage, StorageEvent,
    StoragePredicate, TableDeclaration, TypedValue,
};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::mpsc::TryRecvError;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::hlc::HLC;
use uuid::Uuid;

fn make_storage() -> InMemoryStorage {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    let schema = SchemaDeclaration::new(
        "test-kit",
        1,
        vec![TableDeclaration::new(
            "drawers",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("content"),
                ColumnDeclaration::bitmap("flags"),
                ColumnDeclaration::int("priority"),
            ],
            vec!["id".to_string()],
        )],
    )
    .with_indices(vec![IndexDeclaration::new(
        "idx_drawers_priority",
        "drawers",
        vec!["priority".to_string()],
    )]);
    storage.open(&schema).expect("open");
    storage
}

fn drawer_row(id: Uuid, content: &str, flags: i64, priority: i64) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".into(), TypedValue::Uuid(id));
    m.insert("content".into(), TypedValue::Text(content.into()));
    m.insert("flags".into(), TypedValue::Bitmap(flags));
    m.insert("priority".into(), TypedValue::Int(priority));
    m
}

#[test]
fn insert_and_query_roundtrip() {
    let s = make_storage();
    let rows = s.row_store();
    let id = Uuid::new_v4();
    let handle = rows
        .insert("drawers", drawer_row(id, "hello", 0b1010, 5))
        .unwrap();
    assert_eq!(handle.key, id);

    let results = rows.query("drawers", None, &[], None, None).unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(
        results[0].get("content"),
        Some(&TypedValue::Text("hello".into()))
    );
}

#[test]
fn predicate_filters_rows() {
    let s = make_storage();
    let rows = s.row_store();
    for (i, content) in ["alpha", "beta", "gamma", "delta"].iter().enumerate() {
        rows.insert(
            "drawers",
            drawer_row(Uuid::new_v4(), content, 0, i as i64 + 1),
        )
        .unwrap();
    }
    let predicate = StoragePredicate::Gt(Column::new("drawers", "priority"), TypedValue::Int(2));
    let results = rows
        .query("drawers", Some(&predicate), &[], None, None)
        .unwrap();
    assert_eq!(results.len(), 2);
}

#[test]
fn order_by_priority_ascending() {
    let s = make_storage();
    let rows = s.row_store();
    for (i, name) in ["z", "a", "m"].iter().enumerate() {
        rows.insert("drawers", drawer_row(Uuid::new_v4(), name, 0, 3 - i as i64))
            .unwrap();
    }
    let order = vec![OrderClause::new(
        Column::new("drawers", "priority"),
        OrderDirection::Ascending,
    )];
    let results = rows.query("drawers", None, &order, None, None).unwrap();
    assert_eq!(results.len(), 3);
    let priorities: Vec<i64> = results
        .iter()
        .filter_map(|r| match r.get("priority") {
            Some(TypedValue::Int(p)) => Some(*p),
            _ => None,
        })
        .collect();
    assert_eq!(priorities, vec![1, 2, 3]);
}

#[test]
fn limit_and_offset_paginates() {
    let s = make_storage();
    let rows = s.row_store();
    for i in 0..10 {
        rows.insert(
            "drawers",
            drawer_row(Uuid::new_v4(), &format!("doc-{}", i), 0, i),
        )
        .unwrap();
    }
    let order = vec![OrderClause::new(
        Column::new("drawers", "priority"),
        OrderDirection::Ascending,
    )];
    let page = rows
        .query("drawers", None, &order, Some(3), Some(2))
        .unwrap();
    assert_eq!(page.len(), 3);
    let priorities: Vec<i64> = page
        .iter()
        .filter_map(|r| match r.get("priority") {
            Some(TypedValue::Int(p)) => Some(*p),
            _ => None,
        })
        .collect();
    assert_eq!(priorities, vec![2, 3, 4]);
}

#[test]
fn upsert_updates_on_conflict() {
    let s = make_storage();
    let rows = s.row_store();
    let id = Uuid::new_v4();
    rows.upsert(
        "drawers",
        drawer_row(id, "first", 0, 1),
        &["id".to_string()],
    )
    .unwrap();
    rows.upsert(
        "drawers",
        drawer_row(id, "second", 0, 2),
        &["id".to_string()],
    )
    .unwrap();
    let results = rows.query("drawers", None, &[], None, None).unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(
        results[0].get("content"),
        Some(&TypedValue::Text("second".into()))
    );
}

#[test]
fn update_predicate_modifies_matching() {
    let s = make_storage();
    let rows = s.row_store();
    for i in 0..5 {
        rows.insert(
            "drawers",
            drawer_row(Uuid::new_v4(), &format!("d-{}", i), 0, i),
        )
        .unwrap();
    }
    let predicate = StoragePredicate::Gte(Column::new("drawers", "priority"), TypedValue::Int(3));
    let mut updates = BTreeMap::new();
    updates.insert("flags".to_string(), TypedValue::Bitmap(0xFF));
    let changed = rows.update("drawers", updates, &predicate).unwrap();
    assert_eq!(changed, 2);
    let high_priority = rows
        .query("drawers", Some(&predicate), &[], None, None)
        .unwrap();
    for r in high_priority {
        assert_eq!(r.get("flags"), Some(&TypedValue::Bitmap(0xFF)));
    }
}

#[test]
fn delete_removes_matching_rows() {
    let s = make_storage();
    let rows = s.row_store();
    for i in 0..5 {
        rows.insert(
            "drawers",
            drawer_row(Uuid::new_v4(), &format!("d-{}", i), 0, i),
        )
        .unwrap();
    }
    let predicate = StoragePredicate::Lt(Column::new("drawers", "priority"), TypedValue::Int(2));
    let removed = rows.delete("drawers", &predicate).unwrap();
    assert_eq!(removed, 2);
    let remaining = rows.count("drawers", None).unwrap();
    assert_eq!(remaining, 3);
}

#[test]
fn bitmask_predicates() {
    let s = make_storage();
    let rows = s.row_store();
    rows.insert("drawers", drawer_row(Uuid::new_v4(), "a", 0b0101, 1))
        .unwrap();
    rows.insert("drawers", drawer_row(Uuid::new_v4(), "b", 0b1010, 2))
        .unwrap();
    rows.insert("drawers", drawer_row(Uuid::new_v4(), "c", 0b1111, 3))
        .unwrap();

    let p_all = StoragePredicate::BitmaskAll {
        column: Column::new("drawers", "flags"),
        mask: 0b0011,
    };
    let res_all = rows
        .query("drawers", Some(&p_all), &[], None, None)
        .unwrap();
    assert_eq!(res_all.len(), 1);
    assert_eq!(
        res_all[0].get("content"),
        Some(&TypedValue::Text("c".into()))
    );

    let p_any = StoragePredicate::BitmaskAny {
        column: Column::new("drawers", "flags"),
        mask: 0b0001,
    };
    let res_any = rows
        .query("drawers", Some(&p_any), &[], None, None)
        .unwrap();
    assert_eq!(res_any.len(), 2);
}

#[test]
fn blob_store_roundtrip() {
    let s = make_storage();
    let blobs = s.blob_store();
    let bytes: Vec<u8> = (0..256).map(|i| i as u8).collect();
    blobs.put("blob-1", &bytes).unwrap();
    let fetched = blobs.get("blob-1").unwrap();
    assert_eq!(fetched, Some(bytes));
    assert!(blobs.exists("blob-1").unwrap());
    assert_eq!(blobs.size("blob-1").unwrap(), Some(256));
    blobs.delete("blob-1").unwrap();
    assert!(!blobs.exists("blob-1").unwrap());
}

#[test]
fn audit_log_idempotent_on_duplicate_event() {
    let s = make_storage();
    let log = s.audit_log();
    let estate = Uuid::new_v4();
    let row_id = Uuid::new_v4();
    let event_id = Uuid::new_v4();
    let hlc = HLC {
        physical_time: 1_000,
        logical_count: 0,
        node_id: 1,
    };
    let event = AuditEvent {
        event_id,
        estate_uuid: estate,
        row_id,
        hlc,
        verb: "capture".into(),
        before_adjective: None,
        before_operational: None,
        before_provenance: None,
        after_adjective: 0x01,
        after_operational: 0x02,
        after_provenance: 0x03,
        before_lattice_anchor: None,
        after_lattice_anchor: 0,
        actor: "test".into(),
        reason: None,
    };
    log.append(event.clone()).unwrap();
    log.append(event.clone()).unwrap(); // duplicate, must be a no-op
    log.append(event).unwrap();
    assert_eq!(log.count().unwrap(), 1);
}

#[test]
fn audit_log_iterate_orders_by_hlc() {
    let s = make_storage();
    let log = s.audit_log();
    let estate = Uuid::new_v4();
    let row_id = Uuid::new_v4();
    for t in [3i64, 1, 2] {
        log.append(AuditEvent {
            event_id: Uuid::new_v4(),
            estate_uuid: estate,
            row_id,
            hlc: HLC {
                physical_time: t,
                logical_count: 0,
                node_id: 1,
            },
            verb: "capture".into(),
            before_adjective: None,
            before_operational: None,
            before_provenance: None,
            after_adjective: 0,
            after_operational: 0,
            after_provenance: 0,
            before_lattice_anchor: None,
            after_lattice_anchor: 0,
            actor: "test".into(),
            reason: None,
        })
        .unwrap();
    }
    let events = log.iterate(None, None, 10).unwrap();
    let physicals: Vec<i64> = events.iter().map(|e| e.hlc.physical_time).collect();
    assert_eq!(physicals, vec![1, 2, 3]);
}

#[test]
fn observer_fires_on_insert() {
    let s = make_storage();
    let observer = s.observer();
    let mut events = BTreeSet::new();
    events.insert(StorageEvent::Insert);
    let rx = observer.observe("drawers", events).unwrap();

    let rows = s.row_store();
    rows.insert("drawers", drawer_row(Uuid::new_v4(), "watched", 0, 1))
        .unwrap();

    let change = rx
        .recv_timeout(std::time::Duration::from_millis(100))
        .expect("observer should have received the insert");
    assert_eq!(change.table, "drawers");
    assert_eq!(change.event, StorageEvent::Insert);
}

#[test]
fn observer_filters_by_event_type() {
    let s = make_storage();
    let observer = s.observer();
    let mut events = BTreeSet::new();
    events.insert(StorageEvent::Delete);
    let rx = observer.observe("drawers", events).unwrap();

    let rows = s.row_store();
    let id = Uuid::new_v4();
    rows.insert("drawers", drawer_row(id, "to-delete", 0, 1))
        .unwrap();
    // Insert should not appear in delete-only stream.
    assert_eq!(rx.try_recv().err(), Some(TryRecvError::Empty));

    rows.delete(
        "drawers",
        &StoragePredicate::Eq(Column::new("drawers", "id"), TypedValue::Uuid(id)),
    )
    .unwrap();

    let change = rx
        .recv_timeout(std::time::Duration::from_millis(100))
        .expect("observer should have received the delete");
    assert_eq!(change.event, StorageEvent::Delete);
}

#[test]
fn schema_version_starts_at_one_after_open() {
    let s = make_storage();
    assert_eq!(s.current_schema_version().unwrap(), 1);
}

#[test]
fn like_pattern_filters() {
    let s = make_storage();
    let rows = s.row_store();
    rows.insert("drawers", drawer_row(Uuid::new_v4(), "alpha-doc", 0, 1))
        .unwrap();
    rows.insert("drawers", drawer_row(Uuid::new_v4(), "beta-doc", 0, 2))
        .unwrap();
    rows.insert("drawers", drawer_row(Uuid::new_v4(), "gamma-doc", 0, 3))
        .unwrap();

    let predicate =
        StoragePredicate::Like(Column::new("drawers", "content"), "%alpha%".to_string());
    let results = rows
        .query("drawers", Some(&predicate), &[], None, None)
        .unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(
        results[0].get("content"),
        Some(&TypedValue::Text("alpha-doc".into()))
    );
}

#[test]
fn predicate_all_short_circuits_trivial_cases() {
    // Empty list -> IsTrue (matches everything).
    let p = StoragePredicate::all(vec![]);
    assert!(matches!(p, StoragePredicate::IsTrue));
    // With IsFalse anywhere -> IsFalse.
    let p2 = StoragePredicate::all(vec![StoragePredicate::IsTrue, StoragePredicate::IsFalse]);
    assert!(matches!(p2, StoragePredicate::IsFalse));
}

// ----- Generated columns -----

use persistence_kit::{ColumnType, GeneratedColumn, GeneratedExpression};

fn generated_storage() -> InMemoryStorage {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    let schema = SchemaDeclaration::new(
        "gen-kit",
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
    );
    storage.open(&schema).unwrap();
    storage
}

#[test]
fn generated_columns_materialize_on_insert() {
    let storage = generated_storage();
    let rs = storage.row_store();
    let id = Uuid::new_v4();
    let mut v = BTreeMap::new();
    v.insert("id".to_string(), TypedValue::Uuid(id));
    v.insert("flags".to_string(), TypedValue::Bitmap(0xA5));
    v.insert("name".to_string(), TypedValue::Text("a".into()));
    rs.insert("gen_items", v).unwrap();

    let rows = rs
        .query(
            "gen_items",
            Some(&StoragePredicate::Eq(
                Column::new("gen_items", "id"),
                TypedValue::Uuid(id),
            )),
            &[],
            None,
            None,
        )
        .unwrap();
    assert_eq!(rows.len(), 1);
    // 0xA5 = 1010_0101: low=0x5, high=0xA, bit7 set.
    assert_eq!(rows[0].get("low_nibble"), Some(&TypedValue::Int(0x5)));
    assert_eq!(rows[0].get("high_nibble"), Some(&TypedValue::Int(0xA)));
    assert_eq!(rows[0].get("has_bit7"), Some(&TypedValue::Bool(true)));
}

#[test]
fn generated_columns_recompute_on_update() {
    let storage = generated_storage();
    let rs = storage.row_store();
    let id = Uuid::new_v4();
    let mut v = BTreeMap::new();
    v.insert("id".to_string(), TypedValue::Uuid(id));
    v.insert("flags".to_string(), TypedValue::Bitmap(0x42));
    v.insert("name".to_string(), TypedValue::Text("b".into()));
    rs.insert("gen_items", v).unwrap();

    // 0x42: low=0x2, bit7 clear.
    let rows = rs
        .query(
            "gen_items",
            Some(&StoragePredicate::Eq(
                Column::new("gen_items", "id"),
                TypedValue::Uuid(id),
            )),
            &[],
            None,
            None,
        )
        .unwrap();
    assert_eq!(rows[0].get("low_nibble"), Some(&TypedValue::Int(0x2)));
    assert_eq!(rows[0].get("has_bit7"), Some(&TypedValue::Bool(false)));

    // Update source column; generated value recomputes.
    let mut upd = BTreeMap::new();
    upd.insert("flags".to_string(), TypedValue::Bitmap(0x0F));
    rs.update(
        "gen_items",
        upd,
        &StoragePredicate::Eq(Column::new("gen_items", "id"), TypedValue::Uuid(id)),
    )
    .unwrap();
    let rows2 = rs
        .query(
            "gen_items",
            Some(&StoragePredicate::Eq(
                Column::new("gen_items", "id"),
                TypedValue::Uuid(id),
            )),
            &[],
            None,
            None,
        )
        .unwrap();
    assert_eq!(rows2[0].get("low_nibble"), Some(&TypedValue::Int(0xF)));
    assert_eq!(rows2[0].get("has_bit7"), Some(&TypedValue::Bool(false)));
}

#[test]
fn generated_column_is_filterable() {
    let storage = generated_storage();
    let rs = storage.row_store();
    for flags in [0xA5_i64, 0x42, 0x05] {
        let mut v = BTreeMap::new();
        v.insert("id".to_string(), TypedValue::Uuid(Uuid::new_v4()));
        v.insert("flags".to_string(), TypedValue::Bitmap(flags));
        v.insert("name".to_string(), TypedValue::Text("x".into()));
        rs.insert("gen_items", v).unwrap();
    }
    // 0xA5 and 0x05 both have low nibble 0x5.
    let count = rs
        .count(
            "gen_items",
            Some(&StoragePredicate::Eq(
                Column::new("gen_items", "low_nibble"),
                TypedValue::Int(0x5),
            )),
        )
        .unwrap();
    assert_eq!(count, 2);
}

#[test]
fn generated_sql_renders_for_sql_backends() {
    // The SQLite/PostgreSQL backends are a follow-on R-mission, but
    // the rendered DDL is stable today and worth pinning.
    let expr = GeneratedExpression::BitAnd(
        Box::new(GeneratedExpression::ShiftRight(
            Box::new(GeneratedExpression::Column("flags".into())),
            6,
        )),
        Box::new(GeneratedExpression::Literal(0x3F)),
    );
    assert_eq!(expr.render_sql(), "((\"flags\" >> 6) & 63)");
}

// ----- Append-only tables -----

fn append_only_storage() -> InMemoryStorage {
    let storage = InMemoryStorage::with_estate(Uuid::new_v4());
    let schema = SchemaDeclaration::new(
        "ledger-kit",
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
    );
    storage.open(&schema).unwrap();
    storage
}

#[test]
fn append_only_allows_insert_rejects_update_and_delete() {
    let storage = append_only_storage();
    let rs = storage.row_store();
    let id1 = Uuid::new_v4();
    let mut v = BTreeMap::new();
    v.insert("id".to_string(), TypedValue::Uuid(id1));
    v.insert("entry".to_string(), TypedValue::Text("first".into()));
    v.insert("amount".to_string(), TypedValue::Int(100));
    rs.insert("ledger", v).unwrap();

    // UPDATE rejected.
    let mut upd = BTreeMap::new();
    upd.insert("amount".to_string(), TypedValue::Int(999));
    let update_result = rs.update(
        "ledger",
        upd,
        &StoragePredicate::Eq(Column::new("ledger", "id"), TypedValue::Uuid(id1)),
    );
    assert!(matches!(
        update_result,
        Err(persistence_kit::StorageError::AppendOnlyViolation { .. })
    ));

    // DELETE rejected.
    let delete_result = rs.delete(
        "ledger",
        &StoragePredicate::Eq(Column::new("ledger", "id"), TypedValue::Uuid(id1)),
    );
    assert!(matches!(
        delete_result,
        Err(persistence_kit::StorageError::AppendOnlyViolation { .. })
    ));

    // Row intact.
    let count = rs.count("ledger", None).unwrap();
    assert_eq!(count, 1);
    let rows = rs
        .query(
            "ledger",
            Some(&StoragePredicate::Eq(
                Column::new("ledger", "id"),
                TypedValue::Uuid(id1),
            )),
            &[],
            None,
            None,
        )
        .unwrap();
    assert_eq!(rows[0].get("amount"), Some(&TypedValue::Int(100)));
}

// ─────────────────────────────────────────────────────────────────────
// StorageIntrospection tests for InMemoryStorage.
// ─────────────────────────────────────────────────────────────────────

use persistence_kit::StorageIntrospection;

#[test]
fn inmemory_introspection_row_count_zero_on_empty() {
    // row_count must be 0 before any inserts.
    let storage = make_storage();
    let stats = storage.stats(0).unwrap();
    assert_eq!(stats.row_count, Some(0));
}

#[test]
fn inmemory_introspection_row_count_reflects_inserts() {
    // row_count tracks the number of rows inserted across all tables.
    let storage = make_storage();
    let id1 = Uuid::new_v4();
    let id2 = Uuid::new_v4();
    storage
        .row_store()
        .insert("drawers", drawer_row(id1, "a", 0, 1))
        .unwrap();
    storage
        .row_store()
        .insert("drawers", drawer_row(id2, "b", 0, 2))
        .unwrap();
    let stats = storage.stats(0).unwrap();
    assert_eq!(stats.row_count, Some(2));
}

#[test]
fn inmemory_introspection_blob_count_reflects_puts() {
    // blob_count tracks stored blob entries.
    let storage = make_storage();
    storage.blob_store().put("k1", b"hello").unwrap();
    storage.blob_store().put("k2", b"world").unwrap();
    let stats = storage.stats(0).unwrap();
    assert_eq!(stats.blob_count, Some(2));
}

#[test]
fn inmemory_introspection_logical_size_grows_with_blobs() {
    // logical_size_bytes grows after adding a large blob.
    let storage = make_storage();
    let before = storage.stats(0).unwrap().logical_size_bytes;
    let payload = vec![0xFFu8; 1024];
    storage.blob_store().put("bigblob", &payload).unwrap();
    let after = storage.stats(0).unwrap().logical_size_bytes;
    assert!(after > before, "logical_size_bytes must grow after a large blob insert");
}

#[test]
fn inmemory_introspection_rollback_count_increments() {
    // transaction_rollback_count increments when the user block returns Err.
    use persistence_kit::error::StorageError;
    let storage = make_storage();
    let before_stats = storage.stats(0).unwrap();
    let before_rollbacks = before_stats.transaction_rollback_count.unwrap_or(0);

    let _err = storage.transaction(
        persistence_kit::IsolationLevel::Serializable,
        &mut |_txn| {
            Err(StorageError::BackendError { underlying: "forced rollback".into() })
        },
    );

    let after_stats = storage.stats(0).unwrap();
    let after_rollbacks = after_stats.transaction_rollback_count.unwrap_or(0);
    assert_eq!(after_rollbacks, before_rollbacks + 1, "rollback_count must increment on rollback");
}

#[test]
fn inmemory_introspection_sqlite_fields_are_none() {
    // SQLite-specific fields must be None for InMemory backend.
    let storage = make_storage();
    let stats = storage.stats(0).unwrap();
    assert_eq!(stats.page_size, None, "page_size must be None for InMemory");
    assert_eq!(stats.page_count, None, "page_count must be None for InMemory");
    assert_eq!(stats.freelist_page_count, None, "freelist_page_count must be None for InMemory");
    assert_eq!(stats.wal_frame_count, None, "wal_frame_count must be None for InMemory");
    assert_eq!(stats.lock_contention, None, "lock_contention must be None for InMemory");
}

#[test]
fn inmemory_introspection_captured_at_matches_input() {
    // captured_at_secs must equal the injected now_secs value.
    let storage = make_storage();
    let now = 1_700_000_000_i64;
    let stats = storage.stats(now).unwrap();
    assert_eq!(stats.captured_at_secs, now);
}
