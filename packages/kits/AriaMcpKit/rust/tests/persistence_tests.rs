//! Persistence integration tests — SQLite and PostgreSQL estate backends.
//!
//! Tests the SQLite-backed and PostgreSQL-backed `EstateRegistry` constructors
//! and the persistence round-trip at the dispatch layer. These tests are
//! isolated from the dispatch suite (tests/dispatch_tests.rs) to avoid edit
//! contention with a queued mission that owns that file's next edit.
//!
//! # PostgreSQL tests
//!
//! `new_postgres` and `register_postgres` require a live PostgreSQL server
//! because `DrawerStoreCore::new` initializes the estate manifest on first open.
//! All PostgreSQL tests are gated on the `PERSISTENCEKIT_PG_URL` environment
//! variable and skipped when that variable is absent.
//!
//! # Isolation
//!
//! Each test creates a uniquely-named SQLite database under `std::env::temp_dir()`
//! and removes it on completion. No `tempfile` crate is needed — the same
//! approach used by LocusKit's own SQLite conformance tests.
//!
//! # Round-trip shape
//!
//! The critical persistence invariant: a memory filed through the dispatch
//! layer survives a registry drop and is recoverable by a second registry
//! opened at the same path. This exercises the full WAL flush path
//! (moot_file_memory → SQLite write → process-level drop → reopen → moot_memory_search).

use std::collections::BTreeMap;

mod test_support;
use test_support::SelectedV2Session;

use aria_mcp::{estate_registry::EstateRegistry, jsonrpc::JsonValue};
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helper: build a BTreeMap<String, JsonValue> from key-value pairs.
// ---------------------------------------------------------------------------

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

