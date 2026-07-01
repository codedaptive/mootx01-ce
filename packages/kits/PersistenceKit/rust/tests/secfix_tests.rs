//! Regression tests for SECFIX-WS2-PK planned security hardening (Rust port).
//!
//! F1 — SQL identifier injection guard: caller-supplied column names must be
//!      rejected when they contain characters outside [A-Za-z_][A-Za-z0-9_]*.
//!
//! F2/F4 — InMemory transaction notification isolation: row and blob change events
//!         must not be emitted via observers when the transaction is rolled back.
//!
//! F6 — Hash-on-write correctness: `update` and `upsert` on an existing row must
//!      hash the full committed row (current state merged with incoming values,
//!      excluding `content_hash`), not just the partial SET dict / incoming values.

use persistence_kit::error::{StorageError, validate_sql_identifier};
use persistence_kit::hashing_row_store::{HashOnWriteConfig, HashingRowStore};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::observer::{DirtyChainEvent, DirtyChainHub, StorageEvent};
use persistence_kit::row_store::RowStore;
use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
use persistence_kit::storage::{
    BackendConfiguration, EstateConfiguration, IsolationLevel, Storage,
};
use persistence_kit::types::TypedValue;
use persistence_kit::{Column, StoragePredicate};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::sync::Arc;
use substrate_types::content_hash::ContentHash;
use uuid::Uuid;

// ─────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────

fn make_storage() -> InMemoryStorage {
    InMemoryStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::InMemory,
    ))
}

fn open_simple_schema(storage: &InMemoryStorage) {
    let schema = SchemaDeclaration::new(
        "SecFixTestKit",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("label"),
                ColumnDeclaration::bitmap("flags"),
            ],
            vec!["id".to_string()],
        )],
    );
    storage.open(&schema).expect("open schema");
}

fn open_hashable_schema(storage: &InMemoryStorage) {
    let schema = SchemaDeclaration::new(
        "HashTestKit",
        1,
        vec![TableDeclaration::new(
            "entries",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("title"),
                ColumnDeclaration::text("body").nullable(),
                ColumnDeclaration::bitmap("flags"),
                ColumnDeclaration::blob("content_hash").nullable(),
            ],
            vec!["id".to_string()],
        )
        .hashable()],
    );
    storage.open(&schema).expect("open schema");
}

fn simple_row(id: Uuid, label: &str) -> BTreeMap<String, TypedValue> {
    let mut m = BTreeMap::new();
    m.insert("id".into(), TypedValue::Uuid(id));
    m.insert("label".into(), TypedValue::Text(label.into()));
    m.insert("flags".into(), TypedValue::Bitmap(0));
    m
}

// ─────────────────────────────────────────────────────────────────
// F1 — validate_sql_identifier (shared util, also called by sqlite.rs + postgres.rs)
// ─────────────────────────────────────────────────────────────────

#[test]
fn f1_rejects_double_quote_in_identifier() {
    let bad = r#"id" FROM items; --"#;
    assert!(
        matches!(
            validate_sql_identifier(bad),
            Err(StorageError::InvalidIdentifier { .. })
        ),
        "double-quote in column name must be rejected"
    );
}

#[test]
fn f1_rejects_semicolon_in_identifier() {
    let bad = "id; DROP TABLE items; --";
    assert!(
        matches!(
            validate_sql_identifier(bad),
            Err(StorageError::InvalidIdentifier { .. })
        ),
        "semicolon in column name must be rejected"
    );
}

#[test]
fn f1_rejects_space_in_identifier() {
    assert!(
        matches!(
            validate_sql_identifier("my column"),
            Err(StorageError::InvalidIdentifier { .. })
        ),
        "space in column name must be rejected"
    );
}

#[test]
fn f1_rejects_empty_identifier() {
    assert!(
        matches!(
            validate_sql_identifier(""),
            Err(StorageError::InvalidIdentifier { .. })
        ),
        "empty string must be rejected as an identifier"
    );
}

#[test]
fn f1_rejects_digit_leading_identifier() {
    assert!(
        matches!(
            validate_sql_identifier("1id"),
            Err(StorageError::InvalidIdentifier { .. })
        ),
        "digit-leading identifier must be rejected"
    );
}

#[test]
fn f1_accepts_valid_identifiers() {
    assert!(validate_sql_identifier("id").is_ok());
    assert!(validate_sql_identifier("label").is_ok());
    assert!(validate_sql_identifier("flags").is_ok());
    assert!(validate_sql_identifier("row_id").is_ok());
    assert!(validate_sql_identifier("_label").is_ok());
    assert!(validate_sql_identifier("col2").is_ok());
}

// ─────────────────────────────────────────────────────────────────
// F2 — InMemory row-change notification isolation
// ─────────────────────────────────────────────────────────────────

/// A row inserted inside a rolled-back transaction must not deliver a row
/// change event to observers. The hub must stay silent for rolled-back writes.
#[test]
fn f2_rolled_back_row_insert_does_not_notify() {
    let storage = make_storage();
    open_simple_schema(&storage);

    // Subscribe BEFORE the transaction.
    let observer = storage.observer();
    let rx = observer
        .observe("items", BTreeSet::from([StorageEvent::Insert]))
        .expect("subscribe");

    let id = Uuid::new_v4();
    let result = storage.transaction(IsolationLevel::Serializable, &mut |txn| {
        let row_store = txn.row_store();
        row_store.insert("items", simple_row(id, "ghost"))?;
        Err(StorageError::BackendError { underlying: "forced rollback".into() })
    });
    assert!(result.is_err(), "transaction should return the forced error");

    // No event must have arrived.
    match rx.try_recv() {
        Err(std::sync::mpsc::TryRecvError::Empty) => {} // correct
        Ok(event) => panic!(
            "Row observer received an event for a rolled-back transaction: {:?}", event
        ),
        Err(e) => panic!("Channel error: {:?}", e),
    }

    // The row must not be readable after rollback.
    let rows = storage
        .row_store()
        .query("items", None, &[], None, None)
        .expect("query after rollback");
    assert!(rows.is_empty(), "rolled-back row must not be readable");
}

