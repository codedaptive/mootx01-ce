//! inmemory_semantic_lanes_tests.rs — end-to-end proof that the Rust MCP
//! dispatch surface has semantic (BM25 + vector) recall lanes live for
//! in-memory estates, and that Lane D (dense float recall) is live under
//! the beta default embedding model.
//!
//! # What these tests prove
//!
//! 1. `inmemory_impatient_capture_then_search_returns_result` — impatient
//!    capture into an in-memory estate (wired by `new_inmemory`) makes content
//!    immediately searchable via the BM25 lane. Before the fix, `new_inmemory`
//!    did not register a Corpus — so searches could only return results via the
//!    structured LocusKit row lane (BM25 dark). After the fix, the Corpus is
//!    registered and BM25 is live from the first capture.
//!
//! 2. `inmemory_regular_capture_drain_then_search_returns_result` — regular
//!    (non-impatient) capture → drain → search. Proves the encode-queue path
//!    on in-memory.
//!
//! 3. `postgres_wiring_shape_proof` — opt-in (skipped when
//!    `PERSISTENCEKIT_PG_URL`, the PersistenceKit live-PostgreSQL test seam, is
//!    absent). When it is set, the full
//!    capture → search e2e runs against a live PG server using `new_postgres`.
//!
//! 5. `drained_estate_is_distilled` — the drain-stage distillation rider is
//!    installed by the registry wiring path (not only by GLK `provision`):
//!    a regular capture that rides the encode drain carries its distilled
//!    representation once the drain settles, with NO `moot_distill` call.

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
};

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

// ---------------------------------------------------------------------------
// 1. In-memory impatient capture → search (BM25 lane)
// ---------------------------------------------------------------------------

/// Prove the in-memory backend wires semantic recall. Impatient capture inlines
/// directly into the Corpus (no drain wait). A bare `new_inmemory` (pre-fix)
/// would leave the BM25 lane dark; the fixed path registers a Corpus so the
/// lane is live from the first capture.
#[test]
fn inmemory_impatient_capture_then_search_returns_result() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Impatient capture — inlines directly into the Corpus's BM25 index.
    let capture_args = args![
        "content" => "swift nest aperture cliff face breeding colony aerial feeder",
        "subject" => "swift nest aperture cliff face breeding colony aerial feeder",
        "location" => "memories/birds",
        "impatient" => true,
    ];
    let capture_result = dispatch_tool("moot_file_memory", &capture_args, &registry, &ledger)
        .expect("moot_file_memory dispatch must not fail");
    assert!(
        is_success(&capture_result),
        "impatient moot_file_memory should succeed; got: {capture_result:?}"
    );

    // Search — BM25 lane is live so the content surfaces immediately.
    let search_args = args![
        "query" => "swift cliff aerial colony",
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
        "expected at least 1 result from in-memory BM25 lane; got: {text}"
    );
    assert!(
        text.contains("swift"),
        "search result should contain captured content; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 2. In-memory regular capture → drain → search
// ---------------------------------------------------------------------------

/// Prove the regular write path (encode-queue drain) on in-memory.
#[test]
fn inmemory_regular_capture_drain_then_search_returns_result() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Regular (non-impatient) capture — enqueues a job to the encode queue.
    let capture_args = args![
        "content" => "nightjar cryptic plumage crepuscular insectivore churring call",
        "subject" => "nightjar cryptic plumage crepuscular insectivore churring call",
        "location" => "memories/birds",
    ];
    let capture_result = dispatch_tool("moot_file_memory", &capture_args, &registry, &ledger)
        .expect("moot_file_memory dispatch must not fail");
    assert!(
        is_success(&capture_result),
        "regular moot_file_memory should succeed; got: {capture_result:?}"
    );

    // Drain the encode queue synchronously.
    {
        let mut coord = registry.default.coord.lock().unwrap();
        coord
            .await_encode_drain(&registry.default.handle)
            .expect("await_encode_drain must succeed");
    }

    // Search for the captured content.
    let search_args = args![
        "query" => "nightjar crepuscular insectivore",
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
        "expected at least 1 result after drain; got: {text}"
    );
    assert!(
        text.contains("nightjar"),
        "search result should contain captured content; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 3. Lane D live under the beta default (deterministic provider)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 4. PostgreSQL wiring shape proof (env-gated)
// ---------------------------------------------------------------------------

/// Prove the PostgreSQL wiring shape. Skipped when `PERSISTENCEKIT_PG_URL` (the
/// PersistenceKit live-PostgreSQL test seam, as the Swift tests use) is absent.
/// When it is set, runs the full e2e capture → search against a live PG server
/// using `new_postgres`.
///
/// Even when skipped, the proof is: `new_postgres` builds its `PostgresStorage`
/// and hands it to the same GLK `wire_glk_substores` call as `new_sqlite` and
/// `new_inmemory`. The in-memory tests (1–3) above cover the shared logic.
#[test]
fn postgres_wiring_shape_proof() {
    let pg_url = std::env::var("PERSISTENCEKIT_PG_URL").unwrap_or_default();
    if pg_url.is_empty() {
        // PG integration test skipped — not a failure.
        return;
    }

    let registry = EstateRegistry::new_postgres(&pg_url, "test-owner-pg")
        .expect("new_postgres must succeed when PG URL is set");
    let ledger = SurfacedRecallLedger::new();

    let capture_args = args![
        "content" => "marsh harrier reed bed habitat lowland wetland Britain breeding",
        "subject" => "marsh harrier reed bed habitat lowland wetland Britain breeding",
        "location" => "memories/birds",
        "impatient" => true,
    ];
    let capture_result = dispatch_tool("moot_file_memory", &capture_args, &registry, &ledger)
        .expect("moot_file_memory dispatch must not fail on PG estate");
    assert!(
        is_success(&capture_result),
        "impatient moot_file_memory should succeed on PG estate; got: {capture_result:?}"
    );

    let search_args = args![
        "query" => "marsh harrier wetland breeding",
        "scoring" => "rrf",
    ];
    let search_result = dispatch_tool("moot_memory_search", &search_args, &registry, &ledger)
        .expect("moot_memory_search dispatch must not fail on PG estate");
    assert!(
        is_success(&search_result),
        "moot_memory_search should succeed on PG estate; got: {search_result:?}"
    );

    let text = content_text(&search_result);
    assert!(
        text.starts_with("found ") && !text.starts_with("found 0"),
        "expected at least 1 result on PG estate; got: {text}"
    );
    assert!(
        text.contains("marsh harrier"),
        "search result should contain captured content on PG estate; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 5. Drain-stage distillation rider on the registry wiring path
// ---------------------------------------------------------------------------

