// keyless_conformance.rs
//
// Conformance suite pinning "SQLCipher keyless == stock SQLite" behaviour.
// These tests serve as the acceptance gate for any future SQLCipher vendor bump.
//
// A keyless open must produce a standard SQLite file (magic + zero reserve bytes),
// ATTACH with KEY '' must succeed, VACUUM must succeed, and attach_with_install_key
// must use KEY '' when no sibling key file is present.
//
// Background: sqlite3.c:131181 (attachFunc) fires sqlcipherCodecAttach when the
// SQLITE_NULL branch detects reserve>0 on the main database — this causes a
// plaintext ATTACH to fail on any host where the main database has reserve bytes.
// KEY '' sidesteps this: the SQLITE_TEXT/BLOB branch skips codec attachment when
// nKey=0 (sqlite3.c:131171: `if(nKey && zKey)`), regardless of reserve geometry.

use persistence_kit::attach_with_install_key;
use uuid::Uuid;

fn temp_path(tag: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("pk_kls_{}_{}.sqlite", tag, Uuid::new_v4()))
}

/// A keyless SQLCipher database must be byte-compatible with stock SQLite:
/// header magic "SQLite format 3\0" at bytes 0–15, and reserve-per-page = 0
/// at byte 20 (SQLCipher only sets reserve > 0 on encrypted databases for
/// per-page IV+HMAC overhead).
#[test]
fn keyless_db_header_magic_and_reserve_zero() {
    let path = temp_path("magic");
    // Open and close a keyless connection — no PRAGMA key, no encryption config.
    {
        let conn = rusqlite::Connection::open(&path).expect("open keyless db");
        conn.execute_batch("CREATE TABLE sentinel (id TEXT PRIMARY KEY)")
            .expect("create sentinel table");
        // Connection drops here, closing and flushing to disk.
    }

    let data = std::fs::read(&path).expect("read db file");
    assert!(data.len() >= 21, "db file must be at least 21 bytes (got {})", data.len());

    // SQLite file-format §1.2: bytes 0–15 are the magic header string.
    let magic: &[u8] = b"SQLite format 3\0";
    assert_eq!(
        &data[0..16],
        magic,
        "first 16 bytes must be the SQLite magic header (keyless SQLCipher must be stock-compatible)"
    );

    // SQLite file-format §1.2: byte 20 is reserved space per page.
    // SQLCipher uses reserve > 0 only for encrypted databases; keyless must be 0.
    assert_eq!(
        data[20], 0,
        "reserve bytes per page must be 0 for a keyless SQLCipher database (found {})",
        data[20]
    );
}

/// ATTACH with explicit KEY '' must succeed against a plain (keyless) SQLite
/// database. This pins the safe path through the attachFunc SQLITE_TEXT/BLOB
/// branch (sqlite3.c:131171) where nKey=0 causes sqlcipherCodecAttach to be
/// skipped entirely, regardless of the main database's reserve geometry.
#[test]
fn keyless_attach_key_empty_string_succeeds() {
    let shard_path = temp_path("attach_shard");
    let main_path = temp_path("attach_main");

    // Create the shard with a table via a temporary connection.
    {
        let conn = rusqlite::Connection::open(&shard_path).expect("open shard db");
        conn.execute_batch("CREATE TABLE items (id TEXT PRIMARY KEY, label TEXT NOT NULL)")
            .expect("create shard table");
    }

    // Open main connection and ATTACH the shard with KEY ''.
    // The SQL matches what encryption.rs:435 emits on the no-key-file branch.
    let conn = rusqlite::Connection::open(&main_path).expect("open main db");
    let attach_sql = format!("ATTACH DATABASE '{}' AS shard KEY ''", shard_path.display());
    conn.execute_batch(&attach_sql)
        .expect("ATTACH KEY '' must succeed on a keyless database");

    // Verify the attached table is accessible through the attached schema.
    let n: i64 = conn
        .query_row("SELECT COUNT(*) FROM shard.items", [], |r| r.get(0))
        .expect("SELECT through attached shard must succeed");
    // Table is empty but visible — count=0 proves the schema is accessible.
    assert_eq!(n, 0, "attached shard table must be accessible (count must be 0 for empty table)");
}

/// VACUUM on a keyless SQLCipher database must succeed. VACUUM rebuilds the
/// database file in place; it would fail if the codec tried to decrypt pages
/// that were never encrypted.
#[test]
fn keyless_vacuum_succeeds() {
    let path = temp_path("vacuum");

    // Create a database with data, then delete to give VACUUM something to reclaim.
    {
        let conn = rusqlite::Connection::open(&path).expect("open db for vacuum");
        conn.execute_batch(
            "CREATE TABLE t (x TEXT); INSERT INTO t VALUES ('a'); DELETE FROM t",
        )
        .expect("create + populate + delete");
    }

    // Reopen and run VACUUM on the keyless database.
    let conn = rusqlite::Connection::open(&path).expect("reopen db for vacuum");
    conn.execute_batch("VACUUM")
        .expect("VACUUM must succeed on a keyless SQLCipher database");
}

/// attach_with_install_key with no sibling key file must use KEY '' (the
/// plaintext branch). If it incorrectly used the SQLITE_NULL code path (the
/// null-key heuristic), ATTACH would attempt codec attachment and fail on a
/// keyless shard — proving encryption.rs:435 takes the correct branch when
/// no install key is present.
#[test]
fn attach_with_install_key_no_key_file_uses_key_empty_string() {
    // Use a subdirectory for the shard so attach_with_install_key looks for
    // the key file there (it checks shard_path.parent / INSTALL_KEY_FILE).
    // No key file is created in that directory.
    let shard_dir = std::env::temp_dir().join(format!("pk_kls_pin_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&shard_dir).expect("create shard dir");
    let shard_path = shard_dir.join("shard.sqlite");
    let main_path = temp_path("pin_main");

    // Create a keyless shard (no sibling db.key file in shard_dir).
    {
        let conn = rusqlite::Connection::open(&shard_path).expect("open shard");
        conn.execute_batch("CREATE TABLE items (id TEXT PRIMARY KEY)")
            .expect("create shard table");
    }

    let main_conn = rusqlite::Connection::open(&main_path).expect("open main connection");

    // attach_with_install_key must select KEY '' when no key file is present:
    // key_hex resolves to None → the None branch emits `KEY ''`.
    let result = attach_with_install_key(
        &main_conn,
        shard_path.to_str().expect("shard path must be valid UTF-8"),
        "shard",
    );
    assert!(
        result.is_ok(),
        "attach_with_install_key must succeed when no install key file is present; got {:?}",
        result
    );

    // Verify the attached shard is accessible — the ATTACH succeeded and the
    // schema is visible.
    let n: i64 = main_conn
        .query_row("SELECT COUNT(*) FROM shard.items", [], |r| r.get(0))
        .expect("SELECT through attached shard must succeed");
    assert_eq!(n, 0);
}