/// A row inserted in a committed transaction MUST deliver a row change event.
#[test]
fn f2_committed_row_insert_notifies() {
    let storage = make_storage();
    open_simple_schema(&storage);

    let observer = storage.observer();
    let rx = observer
        .observe("items", BTreeSet::from([StorageEvent::Insert]))
        .expect("subscribe");

    let id = Uuid::new_v4();
    storage
        .transaction(IsolationLevel::Serializable, &mut |txn| {
            txn.row_store().insert("items", simple_row(id, "real"))?;
            Ok(())
        })
        .expect("committed transaction must succeed");

    match rx.try_recv() {
        Ok(_) => {} // correct — event arrived
        Err(std::sync::mpsc::TryRecvError::Empty) => panic!(
            "No row event emitted after committed transaction"
        ),
        Err(e) => panic!("Channel error: {:?}", e),
    }
}

// ─────────────────────────────────────────────────────────────────
// F4 — InMemory blob-change notification isolation
// ─────────────────────────────────────────────────────────────────

/// A blob put inside a rolled-back transaction must not deliver a blob event
/// to blob observers.
#[test]
fn f4_rolled_back_blob_put_does_not_notify() {
    let storage = make_storage();
    open_simple_schema(&storage);

    let observer = storage.observer();
    let rx = observer.observe_blobs();

    let key = format!("secfix/f4/{}", Uuid::new_v4());
    let result = storage.transaction(IsolationLevel::Serializable, &mut |txn| {
        txn.blob_store().put(&key, &[0xDE, 0xAD])?;
        Err(StorageError::BackendError { underlying: "forced rollback".into() })
    });
    assert!(result.is_err());

    match rx.try_recv() {
        Err(std::sync::mpsc::TryRecvError::Empty) => {} // correct
        Ok(event) => panic!(
            "Blob observer received event for rolled-back transaction: {:?}", event
        ),
        Err(e) => panic!("Channel error: {:?}", e),
    }

    // Blob must not exist in storage.
    let stored = storage
        .blob_store()
        .get(&key)
        .expect("get after rollback");
    assert!(stored.is_none(), "rolled-back blob must not be readable");
}

/// A blob put in a committed transaction MUST deliver a blob event.
#[test]
fn f4_committed_blob_put_notifies() {
    let storage = make_storage();
    open_simple_schema(&storage);

    let observer = storage.observer();
    let rx = observer.observe_blobs();

    let key = format!("secfix/f4/committed/{}", Uuid::new_v4());
    storage
        .transaction(IsolationLevel::Serializable, &mut |txn| {
            txn.blob_store().put(&key, &[0xAB, 0xCD])?;
            Ok(())
        })
        .expect("committed transaction must succeed");

    match rx.try_recv() {
        Ok(event) => {
            assert_eq!(event.key, key, "blob event must carry the correct key");
        }
        Err(std::sync::mpsc::TryRecvError::Empty) => panic!(
            "No blob event emitted after committed transaction"
        ),
        Err(e) => panic!("Channel error: {:?}", e),
    }
}

// ─────────────────────────────────────────────────────────────────
// F6 — Hash-on-write correctness for update and upsert
// ─────────────────────────────────────────────────────────────────

/// Hash function that encodes the sorted column-name set (excluding `content_hash`)
/// in bytes 16–31. Different column sets → different fingerprints → mis-hashes
/// are detectable. The implementation strips `content_hash` before calling this,
/// so it must not appear in `values` when this function is called.
fn f6_hash(
    _table: &str,
    row_key: Uuid,
    values: &BTreeMap<String, TypedValue>,
) -> ContentHash {
    let mut bytes = [0u8; 32];
    // Bytes 0–15: row key UUID.
    bytes[..16].copy_from_slice(row_key.as_bytes());
    // Bytes 16–31: fingerprint of sorted column names.
    let mut sorted_keys: Vec<_> = values.keys().collect();
    sorted_keys.sort();
    let key_string: String = sorted_keys.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(",");
    let key_bytes = key_string.as_bytes();
    for i in 0..16.min(key_bytes.len()) {
        bytes[16 + i] = key_bytes[i];
    }
    ContentHash::new(bytes)
}

fn f6_parent_chain(_table: &str, _row_key: Uuid) -> Option<(Uuid, Uuid)> {
    Some((
        Uuid::parse_str("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").unwrap(),
        Uuid::parse_str("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb").unwrap(),
    ))
}

fn make_f6_store(storage: &InMemoryStorage) -> (HashingRowStore, std::sync::mpsc::Receiver<DirtyChainEvent>) {
    let hub = Arc::new(DirtyChainHub::new());
    let rx = hub.subscribe();
    let config = HashOnWriteConfig {
        hashable_tables: HashSet::from(["entries".to_string()]),
        hash_provider: Box::new(f6_hash),
        parent_chain_provider: Box::new(f6_parent_chain),
    };
    let store = HashingRowStore::new(storage.row_store(), config, Some(hub));
    (store, rx)
}

/// After inserting a row with all data columns, calling `update` with only a
/// subset of columns must produce a hash computed from the FULL merged row
/// (all data columns excluding `content_hash`), not just the SET dict.
///
/// Pre-fix: `update({"body": "X"})` → hash({"body": "X"})
/// Post-fix: `update({"body": "X"})` → hash({"id":…, "title":…, "body":"X", "flags":…})
#[test]
fn f6_update_hashes_full_merged_row() {
    let storage = make_storage();
    open_hashable_schema(&storage);
    let (store, _rx) = make_f6_store(&storage);

    let id = Uuid::new_v4();
    // Insert with all data columns.
    let mut insert_values = BTreeMap::new();
    insert_values.insert("id".to_string(), TypedValue::Uuid(id));
    insert_values.insert("title".to_string(), TypedValue::Text("original title".into()));
    insert_values.insert("body".to_string(), TypedValue::Text("original body".into()));
    insert_values.insert("flags".to_string(), TypedValue::Bitmap(0));
    store.insert("entries", insert_values).expect("insert");

    // Update only the "body" column.
    let mut update_values = BTreeMap::new();
    update_values.insert("body".to_string(), TypedValue::Text("updated body".into()));
    let predicate = StoragePredicate::Eq(
        Column { table: "entries".to_string(), name: "id".to_string() },
        TypedValue::Uuid(id),
    );
    store.update("entries", update_values, &predicate).expect("update");

    let rows = store.query("entries", None, &[], None, None).expect("query");
    assert_eq!(rows.len(), 1);

    // Expected hash: all four data columns merged (content_hash excluded by impl).
    let mut full_values = BTreeMap::new();
    full_values.insert("id".to_string(), TypedValue::Uuid(id));
    full_values.insert("title".to_string(), TypedValue::Text("original title".into()));
    full_values.insert("body".to_string(), TypedValue::Text("updated body".into()));
    full_values.insert("flags".to_string(), TypedValue::Bitmap(0));
    let expected_hash = f6_hash("entries", id, &full_values);
    let expected_blob: Vec<u8> = expected_hash.bytes().to_vec();

    let stored = rows[0].values.get("content_hash")
        .expect("content_hash must be present after update");
    if let TypedValue::Blob(stored_bytes) = stored {
        assert_eq!(
            stored_bytes, &expected_blob,
            "content_hash after update must reflect full merged row, not just SET columns"
        );
    } else {
        panic!("content_hash has wrong type: {:?}", stored);
    }
}

