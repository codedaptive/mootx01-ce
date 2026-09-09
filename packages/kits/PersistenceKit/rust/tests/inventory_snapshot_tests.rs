use std::collections::BTreeMap;
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;

use persistence_kit::{
    BackendConfiguration, ColumnDeclaration, EstateConfiguration, EstateEncryptionConfig, InventorySnapshotError,
    InventorySnapshotLimits, IsolationLevel, PostgresStorage, SchemaDeclaration, SqliteStorage, Storage,
    StorageError, TableDeclaration, TypedValue,
};
use persistence_kit::inmemory::InMemoryStorage;
use postgres::{Client, NoTls};
use rusqlite::Connection;
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hlc::HLC;
use uuid::Uuid;

fn storage() -> InMemoryStorage {
    let storage = InMemoryStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::InMemory,
    ));
    storage
        .open(&SchemaDeclaration::new(
            "inventory-snapshot-tests",
            1,
            vec![
                TableDeclaration::new(
                    "drawers",
                    vec![ColumnDeclaration::text("id"), ColumnDeclaration::text("body").nullable()],
                    vec!["id".to_owned()],
                ),
                TableDeclaration::new(
                    "nodes",
                    vec![ColumnDeclaration::text("id")],
                    vec!["id".to_owned()],
                ),
            ],
        ))
        .unwrap();
    storage
}

fn inventory_schema(kit_id: &str) -> SchemaDeclaration {
    SchemaDeclaration::new(
        kit_id,
        1,
        vec![
            TableDeclaration::new(
                "drawers",
                vec![ColumnDeclaration::text("id"), ColumnDeclaration::text("body").nullable()],
                vec!["id".to_owned()],
            ),
            TableDeclaration::new(
                "nodes",
                vec![ColumnDeclaration::text("id")],
                vec!["id".to_owned()],
            ),
        ],
    )
}

fn typed_inventory_schema(kit_id: &str) -> SchemaDeclaration {
    SchemaDeclaration::new(
        kit_id,
        1,
        vec![
            TableDeclaration::new(
                "drawers",
                vec![
                    ColumnDeclaration::text("id"),
                    ColumnDeclaration::text("nullable_text").nullable(),
                    ColumnDeclaration::json("metadata").nullable(),
                    ColumnDeclaration::fingerprint("fingerprint").nullable(),
                ],
                vec!["id".to_owned()],
            ),
            TableDeclaration::new(
                "nodes",
                vec![ColumnDeclaration::text("id")],
                vec!["id".to_owned()],
            ),
        ],
    )
}

fn sqlite_storage() -> SqliteStorage {
    let storage = SqliteStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: ":memory:".to_owned(),
            busy_timeout_secs: 5.0,
        },
    ))
    .unwrap();
    storage.open(&inventory_schema("inventory-snapshot-sqlite-tests")).unwrap();
    storage
}

fn row(id: &str) -> BTreeMap<String, TypedValue> {
    BTreeMap::from([
        ("id".to_owned(), TypedValue::Text(id.to_owned())),
        ("body".to_owned(), TypedValue::Text("bounded inventory row".to_owned())),
    ])
}

#[test]
fn inmemory_snapshot_copies_both_inventory_tables() {
    let storage = storage();
    storage.row_store().insert("drawers", row("drawer-1")).unwrap();
    storage
        .row_store()
        .insert(
            "nodes",
            BTreeMap::from([("id".to_owned(), TypedValue::Text("node-1".to_owned()))]),
        )
        .unwrap();

    let snapshot = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::production())
        .unwrap();

    assert_eq!(snapshot.drawers.len(), 1);
    assert_eq!(snapshot.nodes.len(), 1);
    assert!(snapshot.serialized_row_bytes() > 0);
}

#[test]
fn inmemory_snapshot_rejects_row_limit_before_returning_a_partial_copy() {
    let storage = storage();
    storage.row_store().insert("drawers", row("drawer-1")).unwrap();
    storage.row_store().insert("drawers", row("drawer-2")).unwrap();

    let error = storage
        .capture_inventory_snapshot(
            InventorySnapshotLimits::new(1, InventorySnapshotLimits::production().max_serialized_bytes())
                .unwrap(),
        )
        .unwrap_err();

    assert!(matches!(
        error,
        InventorySnapshotError::RowLimitExceeded { ref table, limit: 1 } if table == "drawers"
    ));
}

