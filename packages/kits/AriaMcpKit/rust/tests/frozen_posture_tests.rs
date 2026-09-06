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
//!   3. `memory` is view-only when frozen: every other command is refused
//!      before the adapter runs, with the estate byte-identical on disk, and
//!      the same delete lands live (the adapter is posture-blind). The
//!      "not recorded in session state" half lives in-crate, beside the
//!      private field it observes (`dispatcher::frozen_command_tests`).
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

/// Serialize the tests that set or clear `MOOTX01_MEMORY_TOOL`: `Dispatcher::new`
/// reads the process environment once at construction, and the test runner is
/// parallel, so tests that mutate the env before constructing a dispatcher must
/// not race with each other.
fn memory_env_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// The on-disk estate: the main database file plus its WAL sibling (the
/// backend runs SQLite in WAL mode, so a write that has not been checkpointed
/// lives in `-wal`). Two snapshots that compare equal prove no byte of
/// committed or pending state changed between them.
fn estate_bytes(path: &str) -> (Vec<u8>, Vec<u8>) {
    (
        std::fs::read(path).expect("estate file"),
        std::fs::read(format!("{path}-wal")).unwrap_or_default(),
    )
}

/// `memory` is classified per call: `view` proceeds and reads; every other
/// command, and a missing or unknown one, is refused before the adapter runs,
/// with the estate byte-identical on disk. The adapter itself is
/// posture-blind: the same `delete` lands through a live dispatcher.
#[test]
fn frozen_memory_tool_is_view_only_and_the_estate_is_untouched() {
    let _guard = memory_env_lock();
    std::env::set_var("MOOTX01_MEMORY_TOOL", "1");
    let path = temp_sqlite_path("memory");
    let file = "/memories/frozen-notes.txt";

    // One file created live, so view has something to read and delete a target.
    let live = make_dispatcher(EstateRegistry::new_sqlite(&path, "frozen-tests").expect("open"), EstatePosture::Live);
    let created = tools_call(&live, "memory",
        serde_json::json!({"command": "create", "path": file, "file_text": "frozen posture view-only test"}));
    assert!(first_text(&created).contains("File created successfully"), "precondition; got: {created}");
    drop(live);

    let frozen = make_dispatcher(EstateRegistry::new_sqlite(&path, "frozen-tests").expect("reopen"), EstatePosture::Frozen);
    let before = estate_bytes(&path);
    let mutating: [(Option<&str>, JsonValue); 7] = [
        (Some("create"), serde_json::json!({"path": "/memories/other.txt", "file_text": "must not land"})),
        (Some("str_replace"), serde_json::json!({"path": file, "old_str": "view-only", "new_str": "must not land"})),
        (Some("insert"), serde_json::json!({"path": file, "insert_line": 0, "insert_text": "must not land"})),
        (Some("delete"), serde_json::json!({"path": file})),
        (Some("rename"), serde_json::json!({"old_path": file, "new_path": "/memories/renamed.txt"})),
        (Some("frobnicate"), serde_json::json!({"path": file})),
        (None, serde_json::json!({"path": file})),
    ];
    for (command, mut args) in mutating {
        if let Some(command) = command {
            args["command"] = JsonValue::String(command.to_owned());
        }
        let response = tools_call(&frozen, "memory", args);
        assert!(is_error(&response), "memory {command:?} must be refused when frozen; got: {response}");
        assert_eq!(first_text(&response), EstatePosture::refusal_message_for_command("memory", command));
    }
    assert_eq!(estate_bytes(&path), before, "refused memory commands must leave the estate byte-identical on disk");

    // view proceeds and reads the live-created file.
    let view = tools_call(&frozen, "memory", serde_json::json!({"command": "view", "path": file}));
    assert!(
        !is_error(&view) && first_text(&view).contains("frozen posture view-only test"),
        "memory view is a read and must work when frozen; got: {view}"
    );
    drop(frozen);

    // The adapter is posture-blind: the same delete lands live.
    let live = make_dispatcher(EstateRegistry::new_sqlite(&path, "frozen-tests").expect("reopen live"), EstatePosture::Live);
    let deleted = tools_call(&live, "memory", serde_json::json!({"command": "delete", "path": file}));
    assert!(first_text(&deleted).starts_with("Successfully deleted"), "live delete must still work; got: {deleted}");
    let gone = tools_call(&live, "memory", serde_json::json!({"command": "view", "path": file}));
    assert!(first_text(&gone).contains("does not exist"), "the deleted file must be gone; got: {gone}");

    std::env::remove_var("MOOTX01_MEMORY_TOOL");
    let _ = std::fs::remove_file(&path);
}

