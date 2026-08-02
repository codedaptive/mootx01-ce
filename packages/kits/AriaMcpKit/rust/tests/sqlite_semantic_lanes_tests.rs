//! sqlite_semantic_lanes_tests.rs — end-to-end proof that the Rust MCP
//! dispatch surface has semantic (BM25 + vector) recall lanes live for
//! SQLite, in-memory, and `register_sqlite`. PostgreSQL coverage is
//! env-gated and lives in the sibling `inmemory_semantic_lanes_tests.rs`
//! file alongside the other PostgreSQL proof.
//!
//! # What these tests prove
//!
//! SQLite and in-memory backends wire semantic recall — `Corpus` + `VectorStore`
//! are registered after `coord.open`. `moot_memory_search` uses BM25 + vector
//! lanes from the first capture on these backends.
//!
//! # Per-backend wiring policy (mirrors Swift AriaMCPMain.swift)
//!
//! - SQLite (ARIA_MCP_SQLITE_PATH set): semantic recall wired via the DrawerStore's
//!   shared `Storage` connection (passed as `shared_storage` to `wire_sqlite_semantic_recall`).
//!   One connection for ALL sub-stores — LocusKit, Corpus, VectorStore. Matches the
//!   Swift `wireGLKSubstores(for: handle, backingStorage: storage)` pattern exactly.
//!   Fixes the Windows-ARM NOTADB bug where a second independent SqliteStorage handle
//!   on an encrypted WAL-mode estate failed to receive the PRAGMA key.
//! - In-memory (default, neither env var set): semantic recall wired via a
//!   second `InMemoryStorage` handle. Corpus + VectorStore tables are disjoint
//!   from the LocusKit tables — two handles, same ephemeral process.
//! - PostgreSQL: env-gated proof in the sibling `inmemory_semantic_lanes_tests.rs`.
//!
//! # Test coverage
//!
//! 1. `sqlite_impatient_capture_then_search_returns_result` — impatient write
//!    (inline BM25 ingest) → `moot_memory_search` returns the captured content.
//!    No drain wait needed: impatient mode writes directly into the Corpus.
//!
//! 2. `sqlite_regular_capture_drain_then_search_returns_result` — regular write
//!    (encode-queue path) → `await_encode_drain` → `moot_memory_search` returns
//!    the captured content. Proves the full queue+drain+BM25-search path.
//!
//! 3. `inmemory_semantic_recall_is_wired` — in-memory estate HAS a Corpus
//!    registered and capture → search works through BM25/vector lanes.
//!    Proves the new all-backends policy: no dark lanes.
//!
//! 4. `sqlite_semantic_lanes_lit_after_register_sqlite` — `register_sqlite` also
//!    wires semantic recall (same helper as `new_sqlite`).
//!
//! 5. `sqlite_encrypted_estate_semantic_lanes_lit` — encrypted estate (db.key present)
//!    wires semantic recall via the shared DrawerStore storage. Proves the Windows-ARM
//!    fix: Corpus + VectorStore share the already-keyed connection rather than opening
//!    a second independent handle that would see NOTADB on encrypted WAL-mode files.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
};
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

fn is_success(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(false)
}

fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