#[test]
fn inmemory_snapshot_rejects_serialized_byte_limit_before_retaining_the_row() {
    let storage = storage();
    storage.row_store().insert("drawers", row("drawer-1")).unwrap();

    let error = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::new(1, 0).unwrap())
        .unwrap_err();

    assert!(matches!(error, InventorySnapshotError::ByteLimitExceeded { limit: 0 }));
}

#[test]
fn sqlite_snapshot_captures_both_tables_and_enforces_tightened_bounds() {
    let storage = sqlite_storage();
    storage.row_store().insert("drawers", row("drawer-1")).unwrap();
    storage
        .row_store()
        .insert(
            "nodes",
            BTreeMap::from([("id".to_owned(), TypedValue::Text("node-1".to_owned()))]),
        )
        .unwrap();

    let snapshot = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::production())
        .unwrap();
    assert_eq!(snapshot.drawers.len(), 1);
    assert_eq!(snapshot.nodes.len(), 1);

    let row_limit = storage
        .capture_inventory_snapshot(
            InventorySnapshotLimits::new(0, InventorySnapshotLimits::production().max_serialized_bytes())
                .unwrap(),
        )
        .unwrap_err();
    assert!(matches!(
        row_limit,
        InventorySnapshotError::RowLimitExceeded { ref table, limit: 0 } if table == "drawers"
    ));

    let byte_limit = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::new(1, 0).unwrap())
        .unwrap_err();
    assert!(matches!(byte_limit, InventorySnapshotError::ByteLimitExceeded { limit: 0 }));
}

#[test]
fn sqlite_snapshot_preflight_rejects_an_oversized_single_body() {
    let path = std::env::temp_dir().join(format!("inventory-snapshot-{}.sqlite", Uuid::new_v4()));
    let storage = SqliteStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    ))
    .unwrap();
    storage
        .open(&SchemaDeclaration::new(
            "inventory-snapshot-preflight-order",
            1,
            vec![
                TableDeclaration::new(
                    "drawers",
                    vec![ColumnDeclaration::uuid("id"), ColumnDeclaration::text("body")],
                    vec!["id".to_owned()],
                ),
                TableDeclaration::new(
                    "nodes",
                    vec![ColumnDeclaration::text("id")],
                    vec!["id".to_owned()],
                ),
            ],
        ))
        .unwrap();
    // A body scan would decode this invalid UUID first. Byte-limit failure
    // proves the stored-size preflight rejects before any body row is read.
    Connection::open(&path)
        .unwrap()
        .execute(
            "INSERT INTO \"drawers\" (\"id\", \"body\") VALUES (?1, ?2)",
            rusqlite::params!["not-a-uuid", "x".repeat(256 * 1024)],
        )
        .unwrap();

    let error = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::new(1, 1).unwrap())
        .unwrap_err();
    drop(storage);
    let _ = std::fs::remove_file(path);
    assert!(matches!(error, InventorySnapshotError::ByteLimitExceeded { limit: 1 }));
}

#[test]
fn sqlite_snapshot_preflight_bounds_corrupt_huge_timestamp_before_decode() {
    let path = std::env::temp_dir().join(format!("inventory-snapshot-timestamp-{}.sqlite", Uuid::new_v4()));
    let storage = SqliteStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string_lossy().into_owned(),
            busy_timeout_secs: 5.0,
        },
    ))
    .unwrap();
    storage
        .open(&SchemaDeclaration::new(
            "inventory-snapshot-timestamp-preflight-order",
            1,
            vec![
                TableDeclaration::new(
                    "drawers",
                    vec![ColumnDeclaration::text("id"), ColumnDeclaration::timestamp("filed_at")],
                    vec!["id".to_owned()],
                ),
                TableDeclaration::new(
                    "nodes",
                    vec![ColumnDeclaration::text("id")],
                    vec!["id".to_owned()],
                ),
            ],
        ))
        .unwrap();
    // A decode would return CorruptStoredValue for filed_at. The byte-limit
    // result proves the typeof-aware guard runs before ValueRef reads it.
    Connection::open(&path)
        .unwrap()
        .execute(
            "INSERT INTO \"drawers\" (\"id\", \"filed_at\") VALUES (?1, ?2)",
            rusqlite::params!["timestamp-drawer", format!("not-a-timestamp{}", "x".repeat(256 * 1024))],
        )
        .unwrap();

    let error = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::new(1, 1).unwrap())
        .unwrap_err();
    drop(storage);
    let _ = std::fs::remove_file(path);
    assert!(matches!(error, InventorySnapshotError::ByteLimitExceeded { limit: 1 }));
}

