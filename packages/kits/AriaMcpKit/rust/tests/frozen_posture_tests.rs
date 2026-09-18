//! Frozen posture tests — Rust twin of Swift `FrozenPostureTests.swift`.
//!
//! Coverage:
//!   1. A frozen dispatcher refuses `moot_file_memory` / `moot_update_memory`
//!      with the v2 estate_frozen error code and no side effect, allows
//!      `moot_memory_search` and `moot_estate_status`, and leaves the memory
//!      count unchanged; a live dispatcher accepts writes.
//!   2. A frozen search then dereference writes no recall-trace rows and
//!      leaves the reward mark untouched (probed through `mark_recall_used`,
//!      which returns the number of rows it flips).
//!   3. `moot_synthesize` reads candidates and generates text; it writes no
//!      drawer, packet, journal, meta, trace, or reward. A frozen dispatcher
//!      must let it through, and the estate must be byte-identical before and
//!      after the call. FRZ-3: moved from MUTATION_TOOLS to FROZEN_READ_TOOLS.
//!
//! The posture is injected with `with_posture`, never through the process
//! environment: std::env is process-global and the test runner is parallel.
//! `EstatePosture` resolution itself is covered by the unit tests in
//! `estate_posture.rs`.

use aria_mcp::dispatcher::Dispatcher;
use aria_mcp::estate_posture::EstatePosture;
use aria_mcp::estate_registry::EstateRegistry;
use aria_mcp::jsonrpc::JSONRPCRequest;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy, RecallOrigin,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::LatticeAnchor;
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;
use serde_json::Value as JsonValue;
use uuid::Uuid;

// Epoch MILLISECONDS for capture/recall `now`; ISO twins for the reward window.
const NOW: i64 = 1_700_000_000_000;
const NOW_ISO: &str = "2023-11-14T22:13:20Z";
const SINCE_FLOOR: &str = "0000-01-01T00:00:00Z";

/// Per-estate temp directory so the queue sibling is unique (mirrors
/// persistence_tests). The file does not exist yet; `new_sqlite` creates it.
fn temp_sqlite_path(label: &str) -> String {
    let dir = std::env::temp_dir().join(format!("aria_mcp_frozen_{}_{}", label, Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("create per-estate temp dir");
    dir.join("estate.sqlite").to_string_lossy().into_owned()
}

fn make_dispatcher(registry: EstateRegistry, posture: EstatePosture) -> Dispatcher {
    Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None).with_posture(posture)
}

fn tools_call(dispatcher: &Dispatcher, tool: &str, args: JsonValue) -> JsonValue {
    let raw = serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": { "name": tool, "arguments": args }
    });
    let request = JSONRPCRequest::decode(&raw).expect("request must decode");
    let response = dispatcher.handle(&request);
    serde_json::to_value(&response).expect("response must serialize")
}

fn is_error(response: &JsonValue) -> bool {
    response["result"]["isError"].as_bool().unwrap_or(false)
}

/// Capture a drawer straight through the coordinator (the estate is shared
/// with the dispatcher built from this registry) and return its id.
fn capture(registry: &EstateRegistry, content: &str) -> String {
    let coord = registry.coord.lock().unwrap();
    let frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "frozen-room",
        LatticeAnchor::udc("0"),
        "frozen-posture-tests",
        "test-embed-v1",
    );
    coord.capture(&registry.default.handle, frame, NOW).expect("capture").id
}

/// One EXTERNAL recall so the surfaced drawer gets recall-trace rows — the
/// seeded state a frozen search must leave untouched.
fn recall_writing_traces(registry: &EstateRegistry) {
    let coord = registry.coord.lock().unwrap();
    let req = GLKRecallRequest::new(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        GLKRecallMode::UnionBest,
        GLKRecallScoring::MatrixAware,
        50,
        RecallFallbackPolicy::FailClosed,
        RecallOrigin::External,
    )
    .with_trace_limit(10);
    coord.recall_scored(&registry.default.handle, req, NOW).expect("recall writing traces");
}

