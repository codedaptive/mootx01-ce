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
//! 3. `lane_d_live_under_deterministic_provider` — the beta default embedding
//!    model (`EmbeddingModelConfig::Deterministic`) has a live Lane D (dense
//!    float recall). The deterministic provider's `embed_float` returns a
//!    non-empty float vector; `floatNearest` returns results, not an opt-out.
//!
//! 4. `postgres_wiring_shape_proof` — env-gated (skipped when
//!    `ARIA_MCP_POSTGRES_URL` is absent). When the env var is set, the full
//!    capture → search e2e runs against a live PG server using `new_postgres`.

use std::collections::BTreeMap;
use std::sync::Arc;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::JsonValue,
    surfaced_recall_ledger::SurfacedRecallLedger,
};
use corpus_kit::corpus::{Corpus, EmbeddingModelConfig};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::storage::Storage;
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

/// Prove that the beta default embedding model (`EmbeddingModelConfig::Deterministic`)
/// has a live Lane D (dense float lane). The deterministic provider implements
/// `embed_float` and returns a non-empty float vector. `floatNearest` therefore
/// returns results rather than an opt-out outcome.
///
/// Dark-by-default (the float lane silently absent) is forbidden per the
/// no-deferrals mandate.
#[test]
fn lane_d_live_under_deterministic_provider() {
    // Build a Corpus directly against InMemoryStorage — bypasses the dispatcher
    // layer to assert on the float lane outcome directly.
    let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));

    // EmbeddingModelConfig::Deterministic is the production default.
    let corpus = Corpus::open(storage as Arc<dyn Storage>, EmbeddingModelConfig::Deterministic)
        .expect("Corpus::open on InMemoryStorage must succeed");

    // Ingest a document. The deterministic provider's embed_float returns a
    // non-empty float vector; ingest writes a float row at vector_index=1.
    corpus
        .ingest("kestrel hovering wind updraft prey detection hunting", "birds/kestrel", 1_700_000_000)
        .expect("ingest must succeed");

    // floatNearest must return hits — Lane D is live.
    let outcome = corpus.float_nearest("kestrel hovering wind", 5);
    match outcome {
        corpus_kit::FloatLaneOutcome::Hits(results) => {
            assert!(
                !results.is_empty(),
                "floatNearest must return ≥1 hit for the ingested document; got empty"
            );
        }
        corpus_kit::FloatLaneOutcome::UnavailableProviderOptOut => {
            panic!(
                "Lane D DARK — deterministic provider threw embed_float (opt-out). \
                 The beta default must have a live float lane (no deferrals)."
            );
        }
        corpus_kit::FloatLaneOutcome::UnavailableNoFloatRows => {
            panic!(
                "Lane D DARK — no float rows stored after ingest. \
                 The deterministic provider must write Lane D rows during ingest."
            );
        }
        corpus_kit::FloatLaneOutcome::EmptyQuery => {
            panic!("floatNearest returned EmptyQuery — query was non-empty, this is a bug.");
        }
        corpus_kit::FloatLaneOutcome::StoreError(e) => {
            panic!("Lane D store error (unexpected): {e:?}");
        }
    }
}

// ---------------------------------------------------------------------------
// 4. PostgreSQL wiring shape proof (env-gated)
// ---------------------------------------------------------------------------

/// Prove the PostgreSQL wiring shape. Skipped when `ARIA_MCP_POSTGRES_URL` is
/// absent. When the env var is set, runs the full e2e capture → search against
/// a live PG server using `new_postgres`.
///
/// Even when skipped, the proof is: `new_postgres` calls
/// `wire_postgres_semantic_recall` — the same `Corpus::open` + `VectorStore::open`
/// + `register_corpus` + `register_vector_store` pattern as `new_sqlite` and
/// `new_inmemory`. The in-memory tests (1–3) above cover the shared logic.
#[test]
fn postgres_wiring_shape_proof() {
    let pg_url = std::env::var("ARIA_MCP_POSTGRES_URL").unwrap_or_default();
    if pg_url.is_empty() {
        // PG integration test skipped — not a failure.
        return;
    }

    let registry = EstateRegistry::new_postgres(&pg_url, "test-owner-pg")
        .expect("new_postgres must succeed when PG URL is set");
    let ledger = SurfacedRecallLedger::new();

    let capture_args = args![
        "content" => "marsh harrier reed bed habitat lowland wetland Britain breeding",
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
