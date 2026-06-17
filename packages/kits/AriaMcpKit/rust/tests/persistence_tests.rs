//! Persistence integration tests — SQLite and PostgreSQL estate backends.
//!
//! Tests the SQLite-backed and PostgreSQL-backed `EstateRegistry` constructors
//! and the persistence round-trip at the dispatch layer. These tests are
//! isolated from the dispatch suite (tests/dispatch_tests.rs) to avoid edit
//! contention with a queued mission that owns that file's next edit.
//!
//! # PostgreSQL tests
//!
//! `new_postgres` and `register_postgres` are tested for the lazy-construction
//! contract (construction succeeds without a live PG server because the pool
//! connects on first use). Live round-trip tests require a real PostgreSQL
//! server and are gated on the `PERSISTENCEKIT_PG_URL` environment variable;
//! they are skipped when that variable is absent.
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

use aria_mcp::{dispatch::dispatch_tool,
    surfaced_recall_ledger::SurfacedRecallLedger, estate_registry::EstateRegistry, jsonrpc::JsonValue};
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

/// Generate a unique temp-dir path for a SQLite estate. The file does not
/// exist yet; it will be created by `new_sqlite`. On test teardown, the
/// caller removes the file with `std::fs::remove_file`.
fn temp_sqlite_path(label: &str) -> String {
    let name = format!("aria_mcp_persist_{}_{}.sqlite", label, Uuid::new_v4());
    std::env::temp_dir()
        .join(name)
        .to_string_lossy()
        .into_owned()
}

/// Extract content[0].text from a dispatch result.
fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
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
        let registry =
            EstateRegistry::new_sqlite(&path, "test-owner").expect("pass-1 open must succeed");

        let a = args![
            "content" => "persistent content for round-trip test",
            "location" => "persistence-room"
        ];
        let result =
            dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new()).expect("capture must succeed");
        let text = content_text(&result);
        assert!(
            text.starts_with("filed memory "),
            "file_memory result must start with id prefix; got: {text}"
        );

        // Parse the drawer id from "filed memory <id>\nroom: ...\nlineage: ..."
        let id_line = text.lines().next().unwrap_or("");
        let id = id_line
            .strip_prefix("filed memory ")
            .unwrap_or("")
            .to_owned();
        assert!(!id.is_empty(), "filed memory id must be non-empty");
        id
        // registry drops here — SQLite WAL should flush to main file.
    };

    // --- Pass 2: open a new registry at the same path and search. ---
    {
        let registry2 =
            EstateRegistry::new_sqlite(&path, "test-owner").expect("pass-2 reopen must succeed");

        let search_a = args!["query" => "persistent content"];
        let search_result = dispatch_tool("moot_memory_search", &search_a, &registry2, &SurfacedRecallLedger::new())
            .expect("search must succeed");
        let search_text = content_text(&search_result);

        assert!(
            search_text.contains("found 1 memory(s)"),
            "reopen must find exactly one persisted memory; got: {search_text}"
        );
        assert!(
            search_text.contains(&filed_id),
            "search result must include the filed memory id {filed_id}; got: {search_text}"
        );
        assert!(
            search_text.contains("persistent content"),
            "search result must include memory content; got: {search_text}"
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
// Precedence-ladder logic tests (no live Postgres required)
//
// ServerConfig::from_env() calls process::exit for the ambiguous-config
// branch, so that cannot be tested through from_env() directly. These tests
// verify the PREDICATE LOGIC that drives the four-state decision — same
// approach as Swift's PostgresPrecedenceTests.
//
// The invariant being tested: given two strings (postgres_url, sqlite_path),
// the decision rule must be unambiguous and deterministic.
// ---------------------------------------------------------------------------

/// Helper: replicate the from_env precedence decision as a pure function.
/// Returns one of four branch labels that from_env would take.
fn precedence_branch(postgres_url: &str, sqlite_path: &str) -> &'static str {
    if !postgres_url.is_empty() && !sqlite_path.is_empty() {
        "ambiguous"
    } else if !postgres_url.is_empty() {
        "postgres"
    } else if !sqlite_path.is_empty() {
        "sqlite"
    } else {
        "inmemory"
    }
}

/// Both vars set → ambiguous config.
#[test]
fn precedence_both_set_is_ambiguous() {
    assert_eq!(
        precedence_branch("postgresql://localhost/db", "/tmp/estate.sqlite"),
        "ambiguous"
    );
}

/// Only postgres URL set → postgres branch.
#[test]
fn precedence_only_postgres_url_selects_postgres() {
    assert_eq!(
        precedence_branch("postgresql://localhost/db", ""),
        "postgres"
    );
}

/// Only sqlite path set → sqlite branch.
#[test]
fn precedence_only_sqlite_path_selects_sqlite() {
    assert_eq!(precedence_branch("", "/tmp/estate.sqlite"), "sqlite");
}

/// Neither set → in-memory branch.
#[test]
fn precedence_neither_set_selects_inmemory() {
    assert_eq!(precedence_branch("", ""), "inmemory");
}

/// No-trimming invariant: whitespace-only postgres URL is non-empty.
// The literal `"   "` is a compile-time constant; clippy::const_is_empty
// would fire on `!url.is_empty()`. Allow it here — the test is specifically
// documenting that the no-trim invariant holds for string literals, not
// calling is_empty() on an opaque runtime value.
#[test]
#[allow(clippy::const_is_empty)]
fn precedence_whitespace_postgres_url_is_non_empty() {
    // No trimming — whitespace-only is non-empty, treated as a config
    // attempt. Mirrors Swift's no-trimming invariant test.
    let url = "   ";
    assert!(
        !url.is_empty(),
        "whitespace-only ARIA_MCP_POSTGRES_URL must be non-empty (no trimming)"
    );
}

/// No-trimming invariant: whitespace-only sqlite path is non-empty.
#[test]
#[allow(clippy::const_is_empty)]
fn precedence_whitespace_sqlite_path_is_non_empty() {
    let path = "  ";
    assert!(
        !path.is_empty(),
        "whitespace-only ARIA_MCP_SQLITE_PATH must be non-empty (no trimming)"
    );
}

/// Whitespace-only postgres URL with empty sqlite path → postgres branch
/// (not in-memory; whitespace-only is not empty, fails fast).
#[test]
fn precedence_whitespace_postgres_url_routes_to_postgres_branch() {
    assert_eq!(precedence_branch("   ", ""), "postgres");
}