/// Calling `upsert` on an already-existing row must hash the full merged row
/// (current state merged with incoming values, excluding `content_hash`),
/// not just the incoming values dict.
///
/// Pre-fix: `upsert({"id":…, "title":"new"})` → hash({"id":…, "title":"new"})
/// Post-fix: `upsert({"id":…, "title":"new"})` → hash({"id":…, "title":"new", "body":…, "flags":…})
#[test]
fn f6_upsert_on_existing_row_hashes_full_merged_row() {
    let storage = make_storage();
    open_hashable_schema(&storage);
    let (store, _rx) = make_f6_store(&storage);

    let id = Uuid::new_v4();
    // Insert a full row.
    let mut insert_values = BTreeMap::new();
    insert_values.insert("id".to_string(), TypedValue::Uuid(id));
    insert_values.insert("title".to_string(), TypedValue::Text("initial title".into()));
    insert_values.insert("body".to_string(), TypedValue::Text("initial body".into()));
    insert_values.insert("flags".to_string(), TypedValue::Bitmap(7));
    store.insert("entries", insert_values).expect("insert");

    // Upsert with only id + title (conflict column + one updated column).
    let mut upsert_values = BTreeMap::new();
    upsert_values.insert("id".to_string(), TypedValue::Uuid(id));
    upsert_values.insert("title".to_string(), TypedValue::Text("revised title".into()));
    store
        .upsert("entries", upsert_values, &["id".to_string()])
        .expect("upsert");

    let rows = store.query("entries", None, &[], None, None).expect("query");
    assert_eq!(rows.len(), 1);

    // Expected hash: all four data columns merged (content_hash excluded).
    let mut full_values = BTreeMap::new();
    full_values.insert("id".to_string(), TypedValue::Uuid(id));
    full_values.insert("title".to_string(), TypedValue::Text("revised title".into()));
    full_values.insert("body".to_string(), TypedValue::Text("initial body".into()));
    full_values.insert("flags".to_string(), TypedValue::Bitmap(7));
    let expected_hash = f6_hash("entries", id, &full_values);
    let expected_blob: Vec<u8> = expected_hash.bytes().to_vec();

    let stored = rows[0].values.get("content_hash")
        .expect("content_hash must be present after upsert");
    if let TypedValue::Blob(stored_bytes) = stored {
        assert_eq!(
            stored_bytes, &expected_blob,
            "content_hash after upsert must reflect full merged row, not just incoming values"
        );
    } else {
        panic!("content_hash has wrong type: {:?}", stored);
    }
}

// ─────────────────────────────────────────────────────────────────
// CAND-052/055 — db.key atomic creation (SECFIX-WS2-PK F-key)
//
// The key file must be created with O_CREAT|O_EXCL (create_new) so:
//   (a) permissions are set atomically at inode creation time — no window
//       where the file is world/group-readable.
//   (b) a pre-planted symlink at the key path is refused (O_EXCL does not
//       follow symlinks for the final path component on POSIX platforms).
// ─────────────────────────────────────────────────────────────────

#[test]
#[cfg(unix)]
fn key_file_permissions_are_0600_at_creation() {
    use persistence_kit::ensure_install_key;
    use std::os::unix::fs::PermissionsExt;

    // Use a uniquely-named temp directory to avoid collision with parallel tests.
    let dir = std::env::temp_dir().join(format!("pk_keytest_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create temp dir");

    ensure_install_key(&dir).expect("ensure_install_key must succeed");

    let key_path = dir.join("db.key");
    let meta = std::fs::metadata(&key_path).expect("key file must exist");
    let mode = meta.permissions().mode() & 0o777;
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        mode, 0o600,
        "db.key must be 0o600 from creation — got {:#o}",
        mode
    );
}

#[test]
#[cfg(unix)]
fn key_file_creation_refuses_pre_planted_symlink() {
    use persistence_kit::ensure_install_key;

    // Use a uniquely-named temp directory to avoid collision with parallel tests.
    let dir = std::env::temp_dir().join(format!("pk_symlinktest_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    let key_path = dir.join("db.key");

    // Plant a dangling symlink at the key path before the key is created.
    // O_CREAT|O_EXCL must refuse to follow it and must return an error.
    let nowhere = dir.join("_nonexistent_target");
    std::os::unix::fs::symlink(&nowhere, &key_path)
        .expect("failed to create test symlink");

    let result = ensure_install_key(&dir);
    // The symlink must still be there — we must not have overwritten it.
    let symlink_intact = key_path
        .symlink_metadata()
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false);
    let _ = std::fs::remove_dir_all(&dir); // cleanup before assertions
    assert!(
        result.is_err(),
        "ensure_install_key must fail when a symlink already exists at the key path"
    );
    assert!(
        symlink_intact,
        "the pre-planted symlink must still exist after the rejected create"
    );
}

// ─────────────────────────────────────────────────────────────────
// CAND-047 — PostgreSQL identifier injection guard (SECFIX-WS2-PK F2)
//
// validate_sql_identifier is the shared allowlist used by SQLite's
// query_projected and now by PgRowStore::query_projected. These tests
// exercise the function directly (the Postgres backend integration test
// would need a live PG instance; the identifier guard is unit-testable
// through the shared utility).
// ─────────────────────────────────────────────────────────────────

#[test]
fn pg_identifier_guard_rejects_double_quote() {
    // A column name containing '"' can escape the double-quote delimiter in
    // a dynamically-constructed SELECT list even after quoting.
    let result = validate_sql_identifier(r#"col" FROM secrets; --"#);
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "double-quote in pg column name must be rejected"
    );
}

#[test]
fn pg_identifier_guard_rejects_whitespace() {
    let result = validate_sql_identifier("col name");
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "space in pg column name must be rejected"
    );
}