#[test]
fn sqlite_snapshot_accepts_high_bit_hlc_exact_boundary_then_rejects_one_less() {
    let storage = SqliteStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: ":memory:".to_owned(),
            busy_timeout_secs: 5.0,
        },
    ))
    .unwrap();
    storage
        .open(&SchemaDeclaration::new(
            "inventory-snapshot-hlc-boundary",
            1,
            vec![
                TableDeclaration::new(
                    "drawers",
                    vec![ColumnDeclaration::hlc("h")],
                    vec!["h".to_owned()],
                ),
                TableDeclaration::new(
                    "nodes",
                    vec![ColumnDeclaration::hlc("h")],
                    vec!["h".to_owned()],
                ),
            ],
        ))
        .unwrap();
    storage
        .row_store()
        .insert(
            "drawers",
            BTreeMap::from([("h".to_owned(), TypedValue::Hlc(HLC::new(0, 0, 0x80)))]),
        )
        .unwrap();

    storage
        .capture_inventory_snapshot(InventorySnapshotLimits::new(1, 23).unwrap())
        .expect("exact high-bit HLC canonical boundary is accepted");
    assert!(matches!(
        storage.capture_inventory_snapshot(InventorySnapshotLimits::new(1, 22).unwrap()),
        Err(InventorySnapshotError::ByteLimitExceeded { limit: 22 })
    ));
}

#[test]
fn sqlite_row_encrypted_snapshot_accepts_its_exact_canonical_boundary() {
    let mut configuration = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: ":memory:".to_owned(),
            busy_timeout_secs: 5.0,
        },
    );
    configuration.encryption_config = EstateEncryptionConfig::row_encryption();
    let storage = SqliteStorage::new(configuration).unwrap();
    storage
        .open(&SchemaDeclaration::new(
            "inventory-snapshot-row-encryption",
            1,
            vec![
                TableDeclaration::new(
                    "drawers",
                    vec![
                        ColumnDeclaration::text("id"),
                        ColumnDeclaration::text("content"),
                        ColumnDeclaration::text("keyID").nullable(),
                    ],
                    vec!["id".to_owned()],
                ),
                TableDeclaration::new(
                    "nodes",
                    vec![ColumnDeclaration::text("id")],
                    vec!["id".to_owned()],
                ),
            ],
        ))
        .unwrap();
    storage.row_store().insert(
        "drawers",
        BTreeMap::from([
            ("id".to_owned(), TypedValue::Text("sealed-drawer".to_owned())),
            ("content".to_owned(), TypedValue::Text("sealed exact boundary".to_owned())),
        ]),
    ).unwrap();

    let snapshot = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::production())
        .unwrap();
    let exact = snapshot.serialized_row_bytes();
    assert!(matches!(
        snapshot.drawers[0].values.get("content"),
        Some(TypedValue::Text(value)) if value == "sealed exact boundary"
    ));
    storage
        .capture_inventory_snapshot(InventorySnapshotLimits::new(1, exact).unwrap())
        .expect("exact decrypted canonical boundary is accepted");
    assert!(matches!(
        storage.capture_inventory_snapshot(InventorySnapshotLimits::new(1, exact - 1).unwrap()),
        Err(InventorySnapshotError::ByteLimitExceeded { limit }) if limit == exact - 1
    ));
}