fn count_traces(registry: &EstateRegistry) -> usize {
    let coord = registry.coord.lock().unwrap();
    coord.count_recall_traces(&registry.default.handle).expect("count_recall_traces")
}

/// Rows flipped by the reward mark: non-zero proves the rows were still
/// unmarked when this probe ran.
fn mark_used(registry: &EstateRegistry, target: &str) -> usize {
    let coord = registry.coord.lock().unwrap();
    coord
        .mark_recall_used(&registry.default.handle, target, SINCE_FLOOR, NOW_ISO)
        .expect("mark_recall_used")
}

#[test]
fn frozen_refuses_writers_and_allows_reads() {
    let path = temp_sqlite_path("refusal");
    // Seed one drawer through a registry that is then moved into the frozen
    // dispatcher, so update has a real target and search has a hit.
    let registry = EstateRegistry::new_sqlite(&path, "frozen-tests").expect("open");
    let id = capture(&registry, "frozen posture refusal test");
    let frozen = make_dispatcher(registry, EstatePosture::Frozen);

    // Estate status is a read tool: must succeed even when frozen.
    let before_status = tools_call(&frozen, "moot_estate_status", serde_json::json!({}));
    assert!(!is_error(&before_status), "estate_status is a read and must work when frozen; got: {before_status}");
    let before_count = before_status["result"]["structuredContent"]["data"]["memory_count"]
        .as_u64()
        .expect("memory_count must be a u64");

    // moot_file_memory refused: v2 returns estate_frozen error code in structuredContent.
    let file = tools_call(&frozen, "moot_file_memory",
        serde_json::json!({"content": "must not land", "subject": "must not land", "location": "frozen-room"}));
    assert!(is_error(&file), "moot_file_memory must be refused when frozen; got: {file}");
    assert_eq!(
        file["result"]["structuredContent"]["error"]["code"], "estate_frozen",
        "refusal code must be estate_frozen; got: {file}"
    );

    // moot_update_memory refused the same way (v2 args: memory_id + set_subject mutation).
    let update = tools_call(&frozen, "moot_update_memory",
        serde_json::json!({"memory_id": id, "mutation": "set_subject", "subject": "must not land"}));
    assert!(is_error(&update), "moot_update_memory must be refused when frozen; got: {update}");
    assert_eq!(
        update["result"]["structuredContent"]["error"]["code"], "estate_frozen",
        "refusal code must be estate_frozen; got: {update}"
    );

    // No partial side effect: memory count must be unchanged after refusals.
    let after_status = tools_call(&frozen, "moot_estate_status", serde_json::json!({}));
    assert!(!is_error(&after_status));
    let after_count = after_status["result"]["structuredContent"]["data"]["memory_count"]
        .as_u64()
        .expect("memory_count must be a u64");
    assert_eq!(after_count, before_count, "refusal must not file anything; counts diverged");

    // Reads keep working: search surfaces the seeded drawer via its memory_id.
    let search = tools_call(&frozen, "moot_memory_search", serde_json::json!({"query": "frozen posture refusal"}));
    assert!(!is_error(&search), "moot_memory_search is a read and must work when frozen; got: {search}");
    let results = search["result"]["structuredContent"]["data"]["results"]
        .as_array()
        .expect("results must be an array");
    assert!(
        results.iter().any(|r| r["fetch"]["arguments"]["memory_id"].as_str() == Some(id.as_str())),
        "frozen search must surface the seeded drawer; got: {search}"
    );

    let _ = std::fs::remove_file(&path);
}

#[test]
fn live_dispatcher_reports_no_frozen_refusals() {
    let live = make_dispatcher(EstateRegistry::new_inmemory(), EstatePosture::Live);
    // Estate status returns a valid structured response for a live dispatcher.
    let status = tools_call(&live, "moot_estate_status", serde_json::json!({}));
    assert!(!is_error(&status), "estate_status must succeed for a live dispatcher; got: {status}");
    // A live dispatcher must accept write tools without issuing estate_frozen refusals.
    let filed = tools_call(&live, "moot_file_memory",
        serde_json::json!({"content": "lands live", "subject": "lands live", "location": "live-room"}));
    assert!(!is_error(&filed), "a live dispatcher must file without refusal; got: {filed}");
}