#[test]
fn pg_identifier_guard_accepts_valid_names() {
    // Representative set of valid identifiers that must pass through.
    for name in &["id", "content_hash", "created_at", "_internal", "col1", "Col_2A"] {
        assert!(
            validate_sql_identifier(name).is_ok(),
            "valid identifier {:?} must be accepted",
            name
        );
    }
}

// ─────────────────────────────────────────────────────────────────
// CAND-029 — PostgreSQL TLS config knob and transport (SECFIX-WS2-PK F3)
//
// The postgres-native-tls = "0.5" crate has been approved (C-1 exception
// in DECISION_RUST_POSTGRES_TLS_CRATE_2026-06-28.md) and is compiled in.
// Pool::open_connection now wires Prefer and Require through a real
// MakeTlsConnector (platform TLS stack) rather than returning
// InvalidConfiguration.
//
// Two concerns are covered here:
//  1. Env-var parsing: PostgresTlsMode::from_env() → correct variant.
//  2. Transport wired: Prefer/Require no longer return InvalidConfiguration.
//     Instead they attempt a real network connection. Against a non-existent
//     host (127.0.0.1:9999) the connection is refused immediately
//     (ECONNREFUSED on loopback), yielding BackendError — not
//     InvalidConfiguration. That distinction proves the transport is wired.
// ─────────────────────────────────────────────────────────────────

// ARIA_MCP_POSTGRES_TLS is a process-global env var. Cargo runs the tests in
// one binary across many threads, so separate #[test] fns that set/remove it
// race each other (one test's remove_var wipes another's set_var mid-flight).
// All env-var parsing AND transport-wired cases live in ONE test that owns
// the var sequentially — no shared-state race, no external serialization
// crate (C-1).
#[test]
fn postgres_tls_mode_env_parsing() {
    use persistence_kit::postgres_tls::PostgresTlsMode;

    // ── Part 1: env-var → mode mapping ─────────────────────────────────

    // Absent → Prefer (safe default: attempts TLS, falls back to plaintext —
    // no connection refused on old servers that don't support TLS, but
    // encrypts when the server agrees).
    std::env::remove_var("ARIA_MCP_POSTGRES_TLS");
    assert_eq!(PostgresTlsMode::from_env(), PostgresTlsMode::Prefer);

    // disable → Disable
    unsafe { std::env::set_var("ARIA_MCP_POSTGRES_TLS", "disable") };
    assert_eq!(PostgresTlsMode::from_env(), PostgresTlsMode::Disable);

    // require → Require
    unsafe { std::env::set_var("ARIA_MCP_POSTGRES_TLS", "require") };
    assert_eq!(PostgresTlsMode::from_env(), PostgresTlsMode::Require);

    // prefer (explicit) → Prefer
    unsafe { std::env::set_var("ARIA_MCP_POSTGRES_TLS", "prefer") };
    assert_eq!(PostgresTlsMode::from_env(), PostgresTlsMode::Prefer);

    // Unrecognised value → Prefer (safe default, not Disable).
    unsafe { std::env::set_var("ARIA_MCP_POSTGRES_TLS", "yes_please") };
    assert_eq!(PostgresTlsMode::from_env(), PostgresTlsMode::Prefer);

    std::env::remove_var("ARIA_MCP_POSTGRES_TLS");

    // ── Part 2: transport is wired for Prefer and Require ───────────────
    //
    // Before CAND-029 completion, Prefer and Require returned
    // StorageError::InvalidConfiguration immediately (dep_required_error).
    // Now they attempt a real TLS connection. Against a non-existent host
    // (127.0.0.1 port 9999, unlikely to have a listening server) the
    // connection is refused by the OS (ECONNREFUSED), which maps to
    // StorageError::BackendError. The key assertion: the error is NOT
    // InvalidConfiguration, which proves the transport is compiled in and
    // the fail-closed stub has been removed.
    use persistence_kit::{BackendConfiguration, EstateConfiguration, PostgresStorage, Storage};
    use persistence_kit::error::StorageError;
    use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};

    let dummy_url = "postgres://127.0.0.1:9999/test_tls_probe";
    let probe_schema = SchemaDeclaration::new(
        "TlsProbe",
        1,
        vec![TableDeclaration::new(
            "probe",
            vec![ColumnDeclaration::uuid("id")],
            vec!["id".to_string()],
        )],
    );

    // Prefer mode: connection should fail with BackendError (network), not
    // InvalidConfiguration (transport missing).
    unsafe { std::env::set_var("ARIA_MCP_POSTGRES_TLS", "prefer") };
    let storage_prefer = PostgresStorage::new(EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::Postgresql {
            connection_string: dummy_url.to_string(),
            pool_size: 1,
            connection_timeout_secs: 5.0,
            idle_timeout_secs: 30.0,
        },
    ))
    .expect("PostgresStorage::new must not fail (no I/O at construction)");
    let err_prefer = storage_prefer
        .open(&probe_schema)
        .expect_err("connection to non-existent host must fail");
    assert!(
        matches!(err_prefer, StorageError::BackendError { .. }),
        "Prefer mode must attempt a real connection (BackendError), \
         not return InvalidConfiguration (transport stub). Got: {:?}",
        err_prefer
    );

    // Require mode: same assertion — real connection attempt, not stub.
    unsafe { std::env::set_var("ARIA_MCP_POSTGRES_TLS", "require") };
    let storage_require = PostgresStorage::new(EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::Postgresql {
            connection_string: dummy_url.to_string(),
            pool_size: 1,
            connection_timeout_secs: 5.0,
            idle_timeout_secs: 30.0,
        },
    ))
    .expect("PostgresStorage::new must not fail (no I/O at construction)");
    let err_require = storage_require
        .open(&probe_schema)
        .expect_err("connection to non-existent host must fail");
    assert!(
        matches!(err_require, StorageError::BackendError { .. }),
        "Require mode must attempt a real TLS connection (BackendError), \
         not return InvalidConfiguration (transport stub). Got: {:?}",
        err_require
    );

    std::env::remove_var("ARIA_MCP_POSTGRES_TLS");
}

// ─────────────────────────────────────────────────────────────────
// CAND-029 (c-pg-tls-downgrade) — effective_sslmode no-downgrade guarantee
//
// These are pure-function tests on effective_sslmode + SslModeRank. No live
// server is required. Each test verifies one scenario from the security truth
// table: the effective sslmode is max(env_rank, dsn_rank) and the DSN is
// always the security floor — the env var may only raise, never lower.
// ─────────────────────────────────────────────────────────────────