/// Generate a unique temp path for a SQLite estate, in its OWN subdirectory.
///
/// Each estate gets a private subdir (codefile + unique id) so its
/// `queue.sqlite` sibling — which `EstateConfiguration::queue_sibling` derives
/// from the estate's PARENT directory — is unique per estate. Dropping every
/// estate flat into `temp_dir()` made them all share one `temp_dir()/queue.sqlite`,
/// which accumulated stale in-flight encode jobs across test runs. A per-estate
/// subdir mirrors production, where each estate lives in its own directory. The
/// file does not exist yet; `new_sqlite` creates it.
fn temp_sqlite_path(label: &str) -> String {
    let dir = std::env::temp_dir()
        .join(format!("aria_mcp_persist_{}_{}", label, Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("create per-estate temp dir");
    dir.join("estate.sqlite").to_string_lossy().into_owned()
}

// ---------------------------------------------------------------------------
// Estate-registry unit tests — new_sqlite
// ---------------------------------------------------------------------------

/// `new_sqlite` opens a fresh database and returns a working registry.
/// The default estate is accessible via the resolve path (absent estateID).
#[test]
fn new_sqlite_opens_fresh_database() {
    let path = temp_sqlite_path("fresh");
    let registry = EstateRegistry::new_sqlite(&path, "test-owner")
        .expect("new_sqlite must succeed on a fresh path");

    // Resolving with no estateID should return the default estate — if
    // resolve returns Ok, the estate is alive and in the registry.
    let empty_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    let result = registry.resolve(&empty_args, "estateID");
    assert!(
        result.is_ok(),
        "resolve with absent estateID must return the default estate"
    );

    // Cleanup.
    let _ = std::fs::remove_file(&path);
}

/// `new_sqlite` on an existing database reopens it without error.
/// This exercises the "create if absent, reopen otherwise" contract.
#[test]
fn new_sqlite_reopens_existing_database() {
    let path = temp_sqlite_path("reopen");

    // First open creates the database.
    let _first = EstateRegistry::new_sqlite(&path, "test-owner").expect("first open must succeed");
    drop(_first);

    // Second open at the same path must succeed — no "already exists" error.
    let second = EstateRegistry::new_sqlite(&path, "test-owner");
    assert!(
        second.is_ok(),
        "second open of existing database must succeed"
    );

    let _ = std::fs::remove_file(&path);
}

/// `new_sqlite` on a path whose parent directories do not yet exist SUCCEEDS:
/// PersistenceKit's `SqliteStorage::new` creates the parent dirs
/// (`create_dir_all`) before opening, mirroring Swift `SQLiteConnection.init`'s
/// `createDirectory(withIntermediateDirectories: true)` — intentional
/// fresh-install robustness (e.g. the moot-mgr store on a clean Windows box).
/// A deeply-nested fresh path is therefore provisioned, not rejected.
#[test]
fn new_sqlite_on_nonexistent_parent_creates_dirs_and_succeeds() {
    // A deeply nested path whose parents don't exist yet.
    let path = std::env::temp_dir()
        .join(format!("aria_mcp_no_such_dir_{}", Uuid::new_v4()))
        .join("sub")
        .join("estate.sqlite")
        .to_string_lossy()
        .into_owned();

    let result = EstateRegistry::new_sqlite(&path, "test-owner");
    assert!(
        result.is_ok(),
        "new_sqlite must create missing parent dirs and open the estate"
    );

    // Clean up the file and the directories that were auto-created.
    let _ = std::fs::remove_file(&path);
    if let Some(parent) = std::path::Path::new(&path).parent() {
        let _ = std::fs::remove_dir_all(parent);
    }
}

// ---------------------------------------------------------------------------
// Persistence round-trip — dispatch layer
// ---------------------------------------------------------------------------

/// Full persistence round-trip: file a memory via dispatch, drop the registry
/// (flushes WAL to main file), open a new registry at the same path, and
/// verify the memory is recoverable via moot_memory_search.
///
/// This is the canonical SQLite persistence invariant for the server: data
/// filed during one server process survives restart and is visible to the
/// next process opening the same path.
#[test]
fn persistence_round_trip_capture_then_reopen_then_recall() {
    let path = temp_sqlite_path("roundtrip");

    // --- Pass 1: file a memory. ---
    let filed_id = {
        let session = SelectedV2Session::new(
            EstateRegistry::new_sqlite(&path, "test-owner").expect("pass-1 open must succeed"),
        );

        let a = args![
            "content" => "persistent content for round-trip test",
        "subject" => "persistent content for round-trip test",
            "location" => "persistence-room"
        ];
        let result = session.call("moot_file_memory", &a).expect("capture must succeed");
        let id = result["structuredContent"]["data"]["memory_id"]
            .as_str()
            .unwrap_or("")
            .to_owned();
        assert!(!id.is_empty(), "filed memory id must be non-empty");
        id
        // registry drops here — SQLite WAL should flush to main file.
    };

    // --- Pass 2: open a new registry at the same path and search. ---
    {
        let session = SelectedV2Session::new(
            EstateRegistry::new_sqlite(&path, "test-owner").expect("pass-2 reopen must succeed"),
        );

        let search_a = args!["query" => "persistent content"];
        let search_result = session.call("moot_memory_search", &search_a).expect("search must succeed");
        let rows = search_result["structuredContent"]["data"]["results"]
            .as_array()
            .expect("selected-v2 search rows");

        // The persisted memory must survive reopen and be found. A reopened
        // SQLite estate also re-seeds the seven default wings (each an
        // AI_Charter_Hint memory) — normal drawers now — so the count is not
        // exactly 1. The id + content assertions below prove THIS memory
        // round-tripped; here we only require the search found something.
        assert!(
            !rows.is_empty(),
            "reopen must find the persisted memory; got: {search_result}"
        );
        assert!(
            rows.iter().any(|row| row["memory_id"] == filed_id),
            "search result must include the filed memory id {filed_id}; got: {search_result}"
        );
        assert!(
            rows.iter().any(|row| row["subject"] == "persistent content for round-trip test"),
            "search result must include memory subject; got: {search_result}"
        );
    }

    let _ = std::fs::remove_file(&path);
}

/// Register an additional SQLite estate via `register_sqlite` and verify
/// it is reachable through the `estateID` routing path.
#[test]
fn register_sqlite_estate_is_routable_by_estate_id() {
    let default_path = temp_sqlite_path("register_default");
    let extra_path = temp_sqlite_path("register_extra");

    let mut registry = EstateRegistry::new_sqlite(&default_path, "default-owner")
        .expect("default sqlite open must succeed");

    let extra_uuid = registry
        .register_sqlite(&extra_path, "extra-owner")
        .expect("register_sqlite must succeed");

    // Resolve by the extra estate's UUID — must find it.
    let args = args!["estateID" => extra_uuid.to_string().as_str()];
    let result = registry.resolve(&args, "estateID");
    assert!(
        result.is_ok(),
        "registered sqlite estate must be resolvable by UUID"
    );
    assert_eq!(
        result.unwrap().estate_id,
        extra_uuid,
        "resolved estate_id must match the registered UUID"
    );

    let _ = std::fs::remove_file(&default_path);
    let _ = std::fs::remove_file(&extra_path);
}

// ---------------------------------------------------------------------------
// PostgreSQL estate registry tests (gated on PERSISTENCEKIT_PG_URL)
//
// DrawerStoreCore::new initialises the estate manifest on first open, which
// requires a live database connection. All PostgreSQL registry tests therefore
// need a real PG server and are skipped when PERSISTENCEKIT_PG_URL is absent.
//
// To run these tests locally:
//   export PERSISTENCEKIT_PG_URL="postgresql://user:pass@localhost/test_db"
//   cargo test --test persistence_tests
// ---------------------------------------------------------------------------

/// Helper: read PERSISTENCEKIT_PG_URL; return None if absent or empty.
fn pg_url() -> Option<String> {
    std::env::var("PERSISTENCEKIT_PG_URL")
        .ok()
        .filter(|s| !s.is_empty())
}

/// `new_postgres` opens a PostgreSQL estate. Skipped when PERSISTENCEKIT_PG_URL
/// is absent — requires a live PG server because DrawerStoreCore::new
/// initialises the estate manifest on first open.
#[test]
fn new_postgres_opens_estate_with_live_server() {
    let url = match pg_url() {
        Some(u) => u,
        None => {
            eprintln!(
                "SKIP new_postgres_opens_estate_with_live_server: PERSISTENCEKIT_PG_URL not set"
            );
            return;
        }
    };
    let result = EstateRegistry::new_postgres(&url, "test-owner");
    assert!(
        result.is_ok(),
        "new_postgres must succeed with a live PG server; got: {:?}",
        result.err()
    );
    // Verify the registry resolves the default estate.
    let registry = result.unwrap();
    let empty_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    assert!(
        registry.resolve(&empty_args, "estateID").is_ok(),
        "resolve with absent estateID must return the default postgres estate"
    );
}

/// `register_postgres` opens an additional PostgreSQL estate. Skipped when
/// PERSISTENCEKIT_PG_URL is absent.
#[test]
fn register_postgres_estate_is_routable_by_estate_id() {
    let url = match pg_url() {
        Some(u) => u,
        None => {
            eprintln!("SKIP register_postgres_estate_is_routable_by_estate_id: PERSISTENCEKIT_PG_URL not set");
            return;
        }
    };
    let mut registry = EstateRegistry::new_postgres(&url, "default-owner")
        .expect("default postgres open must succeed");
    let extra_uuid = registry
        .register_postgres(&url, "extra-owner")
        .expect("register_postgres must succeed with a live server");

    let args = args!["estateID" => extra_uuid.to_string().as_str()];
    let result = registry.resolve(&args, "estateID");
    assert!(
        result.is_ok(),
        "registered postgres estate must be resolvable by UUID"
    );
    assert_eq!(
        result.unwrap().estate_id,
        extra_uuid,
        "resolved estate_id must match the registered UUID"
    );
}

// ---------------------------------------------------------------------------
// Geometry normalization — write-survival regression (test 5, MXE-GY)
//
// Verifies that writes through an `EstateRegistry::new_sqlite` handle survive
// a geometry normalization that fires during estate construction.
//
// The bug: when normalization ran AFTER `SqliteDrawerStore::from_path`, the
// connection pointed to the pre-normalization inode (atomically unlinked by
// the rename). All subsequent writes went to the unlinked inode and were
// silently discarded when the fd was closed on registry drop.
//
// RED before Part 1 (normalization after open → data lost).
// GREEN after Part 1 (normalization before open → writes reach canonical file).
// ---------------------------------------------------------------------------

/// Build a SQLite file with per-page reserved bytes = 12 before the first write.
///
/// Uses `SQLITE_FCNTL_RESERVE_BYTES` (opcode 38) so the file header
/// (byte 20) records reserve=12, matching the value Apple SEE sqlite3 sets
/// for per-page IV allocation. Must be called on a fresh path — the reserve
/// cannot be changed after the first page is written.
fn make_reserve12_estate(path: &std::path::Path) -> rusqlite::Result<()> {
    use rusqlite::ffi as sqlite_ffi;
    use rusqlite::{Connection, OpenFlags};
    use std::ffi::c_void;

    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE,
    )?;
    // SQLITE_FCNTL_RESERVE_BYTES (opcode 38): must be called before any write
    // so the page-size calculation in the file header picks up reserve=12.
    let mut reserve_bytes: i32 = 12;
    let rc = unsafe {
        sqlite_ffi::sqlite3_file_control(
            conn.handle(),
            std::ptr::null(), // NULL = "main" database
            38,               // SQLITE_FCNTL_RESERVE_BYTES
            &mut reserve_bytes as *mut i32 as *mut c_void,
        )
    };
    if rc != sqlite_ffi::SQLITE_OK {
        return Err(rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(rc),
            Some(format!("SQLITE_FCNTL_RESERVE_BYTES rc={rc}")),
        ));
    }
    // Write and checkpoint so the reserve propagates from the WAL into the
    // main file header (byte 20) before we close the connection.
    conn.execute_batch("PRAGMA journal_mode = WAL;")?;
    conn.execute_batch(
        "CREATE TABLE fixture_rows (id INTEGER PRIMARY KEY, value TEXT NOT NULL);",
    )?;
    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
    Ok(())
}

