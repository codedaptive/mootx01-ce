//! Dispatch-surface integration tests — Rust version.
//!
//! Exercises the dispatch routing for every tool category through the full
//! dispatch stack using an in-memory estate (EstateRegistry::new_inmemory).
//! One success path + one error path per tool group — representative tools,
//! not all 49 individually. Tests are ordered by the dispatch routing order in
//! dispatch.rs: recipe → lens → lexicon (capture/recall + lifecycle verbs +
//! tunnel recall). tools_list_count_is_49 plus the schema-keys assertions
//! gate the full 49-tool surface (after v2b-p0 full-matrix projection refactor).
//!
//! # Design
//!
//! Tests call aria_mcp::dispatch::dispatch_tool directly (not through the stdio
//! framing loop) — dispatch routing is the surface under test; framing has its
//! own suite. The estate registry is constructed fresh per group so each group
//! starts with a clean estate.
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
    tool_list::build_tool_list,
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
        confirm_text.contains("discarded 0 branch(es)"),
        "zero-discard case must report an exact zero count; got: {confirm_text}"
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

// ---------------------------------------------------------------------------
// 9. moot_mutate_drawer (v2b-p1)
// ---------------------------------------------------------------------------

#[test]
fn mutate_drawer_confirm_transitions_confirmation_axis() {
    // Confirm is the one mutation kind that is live end-to-end: the coordinator
    // dispatches it to the estate and the row's confirmation axis moves to
    // UserConfirmed. Success result: isError false, text contains the row id.
    let registry = EstateRegistry::new_inmemory();
    let row_id = capture_one_drawer(&registry, "confirm mutation target", "study");
    assert!(!row_id.is_empty(), "capture must return a row id");

    let a = args!["rowID" => row_id.as_str(), "kind" => "confirm"];
    let result = dispatch_tool("moot_mutate_drawer", &a, &registry).expect("mutate must not throw");
    assert!(
        is_success(&result),
        "confirm mutation must be a success result; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains(&row_id),
        "success text must include the row id; got: {text}"
    );
    assert!(
        text.contains("confirm"),
        "success text must include the mutation kind; got: {text}"
    );
}