// Helper: extract the sslmode= value from a connection string (URL or DSN form).
// Used to assert on the rewritten string without coupling to its format.
fn extract_sslmode(s: &str) -> Option<&str> {
    let pos = s.find("sslmode=")?;
    let start = pos + "sslmode=".len();
    let is_url = s.starts_with("postgres://") || s.starts_with("postgresql://");
    let sep = if is_url { '&' } else { ' ' };
    let end = s[start..].find(sep).map(|i| start + i).unwrap_or(s.len());
    Some(&s[start..end])
}

/// env=absent(Prefer) + DSN URL has sslmode=require → effective must stay
/// `require`. Previously, this was silently rewritten to `prefer` (the bug).
#[test]
fn tls_no_downgrade_dsn_require_url_form_preserved() {
    use persistence_kit::postgres_tls::{effective_sslmode, PostgresTlsMode};

    let dsn = "postgres://db.example/app?sslmode=require";
    let (out, use_tls) = effective_sslmode(dsn, PostgresTlsMode::Prefer);

    assert_eq!(
        extract_sslmode(&out),
        Some("require"),
        "DSN sslmode=require must not be downgraded to prefer by env=Prefer"
    );
    assert!(use_tls, "sslmode=require must select a TLS connector");
}

/// env=absent(Prefer) + DSN key-value form has sslmode=require → preserved.
/// DSN form uses space-delimited key=value pairs (not URL query params).
#[test]
fn tls_no_downgrade_dsn_require_dsn_form_preserved() {
    use persistence_kit::postgres_tls::{effective_sslmode, PostgresTlsMode};

    let dsn = "host=db.example dbname=app sslmode=require";
    let (out, use_tls) = effective_sslmode(dsn, PostgresTlsMode::Prefer);

    assert_eq!(
        extract_sslmode(&out),
        Some("require"),
        "DSN-form sslmode=require must not be downgraded to prefer by env=Prefer"
    );
    assert!(use_tls, "sslmode=require must select a TLS connector");
}

/// env=absent(Prefer) + DSN has sslmode=verify-full → preserved verbatim.
/// verify-full ranks higher than require; env=Prefer must not lower it.
#[test]
fn tls_no_downgrade_dsn_verify_full_preserved() {
    use persistence_kit::postgres_tls::{effective_sslmode, PostgresTlsMode};

    let dsn = "postgres://db.example/app?sslmode=verify-full";
    let (out, use_tls) = effective_sslmode(dsn, PostgresTlsMode::Prefer);

    // The string must be returned unchanged — verify-full is already above Prefer.
    assert_eq!(&out, dsn, "verify-full DSN must be returned verbatim");
    assert_eq!(
        extract_sslmode(&out),
        Some("verify-full"),
        "sslmode=verify-full must survive env=Prefer"
    );
    assert!(use_tls, "verify-full must select a TLS connector");
}

/// env=Require + DSN has sslmode=prefer → raised to `require`.
/// The env var is stronger; the connection string must be rewritten upward.
#[test]
fn tls_env_require_raises_dsn_prefer() {
    use persistence_kit::postgres_tls::{effective_sslmode, PostgresTlsMode};

    let dsn = "postgres://db.example/app?sslmode=prefer";
    let (out, use_tls) = effective_sslmode(dsn, PostgresTlsMode::Require);

    assert_eq!(
        extract_sslmode(&out),
        Some("require"),
        "env=Require must raise DSN sslmode=prefer to require"
    );
    assert!(use_tls, "require must select a TLS connector");
}

/// env=Disable + DSN has sslmode=require → effective keeps `require` and
/// mandates a TLS connector. This closes the case where env=Disable would
/// have produced a plaintext (NoTls) connection despite the DSN demanding TLS.
#[test]
fn tls_env_disable_does_not_override_dsn_require() {
    use persistence_kit::postgres_tls::{effective_sslmode, PostgresTlsMode};

    let dsn = "postgres://db.example/app?sslmode=require";
    let (out, use_tls) = effective_sslmode(dsn, PostgresTlsMode::Disable);

    assert_eq!(
        extract_sslmode(&out),
        Some("require"),
        "env=Disable must not overwrite DSN sslmode=require with disable"
    );
    // The TLS connector must be selected (use_tls=true) — the DSN mandates TLS.
    assert!(
        use_tls,
        "env=Disable + DSN sslmode=require must select TLS connector, not NoTls"
    );
}

/// env=Prefer + no DSN sslmode, URL form (no existing query params)
/// → appends sslmode=prefer with '?' separator.
#[test]
fn tls_no_dsn_sslmode_url_no_params_appends_prefer() {
    use persistence_kit::postgres_tls::{effective_sslmode, PostgresTlsMode};

    let dsn = "postgres://db.example/app";
    let (out, use_tls) = effective_sslmode(dsn, PostgresTlsMode::Prefer);

    assert_eq!(
        extract_sslmode(&out),
        Some("prefer"),
        "no existing sslmode + env=Prefer must append sslmode=prefer"
    );
    assert!(out.contains("?sslmode="), "URL with no query params must use '?' separator");
    assert!(use_tls, "prefer must select a TLS connector");
}

/// env=Prefer + no DSN sslmode, URL form WITH existing query params
/// → appends sslmode=prefer with '&' separator.
#[test]
fn tls_no_dsn_sslmode_url_with_params_appends_prefer() {
    use persistence_kit::postgres_tls::{effective_sslmode, PostgresTlsMode};

    let dsn = "postgres://db.example/app?connect_timeout=10";
    let (out, use_tls) = effective_sslmode(dsn, PostgresTlsMode::Prefer);

    assert_eq!(extract_sslmode(&out), Some("prefer"));
    assert!(
        out.contains("&sslmode="),
        "URL with existing params must use '&' separator for sslmode"
    );
    assert!(use_tls);
}

/// env=Prefer + no DSN sslmode, DSN key-value form
/// → appends sslmode=prefer with space separator.
#[test]
fn tls_no_dsn_sslmode_dsn_form_appends_prefer() {
    use persistence_kit::postgres_tls::{effective_sslmode, PostgresTlsMode};

    let dsn = "host=db.example dbname=app";
    let (out, use_tls) = effective_sslmode(dsn, PostgresTlsMode::Prefer);

    assert_eq!(extract_sslmode(&out), Some("prefer"));
    assert!(
        out.starts_with("host=db.example dbname=app sslmode=prefer"),
        "DSN form must append ' sslmode=prefer'"
    );
    assert!(use_tls);
}