#[test]
fn sqlite_snapshot_waits_for_writer_commit_and_never_observes_a_partial_bracket() {
    let storage = Arc::new(sqlite_storage());
    let (writer_entered_tx, writer_entered_rx) = mpsc::channel();
    let (release_writer_tx, release_writer_rx) = mpsc::channel();
    let writer_storage = storage.clone();
    let writer = thread::spawn(move || {
        writer_storage.transaction(IsolationLevel::Serializable, &mut |transaction| {
            transaction.row_store().insert("drawers", row("drawer-1"))?;
            transaction.row_store().insert(
                "nodes",
                BTreeMap::from([("id".to_owned(), TypedValue::Text("node-1".to_owned()))]),
            )?;
            writer_entered_tx.send(()).expect("writer entered signal");
            release_writer_rx.recv().expect("writer release signal");
            Ok(())
        })
    });
    writer_entered_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("writer must open its transaction before the snapshot starts");

    let (snapshot_tx, snapshot_rx) = mpsc::channel();
    let snapshot_storage = storage.clone();
    let snapshot_thread = thread::spawn(move || {
        snapshot_tx
            .send(snapshot_storage.capture_inventory_snapshot(InventorySnapshotLimits::production()))
            .expect("snapshot result receiver remains available");
    });
    let premature = snapshot_rx.recv_timeout(Duration::from_millis(250));
    let timed_out_before_commit = matches!(&premature, Err(mpsc::RecvTimeoutError::Timeout));

    release_writer_tx.send(()).expect("release writer");
    writer.join().expect("writer thread panicked").expect("writer transaction commits");
    let snapshot = match premature {
        Err(mpsc::RecvTimeoutError::Timeout) => snapshot_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("snapshot completes after writer commit"),
        Ok(result) => result,
        Err(mpsc::RecvTimeoutError::Disconnected) => panic!("snapshot thread disconnected before commit"),
    }
    .expect("snapshot succeeds");
    snapshot_thread.join().expect("snapshot thread panicked");

    assert!(timed_out_before_commit);
    assert_eq!(snapshot.drawers.len(), 1);
    assert_eq!(snapshot.nodes.len(), 1);
}

#[test]
fn postgres_snapshot_captures_both_tables_and_enforces_tightened_bounds() {
    let url = match std::env::var("PERSISTENCEKIT_PG_URL") {
        Ok(url) if !url.is_empty() => url,
        _ => {
            eprintln!(
                "postgres_snapshot_captures_both_tables_and_enforces_tightened_bounds: skipped \
                 (set PERSISTENCEKIT_PG_URL to a scratch PostgreSQL database to run it)"
            );
            return;
        }
    };
    let storage = PostgresStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Postgresql {
            connection_string: url,
            pool_size: 2,
            connection_timeout_secs: 5.0,
            idle_timeout_secs: 30.0,
        },
    ))
    .expect("construct postgres storage");
    storage
        .open(&inventory_schema("inventory-snapshot-postgres-tests"))
        .expect("open unique postgres estate schema");
    storage.row_store().insert("drawers", row("drawer-1")).unwrap();
    storage
        .row_store()
        .insert(
            "nodes",
            BTreeMap::from([("id".to_owned(), TypedValue::Text("node-1".to_owned()))]),
        )
        .unwrap();

    let snapshot = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::production())
        .unwrap();
    assert_eq!(snapshot.drawers.len(), 1);
    assert_eq!(snapshot.nodes.len(), 1);

    let row_limit = storage
        .capture_inventory_snapshot(
            InventorySnapshotLimits::new(0, InventorySnapshotLimits::production().max_serialized_bytes())
                .unwrap(),
        )
        .unwrap_err();
    assert!(matches!(
        row_limit,
        InventorySnapshotError::RowLimitExceeded { ref table, limit: 0 } if table == "drawers"
    ));

    let byte_limit = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::new(1, 0).unwrap())
        .unwrap_err();
    assert!(matches!(byte_limit, InventorySnapshotError::ByteLimitExceeded { limit: 0 }));
}

