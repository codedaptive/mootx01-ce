//! Frozen posture tests — Rust twin of Swift `FrozenPostureTests.swift`.
//!
//! Coverage:
//!   1. A frozen dispatcher refuses `moot_file_memory` / `moot_update_memory`
//!      with the exact isError text and no side effect, allows
//!      `moot_memory_search` and `moot_estate_status`, and reports
//!      `frozen: true`; a live dispatcher reports `frozen: false`.
//!   2. A frozen search then dereference writes no recall-trace rows and
//!      leaves the reward mark untouched (probed through `mark_recall_used`,
//!      which returns the number of rows it flips).
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
    Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", "", None).with_posture(posture)
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

fn first_text(response: &JsonValue) -> &str {
    response["result"]["content"][0]["text"].as_str().unwrap_or("")
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

    // A fresh SQLite estate carries seeded charter drawers, so the memory
    // count is compared line-for-line before and after rather than pinned.
    let memories_line = |status: &str| status.lines().find(|l| l.starts_with("memories: ")).map(str::to_owned);
    let before = first_text(&tools_call(&frozen, "moot_estate_status", serde_json::json!({}))).to_string();
    assert!(memories_line(&before).is_some(), "precondition; got: {before}");
    assert!(before.contains("frozen: true"), "frozen status must report frozen: true; got: {before}");
    assert!(
        before.contains("index_composition_policy: ") && before.find("index_composition_policy: ") < before.find("frozen: "),
        "frozen line sits after index_composition_policy; got: {before}"
    );

    // moot_file_memory refused, exact text, isError.
    let file = tools_call(&frozen, "moot_file_memory",
        serde_json::json!({"content": "must not land", "location": "frozen-room"}));
    assert!(is_error(&file));
    assert_eq!(first_text(&file), "estate is frozen (serve --frozen): moot_file_memory is a mutating tool and was refused");

    // moot_update_memory refused the same way.
    let update = tools_call(&frozen, "moot_update_memory",
        serde_json::json!({"id": id, "mutation": "setSubject", "subject": "must not land"}));
    assert!(is_error(&update));
    assert_eq!(first_text(&update), "estate is frozen (serve --frozen): moot_update_memory is a mutating tool and was refused");

    // No partial side effect: the estate is exactly as it was.
    let after = first_text(&tools_call(&frozen, "moot_estate_status", serde_json::json!({}))).to_string();
    assert_eq!(memories_line(&after), memories_line(&before), "refusal must not file anything; got: {after}");

    // Reads keep working.
    let search = tools_call(&frozen, "moot_memory_search", serde_json::json!({"query": "frozen posture refusal"}));
    assert!(!is_error(&search));
    assert!(first_text(&search).contains(&id), "frozen search must still surface the drawer");

    // teachme touches nothing and is answered even for a refused tool.
    let guide = tools_call(&frozen, "moot_file_memory", serde_json::json!({"teachme": true}));
    assert!(!is_error(&guide));

    let _ = std::fs::remove_file(&path);
}

#[test]
fn live_dispatcher_reports_frozen_false() {
    let live = make_dispatcher(EstateRegistry::new_inmemory(), EstatePosture::Live);
    let status = first_text(&tools_call(&live, "moot_estate_status", serde_json::json!({}))).to_string();
    assert!(status.contains("frozen: false"), "a live dispatcher reports frozen: false; got: {status}");
    let filed = tools_call(&live, "moot_file_memory",
        serde_json::json!({"content": "lands live", "subject": "lands live", "location": "live-room"}));
    assert!(!is_error(&filed), "a live dispatcher files; got: {filed}");
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

    // Frozen search: surfaces the drawer, writes no trace row.
    let search = tools_call(&frozen, "moot_memory_search", serde_json::json!({"query": "frozen trace reward"}));
    assert!(first_text(&search).contains(&id));
    assert_eq!(count_traces(&probe), seeded, "a frozen search must not write recall-trace rows");

    // Frozen dereference: succeeds, marks nothing.
    let get = tools_call(&frozen, "moot_memory_get", serde_json::json!({"id": id}));
    assert!(!is_error(&get), "moot_memory_get is a read and must work when frozen; got: {get}");
    let unmarked = mark_used(&probe, &id);
    assert!(unmarked > 0, "the seeded rows must still be unmarked after a frozen dereference (probe flipped {unmarked})");
    assert_eq!(count_traces(&probe), seeded);

    let _ = std::fs::remove_file(&path);
}