/// env=Require + no DSN sslmode → appends sslmode=require.
#[test]
fn tls_no_dsn_sslmode_env_require_appends_require() {
    use persistence_kit::postgres_tls::{effective_sslmode, PostgresTlsMode};

    let dsn = "postgres://db.example/app";
    let (out, use_tls) = effective_sslmode(dsn, PostgresTlsMode::Require);

    assert_eq!(extract_sslmode(&out), Some("require"));
    assert!(use_tls);
}

/// env=Disable + no DSN sslmode → appends sslmode=disable and uses NoTls
/// (use_tls=false). This is the only case where a plaintext connection
/// is legitimate — the operator explicitly chose disable AND the DSN has
/// no sslmode floor to override it.
#[test]
fn tls_env_disable_no_dsn_sslmode_is_plaintext() {
    use persistence_kit::postgres_tls::{effective_sslmode, PostgresTlsMode};

    let dsn = "postgres://loopback/local";
    let (out, use_tls) = effective_sslmode(dsn, PostgresTlsMode::Disable);

    assert_eq!(extract_sslmode(&out), Some("disable"));
    assert!(
        !use_tls,
        "env=Disable + no DSN sslmode must produce use_tls=false (NoTls connector)"
    );
}

/// SslModeRank ordering: disable < allow < prefer < require < verify-ca < verify-full.
/// Tests that the derived Ord is the security ordering we depend on.
#[test]
fn ssl_mode_rank_ordering() {
    use persistence_kit::postgres_tls::SslModeRank;

    assert!(SslModeRank::Disable < SslModeRank::Allow);
    assert!(SslModeRank::Allow < SslModeRank::Prefer);
    assert!(SslModeRank::Prefer < SslModeRank::Require);
    assert!(SslModeRank::Require < SslModeRank::VerifyCa);
    assert!(SslModeRank::VerifyCa < SslModeRank::VerifyFull);
}

/// SslModeRank::from_str and as_str are inverses for all six known values.
#[test]
fn ssl_mode_rank_round_trips() {
    use persistence_kit::postgres_tls::SslModeRank;

    for (s, rank) in &[
        ("disable", SslModeRank::Disable),
        ("allow", SslModeRank::Allow),
        ("prefer", SslModeRank::Prefer),
        ("require", SslModeRank::Require),
        ("verify-ca", SslModeRank::VerifyCa),
        ("verify-full", SslModeRank::VerifyFull),
    ] {
        assert_eq!(SslModeRank::from_str(s), Some(*rank), "from_str({s:?}) failed");
        assert_eq!(rank.as_str(), *s, "as_str() for {rank:?} failed");
    }
    assert_eq!(SslModeRank::from_str("unknown_value"), None);
}

/// An unrecognised DSN sslmode value (e.g. a future libpq value) must be
/// preserved verbatim and must force use_tls=true. We must never overwrite
/// an unknown value that may be stronger than anything in our ranking.
#[test]
fn tls_unrecognised_dsn_sslmode_preserved_verbatim() {
    use persistence_kit::postgres_tls::{effective_sslmode, PostgresTlsMode};

    // "scram-verify-full" is a hypothetical future libpq sslmode value.
    let dsn = "postgres://db.example/app?sslmode=scram-verify-full";
    let (out, use_tls) = effective_sslmode(dsn, PostgresTlsMode::Prefer);

    assert_eq!(&out, dsn, "unrecognised sslmode must be returned verbatim");
    assert!(
        use_tls,
        "unrecognised sslmode must mandate a TLS connector (conservative)"
    );
}

// ─────────────────────────────────────────────────────────────────
// CAND-047 — SQLite backend end-to-end identifier injection guard
// (SECFIX-WS2-PK F7/F9/F10)
//
// These tests drive injection payloads through the real SQLite backend
// (in-memory DB) so the guards fire at the SQL-building layer — one
// seam per concern — not just at the shared utility level. Every
// test that verifies rejection of a bad identifier also verifies that
// the equivalent valid identifier passes (guard is not vacuously
// reject-all).
//
// F9: table name validated in ALL RowStore write+read paths.
// F7: ORDER BY column name validated in query / query_projected / count.
// F10: skip-corrupt projection column name validated in
//      query_projected_skip_corrupt.
// ─────────────────────────────────────────────────────────────────

/// Helper: open an in-memory SqliteStorage with a simple "items" table.
/// Uses path="" (SQLite in-memory mode) so no temp file is needed.
fn make_sqlite_storage() -> persistence_kit::sqlite::SqliteStorage {
    use persistence_kit::{BackendConfiguration, EstateConfiguration, SqliteStorage, Storage};
    use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};

    let storage = SqliteStorage::new(EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: ":memory:".to_string(),
            busy_timeout_secs: 5.0,
        },
    ))
    .expect("SqliteStorage::new must succeed for :memory:");

    let schema = SchemaDeclaration::new(
        "SecFixSQLiteKit",
        1,
        vec![TableDeclaration::new(
            "items",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("label"),
                ColumnDeclaration::bitmap("flags"),
            ],
            vec!["id".to_string()],
        )],
    );
    storage.open(&schema).expect("open schema");
    storage
}

// ── F9: table name injection ────────────────────────────────────

/// `query` with an injection payload as the table name must be rejected
/// with `InvalidIdentifier` before any SQL is built.
#[test]
fn sqlite_f9_query_rejects_injected_table_name() {
    use persistence_kit::{StorageError, Storage};
    let storage = make_sqlite_storage();
    let result = storage.row_store().query(
        r#"items" WHERE 1=1; --"#,
        None,
        &[],
        None,
        None,
    );
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "query with injected table name must be rejected with InvalidIdentifier"
    );
}

/// `query` with a valid table name must succeed (guard is not vacuously reject-all).
#[test]
fn sqlite_f9_query_accepts_valid_table_name() {
    use persistence_kit::Storage;
    let storage = make_sqlite_storage();
    let result = storage.row_store().query("items", None, &[], None, None);
    assert!(result.is_ok(), "query with valid table name must succeed");
}