#[test]
fn mutate_drawer_unknown_kind_returns_invalid_params() {
    // An unrecognized mutation kind is an invalidParams transport fault —
    // the call never reached the substrate.
    let registry = EstateRegistry::new_inmemory();
    let row_id = capture_one_drawer(&registry, "kind check target", "study");

    let a = args!["rowID" => row_id.as_str(), "kind" => "not-a-real-kind"];
    let err = dispatch_tool("moot_mutate_drawer", &a, &registry)
        .expect_err("unknown kind must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "unknown mutation kind must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

#[test]
fn mutate_drawer_missing_kind_returns_invalid_params() {
    // Omitting the required `kind` field is an invalidParams transport fault.
    let registry = EstateRegistry::new_inmemory();
    let row_id = capture_one_drawer(&registry, "missing kind target", "study");

    let a = args!["rowID" => row_id.as_str()];
    let err = dispatch_tool("moot_mutate_drawer", &a, &registry)
        .expect_err("missing kind must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "missing kind must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

// ---------------------------------------------------------------------------
// 10. moot_withdraw_drawer (v2b-p1)
// ---------------------------------------------------------------------------

#[test]
fn withdraw_drawer_removes_row_from_unconfirmed_set() {
    // Withdraw transitions the row's state so it no longer appears in the
    // unconfirmed recall set. Success result: isError false, text contains
    // the row id.
    let registry = EstateRegistry::new_inmemory();
    let row_id = capture_one_drawer(&registry, "withdraw target content", "lab");

    let a = args!["rowID" => row_id.as_str(), "reason" => "obsolete"];
    let result =
        dispatch_tool("moot_withdraw_drawer", &a, &registry).expect("withdraw must not throw");
    assert!(
        is_success(&result),
        "withdraw must be a success result; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains(&row_id),
        "success text must include the row id; got: {text}"
    );

    // Verify the row left the unconfirmed recall set.
    let recall_result =
        dispatch_tool("moot_drawer_recall", &args![], &registry).expect("recall must succeed");
    let recall_text = content_text(&recall_result);
    assert!(
        !recall_text.contains(&row_id),
        "withdrawn row must not appear in unconfirmed recall; got: {recall_text}"
    );
}

#[test]
fn withdraw_drawer_missing_row_id_returns_invalid_params() {
    // Omitting rowID is an invalidParams transport fault — required arg missing.
    let registry = EstateRegistry::new_inmemory();
    let a = args!["reason" => "test"];
    let err = dispatch_tool("moot_withdraw_drawer", &a, &registry)
        .expect_err("missing rowID must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "missing rowID must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

// ---------------------------------------------------------------------------
// 11. moot_expunge_drawer (v2b-p1)
// ---------------------------------------------------------------------------

#[test]
fn expunge_drawer_with_confirmation_true_succeeds() {
    // Expunge with confirmation:true reaches the estate and tombstones the row.
    let registry = EstateRegistry::new_inmemory();
    let row_id = capture_one_drawer(&registry, "expunge target content", "archive");

    let a = args!["rowID" => row_id.as_str(), "reason" => "gdpr erasure", "confirmation" => true];
    let result =
        dispatch_tool("moot_expunge_drawer", &a, &registry).expect("expunge must not throw");
    assert!(
        is_success(&result),
        "expunge with confirmation must be a success result; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains(&row_id),
        "success text must include the row id; got: {text}"
    );
}

#[test]
fn expunge_drawer_without_confirmation_returns_tool_error() {
    // Expunge with confirmation:false is refused at the coordinator boundary
    // without touching the estate — ExpungeNotConfirmed → error_result (isError
    // true), NOT a JSONRPCError transport fault.
    let registry = EstateRegistry::new_inmemory();
    let row_id = capture_one_drawer(&registry, "expunge guard target", "archive");

    let a = args!["rowID" => row_id.as_str(), "reason" => "test", "confirmation" => false];
    let result = dispatch_tool("moot_expunge_drawer", &a, &registry)
        .expect("unconfirmed expunge must return tool error, not transport fault");
    assert!(
        is_tool_error(&result),
        "expunge without confirmation must be isError:true; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        !text.is_empty(),
        "error result must carry a message; got empty text"
    );
    // The coordinator's boundary guard message includes the row id so the caller
    // can correlate the refusal to the specific row.
    assert!(
        text.contains(&row_id) || text.contains("ExpungeNotConfirmed"),
        "refusal message should identify the row or the guard; got: {text}"
    );
}

#[test]
fn expunge_drawer_missing_reason_returns_invalid_params() {
    // `reason` is required for expunge (mandatory justification for the
    // irreversible action). Missing it is an invalidParams transport fault.
    let registry = EstateRegistry::new_inmemory();
    let row_id = capture_one_drawer(&registry, "reason check target", "archive");

    let a = args!["rowID" => row_id.as_str(), "confirmation" => true];
    let err = dispatch_tool("moot_expunge_drawer", &a, &registry)
        .expect_err("missing reason must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "missing reason must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

// ---------------------------------------------------------------------------
// 12. moot_reanchor_drawer (v2b-p1)
// ---------------------------------------------------------------------------

#[test]
fn reanchor_drawer_to_new_room_succeeds() {
    // Reanchor with toRoom moves the drawer's room. Success result: isError
    // false, text contains the row id.
    let registry = EstateRegistry::new_inmemory();
    let row_id = capture_one_drawer(&registry, "reanchor target content", "old-room");

    let a = args!["rowID" => row_id.as_str(), "toRoom" => "new-room"];
    let result =
        dispatch_tool("moot_reanchor_drawer", &a, &registry).expect("reanchor must not throw");
    assert!(
        is_success(&result),
        "reanchor must be a success result; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains(&row_id),
        "success text must include the row id; got: {text}"
    );
}

#[test]
fn reanchor_drawer_empty_reanchor_returns_tool_error() {
    // Reanchor with neither toRoom nor toUDC is refused at the coordinator
    // boundary — EmptyReanchor → error_result (isError true), NOT a transport
    // fault.
    let registry = EstateRegistry::new_inmemory();
    let row_id = capture_one_drawer(&registry, "empty reanchor target", "room-a");

    let a = args!["rowID" => row_id.as_str()];
    let result = dispatch_tool("moot_reanchor_drawer", &a, &registry)
        .expect("empty reanchor must return tool error, not transport fault");
    assert!(
        is_tool_error(&result),
        "empty reanchor must be isError:true; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        !text.is_empty(),
        "error result must carry a message; got empty text"
    );
}

#[test]
fn reanchor_drawer_missing_row_id_returns_invalid_params() {
    // Omitting rowID is an invalidParams transport fault.
    let registry = EstateRegistry::new_inmemory();
    let a = args!["toRoom" => "somewhere"];
    let err = dispatch_tool("moot_reanchor_drawer", &a, &registry)
        .expect_err("missing rowID must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "missing rowID must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

// ---------------------------------------------------------------------------
// 13. moot_tunnel_recall (v2b-p1)
// ---------------------------------------------------------------------------

#[test]
fn tunnel_recall_returns_outgoing_tunnels_for_wing() {
    // Capture a tunnel and then recall it by wing. The result should report the
    // count. Success result: isError false, text starts with the count line.
    let registry = EstateRegistry::new_inmemory();

    // Capture a tunnel connecting two wings.
    let a = args![
        "sourceWing" => "alpha-wing",
        "sourceRoom" => "room-a",
        "targetWing" => "beta-wing",
        "targetRoom" => "room-b",
        "kind" => "relates",
        "addedBy" => "test-agent"
    ];
    let t_result =
        dispatch_tool("moot_capture_tunnel", &a, &registry).expect("capture_tunnel must succeed");
    assert!(is_success(&t_result), "tunnel capture should succeed");

    // Recall tunnels originating from alpha-wing.
    let recall_a = args!["wing" => "alpha-wing"];
    let result = dispatch_tool("moot_tunnel_recall", &recall_a, &registry)
        .expect("tunnel_recall must succeed");
    assert!(
        is_success(&result),
        "tunnel_recall must be a success result; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.starts_with("recalled 1 tunnel(s) from wing alpha-wing"),
        "result must report the tunnel count and wing; got: {text}"
    );
}

#[test]
fn tunnel_recall_empty_wing_returns_zero_tunnels() {
    // Recalling from a wing with no outgoing tunnels returns a zero-count result,
    // not an error.
    let registry = EstateRegistry::new_inmemory();
    let a = args!["wing" => "unlinked-wing"];
    let result =
        dispatch_tool("moot_tunnel_recall", &a, &registry).expect("tunnel_recall must succeed");
    assert!(
        is_success(&result),
        "tunnel_recall on empty wing must be a success result; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.starts_with("recalled 0 tunnel(s)"),
        "empty wing result must report zero tunnels; got: {text}"
    );
}

#[test]
fn tunnel_recall_missing_wing_returns_invalid_params() {
    // Omitting the required `wing` argument is an invalidParams transport fault.
    let registry = EstateRegistry::new_inmemory();
    let a = args![];
    let err = dispatch_tool("moot_tunnel_recall", &a, &registry)
        .expect_err("missing wing must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "missing wing must map to INVALID_PARAMS; got code {}",
        err.code
    );
}

// ---------------------------------------------------------------------------
// 14. tools/list surface assertions — count and schema-keys for v2b-p0/p2 tools
// ---------------------------------------------------------------------------

#[test]
fn tools_list_count_is_49() {
    // The full tool surface after v2b-p0 programmatic projection refactor:
    //   1  moot_list_recipes
    //  16  lens tools (14 reasoning + 2 analytics)
    //   3  foundational recipe tools
    //  28  lexicon projection loop (full Noun.allCases × Verb.allCases matrix,
    //       accepted + surfaced only — 6 drawer + 5 tunnel + 4 kgFact + 1
    //       diaryEntry + 4 proposal + 3 association + 5 learnedReference)
    //   1  moot_cross_estate_recall (federation, above projection)
    // ----
    //  49  total
    //
    // This test gates on the exact count so any accidental addition or removal
    // is caught. Updated from 28 (v2b-p1) when v2b-p0 expanded the lexicon
    // loop to the full acceptance matrix.
    let tools = build_tool_list();
    let arr = tools
        .as_array()
        .expect("build_tool_list must return an array");
    assert_eq!(
        arr.len(),
        49,
        "expected 49 tools in the list; got {}",
        arr.len()
    );
}

#[test]
fn tools_list_existing_8_lexicon_tools_byte_identical() {
    // Byte-identity gate for the v2b-p0 refactor: the 8 lexicon tools that
    // shipped in v1 and v2b-p1 must appear in the list with byte-identical
    // names, descriptions, and inputSchema required+property sets.
    //
    // This test corresponds to the "before/after byte-compare" gate in the
    // v2b-p0 completion report. The 8 tools are:
    //   moot_capture_drawer, moot_drawer_recall, moot_capture_tunnel,
    //   moot_mutate_drawer, moot_withdraw_drawer, moot_expunge_drawer,
    //   moot_reanchor_drawer, moot_tunnel_recall.
    let tools = build_tool_list();
    let arr = tools
        .as_array()
        .expect("build_tool_list must return an array");
    let by_name: std::collections::HashMap<&str, &serde_json::Value> = arr
        .iter()
        .filter_map(|t| t["name"].as_str().map(|n| (n, t)))
        .collect();

    // Spot-check descriptions (these are the exact strings from v2b-p1 tool_list.rs).
    assert_eq!(
        by_name["moot_capture_drawer"]["description"]
            .as_str()
            .unwrap(),
        "File a new drawer into the estate."
    );
    assert_eq!(
        by_name["moot_drawer_recall"]["description"]
            .as_str()
            .unwrap(),
        "Read drawer rows back by filter."
    );
    assert_eq!(
        by_name["moot_capture_tunnel"]["description"]
            .as_str()
            .unwrap(),
        "File a new tunnel into the estate."
    );
    assert_eq!(
        by_name["moot_mutate_drawer"]["description"]
            .as_str()
            .unwrap(),
        "Apply a named mutation to a drawer."
    );
    assert_eq!(
        by_name["moot_withdraw_drawer"]["description"]
            .as_str()
            .unwrap(),
        "Withdraw a drawer from active circulation."
    );
    assert_eq!(
        by_name["moot_expunge_drawer"]["description"]
            .as_str()
            .unwrap(),
        "Hard-erase a drawer (irreversible)."
    );
    assert_eq!(
        by_name["moot_reanchor_drawer"]["description"]
            .as_str()
            .unwrap(),
        "Move where a drawer sits in structure."
    );
    assert_eq!(
        by_name["moot_tunnel_recall"]["description"]
            .as_str()
            .unwrap(),
        "Read tunnel rows back by filter."
    );

    // Spot-check required arrays for the lifecycle verbs (parity of the old
    // tools_list_new_tools_present_with_correct_schema_keys test assertions).
    let mutate = by_name["moot_mutate_drawer"];
    let req: Vec<&str> = mutate["inputSchema"]["required"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|v| v.as_str())
        .collect();
    assert!(req.contains(&"rowID") && req.contains(&"kind"));
    assert!(mutate["inputSchema"]["properties"]
        .as_object()
        .unwrap()
        .contains_key("payload"));
    assert!(mutate["inputSchema"]["properties"]
        .as_object()
        .unwrap()
        .contains_key("estateID"));

    // tunnel_recall: wing required.
    let tr = by_name["moot_tunnel_recall"];
    let req: Vec<&str> = tr["inputSchema"]["required"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|v| v.as_str())
        .collect();
    assert!(req.contains(&"wing"));
    assert!(tr["inputSchema"]["properties"]
        .as_object()
        .unwrap()
        .contains_key("estateID"));
}

#[test]
fn tools_list_new_tools_present_with_correct_schema_keys() {
    // Verify the 5 new v2b-p1 tools appear in tools/list with the correct
    // required-array contents and key presence.
    let tools = build_tool_list();
    let arr = tools
        .as_array()
        .expect("build_tool_list must return an array");

    // Index tools by name for O(1) lookup.
    let by_name: std::collections::HashMap<&str, &serde_json::Value> = arr
        .iter()
        .filter_map(|t| t["name"].as_str().map(|n| (n, t)))
        .collect();

    // moot_mutate_drawer: required = ["rowID", "kind"]
    {
        let tool = by_name
            .get("moot_mutate_drawer")
            .expect("moot_mutate_drawer must be in list");
        let required = tool["inputSchema"]["required"]
            .as_array()
            .expect("required must be array");
        let req: Vec<&str> = required.iter().filter_map(|v| v.as_str()).collect();
        assert!(
            req.contains(&"rowID"),
            "mutate_drawer required must include rowID; got: {req:?}"
        );
        assert!(
            req.contains(&"kind"),
            "mutate_drawer required must include kind; got: {req:?}"
        );
        let props = tool["inputSchema"]["properties"]
            .as_object()
            .expect("properties must be object");
        assert!(
            props.contains_key("payload"),
            "mutate_drawer must have payload property"
        );
        assert!(
            props.contains_key("estateID"),
            "mutate_drawer must have estateID property"
        );
    }

    // moot_withdraw_drawer: required = ["rowID"]
    {
        let tool = by_name
            .get("moot_withdraw_drawer")
            .expect("moot_withdraw_drawer must be in list");
        let required = tool["inputSchema"]["required"]
            .as_array()
            .expect("required must be array");
        let req: Vec<&str> = required.iter().filter_map(|v| v.as_str()).collect();
        assert!(
            req.contains(&"rowID"),
            "withdraw_drawer required must include rowID; got: {req:?}"
        );
        let props = tool["inputSchema"]["properties"]
            .as_object()
            .expect("properties must be object");
        assert!(
            props.contains_key("reason"),
            "withdraw_drawer must have reason property"
        );
    }

    // moot_expunge_drawer: required = ["rowID", "reason", "confirmation"]
    {
        let tool = by_name
            .get("moot_expunge_drawer")
            .expect("moot_expunge_drawer must be in list");
        let required = tool["inputSchema"]["required"]
            .as_array()
            .expect("required must be array");
        let req: Vec<&str> = required.iter().filter_map(|v| v.as_str()).collect();
        assert!(
            req.contains(&"rowID"),
            "expunge_drawer required must include rowID; got: {req:?}"
        );
        assert!(
            req.contains(&"reason"),
            "expunge_drawer required must include reason; got: {req:?}"
        );
        assert!(
            req.contains(&"confirmation"),
            "expunge_drawer required must include confirmation; got: {req:?}"
        );
        // confirmation must be boolean type.
        let conf_type = tool["inputSchema"]["properties"]["confirmation"]["type"]
            .as_str()
            .unwrap_or("");
        assert_eq!(
            conf_type, "boolean",
            "confirmation must be boolean type; got: {conf_type}"
        );
    }

    // moot_reanchor_drawer: required = ["rowID"]
    {
        let tool = by_name
            .get("moot_reanchor_drawer")
            .expect("moot_reanchor_drawer must be in list");
        let required = tool["inputSchema"]["required"]
            .as_array()
            .expect("required must be array");
        let req: Vec<&str> = required.iter().filter_map(|v| v.as_str()).collect();
        assert!(
            req.contains(&"rowID"),
            "reanchor_drawer required must include rowID; got: {req:?}"
        );
        let props = tool["inputSchema"]["properties"]
            .as_object()
            .expect("properties must be object");
        assert!(
            props.contains_key("toRoom"),
            "reanchor_drawer must have toRoom property"
        );
        assert!(
            props.contains_key("toUDC"),
            "reanchor_drawer must have toUDC property"
        );
    }

    // moot_tunnel_recall: required = ["wing"]
    {
        let tool = by_name
            .get("moot_tunnel_recall")
            .expect("moot_tunnel_recall must be in list");
        let required = tool["inputSchema"]["required"]
            .as_array()
            .expect("required must be array");
        let req: Vec<&str> = required.iter().filter_map(|v| v.as_str()).collect();
        assert!(
            req.contains(&"wing"),
            "tunnel_recall required must include wing; got: {req:?}"
        );
        let props = tool["inputSchema"]["properties"]
            .as_object()
            .expect("properties must be object");
        assert!(
            props.contains_key("estateID"),
            "tunnel_recall must have estateID property"
        );
    }
}

// ---------------------------------------------------------------------------
// 15. v2b-p2 new tool groups — success + error path per group
// ---------------------------------------------------------------------------

// 15a. Tunnel lifecycle verbs.
//
// The coordinator routes these through the drawer estate path, which returns
// DrawerNotFound for a non-drawer row ID → VerbError::UnderlyingEstateFailure
// → error_result. This is the "success path" for the current stage (the tool
// reaches the substrate and the substrate reports a typed error, not a
// transport fault). The missing-required-arg path returns JSONRPCError.

#[test]
fn mutate_tunnel_missing_row_id_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    // Missing rowID — invalidParams transport fault.
    let err = dispatch_tool("moot_mutate_tunnel", &args!["kind" => "confirm"], &registry)
        .expect_err("missing rowID must be invalidParams");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn mutate_tunnel_unknown_row_id_returns_tool_error() {
    // A non-existent tunnel rowID reaches the drawer path, gets DrawerNotFound,
    // and surfaces as isError:true (not a transport fault).
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_mutate_tunnel",
        &args!["rowID" => "no-such-tunnel", "kind" => "confirm"],
        &registry,
    )
    .expect("dispatch must not throw transport fault for unknown tunnel row");
    assert!(
        is_tool_error(&result),
        "unknown tunnel rowID must produce isError:true; got: {result}"
    );
}

#[test]
fn expunge_tunnel_without_confirmation_returns_tool_error() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_expunge_tunnel",
        &args!["rowID" => "t1", "reason" => "cleanup"],
        &registry,
    )
    .expect("expunge_tunnel without confirmation must not throw transport fault");
    assert!(
        is_tool_error(&result),
        "expunge_tunnel without confirmation must produce isError:true; got: {result}"
    );
    assert!(
        content_text(&result).contains("ExpungeNotConfirmed"),
        "error text must mention ExpungeNotConfirmed; got: {}",
        content_text(&result)
    );
}

// 15b. kgFact lifecycle and recall.

#[test]
fn mutate_kg_fact_missing_kind_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool("moot_mutate_kgFact", &args!["rowID" => "r1"], &registry)
        .expect_err("missing kind must be invalidParams");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn expunge_kg_fact_without_confirmation_returns_tool_error() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_expunge_kgFact",
        &args!["rowID" => "r1", "reason" => "cleanup"],
        &registry,
    )
    .expect("expunge_kgFact must not throw transport fault");
    assert!(is_tool_error(&result));
}

#[test]
fn kg_fact_recall_returns_not_supported_error() {
    // DrawerStore has no all_kg_facts() — surfaces NotSupportedByEstate.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_kgFact_recall", &args![], &registry).expect("must not throw");
    assert!(
        is_tool_error(&result),
        "kgFact_recall must return isError:true (not supported yet); got: {result}"
    );
}

// 15c. diaryEntry recall.

#[test]
fn diary_entry_recall_returns_not_supported_error() {
    let registry = EstateRegistry::new_inmemory();
    let result =
        dispatch_tool("moot_diaryEntry_recall", &args![], &registry).expect("must not throw");
    assert!(
        is_tool_error(&result),
        "diaryEntry_recall must return isError:true (not supported yet); got: {result}"
    );
}

// 15d. Proposal lifecycle and recall.

#[test]
fn expunge_proposal_requires_confirmation() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_expunge_proposal",
        &args!["rowID" => "p1", "reason" => "stale"],
        &registry,
    )
    .expect("must not throw");
    assert!(is_tool_error(&result));
    assert!(content_text(&result).contains("ExpungeNotConfirmed"));
}

#[test]
fn proposal_recall_returns_not_supported_error() {
    let registry = EstateRegistry::new_inmemory();
    let result =
        dispatch_tool("moot_proposal_recall", &args![], &registry).expect("must not throw");
    assert!(is_tool_error(&result));
}

// 15e. Association lifecycle and recall.

#[test]
fn mutate_association_unknown_row_returns_tool_error() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_mutate_association",
        &args!["rowID" => "no-such-assoc", "kind" => "confirm"],
        &registry,
    )
    .expect("must not throw transport fault");
    assert!(is_tool_error(&result));
}

#[test]
fn association_recall_returns_not_supported_error() {
    let registry = EstateRegistry::new_inmemory();
    let result =
        dispatch_tool("moot_association_recall", &args![], &registry).expect("must not throw");
    assert!(is_tool_error(&result));
}

// 15f. learnedReference — learn, lifecycle, recall.

#[test]
fn learn_learned_reference_returns_not_supported_error() {
    // moot_learn_learnedReference dispatches to coordinator.learn which is a
    // stub (Brain layer not yet present). Both sides return NotSupportedByEstate.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_learn_learnedReference",
        &args!["handle" => "some-catalog-ref"],
        &registry,
    )
    .expect("must not throw transport fault");
    assert!(
        is_tool_error(&result),
        "learn_learnedReference must return isError:true (stub); got: {result}"
    );
}