#[test]
fn postgres_snapshot_strictly_preserves_nullable_json_and_fingerprint_values() {
    let url = match std::env::var("PERSISTENCEKIT_PG_URL") {
        Ok(url) if !url.is_empty() => url,
        _ => {
            eprintln!(
                "postgres_snapshot_strictly_preserves_nullable_json_and_fingerprint_values: skipped \
                 (set PERSISTENCEKIT_PG_URL to a scratch PostgreSQL database to run it)"
            );
            return;
        }
    };
    let estate_id = Uuid::new_v4();
    let storage = PostgresStorage::new(EstateConfiguration::new(
        estate_id,
        BackendConfiguration::Postgresql {
            connection_string: url.clone(),
            pool_size: 2,
            connection_timeout_secs: 5.0,
            idle_timeout_secs: 30.0,
        },
    ))
    .expect("construct postgres storage");
    storage
        .open(&typed_inventory_schema("inventory-snapshot-postgres-strict-values"))
        .expect("open unique postgres estate schema");
    let fingerprint = Fingerprint256::new(0x11, 0x22, 0x33, 0x44);
    let schema = format!("pk_{}", estate_id.simple());
    let mut client = Client::connect(&url, NoTls).expect("connect raw postgres fixture client");
    client
        .batch_execute(&format!("SET search_path TO \"{schema}\", public"))
        .expect("select postgres estate schema");
    client
        .execute(
            "INSERT INTO \"drawers\" (\"id\", \"nullable_text\", \"metadata\", \"fingerprint\") \
             VALUES ($1, $2, $3::text::jsonb, $4)",
            &[
                &"typed-drawer",
                &Option::<String>::None,
                &"{\"kind\":\"inventory\"}",
                &fingerprint.wire_bytes().to_vec(),
            ],
        )
        .expect("insert typed postgres drawer");
    client
        .execute("INSERT INTO \"nodes\" (\"id\") VALUES ($1)", &[&"typed-node"])
        .expect("insert postgres node");

    let snapshot = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::production())
        .expect("capture typed postgres inventory snapshot");
    assert_eq!(snapshot.drawers.len(), 1);
    assert_eq!(snapshot.nodes.len(), 1);
    assert!(matches!(snapshot.drawers[0].values.get("nullable_text"), Some(TypedValue::Null)));
    assert!(matches!(
        snapshot.drawers[0].values.get("metadata"),
        Some(TypedValue::Json(value)) if std::str::from_utf8(value).unwrap().contains("inventory")
    ));
    assert!(matches!(
        snapshot.drawers[0].values.get("fingerprint"),
        Some(TypedValue::Fingerprint(value)) if value == &fingerprint
    ));

    client
        .execute(
            "UPDATE \"drawers\" SET \"fingerprint\" = $1 WHERE \"id\" = $2",
            &[&vec![0_u8; 31], &"typed-drawer"],
        )
        .expect("inject malformed fingerprint fixture");
    let error = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::production())
        .unwrap_err();
    assert!(matches!(
        error,
        InventorySnapshotError::Storage(StorageError::CorruptStoredValue { ref table, ref column, .. })
            if table == "drawers" && column == "fingerprint"
    ));
}

#[test]
fn postgres_snapshot_rejects_non_null_native_type_mismatch_instead_of_null() {
    let url = match std::env::var("PERSISTENCEKIT_PG_URL") {
        Ok(url) if !url.is_empty() => url,
        _ => {
            eprintln!(
                "postgres_snapshot_rejects_non_null_native_type_mismatch_instead_of_null: skipped \
                 (set PERSISTENCEKIT_PG_URL to a scratch PostgreSQL database to run it)"
            );
            return;
        }
    };
    let estate_id = Uuid::new_v4();
    let storage = PostgresStorage::new(EstateConfiguration::new(
        estate_id,
        BackendConfiguration::Postgresql {
            connection_string: url.clone(),
            pool_size: 2,
            connection_timeout_secs: 5.0,
            idle_timeout_secs: 30.0,
        },
    ))
    .expect("construct postgres storage");
    storage
        .open(&inventory_schema("inventory-snapshot-postgres-native-mismatch"))
        .expect("open unique postgres estate schema");
    let schema = format!("pk_{}", estate_id.simple());
    let mut client = Client::connect(&url, NoTls).expect("connect raw postgres fixture client");
    client
        .batch_execute(&format!(
            "SET search_path TO \"{schema}\", public; \
             ALTER TABLE \"drawers\" ALTER COLUMN \"body\" TYPE BYTEA \
             USING convert_to(\"body\", 'UTF8'); \
             INSERT INTO \"drawers\" (\"id\", \"body\") VALUES ('native-mismatch', decode('00ff', 'hex')); \
             INSERT INTO \"nodes\" (\"id\") VALUES ('native-mismatch-node');"
        ))
        .expect("replace declared text body with native bytea fixture");

    let error = storage
        .capture_inventory_snapshot(InventorySnapshotLimits::production())
        .unwrap_err();
    assert!(matches!(
        error,
        InventorySnapshotError::Storage(StorageError::CorruptStoredValue { ref table, ref column, .. })
            if table == "drawers" && column == "body"
    ));
}