/// `insert` with an injected table name must be rejected.
#[test]
fn sqlite_f9_insert_rejects_injected_table_name() {
    use persistence_kit::{StorageError, Storage};
    let storage = make_sqlite_storage();
    let mut row = std::collections::BTreeMap::new();
    row.insert("id".to_string(), persistence_kit::TypedValue::Uuid(uuid::Uuid::new_v4()));
    row.insert("label".to_string(), persistence_kit::TypedValue::Text("x".into()));
    row.insert("flags".to_string(), persistence_kit::TypedValue::Bitmap(0));
    let result = storage.row_store().insert(r#"items; DROP TABLE items; --"#, row);
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "insert with injected table name must be rejected"
    );
}

/// `update` with an injected table name must be rejected.
#[test]
fn sqlite_f9_update_rejects_injected_table_name() {
    use persistence_kit::{StorageError, Storage, StoragePredicate};
    let storage = make_sqlite_storage();
    let mut values = std::collections::BTreeMap::new();
    values.insert("label".to_string(), persistence_kit::TypedValue::Text("y".into()));
    let result = storage.row_store().update(
        r#"items" WHERE 1=1; --"#,
        values,
        &StoragePredicate::IsTrue,
    );
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "update with injected table name must be rejected"
    );
}

/// `delete` with an injected table name must be rejected.
#[test]
fn sqlite_f9_delete_rejects_injected_table_name() {
    use persistence_kit::{StorageError, Storage, StoragePredicate};
    let storage = make_sqlite_storage();
    let result = storage.row_store().delete(
        r#"items; DROP TABLE sqlite_master; --"#,
        &StoragePredicate::IsTrue,
    );
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "delete with injected table name must be rejected"
    );
}

/// `count` with an injected table name must be rejected.
#[test]
fn sqlite_f9_count_rejects_injected_table_name() {
    use persistence_kit::{StorageError, Storage};
    let storage = make_sqlite_storage();
    let result = storage.row_store().count(r#"items" UNION SELECT 1; --"#, None);
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "count with injected table name must be rejected"
    );
}

// ── F7: ORDER BY column injection ───────────────────────────────

/// `query` with an injected column name in the ORDER BY clause must be rejected.
#[test]
fn sqlite_f7_query_order_by_rejects_injected_column() {
    use persistence_kit::{Column, Storage, StorageError};
    use persistence_kit::predicate::{OrderClause, OrderDirection};
    let storage = make_sqlite_storage();
    let bad_col = Column::new("items", r#"label" DESC; DROP TABLE items; --"#);
    let order = vec![OrderClause::new(bad_col, OrderDirection::Ascending)];
    let result = storage.row_store().query("items", None, &order, None, None);
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "query ORDER BY with injected column name must be rejected"
    );
}

/// `query` with a valid ORDER BY column name must succeed.
#[test]
fn sqlite_f7_query_order_by_accepts_valid_column() {
    use persistence_kit::{Column, Storage};
    use persistence_kit::predicate::{OrderClause, OrderDirection};
    let storage = make_sqlite_storage();
    let col = Column::new("items", "label");
    let order = vec![OrderClause::new(col, OrderDirection::Ascending)];
    let result = storage.row_store().query("items", None, &order, None, None);
    assert!(result.is_ok(), "query ORDER BY with valid column name must succeed");
}

/// `query_projected` with an injected ORDER BY column name must be rejected.
#[test]
fn sqlite_f7_query_projected_order_by_rejects_injected_column() {
    use persistence_kit::{Column, Storage, StorageError};
    use persistence_kit::predicate::{OrderClause, OrderDirection};
    let storage = make_sqlite_storage();
    let bad_col = Column::new("items", r#"label" DESC; --"#);
    let order = vec![OrderClause::new(bad_col, OrderDirection::Descending)];
    let result = storage.row_store().query_projected("items", &["id", "label"], None, &order, None, None);
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "query_projected ORDER BY with injected column name must be rejected"
    );
}

// ── F7: predicate column injection (end-to-end through SQLite) ──

/// `query` with an injected column name in the predicate (Eq arm) must be rejected.
#[test]
fn sqlite_f7_predicate_eq_rejects_injected_column() {
    use persistence_kit::{Column, Storage, StorageError, StoragePredicate, TypedValue};
    let storage = make_sqlite_storage();
    let bad_col = Column::new("items", r#"id" UNION SELECT 1,2,3; --"#);
    let predicate = StoragePredicate::Eq(bad_col, TypedValue::Text("val".into()));
    let result = storage.row_store().query("items", Some(&predicate), &[], None, None);
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "query with predicate Eq on injected column name must be rejected"
    );
}

/// `query` with a valid predicate column name must succeed.
#[test]
fn sqlite_f7_predicate_eq_accepts_valid_column() {
    use persistence_kit::{Column, Storage, StoragePredicate, TypedValue};
    let storage = make_sqlite_storage();
    let col = Column::new("items", "label");
    let predicate = StoragePredicate::Eq(col, TypedValue::Text("nonexistent".into()));
    let result = storage.row_store().query("items", Some(&predicate), &[], None, None);
    // Predicate is valid even if no rows match.
    assert!(result.is_ok(), "query with valid predicate column name must succeed");
}

/// `delete` with an injected predicate column name must be rejected.
#[test]
fn sqlite_f7_predicate_delete_rejects_injected_column() {
    use persistence_kit::{Column, Storage, StorageError, StoragePredicate, TypedValue};
    let storage = make_sqlite_storage();
    let bad_col = Column::new("items", r#"id"; DROP TABLE items; --"#);
    let predicate = StoragePredicate::Eq(bad_col, TypedValue::Bitmap(0));
    let result = storage.row_store().delete("items", &predicate);
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "delete with injected predicate column name must be rejected"
    );
}

// ── F10: skip-corrupt projection column injection ────────────────

/// `query_projected_skip_corrupt` with an injected projection column name must be rejected.
#[test]
fn sqlite_f10_skip_corrupt_rejects_injected_projection_column() {
    use persistence_kit::{Storage, StorageError};
    let storage = make_sqlite_storage();
    let result = storage.row_store().query_projected_skip_corrupt(
        "items",
        &[r#"id" UNION SELECT 1,2,3; --"#],
        None,
        &[],
        None,
        None,
    );
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "query_projected_skip_corrupt with injected column name must be rejected"
    );
}