/// `with_memory_tool_enabled` is the construction-time gate: the flag stored at
/// `Dispatcher::new` controls whether `memory` dispatches, regardless of what
/// `MOOTX01_MEMORY_TOOL` contains after construction. Two sub-cases:
///
/// (a) env says enabled; builder says disabled → memory is refused
/// (b) env is unset; builder says enabled → memory view works on a frozen estate
///
/// Extends `frozen_memory_tool_is_view_only_and_the_estate_is_untouched`, which
/// owns the full frozen-posture coverage. This test focuses only on the flag
/// resolution contract.
#[test]
fn memory_tool_enabled_flag_controls_dispatch_not_env() {
    let _guard = memory_env_lock();

    // ── sub-case (a): env on, builder off → memory disabled ──────────────────
    std::env::set_var("MOOTX01_MEMORY_TOOL", "1");
    let path_a = temp_sqlite_path("mem_flag_off");
    let dispatcher_off = Dispatcher::new(
        EstateRegistry::new_sqlite(&path_a, "flag-off-tests").expect("open"),
        "ARIA_MCP_Rust", "test", "test-serial", "", None,
    )
    .with_posture(EstatePosture::Live)
    .with_memory_tool_enabled(false);

    // The env still says "1" at this point. The flag must win.
    let refused = tools_call(
        &dispatcher_off,
        "memory",
        serde_json::json!({"command": "view", "path": "/memories/x.txt"}),
    );
    assert!(
        is_error(&refused),
        "memory must be refused when flag is off, even with MOOTX01_MEMORY_TOOL=1 in env; got: {refused}"
    );
    assert!(
        first_text(&refused).contains("memory tool is disabled"),
        "refusal text must mention 'memory tool is disabled'; got: {}",
        first_text(&refused)
    );
    let _ = std::fs::remove_file(&path_a);

    // ── sub-case (b): env unset, builder on → memory view works frozen ────────
    std::env::remove_var("MOOTX01_MEMORY_TOOL");
    let path_b = temp_sqlite_path("mem_flag_on");
    let file = "/memories/canary.txt";

    // Seed a file via a live dispatcher with the flag on so view has a target.
    let seeder = Dispatcher::new(
        EstateRegistry::new_sqlite(&path_b, "flag-on-tests").expect("open"),
        "ARIA_MCP_Rust", "test", "test-serial", "", None,
    )
    .with_posture(EstatePosture::Live)
    .with_memory_tool_enabled(true);
    let created = tools_call(&seeder, "memory",
        serde_json::json!({"command": "create", "path": file, "file_text": "flag-on canary"}));
    assert!(first_text(&created).contains("File created successfully"), "precondition; got: {created}");
    drop(seeder);

    // Frozen dispatcher with flag on, env still unset: view must succeed.
    let frozen_on = Dispatcher::new(
        EstateRegistry::new_sqlite(&path_b, "flag-on-tests").expect("reopen"),
        "ARIA_MCP_Rust", "test", "test-serial", "", None,
    )
    .with_posture(EstatePosture::Frozen)
    .with_memory_tool_enabled(true);
    let view = tools_call(&frozen_on, "memory",
        serde_json::json!({"command": "view", "path": file}));
    assert!(
        !is_error(&view) && first_text(&view).contains("flag-on canary"),
        "memory view must work when flag is on (env unset) and posture is frozen; got: {view}"
    );
    let _ = std::fs::remove_file(&path_b);
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
    let before = estate_bytes(&path);

    let result = tools_call(&frozen, "moot_synthesize",
        serde_json::json!({"query": "carbon compounds", "limit": 5}));
    assert!(!is_error(&result),
        "moot_synthesize is a read and must work when frozen; got: {result:?}");
    assert_eq!(estate_bytes(&path), before,
        "moot_synthesize must leave the estate byte-identical on disk");
    // The frozen refused-set must no longer name moot_synthesize.
    assert!(!is_frozen_refused("moot_synthesize"),
        "moot_synthesize must not be in the refused set after FRZ-3");
    assert!(FROZEN_READ_TOOLS.contains(&"moot_synthesize"),
        "moot_synthesize must be in the explicit read set after FRZ-3");

    let _ = std::fs::remove_file(&path);
}

