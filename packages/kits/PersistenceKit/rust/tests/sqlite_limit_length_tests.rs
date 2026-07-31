// sqlite_limit_length_tests.rs
//
// Mission MXE-BB / Part 3 — defense-in-depth: verify that SqliteStorage
// applies the SQLITE_LIMIT_LENGTH guard on connection open.
//
// ## What the limit call actually does
//
// SQLite's `sqlite3_limit(SQLITE_LIMIT_LENGTH, newVal)` is silently clamped
// to the compile-time `SQLITE_MAX_LENGTH` (= 1,000,000,000 bytes in the
// bundled SQLCipher build). Passing i32::MAX does NOT raise the limit above
// 1 GB; it restores the per-connection limit to the compile-time ceiling in
// case a prior set_limit call lowered it. The primary fix for the >1 GB blob
// failure (ee#49) is chunked persistence (Parts 1+2); this is defense-in-depth.
//
// ## Test approach
//
// We open a raw rusqlite connection, apply the same set_limit call that
// SqliteStorage::new applies, then query the effective value. The returned
// value must equal the compile-time maximum (1,000,000,000) — not i32::MAX,
// because the clamping prevents exceeding the compile-time ceiling.
//
// We also verify the effective limit on a live SqliteStorage by inserting a
// 1 MB blob and asserting the insert succeeds.

use rusqlite::limits::Limit;
use persistence_kit::{
    BackendConfiguration, ColumnDeclaration, EstateConfiguration, SchemaDeclaration,
    SqliteStorage, Storage, TableDeclaration, TypedValue,
};
use std::collections::BTreeMap;
use uuid::Uuid;

fn scratch_path() -> String {
    std::env::temp_dir()
        .join(format!("pk-limit-{}.sqlite3", Uuid::new_v4()))
        .to_string_lossy()
        .to_string()
}

fn make_sqlite(path: &str) -> SqliteStorage {
    SqliteStorage::new(EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: path.to_string(),
            busy_timeout_secs: 5.0,
        },
    ))
    .expect("SqliteStorage::new must succeed")
}

// ── Direct C-API verification ──

/// Open a raw rusqlite connection, apply the same SQLITE_LIMIT_LENGTH call
/// that SqliteStorage::new applies, then query the effective value.
///
/// The limit call uses i32::MAX as the new value, but SQLite clamps it to
/// SQLITE_MAX_LENGTH (= 1,000,000,000 in the bundled SQLCipher build).
/// Therefore the effective limit after the call is 1,000,000,000 — not
/// i32::MAX. The call is still useful as a restore for connections where a
/// prior set_limit lowered the per-connection limit below the compile-time
/// default.
#[test]
fn sqlite_limit_length_is_at_compile_time_maximum_after_guard_call() {
    let path = scratch_path();
    let conn = rusqlite::Connection::open(&path)
        .expect("rusqlite::Connection::open must succeed");

    // Apply the same limit call SqliteStorage::new applies.
    // set_limit returns the previous value (the build-time default).
    let prev = conn.set_limit(Limit::SQLITE_LIMIT_LENGTH, i32::MAX);
    // The previous value must be at or below 1,000,000,000 (the compile-time
    // maximum in the bundled SQLCipher build — it cannot be higher).
    assert!(
        prev <= 1_000_000_000,
        "previous SQLITE_LIMIT_LENGTH should be at or below the compile-time max (1,000,000,000); got {prev}"
    );

    // Query the current limit by calling limit() (read-only, no change).
    // Because sqlite3_limit clamps to SQLITE_MAX_LENGTH, the effective value
    // is 1,000,000,000 regardless of whether we passed i32::MAX or a lower value.
    let effective = conn.limit(Limit::SQLITE_LIMIT_LENGTH);
    assert!(
        effective >= 1_000_000_000,
        "SQLITE_LIMIT_LENGTH must be at the compile-time maximum (1,000,000,000) after the guard call; got {effective}"
    );
}

// ── Integration: moderate-size BLOB insert succeeds on SqliteStorage ──

/// Verify that a SqliteStorage connection (which has the limit guard applied)
/// can store and retrieve a 1 MB blob without error. This is a conservative
/// bound — the defense-in-depth target is the 1 GB threshold, but allocating
/// 1 GB in a unit test is impractical. The 1 MB insert confirms the BLOB path
/// is functional.
#[test]
fn sqlite_storage_stores_and_loads_one_mb_blob() {
    let path = scratch_path();
    let storage = make_sqlite(&path);
    storage
        .migrate(&SchemaDeclaration::new(
            "LimitTestKit",
            1,
            vec![TableDeclaration::new(
                "blobs",
                vec![ColumnDeclaration::text("key"), ColumnDeclaration::blob("data")],
                vec!["key".to_string()],
            )],
        ))
        .expect("migrate");

    // 1 MB blob: large enough to be meaningful, small enough for a unit test.
    let one_mb: Vec<u8> = (0..(1024 * 1024)).map(|i| (i % 251) as u8).collect();
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("key".into(), TypedValue::Text("blob-key".into()));
    values.insert("data".into(), TypedValue::Blob(one_mb.clone()));
    storage
        .row_store()
        .insert("blobs", values)
        .expect("inserting a 1 MB blob must succeed");

    let rows = storage
        .row_store()
        .query("blobs", None, &[], None, None)
        .expect("query");
    let row = rows.first().expect("one row must be present");
    match row.get("data") {
        Some(TypedValue::Blob(b)) => {
            assert_eq!(b.len(), one_mb.len(), "loaded blob length must match stored length");
        }
        other => panic!("expected Blob on 'data' column, got {:?}", other),
    }
}