/// `query_projected_skip_corrupt` with valid projection columns must succeed.
#[test]
fn sqlite_f10_skip_corrupt_accepts_valid_projection_columns() {
    use persistence_kit::Storage;
    let storage = make_sqlite_storage();
    let result = storage.row_store().query_projected_skip_corrupt(
        "items",
        &["id", "label"],
        None,
        &[],
        None,
        None,
    );
    assert!(result.is_ok(), "query_projected_skip_corrupt with valid columns must succeed");
    let (rows, skipped) = result.unwrap();
    assert!(rows.is_empty(), "freshly-opened table must return zero rows");
    assert_eq!(skipped, 0, "no rows to skip in an empty table");
}

/// `query_projected_skip_corrupt` with an injected table name must be rejected.
#[test]
fn sqlite_f10_skip_corrupt_rejects_injected_table_name() {
    use persistence_kit::{Storage, StorageError};
    let storage = make_sqlite_storage();
    let result = storage.row_store().query_projected_skip_corrupt(
        r#"items" WHERE 1=1; --"#,
        &["id"],
        None,
        &[],
        None,
        None,
    );
    assert!(
        matches!(result, Err(StorageError::InvalidIdentifier { .. })),
        "query_projected_skip_corrupt with injected table name must be rejected"
    );
}

// ─────────────────────────────────────────────────────────────────
// Two-handle encrypted SQLite regression test
//
// Regression for the "NOTADB on second SqliteStorage handle" bug
// observed on Windows ARM (v1.0.5-beta). AriaMcpKit's
// wire_sqlite_semantic_recall opens a SECOND SqliteStorage handle on
// the same WAL-mode encrypted estate. This test confirms whether
// both handles correctly receive the PRAGMA key from the sibling
// db.key — or whether the second handle fails with NOTADB.
//
// On macOS with bundled-sqlcipher-vendored-openssl, resolve_install_encryption
// is called inside SqliteStorage::new for both handles, so PRAGMA key is
// applied to both. The test documents the macOS result so we have a baseline
// before and after the fix of sharing a single Storage handle.
//
// The FIX (sharing the DrawerStore's keyed storage with Corpus/VectorStore
// instead of opening a second handle) is implemented in
// packages/kits/AriaMcpKit/rust/src/estate_registry.rs.
// ─────────────────────────────────────────────────────────────────

/// Opens a fresh encrypted SQLite estate via handle 1 (DrawerStore path),
/// then opens a SECOND independent SqliteStorage on the same file
/// (Corpus/VectorStore path) and asserts whether the second handle
/// can run schema migration.
///
/// Expected result on macOS: PASS — resolve_install_encryption supplies
/// PRAGMA key to both handles via SqliteStorage::new, so the second handle
/// opens the encrypted file correctly.
///
/// Expected result on Windows ARM (reported bug): FAIL — the second handle
/// gets NOTADB, indicating resolve_install_encryption or PRAGMA key is not
/// working correctly for the second connection in that build.
#[test]
fn encrypted_estate_second_sqlite_handle_opens_with_key() {
    use persistence_kit::{
        ensure_install_key, BackendConfiguration, EstateConfiguration, SqliteStorage, Storage,
        TypedValue,
    };
    use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
    use std::collections::BTreeMap;

    // Unique temp dir per test run to avoid cross-test collision.
    let dir = std::env::temp_dir().join(format!(
        "pk_twohandle_{}_{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    let db_path = dir.join("estate.sqlite");
    let db_path_str = db_path.to_string_lossy().into_owned();

    // Step 1: Write the install key — mirrors production resident service behaviour.
    ensure_install_key(&dir).expect("ensure_install_key must succeed");

    // Step 2: Open FIRST handle (mirrors DrawerStore), migrate schema, write a row.
    // This creates the encrypted database file with PRAGMA key.
    let config1 = EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: db_path_str.clone(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage1 = SqliteStorage::new(config1).expect("first handle must open");
    let schema = SchemaDeclaration::new(
        "TwoHandleTestKit",
        1,
        vec![TableDeclaration::new(
            "probe",
            vec![
                ColumnDeclaration::uuid("id"),
                ColumnDeclaration::text("body"),
                ColumnDeclaration::bitmap("flags"),
            ],
            vec!["id".to_string()],
        )],
    );
    storage1.open(&schema).expect("first handle schema migration must succeed");
    let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
    row.insert("id".to_string(), TypedValue::Uuid(uuid::Uuid::new_v4()));
    row.insert("body".to_string(), TypedValue::Text("hello from handle 1".into()));
    row.insert("flags".to_string(), TypedValue::Bitmap(0));
    storage1.row_store().insert("probe", row)
        .expect("insert via first handle must succeed");

    // Step 3: Verify the DB file is actually encrypted.
    // An encrypted SQLite page 1 does NOT start with "SQLite format 3\000" —
    // that header is reserved for plaintext SQLite files. If it IS "SQLite format 3",
    // then SQLCipher is not linked (PRAGMA key is a no-op) and this test's
    // encryption analysis does not apply.
    let raw_header: Vec<u8> = std::fs::read(&db_path).expect("read db file");
    let header_tag = &raw_header[..std::cmp::min(16, raw_header.len())];
    let is_encrypted = header_tag != b"SQLite format 3\x00";
    if !is_encrypted {
        // SQLCipher not linked — PRAGMA key is a no-op. The bug scenario
        // (encrypted file + second handle without key) cannot occur.
        // Clean up and skip the rest of the test by returning early.
        let _ = std::fs::remove_dir_all(&dir);
        eprintln!(
            "SKIP: DB file header is the standard SQLite magic — \
             bundled-sqlcipher-vendored-openssl appears to be a no-op on this build. \
             The NOTADB / two-handle encryption bug cannot be reproduced."
        );
        return;
    }

    // Step 4: Open SECOND handle on the same file — mirrors wire_sqlite_semantic_recall.
    // This is the path that fails with NOTADB on Windows ARM.
    let config2 = EstateConfiguration::new(
        uuid::Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: db_path_str.clone(),
            busy_timeout_secs: 5.0,
        },
    );
    let result_open = SqliteStorage::new(config2)
        .and_then(|s| s.open(&schema).map(|_| s));

    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        result_open.is_ok(),
        "Second SqliteStorage handle on the same encrypted estate must succeed \
         when resolve_install_encryption correctly supplies PRAGMA key. \
         On macOS this is expected to PASS (bug is Windows-ARM-specific). \
         Got error: {:?}",
        result_open.err()
    );
}