/// Generate a unique temp path for a SQLite estate, in its OWN subdirectory.
///
/// Each estate gets a private subdir (codefile + unique id) so its
/// `queue.sqlite` sibling — which `EstateConfiguration::queue_sibling` derives
/// from the estate's PARENT directory — is unique per estate. Dropping every
/// estate flat into `temp_dir()` made them all share one `temp_dir()/queue.sqlite`,
/// which accumulated stale in-flight encode jobs across test runs (a test
/// drainer claims a job into `cur`, the process exits before completing it, and
/// the next run's barrier hangs on that orphaned row). A per-estate subdir
/// mirrors production, where each estate lives in its own directory. The file
/// does not exist yet — `new_sqlite` creates it.
fn temp_sqlite_path(label: &str) -> String {
    let dir = std::env::temp_dir()
        .join(format!("aria_mcp_semantic_{}_{}", label, Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("create per-estate temp dir");
    dir.join("estate.sqlite").to_string_lossy().into_owned()
}

// ---------------------------------------------------------------------------
// 1. Impatient capture → search (SQLite, MCP dispatch surface)
// ---------------------------------------------------------------------------

/// Prove the full capture→search path at the MCP dispatch surface for the
/// SQLite-backed estate: impatient write inlines into the Corpus, so a search
/// immediately after capture returns the content without any drain wait.
///
/// This is the primary e2e proof required by the P0 beta blocker: the
/// semantic lanes are LIVE from the first capture on a SQLite registry estate.
#[test]
fn sqlite_impatient_capture_then_search_returns_result() {
    let path = temp_sqlite_path("impatient_e2e");
    let registry = EstateRegistry::new_sqlite(&path, "test-owner")
        .expect("new_sqlite must succeed on a fresh path");
    let ledger = SurfacedRecallLedger::new();

    // File a memory using impatient mode — inlines directly into the Corpus.
    let capture_args = args![
        "content" => "the kingfisher dives from a willow branch",
        "subject" => "the kingfisher dives from a willow branch",
        "location" => "memories/birds",
        "impatient" => true,
    ];
    let capture_result = dispatch_tool("moot_file_memory", &capture_args, &registry, &ledger)
        .expect("moot_file_memory dispatch must not fail");
    assert!(
        is_success(&capture_result),
        "impatient moot_file_memory should succeed; got: {capture_result:?}"
    );

    // Search for the captured content by a keyword from the body.
    // Because the Corpus is registered (SQLite backend, wireSemanticRecall),
    // recall_scored routes through the BM25 lane and finds the drawer.
    let search_args = args![
        "query" => "kingfisher willow",
        "scoring" => "rrf",
    ];
    let search_result = dispatch_tool("moot_memory_search", &search_args, &registry, &ledger)
        .expect("moot_memory_search dispatch must not fail");
    assert!(
        is_success(&search_result),
        "moot_memory_search should succeed; got: {search_result:?}"
    );

    // The search result text must report at least 1 hit and contain the content.
    let text = content_text(&search_result);
    assert!(
        text.starts_with("found ") && !text.starts_with("found 0"),
        "expected at least 1 result; got: {text}"
    );
    assert!(
        text.contains("kingfisher"),
        "search result should contain captured content; got: {text}"
    );

    let _ = std::fs::remove_file(&path);
}

// ---------------------------------------------------------------------------
// 2. Regular capture → drain → search (SQLite, MCP dispatch surface)
// ---------------------------------------------------------------------------

/// Prove the regular write path (encode-queue drain) at the MCP dispatch
/// surface for the SQLite-backed estate: regular write enqueues a job, drain
/// processes it into the Corpus, then search returns the content.
#[test]
fn sqlite_regular_capture_drain_then_search_returns_result() {
    let path = temp_sqlite_path("regular_e2e");
    let registry = EstateRegistry::new_sqlite(&path, "test-owner")
        .expect("new_sqlite must succeed on a fresh path");
    let ledger = SurfacedRecallLedger::new();

    // Regular (non-impatient) capture — enqueues a job to the encode queue.
    let capture_args = args![
        "content" => "the osprey circles above the reservoir",
        "subject" => "the osprey circles above the reservoir",
        "location" => "memories/birds",
    ];
    let capture_result = dispatch_tool("moot_file_memory", &capture_args, &registry, &ledger)
        .expect("moot_file_memory dispatch must not fail");
    assert!(
        is_success(&capture_result),
        "regular moot_file_memory should succeed; got: {capture_result:?}"
    );

    // Drain the encode queue synchronously so the BM25 index is populated
    // before the search. The Rust port has no background drain thread — caller
    // drives drain via await_encode_drain (pump-based, same contract as Swift).
    {
        let mut coord = registry.default.coord.lock().unwrap();
        coord
            .await_encode_drain(&registry.default.handle)
            .expect("await_encode_drain must succeed");
    }

    // Search for the captured content.
    let search_args = args![
        "query" => "osprey reservoir",
        "scoring" => "rrf",
    ];
    let search_result = dispatch_tool("moot_memory_search", &search_args, &registry, &ledger)
        .expect("moot_memory_search dispatch must not fail");
    assert!(
        is_success(&search_result),
        "moot_memory_search should succeed; got: {search_result:?}"
    );

    let text = content_text(&search_result);
    assert!(
        text.starts_with("found ") && !text.starts_with("found 0"),
        "expected at least 1 result; got: {text}"
    );
    assert!(
        text.contains("osprey"),
        "search result should contain captured content; got: {text}"
    );

    let _ = std::fs::remove_file(&path);
}

// ---------------------------------------------------------------------------
// 3. In-memory estate wires semantic recall (all-backends policy)
// ---------------------------------------------------------------------------

/// Confirm the in-memory estate (default when neither env var is set) has a
/// Corpus registered and that impatient capture → search works through the
/// BM25/vector lane. This proves the all-backends semantic recall wiring:
/// no dark lanes on any backend (no deferrals).
#[test]
fn inmemory_semantic_recall_is_wired() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Verify the coordinator has a corpus registered for the default handle.
    // In-memory wiring uses a second InMemoryStorage handle dedicated to the
    // Corpus + VectorStore tables — disjoint from the LocusKit DrawerStore tables.
    let coord = registry.default.coord.lock().unwrap();
    assert!(
        coord.has_corpus(&registry.default.handle),
        "in-memory estate must have a Corpus registered (all-backends semantic recall wiring)"
    );
    drop(coord);

    // Impatient capture → search via BM25 lane must return the content.
    let capture_args = args![
        "content" => "heron standing in shallow water marshland",
        "subject" => "heron standing in shallow water marshland",
        "location" => "memories/birds",
        "impatient" => true,
    ];
    let capture_result = dispatch_tool("moot_file_memory", &capture_args, &registry, &ledger)
        .expect("moot_file_memory dispatch must not fail");
    assert!(is_success(&capture_result), "got: {capture_result:?}");

    // Search via BM25 — the Corpus is registered so the BM25 lane is live.
    let search_args = args![
        "query" => "heron water marshland",
        "scoring" => "rrf",
    ];
    let search_result = dispatch_tool("moot_memory_search", &search_args, &registry, &ledger)
        .expect("moot_memory_search dispatch must not fail");
    assert!(is_success(&search_result), "got: {search_result:?}");

    let text = content_text(&search_result);
    assert!(
        text.starts_with("found ") && !text.starts_with("found 0"),
        "expected at least 1 result from in-memory BM25 lane; got: {text}"
    );
    assert!(
        text.contains("heron"),
        "search result should contain captured content; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 4. register_sqlite also wires semantic recall
// ---------------------------------------------------------------------------

/// `register_sqlite` (used for additional estates beyond the default) wires
/// the same semantic-recall lanes as `new_sqlite`. Capture on the additional
/// estate → impatient → search returns the content.
#[test]
fn sqlite_semantic_lanes_lit_after_register_sqlite() {
    // Start with an in-memory default estate.
    let mut registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Register a second SQLite-backed estate.
    let path = temp_sqlite_path("register_sqlite_e2e");
    let extra_id = registry
        .register_sqlite(&path, "test-owner-extra")
        .expect("register_sqlite must succeed on a fresh path");

    // Verify the additional estate has a Corpus registered.
    // `handle_uuid_for` resolves the registry's estate_id key to the
    // coordinator's EstateHandle UUID (the public bridge method).
    // We retrieve the handle directly from the registry's resolve path.
    let handle = {
        let empty: BTreeMap<String, JsonValue> = BTreeMap::new();
        // Build a fake args map with the estateID so resolve returns the extra estate.
        let mut resolve_args: BTreeMap<String, JsonValue> = BTreeMap::new();
        resolve_args.insert(
            "estateID".to_string(),
            JsonValue::from(serde_json::json!(extra_id.to_string())),
        );
        let open_estate = registry.resolve(&resolve_args, "estateID")
            .expect("registered estate must resolve");
        drop(empty);
        open_estate.handle
    };
    {
        let coord = registry.default.coord.lock().unwrap();
        assert!(
            coord.has_corpus(&handle),
            "register_sqlite estate must have a Corpus registered (semantic recall wired)"
        );
    }

    // Capture into the additional estate using impatient mode (direct coordinator call).
    //
    // We bypass the MCP dispatch surface here because secfix/batch2-aria Item 3
    // restricts direct `estateID` routing to the default estate — a non-default
    // `estateID` in `moot_file_memory` now returns invalidParams by design.
    // This test verifies that `register_sqlite` wires semantic recall lanes
    // correctly, not that the MCP security gate is enforced (that is covered by
    // `testNonDefaultEstateIDIsRefused` in Swift and `resolve_direct` unit tests
    // in Rust). Using `capture_with_mode(Impatient)` reproduces what
    // `moot_file_memory` with `impatient: true` did: inline Corpus ingest so
    // the content is immediately findable via BM25 without an encode-drain wait.
    {
        use genius_locus_kit::WriteMode;
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::estate_types::LatticeAnchor;
        use locus_kit::frames::CaptureFrame;

        let frame = CaptureFrame::new(
            "the egret stalks through marshland",
            CaptureChannel::Typed,
            "memories/birds",
            LatticeAnchor::udc("004"),
            "aria-mcp-tests",
            "default",
        );
        let now = aria_mcp::dispatch::wall_now();
        // capture_with_mode requires &mut self; acquire the lock mutably.
        let mut coord = registry.default.coord.lock().unwrap();
        coord
            .capture_with_mode(&handle, frame, now, WriteMode::Impatient)
            .expect("direct capture_with_mode on register_sqlite estate must succeed");
    }

    // Search the additional estate via direct coordinator recall.
    //
    // Same bypass rationale as capture above: the MCP gate (`resolve_direct`)
    // is not the thing under test here — the Corpus wiring is. We call
    // `recall_scored` with mode=UnionBest and scoring=Rrf to match what
    // `moot_memory_search` with `scoring: "rrf"` dispatches through.
    // Full hydration is required so `drawer.content` is populated in the hits.
    let hits = {
        use genius_locus_kit::recall::{
            GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy,
        };
        use locus_kit::filter::{HydrationLevel, RecallFrame};

        let mut frame = RecallFrame::new(vec![]);
        // Full hydration: content blob required for the content-contains assertion below.
        frame.hydration_level = HydrationLevel::Full;

        let request = GLKRecallRequest::new(frame)
            .with_mode(GLKRecallMode::UnionBest)
            .with_scoring(GLKRecallScoring::Rrf)
            .with_limit(20)
            .with_fallback(RecallFallbackPolicy::AllowDegraded)
            .with_query_text("egret marshland".to_string());

        let now = aria_mcp::dispatch::wall_now();
        let coord = registry.default.coord.lock().unwrap();
        coord
            .recall_scored(&handle, request, now)
            .expect("direct recall_scored on register_sqlite estate must succeed")
            .hits
    };

    assert!(
        !hits.is_empty(),
        "expected at least 1 result on register_sqlite estate; got 0 hits"
    );
    assert!(
        hits.iter().any(|h| h.drawer.as_ref().map_or(false, |d| d.content.contains("egret"))),
        "search result should contain captured content"
    );

    let _ = std::fs::remove_file(&path);
}

// ---------------------------------------------------------------------------
// 5. Encrypted estate wires semantic recall via shared DrawerStore storage
// ---------------------------------------------------------------------------

/// Prove that an encrypted SQLite estate (db.key sibling present) wires
/// semantic recall — Corpus + VectorStore share the DrawerStore's already-keyed
/// `Storage` connection via `wire_sqlite_semantic_recall`.
///
/// This is the regression test for the Windows-ARM NOTADB bug: before the fix,
/// `wire_sqlite_semantic_recall` opened a SECOND `SqliteStorage` handle on the
/// encrypted file. On Windows ARM the second handle failed to apply `PRAGMA key`,
/// returning NOTADB on the first SQL executed by `Corpus::open_many`. The fix
/// shares the DrawerStore's storage (which already received `PRAGMA key`) with
/// all sub-stores, eliminating the second connection entirely.
///
/// On macOS the two-handle path also works (both handles receive the key via
/// `resolve_install_encryption`), so this test verifies the shared-storage path
/// is equally correct on macOS — one connection, all tables, same schema.
#[test]
fn sqlite_encrypted_estate_semantic_lanes_lit() {
    use persistence_kit::ensure_install_key;

    // Create a per-estate subdir so the db.key sibling is estate-local.
    // `resolve_install_encryption` reads the key from the PARENT dir of the
    // estate.sqlite file — exactly the layout `ensure_install_key` writes.
    let dir = std::env::temp_dir()
        .join(format!("aria_mcp_enc_estate_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("create per-estate dir");
    let path = dir.join("estate.sqlite").to_string_lossy().into_owned();

    // Write the install key — mirrors what the resident service does at startup.
    ensure_install_key(&dir).expect("ensure_install_key must succeed");

    // new_sqlite on an encrypted estate: DrawerStore opens the file with
    // PRAGMA key (via resolve_install_encryption), then wire_sqlite_semantic_recall
    // passes that already-keyed storage to Corpus::open_many + VectorStore.
    let registry = EstateRegistry::new_sqlite(&path, "test-owner-enc")
        .expect("new_sqlite must succeed on an encrypted estate");
    let ledger = SurfacedRecallLedger::new();

    // Verify the Corpus is registered — semantic recall lanes are live.
    {
        let coord = registry.default.coord.lock().unwrap();
        assert!(
            coord.has_corpus(&registry.default.handle),
            "encrypted SQLite estate must have a Corpus registered (shared-storage wiring)"
        );
    }

    // Impatient capture → immediate BM25 search via the shared encrypted storage.
    let capture_args = args![
        "content" => "the barn owl hunts at dusk over open fields",
        "subject" => "the barn owl hunts at dusk over open fields",
        "location" => "memories/birds",
        "impatient" => true,
    ];
    let capture_result = dispatch_tool("moot_file_memory", &capture_args, &registry, &ledger)
        .expect("moot_file_memory dispatch must not fail on encrypted estate");
    assert!(
        is_success(&capture_result),
        "impatient moot_file_memory must succeed on encrypted estate; got: {capture_result:?}"
    );

    let search_args = args![
        "query" => "barn owl dusk",
        "scoring" => "rrf",
    ];
    let search_result = dispatch_tool("moot_memory_search", &search_args, &registry, &ledger)
        .expect("moot_memory_search dispatch must not fail on encrypted estate");
    assert!(
        is_success(&search_result),
        "moot_memory_search must succeed on encrypted estate; got: {search_result:?}"
    );

    let text = content_text(&search_result);
    assert!(
        text.starts_with("found ") && !text.starts_with("found 0"),
        "expected at least 1 result from encrypted estate BM25 lane; got: {text}"
    );
    assert!(
        text.contains("barn owl"),
        "search result must contain captured content from encrypted estate; got: {text}"
    );

    // Cleanup — remove the per-estate dir (estate.sqlite, db.key, WAL sidecars).
    let _ = std::fs::remove_dir_all(&dir);
}
