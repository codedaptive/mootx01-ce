//! Dispatch-surface integration tests — Rust version.
//!
//! Exercises the 17 non-routing tools through the full dispatch stack using an
//! in-memory estate (EstateRegistry::new_inmemory). One success path + one error
//! path per tool group. Tests are ordered by the dispatch routing order in
//! dispatch.rs: recipe → lens → lexicon.
//!
//! # Design
//!
//! Tests call aria_mcp::dispatch::dispatch_tool directly (not through the stdio
//! framing loop) — the dispatch layer is what Adams' finding targets. The estate
//! registry is constructed fresh per group so each group starts with a clean estate.
//!
//! # Result shape conventions
//!
//! Success results: isError == false, content[0].text contains expected fragment.
//! Tool-level refusals (expected errors): isError == true, content[0].text carries
//! the message. These are on the isError path, not transport faults (Err(JSONRPCError)).
//! Out-of-band faults (bad estateID, missing required args): Err(JSONRPCError).

use std::collections::BTreeMap;

use aria_mcp::{
    dispatch::dispatch_tool,
    estate_registry::EstateRegistry,
    jsonrpc::{JSONRPCErrorCode, JsonValue},
};

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Build a BTreeMap<String, JsonValue> from key-value pairs.
/// Accepts serde_json::Value (converted via From impl) for ergonomics.
macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

/// Extract content[0].text from a dispatch success result.
fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

/// True when the result has isError == false (success result shape).
fn is_success(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(false)
}

/// True when the result has isError == true (tool-level refusal shape).
fn is_tool_error(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(true)
}

// ---------------------------------------------------------------------------
// Helper: capture a drawer into the default estate and return its id string.
// ---------------------------------------------------------------------------

fn capture_one_drawer(registry: &EstateRegistry, content: &str, room: &str) -> String {
    let a = args![
        "content" => content,
        "room" => room,
        "udcCode" => "000.000",
        "addedBy" => "test-agent",
        "embeddingModelID" => "test-model"
    ];
    let result = dispatch_tool("moot_capture_drawer", &a, registry).expect("capture must succeed");
    assert!(is_success(&result), "capture should be a success result");
    let text = content_text(&result);
    // text is "captured drawer <id>\nroom: ...\nscheme: ..."
    let id_line = text.lines().next().unwrap_or("");
    id_line
        .strip_prefix("captured drawer ")
        .unwrap_or("")
        .to_owned()
}

// ---------------------------------------------------------------------------
// 1. moot_list_recipes
// ---------------------------------------------------------------------------