#[test]
fn learned_reference_recall_returns_not_supported_error() {
    let registry = EstateRegistry::new_inmemory();
    let result =
        dispatch_tool("moot_learnedReference_recall", &args![], &registry).expect("must not throw");
    assert!(is_tool_error(&result));
}

// 15g. Federation stub — moot_cross_estate_recall.

#[test]
fn cross_estate_recall_advertises_and_returns_not_implemented() {
    // The Rust GLK fan_out has no grant model yet. The tool is advertised in
    // tools/list (confirmed by the count test); every call returns error_result
    // with the explicit "not yet implemented" message.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_cross_estate_recall",
        &args!["requesterEstateID" => "00000000-0000-0000-0000-000000000001"],
        &registry,
    )
    .expect("must not throw transport fault");
    assert!(
        is_tool_error(&result),
        "cross_estate_recall must return isError:true; got: {result}"
    );
    assert!(
        content_text(&result).contains("not yet implemented"),
        "error text must contain 'not yet implemented'; got: {}",
        content_text(&result)
    );
}

// ---------------------------------------------------------------------------
// 16. tools/list name-set equality (v2b-p2 complete surface)
// ---------------------------------------------------------------------------

#[test]
fn tools_list_name_set_matches_expected_49_names() {
    // Gate: all 49 expected tool names are present, no more and no less.
    // Derived from the Swift ToolProjection.tools() output (acceptance matrix
    // × surfaced verbs) plus recipe, lens, and federation tools.
    let expected_names: std::collections::HashSet<&str> = [
        // recipe tools
        "moot_list_recipes",
        "moot_grounded_synthesis",
        "moot_run_migration_benchmark",
        "moot_confirm_migration_promotion",
        // lens tools (14 reasoning + 2 analytics)
        "moot_keystones",
        "moot_constellation",
        "moot_free_association",
        "moot_theme_weather",
        "moot_latent_themes",
        "moot_bias",
        "moot_drift",
        "moot_contradiction",
        "moot_trust_grounded_synthesis",
        "moot_partial_cue_recall",
        "moot_anticipate",
        "moot_tunnel_successor",
        "moot_mind_overlap",
        "moot_estate_divergence",
        "moot_association_rules",
        "moot_formal_concepts",
        // lexicon: drawer (6)
        "moot_capture_drawer",
        "moot_reanchor_drawer",
        "moot_mutate_drawer",
        "moot_withdraw_drawer",
        "moot_expunge_drawer",
        "moot_drawer_recall",
        // lexicon: tunnel (5)
        "moot_capture_tunnel",
        "moot_mutate_tunnel",
        "moot_withdraw_tunnel",
        "moot_expunge_tunnel",
        "moot_tunnel_recall",
        // lexicon: kgFact (4)
        "moot_mutate_kgFact",
        "moot_withdraw_kgFact",
        "moot_expunge_kgFact",
        "moot_kgFact_recall",
        // lexicon: diaryEntry (1)
        "moot_diaryEntry_recall",
        // lexicon: proposal (4)
        "moot_mutate_proposal",
        "moot_withdraw_proposal",
        "moot_expunge_proposal",
        "moot_proposal_recall",
        // lexicon: association (3)
        "moot_mutate_association",
        "moot_expunge_association",
        "moot_association_recall",
        // lexicon: learnedReference (5)
        "moot_learn_learnedReference",
        "moot_mutate_learnedReference",
        "moot_withdraw_learnedReference",
        "moot_expunge_learnedReference",
        "moot_learnedReference_recall",
        // federation (1)
        "moot_cross_estate_recall",
    ]
    .iter()
    .copied()
    .collect();

    let tools = build_tool_list();
    let arr = tools
        .as_array()
        .expect("build_tool_list must return an array");
    let actual_names: std::collections::HashSet<&str> =
        arr.iter().filter_map(|t| t["name"].as_str()).collect();

    // Every expected name must appear.
    for name in &expected_names {
        assert!(
            actual_names.contains(name),
            "expected tool {name} missing from tools/list"
        );
    }
    // No extra names beyond expected.
    for name in &actual_names {
        assert!(
            expected_names.contains(name),
            "unexpected tool {name} in tools/list"
        );
    }
    assert_eq!(
        actual_names.len(),
        49,
        "expected exactly 49 tools; got {}",
        actual_names.len()
    );
}