/// Write-survival regression: writes through a `new_sqlite` handle must
/// survive a geometry normalization that fires during estate construction.
///
/// Before Part 1 (MXE-GY): normalization renamed the file after `from_path`
/// had already opened a connection. The connection held an fd to the
/// now-unlinked original inode; writes went to that inode and were lost when
/// the fd closed. RED before Part 1, GREEN after.
#[test]
fn new_sqlite_on_reserve12_estate_survives_write_through() {
    // Build a reserve=12 fixture at the canonical path BEFORE calling new_sqlite.
    let path = temp_sqlite_path("reserve12");
    make_reserve12_estate(std::path::Path::new(&path))
        .expect("reserve=12 fixture creation must succeed");

    // Confirm the fixture header before handing the path to EstateRegistry.
    {
        let header = std::fs::read(&path).expect("read fixture");
        assert_eq!(
            header[20], 12,
            "fixture byte 20 must be 12 before calling new_sqlite"
        );
    }

    // Pass 1: open via new_sqlite and file a memory through the returned handle.
    let filed_id = {
        let session = SelectedV2Session::new(
            EstateRegistry::new_sqlite(&path, "test-owner")
                .expect("new_sqlite must open a reserve=12 estate without error"),
        );
        let a = args![
            "content" => "geo-norm write-survival regression marker",
            "subject" => "geo-norm write-survival regression marker",
            "location" => "geo-norm-room"
        ];
        let result = session.call("moot_file_memory", &a)
        .expect("moot_file_memory must succeed on the reserve=12 estate");
        let id = result["structuredContent"]["data"]["memory_id"]
            .as_str()
            .unwrap_or("")
            .to_owned();
        assert!(!id.is_empty(), "filed memory id must be non-empty");
        id
        // registry drops here — WAL is flushed to the main file on drop.
    };

    // Pass 2: reopen at the same canonical path and assert the write survived.
    // After Part 1 the file is reserve=0 and the connection received the writes.
    {
        let session = SelectedV2Session::new(
            EstateRegistry::new_sqlite(&path, "test-owner")
                .expect("pass-2 reopen must succeed on the normalized estate"),
        );
        let search_a = args!["query" => "geo-norm write-survival regression"];
        let result = session.call("moot_memory_search", &search_a)
        .expect("moot_memory_search must succeed on reopen");
        let rows = result["structuredContent"]["data"]["results"]
            .as_array()
            .expect("selected-v2 search rows");
        assert!(
            rows.iter().any(|row| row["memory_id"] == filed_id),
            "write must survive geometry normalization and registry drop: \
             expected id={filed_id} in search result; got: {result}"
        );
        assert!(
            rows.iter().any(|row| row["subject"] == "geo-norm write-survival regression marker"),
            "write subject must survive geometry normalization; got: {result}"
        );
    }

    if let Some(parent) = std::path::Path::new(&path).parent() {
        let _ = std::fs::remove_dir_all(parent);
    }
}