#[test]
fn frozen_search_then_dereference_leaves_traces_unmarked() {
    let path = temp_sqlite_path("traces");
    let seed = EstateRegistry::new_sqlite(&path, "frozen-tests").expect("open");
    let id = capture(&seed, "frozen trace reward test");
    recall_writing_traces(&seed);
    let seeded = count_traces(&seed);
    assert!(seeded > 0, "external recall must seed trace rows");
    // The probe registry reopens the same file: trace counting and the
    // reward mark are SQL over the shared database.
    let probe = EstateRegistry::new_sqlite(&path, "frozen-tests").expect("reopen");
    let frozen = make_dispatcher(seed, EstatePosture::Frozen);

    // Frozen search: surfaces the drawer in v2 structured results, writes no trace row.
    let search = tools_call(&frozen, "moot_memory_search", serde_json::json!({"query": "frozen trace reward"}));
    assert!(!is_error(&search), "frozen search must succeed; got: {search}");
    let results = search["result"]["structuredContent"]["data"]["results"]
        .as_array()
        .expect("results must be an array");
    assert!(
        results.iter().any(|r| r["fetch"]["arguments"]["memory_id"].as_str() == Some(id.as_str())),
        "frozen search must surface the seeded drawer; got: {search}"
    );
    assert_eq!(count_traces(&probe), seeded, "a frozen search must not write recall-trace rows");

    // Frozen dereference: succeeds using v2 memory_id arg, marks nothing.
    let get = tools_call(&frozen, "moot_memory_get", serde_json::json!({"memory_id": id}));
    assert!(!is_error(&get), "moot_memory_get is a read and must work when frozen; got: {get}");
    let unmarked = mark_used(&probe, &id);
    assert!(unmarked > 0, "the seeded rows must still be unmarked after a frozen dereference (probe flipped {unmarked})");
    assert_eq!(count_traces(&probe), seeded);

    let _ = std::fs::remove_file(&path);
}

/// `moot_synthesize` reads candidates and generates text; it writes no drawer,
/// packet, journal, meta, trace, or reward. A frozen dispatcher must let it
/// through, and the estate must be byte-identical before and after the call.
/// FRZ-3: moved from MUTATION_TOOLS to FROZEN_READ_TOOLS.
#[test]
fn frozen_synthesize_proceeds_and_estate_is_unchanged() {
    use aria_mcp::tool_mutation_inventory::{FROZEN_READ_TOOLS, is_frozen_refused};
    let path = temp_sqlite_path("synthesize");
    let registry = EstateRegistry::new_sqlite(&path, "frozen-tests").expect("open");
    // Seed one drawer so synthesize has a candidate pool.
    let _id = capture(&registry, "carbon compounds synthesis test");
    let frozen = make_dispatcher(registry, EstatePosture::Frozen);
    let before = (
        std::fs::read(&path).expect("estate file"),
        std::fs::read(format!("{path}-wal")).unwrap_or_default(),
    );

    let result = tools_call(&frozen, "moot_synthesize",
        serde_json::json!({"query": "carbon compounds", "limit": 5}));
    assert!(!is_error(&result),
        "moot_synthesize is a read and must work when frozen; got: {result:?}");
    let after = (
        std::fs::read(&path).expect("estate file"),
        std::fs::read(format!("{path}-wal")).unwrap_or_default(),
    );
    assert_eq!(after, before, "moot_synthesize must leave the estate byte-identical on disk");
    // The frozen refused-set must no longer name moot_synthesize.
    assert!(!is_frozen_refused("moot_synthesize"),
        "moot_synthesize must not be in the refused set after FRZ-3");
    assert!(FROZEN_READ_TOOLS.contains(&"moot_synthesize"),
        "moot_synthesize must be in the explicit read set after FRZ-3");

    let _ = std::fs::remove_file(&path);
}