#[test]
fn list_recipes_returns_catalog_entries() {
    // Dispatches moot_list_recipes and verifies it succeeds with a non-empty
    // catalog. The exact count is the worktree's runtime catalog size (the
    // cognition-kit catalog in this branch); we assert at least 1 entry and
    // the "recipes: N" header format, not a hardcoded count, so this test
    // remains correct regardless of catalog growth.
    let registry = EstateRegistry::new_inmemory();
    let result =
        dispatch_tool("moot_list_recipes", &args![], &registry).expect("list_recipes must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    // Result starts with "recipes: N" where N >= 1.
    assert!(
        text.starts_with("recipes: "),
        "result should start with 'recipes: N'; got: {text}"
    );
    let count_str = text
        .strip_prefix("recipes: ")
        .and_then(|rest| rest.split('\n').next())
        .unwrap_or("0");
    let count: usize = count_str.trim().parse().unwrap_or(0);
    assert!(
        count >= 1,
        "recipe catalog must have at least one entry; got count={count}; full text: {text}"
    );
}

#[test]
fn list_recipes_unknown_tool_name_returns_method_not_found() {
    // Routing guard: an unknown tool name returns JSONRPCError (not a tool result).
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool("moot_nonexistent_tool", &args![], &registry)
        .expect_err("unknown tool must error");
    assert_eq!(err.code, JSONRPCErrorCode::METHOD_NOT_FOUND);
}

// ---------------------------------------------------------------------------
// 2. Lens tools — capture tunnels then run keystones; error path via partial_cue_recall
// ---------------------------------------------------------------------------

#[test]
fn capture_tunnel_then_keystones_ranks_hub() {
    let registry = EstateRegistry::new_inmemory();

    // Capture source and target drawers to satisfy the tunnel edge.
    let src_id = capture_one_drawer(&registry, "source content", "hub-room");
    let tgt_id = capture_one_drawer(&registry, "target content", "spoke-room");

    // Capture a tunnel connecting them in wing "test-wing".
    let a = args![
        "sourceWing" => "test-wing",
        "sourceRoom" => "hub-room",
        "targetWing" => "test-wing",
        "targetRoom" => "spoke-room",
        "kind" => "relates",
        "addedBy" => "test-agent",
        "sourceDrawerID" => src_id.as_str(),
        "targetDrawerID" => tgt_id.as_str()
    ];
    let t_result =
        dispatch_tool("moot_capture_tunnel", &a, &registry).expect("capture_tunnel must succeed");
    assert!(is_success(&t_result), "tunnel capture should succeed");
    let t_text = content_text(&t_result);
    assert!(
        t_text.starts_with("captured tunnel "),
        "expected tunnel id; got: {t_text}"
    );

    // moot_keystones on "test-wing" — should return a non-empty ranked list.
    let k_args = args!["wing" => "test-wing"];
    let k_result =
        dispatch_tool("moot_keystones", &k_args, &registry).expect("keystones must succeed");
    assert!(is_success(&k_result));
    let k_text = content_text(&k_result);
    assert!(
        k_text.contains("keystones:"),
        "result should contain 'keystones:'; got: {k_text}"
    );
}

#[test]
fn partial_cue_recall_unknown_anchor_returns_tool_error_not_transport_fault() {
    // An unknown anchorID should produce isError:true (tool-level refusal),
    // not a JSONRPCError transport fault. This is the critical error-path
    // discipline the Swift server follows.
    let registry = EstateRegistry::new_inmemory();
    let a = args![
        "anchorID" => "definitely-does-not-exist-00000000"
    ];
    let result = dispatch_tool("moot_partial_cue_recall", &a, &registry)
        .expect("partial_cue_recall must not throw transport fault for unknown anchor");
    assert!(
        is_tool_error(&result),
        "unknown anchor should produce isError:true tool result, not transport fault; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        !text.is_empty(),
        "error result must carry a message; got empty text"
    );
}

// ---------------------------------------------------------------------------
// 3. moot_grounded_synthesis — over captured drawers
// ---------------------------------------------------------------------------

#[test]
fn grounded_synthesis_over_captured_drawers_succeeds() {
    let registry = EstateRegistry::new_inmemory();

    // Pre-populate the estate with a couple of drawers.
    capture_one_drawer(&registry, "Meeting notes from sprint review", "work");
    capture_one_drawer(&registry, "Personal goal: finish the book", "personal");

    let a = args![];
    let result = dispatch_tool("moot_grounded_synthesis", &a, &registry)
        .expect("grounded_synthesis must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.starts_with("grounded_synthesis:"),
        "result should start with 'grounded_synthesis:'; got: {text}"
    );
}

#[test]
fn grounded_synthesis_with_unknown_estate_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let a = args!["estateID" => "00000000-0000-0000-0000-000000000000"];
    let err = dispatch_tool("moot_grounded_synthesis", &a, &registry)
        .expect_err("unknown estateID must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "unknown estateID must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

// ---------------------------------------------------------------------------
// 4. moot_run_migration_benchmark + moot_confirm_migration_promotion
// ---------------------------------------------------------------------------

/// Helper: build and dispatch moot_run_migration_benchmark with two entries
/// and one plan, returning the result text. Shared by confirm tests that
/// need a real run first.
fn run_benchmark_for_confirm(registry: &EstateRegistry) -> (String, String) {
    let mut a: BTreeMap<String, JsonValue> = BTreeMap::new();
    a.insert(
        "corpusName".into(),
        JsonValue::from(serde_json::json!("test-corpus")),
    );
    a.insert(
        "entries".into(),
        JsonValue::from(serde_json::json!([
            { "id": "e1", "content": "content one" },
            { "id": "e2", "content": "content two" }
        ])),
    );
    a.insert(
        "plans".into(),
        JsonValue::from(serde_json::json!([{
            "name": "plan-alpha",
            "room": "test-room",
            "latticeCode": "000.000",
            "embeddingModelID": "test-model"
        }])),
    );
    let result = dispatch_tool("moot_run_migration_benchmark", &a, registry)
        .expect("run_migration_benchmark must succeed");
    assert!(is_success(&result), "run must succeed; got: {result:?}");
    let text = content_text(&result).to_owned();

    // Parse the winner branch id from: "winner: plan 'plan-alpha' branch <UUID>"
    let winner_bid = text
        .lines()
        .find(|l| l.starts_with("winner: plan "))
        .and_then(|l| l.split_whitespace().last())
        .expect("winner line must carry branch id")
        .to_owned();

    // Collect ranking branch ids from: "  - plan-alpha [<UUID>] score=..."
    // Exclude the winner from discardBranchIDs — caller may pass it separately.
    (winner_bid, text)
}

#[test]
fn run_migration_benchmark_happy_path_returns_rankings() {
    // Dispatches moot_run_migration_benchmark and verifies the result structure.
    // Exercises the full live substrate path: derive → capture → benchmark.
    let registry = EstateRegistry::new_inmemory();
    let (winner_bid, text) = run_benchmark_for_confirm(&registry);
    assert!(
        text.contains("run_migration_benchmark:"),
        "result should contain benchmark header; got: {text}"
    );
    assert!(
        text.contains("rankings:"),
        "result should contain rankings section; got: {text}"
    );
    assert!(
        !winner_bid.is_empty(),
        "winner branch id must be present; got: {text}"
    );
}

#[test]
fn confirm_migration_promotion_success_end_to_end() {
    // Full two-call pattern: run_migration_benchmark then confirm with the
    // branch ids parsed from the run result. Confirms is_success and the
    // promoted/discarded count text.
    let registry = EstateRegistry::new_inmemory();
    let (winner_bid, _text) = run_benchmark_for_confirm(&registry);

    // Only one plan so no discard ids (the other plans list is empty).
    let mut confirm_args: BTreeMap<String, JsonValue> = BTreeMap::new();
    confirm_args.insert(
        "winnerBranchID".into(),
        JsonValue::from(serde_json::json!(winner_bid)),
    );
    confirm_args.insert(
        "discardBranchIDs".into(),
        JsonValue::from(serde_json::json!([])),
    );
    confirm_args.insert(
        "disqualifiedBranchIDs".into(),
        JsonValue::from(serde_json::json!([])),
    );

    let result = dispatch_tool("moot_confirm_migration_promotion", &confirm_args, &registry)
        .expect("confirm must not throw transport fault");
    assert!(
        is_success(&result),
        "confirm must be a success result; got: {result:?}"
    );
    let confirm_text = content_text(&result);
    assert!(
        confirm_text.contains("confirm_migration_promotion:"),
        "success text must name the tool; got: {confirm_text}"
    );
    assert!(
        confirm_text.contains(&winner_bid),
        "success text must mention promoted branch id; got: {confirm_text}"
    );
    assert!(
        confirm_text.contains("discarded"),
        "success text must mention discard count; got: {confirm_text}"
    );
}

#[test]
fn confirm_migration_promotion_disqualified_winner_returns_tool_error() {
    // Passing the winner's id in disqualifiedBranchIDs triggers C-5 guard →
    // isError:true tool result (not a transport fault).
    let registry = EstateRegistry::new_inmemory();
    let (winner_bid, _text) = run_benchmark_for_confirm(&registry);

    let mut a: BTreeMap<String, JsonValue> = BTreeMap::new();
    a.insert(
        "winnerBranchID".into(),
        JsonValue::from(serde_json::json!(winner_bid.clone())),
    );
    a.insert(
        "discardBranchIDs".into(),
        JsonValue::from(serde_json::json!([])),
    );
    // Treat winner as disqualified.
    a.insert(
        "disqualifiedBranchIDs".into(),
        JsonValue::from(serde_json::json!([winner_bid])),
    );

    let result = dispatch_tool("moot_confirm_migration_promotion", &a, &registry)
        .expect("disqualified winner must return tool error, not transport fault");
    assert!(
        is_tool_error(&result),
        "disqualified winner must be isError:true; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.to_lowercase().contains("silentconceptloss") || text.contains("lost"),
        "error text should indicate silent concept loss; got: {text}"
    );
}

#[test]
fn confirm_migration_promotion_unknown_winner_returns_tool_error() {
    // An id that was never minted by the coordinator triggers UserConfirmationRequired
    // (guard 2) → isError:true tool result.
    let registry = EstateRegistry::new_inmemory();
    let unknown_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

    let mut a: BTreeMap<String, JsonValue> = BTreeMap::new();
    a.insert(
        "winnerBranchID".into(),
        JsonValue::from(serde_json::json!(unknown_id)),
    );
    a.insert(
        "discardBranchIDs".into(),
        JsonValue::from(serde_json::json!([])),
    );
    a.insert(
        "disqualifiedBranchIDs".into(),
        JsonValue::from(serde_json::json!([])),
    );

    let result = dispatch_tool("moot_confirm_migration_promotion", &a, &registry)
        .expect("unknown winner must return tool error, not transport fault");
    assert!(
        is_tool_error(&result),
        "unknown winner must be isError:true; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("unknown branch") || text.contains("userConfirmationRequired"),
        "error text should indicate unknown branch; got: {text}"
    );
}

#[test]
fn confirm_migration_promotion_malformed_winner_returns_invalid_params() {
    // A winnerBranchID that is not a valid UUID string must produce a
    // JSONRPCError with INVALID_PARAMS code (transport-level fault), not
    // a tool result — parsing happens before any dispatch.
    let registry = EstateRegistry::new_inmemory();
    let mut a: BTreeMap<String, JsonValue> = BTreeMap::new();
    a.insert(
        "winnerBranchID".into(),
        JsonValue::from(serde_json::json!("not-a-uuid")),
    );

    let err = dispatch_tool("moot_confirm_migration_promotion", &a, &registry)
        .expect_err("malformed winnerBranchID must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "malformed winnerBranchID must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

#[test]
fn confirm_migration_promotion_missing_winner_returns_invalid_params() {
    // Omitting winnerBranchID entirely must produce a JSONRPCError
    // INVALID_PARAMS (required argument missing).
    let registry = EstateRegistry::new_inmemory();
    let a: BTreeMap<String, JsonValue> = BTreeMap::new();

    let err = dispatch_tool("moot_confirm_migration_promotion", &a, &registry)
        .expect_err("missing winnerBranchID must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "missing winnerBranchID must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

// ---------------------------------------------------------------------------
// 5. Lexicon round-trip: moot_capture_drawer → moot_drawer_recall
// ---------------------------------------------------------------------------

#[test]
fn capture_drawer_then_drawer_recall_round_trips() {
    let registry = EstateRegistry::new_inmemory();

    let content = "integration test content for round-trip";
    let a = args![
        "content" => content,
        "room" => "test-room",
        "udcCode" => "000.001",
        "addedBy" => "test-agent",
        "embeddingModelID" => "test-model"
    ];
    let cap_result =
        dispatch_tool("moot_capture_drawer", &a, &registry).expect("capture must succeed");
    assert!(is_success(&cap_result));
    let cap_text = content_text(&cap_result);
    assert!(
        cap_text.starts_with("captured drawer "),
        "capture result should start with drawer id; got: {cap_text}"
    );
    // Echoes the scheme (default udc).
    assert!(
        cap_text.contains("scheme: udc"),
        "capture result should echo scheme; got: {cap_text}"
    );

    // Recall from the estate and verify the row is present.
    let recall_a = args!["limit" => 10];
    let recall_result =
        dispatch_tool("moot_drawer_recall", &recall_a, &registry).expect("recall must succeed");
    assert!(is_success(&recall_result));
    let recall_text = content_text(&recall_result);
    assert!(
        recall_text.starts_with("recalled 1 drawer(s)"),
        "should recall exactly one drawer; got: {recall_text}"
    );
    // Use a substring of the content that is guaranteed to fit; the recall
    // handler caps each row at 80 chars via content[..content.len().min(80)].
    let content_prefix = &content[..content.len().min(20)];
    assert!(
        recall_text.contains(content_prefix),
        "recalled text should include the captured content; got: {recall_text}"
    );
}

#[test]
fn capture_drawer_with_mdcc_scheme_echoes_mdcc() {
    let registry = EstateRegistry::new_inmemory();
    let a = args![
        "content" => "mdcc test content",
        "room" => "test-room",
        "udcCode" => "000.000",
        "classificationScheme" => "mdcc",
        "addedBy" => "test-agent",
        "embeddingModelID" => "test-model"
    ];
    let result = dispatch_tool("moot_capture_drawer", &a, &registry).expect("capture must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("scheme: mdcc"),
        "capture with mdcc scheme should echo 'scheme: mdcc'; got: {text}"
    );
}

#[test]
fn capture_drawer_with_unknown_scheme_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let a = args![
        "content" => "test",
        "room" => "test-room",
        "udcCode" => "000.000",
        "classificationScheme" => "dewey-decimal",
        "addedBy" => "test-agent",
        "embeddingModelID" => "test-model"
    ];
    let err = dispatch_tool("moot_capture_drawer", &a, &registry)
        .expect_err("unknown scheme must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "unknown classificationScheme must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

// ---------------------------------------------------------------------------
// 6. estateID routing — unknown estateID → invalidParams
// ---------------------------------------------------------------------------

#[test]
fn unknown_estate_id_returns_invalid_params_for_capture_drawer() {
    let registry = EstateRegistry::new_inmemory();
    let a = args![
        "content" => "test",
        "room" => "room",
        "udcCode" => "000.000",
        "addedBy" => "agent",
        "embeddingModelID" => "model",
        "estateID" => "ffffffff-ffff-ffff-ffff-ffffffffffff"
    ];
    let err = dispatch_tool("moot_capture_drawer", &a, &registry)
        .expect_err("unknown estateID must be a transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "unknown estateID must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

#[test]
fn malformed_estate_id_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let a = args![
        "content" => "test",
        "room" => "room",
        "udcCode" => "000.000",
        "addedBy" => "agent",
        "embeddingModelID" => "model",
        "estateID" => "not-a-uuid"
    ];
    let err = dispatch_tool("moot_capture_drawer", &a, &registry)
        .expect_err("malformed estateID must be a transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "malformed estateID must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

// ---------------------------------------------------------------------------
// 7. moot_association_rules — analytics lens (AR_FCA_CAPABILITY_001)
// ---------------------------------------------------------------------------

#[test]
fn association_rules_over_captured_drawers_succeeds() {
    // Capture drawers with the same categorical facets so the co-occurrence
    // matrix has entries to mine. Association rules require repeated
    // co-occurrence; three drawers in the same room/kind/channel/sensitivity
    // bucket produce non-empty matrix cells.
    let registry = EstateRegistry::new_inmemory();
    for _ in 0..3 {
        capture_one_drawer(&registry, "study content about knowledge", "study-room");
    }

    let a = args![];
    let result = dispatch_tool("moot_association_rules", &a, &registry)
        .expect("moot_association_rules must succeed");
    assert!(
        is_success(&result),
        "association_rules should be a success result; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.starts_with("association_rules:"),
        "result should start with 'association_rules:'; got: {text}"
    );
    assert!(
        text.contains("drawer(s)"),
        "result should mention drawer count; got: {text}"
    );
}

#[test]
fn association_rules_with_unknown_estate_returns_invalid_params() {
    // Unknown estateID must produce a transport fault (INVALID_PARAMS),
    // not a tool-level error result — the estate registry cannot resolve it.
    let registry = EstateRegistry::new_inmemory();
    let a = args!["estateID" => "00000000-0000-0000-0000-000000000000"];
    let err = dispatch_tool("moot_association_rules", &a, &registry)
        .expect_err("unknown estateID must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "unknown estateID must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

// ---------------------------------------------------------------------------
// 8. moot_formal_concepts — analytics lens (AR_FCA_CAPABILITY_001)
// ---------------------------------------------------------------------------

#[test]
fn formal_concepts_over_captured_drawers_succeeds() {
    // Two drawers in the same room share categorical facets; the formal context
    // will have at least one concept.
    let registry = EstateRegistry::new_inmemory();
    capture_one_drawer(&registry, "concept content alpha", "concept-room");
    capture_one_drawer(&registry, "concept content beta", "concept-room");

    let a = args![
        "minSupport" => 1,
        "maxIntentSize" => 8,
        "maxConcepts" => 20
    ];
    let result = dispatch_tool("moot_formal_concepts", &a, &registry)
        .expect("moot_formal_concepts must succeed");
    assert!(
        is_success(&result),
        "formal_concepts should be a success result; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.starts_with("formal_concepts:"),
        "result should start with 'formal_concepts:'; got: {text}"
    );
    assert!(
        text.contains("drawer(s)"),
        "result should mention drawer count; got: {text}"
    );
}

#[test]
fn formal_concepts_with_unknown_estate_returns_invalid_params() {
    // Mirror of the association_rules estateID test — same transport fault
    // discipline for all lens tools.
    let registry = EstateRegistry::new_inmemory();
    let a = args!["estateID" => "00000000-0000-0000-0000-000000000000"];
    let err = dispatch_tool("moot_formal_concepts", &a, &registry)
        .expect_err("unknown estateID must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "unknown estateID must map to INVALID_PARAMS; got code {}",
        err.code
    );
}