// ---------------------------------------------------------------------------
// B-10a reward wiring: moot_memory_get is a dereference verb (W1 mission)
// ---------------------------------------------------------------------------

/// `moot_memory_get` must mark recall-trace rows as used (B-10a reward path)
/// when the fetched drawer was previously surfaced by `moot_memory_search`.
///
/// Probe pattern: after a successful `moot_memory_get`, call
/// `mark_recall_used` with a window wide enough to cover any trace row
/// written in this test. If `moot_memory_get` already fired the reward path
/// (set `used=true` on all live rows), the probe finds zero rows with
/// `used=false` and returns 0. A non-zero return proves the reward path
/// did NOT fire, which is a B-10a violation.
///
/// Uses a SQLite-backed estate because recall-trace rows are only written
/// on the SQLite backend (in-memory estates cannot test this). Mirrors
/// Swift `memoryGetAfterTracedSearchSetsUsedBit` in `TraceRewardTests.swift`.
#[test]
fn memory_get_after_search_sets_used_bit() {
    let path = temp_sqlite_path("b10a-get-reward");

    let session = SelectedV2Session::new(
        EstateRegistry::new_sqlite(&path, "test-owner").expect("new_sqlite must succeed"),
    );

    // File a memory so the estate is non-empty.
    let drawer_id = {
        let a = args![
            "content" => "memory get reward wiring test",
            "subject" => "memory get reward wiring test",
            "location" => "get-reward-room"
        ];
        let result = session.call("moot_file_memory", &a).expect("moot_file_memory must succeed");
        let id = result["structuredContent"]["data"]["memory_id"]
            .as_str()
            .unwrap_or("")
            .to_owned();
        assert!(!id.is_empty(), "filed memory id must be non-empty; got: {result}");
        id
    };

    // The persistent selected-v2 dispatcher owns the surfaced-id ledger across
    // this search and dereference pair.
    let search_result = session.call("moot_memory_search", &args!["query" => "memory get reward"])
        .expect("moot_memory_search must succeed");
    let rows = search_result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("selected-v2 search rows");
    assert!(
        rows.iter().any(|row| row["memory_id"] == drawer_id),
        "search must surface the filed drawer; got: {search_result}"
    );

    // Verify trace rows were written (B-10a external-origin contract).
    {
        let coord = session.coord.lock().unwrap();
        let trace_count = coord
            .count_recall_traces(&session.default.handle)
            .expect("count_recall_traces");
        assert!(
            trace_count > 0,
            "external search must write recall-trace rows; got count={trace_count}"
        );
    }

    // Dereference through the same selected-v2 dispatcher so note_usage reaches
    // its dispatcher-owned surfaced-id ledger.
    let get_result = session.call("moot_memory_get", &args!["memory_id" => drawer_id.as_str()])
    .expect("moot_memory_get must succeed");
    let is_error = get_result["isError"].as_bool().unwrap_or(true);
    assert!(
        !is_error,
        "moot_memory_get must return a non-error result; got: {get_result}"
    );

    // Probe: call mark_recall_used with a window guaranteed to cover the test's
    // trace rows ([year-2000, year-3000]). If moot_memory_get already set
    // used=true on all rows, the probe finds 0 rows with used=false → returns 0.
    // A non-zero result means memory_get did NOT fire the reward path.
    let probe_count = {
        let coord = session.coord.lock().unwrap();
        coord
            .mark_recall_used(
                &session.default.handle,
                &drawer_id,
                "2000-01-01T00:00:00Z", // since: far past — guaranteed to cover test rows
                "3000-01-01T00:00:00Z", // now: far future — guaranteed to be after recalledAt
            )
            .expect("probe mark_recall_used must not error")
    };
    assert_eq!(
        probe_count, 0,
        "moot_memory_get must fire the B-10a reward path (note_usage → mark_recall_used) \
         before the probe; probe found {probe_count} rows still with used=false"
    );

    if let Some(parent) = std::path::Path::new(&path).parent() {
        let _ = std::fs::remove_dir_all(parent);
    }
}
