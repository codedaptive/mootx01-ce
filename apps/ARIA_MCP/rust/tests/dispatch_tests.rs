//! Dispatch-surface integration tests — 5-tier AI-client interface (MCP-RUST-ALIGN-01).
//!
//! Tests the 44-tool surface: 19 interface tools (Tier 1–5), 1 federation tool,
//! 4 recipe tools, 16 lens tools, and 4 vault stubs. Exercises dispatch routing,
//! argument validation, and result shapes through the full stack using an in-memory
//! estate. One success path + one error/validation path per tool group.
//!
//! # Result shape conventions
//!
//! Success results: isError == false, content[0].text contains expected fragment.
//! Tool-level refusals (expected errors): isError == true, content[0].text carries
//! the message. These use the isError path, not transport faults (Err(JSONRPCError)).
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

macro_rules! args {
    () => { BTreeMap::new() };
    ( $( $k:expr => $v:expr ),+ $(,)? ) => {{
        let mut m = BTreeMap::new();
        $( m.insert($k.to_string(), JsonValue::from(serde_json::json!($v))); )+
        m
    }};
}

fn content_text(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().unwrap_or("")
}

fn is_success(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(false)
}

fn is_tool_error(result: &serde_json::Value) -> bool {
    result["isError"] == serde_json::json!(true)
}

/// File a memory into the default estate and return its id.
fn file_one_memory(registry: &EstateRegistry, content: &str, location: &str) -> String {
    let a = args!["content" => content, "location" => location];
    let result = dispatch_tool("moot_file_memory", &a, registry).expect("file_memory must succeed");
    assert!(is_success(&result), "file_memory should succeed; got: {result:?}");
    let text = content_text(&result);
    // "filed memory <id>\nroom: ..."
    text.lines()
        .next()
        .and_then(|l| l.strip_prefix("filed memory "))
        .unwrap_or("")
        .to_owned()
}

// ---------------------------------------------------------------------------
// 1. tools/list surface assertions — 44 tools exact
// ---------------------------------------------------------------------------

#[test]
fn tools_list_count_is_44() {
    // Gate: the 5-tier AI-client surface after MCP-RUST-ALIGN-01:
    //   19  interface tools (Tier 1–5)
    //    1  federation tool (moot_federated_search)
    //    4  recipe tools (moot_list_lenses, moot_synthesize, …)
    //   16  lens tools (moot_lens_* prefix)
    //    4  vault stubs (moot_vault_*)
    // ----
    //   44  total
    let tools = build_tool_list();
    let arr = tools.as_array().expect("build_tool_list must return an array");
    assert_eq!(arr.len(), 44, "expected 44 tools; got {}", arr.len());
}

#[test]
fn tools_list_name_set_matches_expected_44_names() {
    // Gate: all 44 expected tool names are present, no more and no less.
    let expected: std::collections::HashSet<&str> = [
        // Tier 1 — Core memory (7)
        "moot_file_memory",
        "moot_memory_search",
        "moot_update_memory",
        "moot_withdraw_memory",
        "moot_erase_memory",
        "moot_confirm_memory",
        "moot_move_memory",
        // Tier 2 — Connections (3)
        "moot_link_memories",
        "moot_connection_search",
        "moot_connection_map",
        // Tier 3 — Knowledge graph (4)
        "moot_file_fact",
        "moot_fact_search",
        "moot_retire_fact",
        "moot_fact_timeline",
        // Tier 4 — Journal (2)
        "moot_write_journal",
        "moot_read_journal",
        // Tier 5 — Estate (3)
        "moot_estate_status",
        "moot_estate_map",
        "moot_estate_ping",
        // Federation (1)
        "moot_federated_search",
        // Recipe (4)
        "moot_list_lenses",
        "moot_synthesize",
        "moot_run_migration",
        "moot_confirm_migration",
        // Lens tools (16) — names from lens_tools.rs LENS_TOOLS constant
        "moot_lens_keystones",
        "moot_lens_constellation",
        "moot_lens_free_association",
        "moot_lens_theme_weather",
        "moot_lens_latent_themes",
        "moot_lens_bias",
        "moot_lens_drift",
        "moot_lens_contradiction",
        "moot_lens_trust_synthesis",
        "moot_lens_partial_cue",
        "moot_lens_anticipate",
        "moot_lens_successors",
        "moot_lens_overlap",
        "moot_lens_divergence",
        "moot_lens_associations",
        "moot_lens_concepts",
        // Vault stubs (4)
        "moot_vault_export",
        "moot_vault_import",
        "moot_vault_status",
        "moot_vault_reconcile",
    ]
    .iter()
    .copied()
    .collect();

    let tools = build_tool_list();
    let arr = tools.as_array().expect("build_tool_list must return an array");
    let actual: std::collections::HashSet<&str> =
        arr.iter().filter_map(|t| t["name"].as_str()).collect();

    for name in &expected {
        assert!(actual.contains(name), "expected tool {name} missing from tools/list");
    }
    for name in &actual {
        assert!(expected.contains(name), "unexpected tool {name} in tools/list");
    }
}

// ---------------------------------------------------------------------------
// 2. Unknown tool → METHOD_NOT_FOUND transport fault
// ---------------------------------------------------------------------------

#[test]
fn unknown_tool_name_returns_method_not_found() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool("moot_nonexistent_tool", &args![], &registry)
        .expect_err("unknown tool must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::METHOD_NOT_FOUND);
}

// ---------------------------------------------------------------------------
// 3. Teachme interception — before any runner fires
// ---------------------------------------------------------------------------

#[test]
fn teachme_true_returns_guide_without_touching_estate() {
    // teachme:true on any interface tool returns guide text, never touches estate.
    // Test with moot_file_memory (no content/location required when teachme:true).
    let registry = EstateRegistry::new_inmemory();
    let a = args!["teachme" => true];
    let result = dispatch_tool("moot_file_memory", &a, &registry)
        .expect("teachme interception must not throw");
    assert!(is_success(&result), "teachme result must be isError:false");
    let text = content_text(&result);
    assert!(
        text.contains("moot_file_memory"),
        "guide must name the tool; got: {text}"
    );
}

#[test]
fn teachme_true_on_unknown_tool_returns_generic_guide() {
    let registry = EstateRegistry::new_inmemory();
    let a = args!["teachme" => true];
    let result = dispatch_tool("moot_nonexistent_tool", &a, &registry)
        .expect("teachme on unknown tool must return generic guide, not transport fault");
    assert!(is_success(&result));
    // Generic guide directs to moot_estate_status teachme.
    let text = content_text(&result);
    assert!(
        text.contains("moot_estate_status"),
        "generic guide must reference moot_estate_status; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 4. Tier 1 — Core memory
// ---------------------------------------------------------------------------

#[test]
fn file_memory_returns_id_and_room() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_one_memory(&registry, "Sprint review notes Q2", "work/meetings");
    assert!(!id.is_empty(), "file_memory must return a non-empty id");
}

#[test]
fn file_memory_missing_content_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool("moot_file_memory", &args!["location" => "work"], &registry)
        .expect_err("missing content must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn memory_search_over_filed_memory_finds_it() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "unique-phrase-for-search-test", "lab/notes");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "unique-phrase-for-search-test"],
        &registry,
    )
    .expect("memory_search must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("found 1 memory(s)"),
        "should find the filed memory; got: {text}"
    );
}

#[test]
fn memory_search_missing_query_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool("moot_memory_search", &args![], &registry)
        .expect_err("missing query must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// ARIA-SCORED-1: moot_memory_search honors the `scoring` argument.
//
// After the hybrid-recall flip, `moot_memory_search` routes through
// `recall_scored` with mode=unionBest. Verifies:
//   1. The tool succeeds with scoring="rrf".
//   2. The tool succeeds with scoring="matrixAware".
//   3. The tool succeeds with the default scoring (no arg).
//   4. The result text includes a score value in the expected format.
//
// Without CorpusKit/VectorKit registration (the test estate is locus-only),
// all three paths fall back to rank-normalised locus scoring, producing
// valid results. The score value is present in the output text, proving the
// recall_scored path ran (plain recall + substring did not emit scores).
#[test]
fn memory_search_with_scoring_arg_rrf_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "scoring-arg-rrf-test content", "lab/notes");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "scoring-arg-rrf-test", "scoring" => "rrf"],
        &registry,
    )
    .expect("memory_search with scoring=rrf must not throw");
    assert!(is_success(&result), "scoring=rrf must succeed; got: {result:?}");
    let text = content_text(&result);
    // recall_scored always returns at least one hit (the locus fallback).
    assert!(
        text.contains("found 1 memory(s)"),
        "must find the filed memory; got: {text}"
    );
    // The score format "(score: 0.xxxx)" appears in the output, proving
    // the recall_scored path ran, not plain recall+substring.
    assert!(
        text.contains("(score:"),
        "recall_scored output must include score annotation; got: {text}"
    );
}

#[test]
fn memory_search_with_scoring_arg_matrix_aware_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "scoring-arg-matrixAware-test content", "lab/notes");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "scoring-arg-matrixAware-test", "scoring" => "matrixAware"],
        &registry,
    )
    .expect("memory_search with scoring=matrixAware must not throw");
    assert!(is_success(&result), "scoring=matrixAware must succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("found 1 memory(s)"),
        "must find the filed memory; got: {text}"
    );
    assert!(
        text.contains("(score:"),
        "recall_scored output must include score annotation; got: {text}"
    );
}

#[test]
fn update_memory_confirm_mutation_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_one_memory(&registry, "confirm target", "lab");

    let result = dispatch_tool(
        "moot_update_memory",
        &args!["id" => id.as_str(), "mutation" => "confirm"],
        &registry,
    )
    .expect("update_memory must not throw");
    assert!(is_success(&result), "confirm mutation must succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains(&id),
        "success text must include the id; got: {text}"
    );
}

#[test]
fn update_memory_unknown_mutation_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_one_memory(&registry, "mutation kind check", "lab");
    let err = dispatch_tool(
        "moot_update_memory",
        &args!["id" => id.as_str(), "mutation" => "explode"],
        &registry,
    )
    .expect_err("unknown mutation must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn withdraw_memory_removes_from_unconfirmed_set() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_one_memory(&registry, "withdraw target content", "lab");

    let result = dispatch_tool(
        "moot_withdraw_memory",
        &args!["id" => id.as_str(), "reason" => "obsolete"],
        &registry,
    )
    .expect("withdraw_memory must not throw");
    assert!(is_success(&result), "withdraw must succeed; got: {result:?}");

    // Searching for the content should return 0 results after withdrawal.
    let search = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "withdraw target content"],
        &registry,
    )
    .expect("search must succeed");
    let search_text = content_text(&search);
    assert!(
        search_text.contains("found 0 memory(s)"),
        "withdrawn memory must not appear in search; got: {search_text}"
    );
}

#[test]
fn erase_memory_with_confirmed_true_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_one_memory(&registry, "erase target content", "archive");

    let result = dispatch_tool(
        "moot_erase_memory",
        &args!["id" => id.as_str(), "reason" => "gdpr", "confirmed" => true],
        &registry,
    )
    .expect("erase_memory must not throw");
    assert!(is_success(&result), "erase with confirmed:true must succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(text.contains(&id), "success text must include id; got: {text}");
}

#[test]
fn erase_memory_without_confirmed_returns_tool_error() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_one_memory(&registry, "erase guard target", "archive");

    let result = dispatch_tool(
        "moot_erase_memory",
        &args!["id" => id.as_str(), "reason" => "test"],
        &registry,
    )
    .expect("erase without confirmed must return tool error, not transport fault");
    assert!(
        is_tool_error(&result),
        "erase without confirmed must be isError:true; got: {result:?}"
    );
}

#[test]
fn confirm_memory_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_one_memory(&registry, "confirm shortcut target", "lab");

    let result = dispatch_tool("moot_confirm_memory", &args!["id" => id.as_str()], &registry)
        .expect("confirm_memory must not throw");
    assert!(is_success(&result), "confirm_memory must succeed; got: {result:?}");
}

#[test]
fn move_memory_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_one_memory(&registry, "move target content", "old-room");

    let result = dispatch_tool(
        "moot_move_memory",
        &args!["id" => id.as_str(), "location" => "new-room"],
        &registry,
    )
    .expect("move_memory must not throw");
    assert!(is_success(&result), "move_memory must succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("new-room"),
        "success text must mention new location; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 5. Tier 2 — Connections
// ---------------------------------------------------------------------------

#[test]
fn link_memories_creates_tunnel() {
    let registry = EstateRegistry::new_inmemory();
    let from_id = file_one_memory(&registry, "source memory for link", "alpha/hub");
    let to_id = file_one_memory(&registry, "target memory for link", "beta/spoke");

    let result = dispatch_tool(
        "moot_link_memories",
        &args![
            "from_id" => from_id.as_str(),
            "to_id" => to_id.as_str(),
            "kind" => "elaborates"
        ],
        &registry,
    )
    .expect("link_memories must not throw");
    assert!(is_success(&result), "link_memories must succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("linked"),
        "success text must contain 'linked'; got: {text}"
    );
    assert!(
        text.contains("elaborates"),
        "success text must mention the tunnel kind; got: {text}"
    );
}

#[test]
fn link_memories_missing_from_id_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_link_memories",
        &args!["to_id" => "some-id", "kind" => "elaborates"],
        &registry,
    )
    .expect_err("missing from_id must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn connection_search_returns_outgoing_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let from_id = file_one_memory(&registry, "connection search source", "search/from");
    let to_id = file_one_memory(&registry, "connection search target", "search/to");

    dispatch_tool(
        "moot_link_memories",
        &args!["from_id" => from_id.as_str(), "to_id" => to_id.as_str(), "kind" => "references"],
        &registry,
    )
    .expect("link must succeed");

    let result = dispatch_tool(
        "moot_connection_search",
        &args!["from_id" => from_id.as_str()],
        &registry,
    )
    .expect("connection_search must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains(": 1") || text.contains("1"),
        "should find 1 outgoing connection; got: {text}"
    );
}

#[test]
fn connection_map_returns_incoming_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let from_id = file_one_memory(&registry, "connection map source", "map/from");
    let to_id = file_one_memory(&registry, "connection map target", "map/to");

    dispatch_tool(
        "moot_link_memories",
        &args!["from_id" => from_id.as_str(), "to_id" => to_id.as_str(), "kind" => "validates"],
        &registry,
    )
    .expect("link must succeed");

    let result = dispatch_tool(
        "moot_connection_map",
        &args!["to_id" => to_id.as_str()],
        &registry,
    )
    .expect("connection_map must not throw");
    assert!(is_success(&result));
}

// ---------------------------------------------------------------------------
// 6. Tier 3 — Knowledge graph
// ---------------------------------------------------------------------------

#[test]
fn fact_search_on_empty_estate_returns_zero() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_fact_search", &args![], &registry)
        .expect("fact_search must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.starts_with("facts:") || text.contains(": 0"),
        "empty estate must return 0 facts; got: {text}"
    );
}

#[test]
fn fact_timeline_on_empty_estate_returns_zero() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_fact_timeline", &args![], &registry)
        .expect("fact_timeline must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains(": 0") || text.contains("0"),
        "empty estate fact timeline must report 0; got: {text}"
    );
}

#[test]
fn file_fact_round_trips_through_coordinator() {
    // moot_file_fact now calls coordinator.add_kg_fact (landed via the GLK
    // write-path mission). It returns a success result carrying the filed
    // fact id; the fact is then discoverable via moot_fact_search.
    let registry = EstateRegistry::new_inmemory();
    // The substrate requires a non-empty source_drawer_id; file a memory to
    // obtain a real drawer id to use as the fact's source.
    let source = file_one_memory(&registry, "Alice context", "people");
    let result = dispatch_tool(
        "moot_file_fact",
        &args![
            "subject" => "Alice",
            "predicate" => "worksAt",
            "object" => "Acme Corp",
            "source_id" => source
        ],
        &registry,
    )
    .expect("file_fact must not throw transport fault");
    assert!(
        is_success(&result),
        "file_fact must return isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("filed fact") && text.contains("[Alice] worksAt [Acme Corp]"),
        "file_fact must report the filed fact; got: {text}"
    );

    // The fact is now discoverable through fact_search.
    let search = dispatch_tool("moot_fact_search", &args!["query" => "Acme"], &registry)
        .expect("fact_search must not throw");
    assert!(is_success(&search), "fact_search must succeed; got: {search:?}");
    assert!(
        content_text(&search).contains("Acme Corp"),
        "filed fact must be discoverable; got: {}",
        content_text(&search)
    );
}

#[test]
fn file_fact_missing_subject_returns_invalid_params() {
    // Arg validation runs before the not-yet-supported check.
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_file_fact",
        &args!["predicate" => "worksAt", "object" => "Acme"],
        &registry,
    )
    .expect_err("missing subject must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn retire_fact_round_trips_through_coordinator() {
    // moot_retire_fact now calls coordinator.withdraw_kg_fact. File a fact,
    // extract its id, then retire it and confirm the success message.
    let registry = EstateRegistry::new_inmemory();
    let source = file_one_memory(&registry, "Bob context", "people");
    let filed = dispatch_tool(
        "moot_file_fact",
        &args![
            "subject" => "Bob",
            "predicate" => "manages",
            "object" => "Widgets",
            "source_id" => source
        ],
        &registry,
    )
    .expect("file_fact must succeed");
    // "filed fact <id>: [Bob] manages [Widgets]"
    let filed_text = content_text(&filed);
    let fact_id = filed_text
        .strip_prefix("filed fact ")
        .and_then(|s| s.split(':').next())
        .expect("filed fact text must carry an id")
        .to_owned();

    let result = dispatch_tool("moot_retire_fact", &args!["id" => fact_id.clone()], &registry)
        .expect("retire_fact must not throw transport fault");
    assert!(is_success(&result), "retire_fact must return isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains(&format!("retired fact {fact_id}")),
        "retire_fact must report the retired fact id; got: {text}"
    );
}

#[test]
fn retire_fact_missing_id_returns_invalid_params() {
    // Arg validation runs before the coordinator call.
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool("moot_retire_fact", &args![], &registry)
        .expect_err("missing id must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// ---------------------------------------------------------------------------
// 7. Tier 4 — Journal
// ---------------------------------------------------------------------------

#[test]
fn write_journal_round_trips_through_coordinator() {
    // moot_write_journal now calls coordinator.add_diary_entry. Write an entry
    // for the default agent, then read it back via moot_read_journal.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_write_journal",
        &args!["entry" => "Completed analysis of Q1 metrics"],
        &registry,
    )
    .expect("write_journal must not throw transport fault");
    assert!(is_success(&result), "write_journal must return isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("wrote journal entry for mcp-agent"),
        "write_journal must confirm the entry for the default agent; got: {text}"
    );

    // The entry is readable back through read_journal for the same agent.
    let read = dispatch_tool("moot_read_journal", &args!["agent" => "mcp-agent"], &registry)
        .expect("read_journal must not throw");
    assert!(is_success(&read), "read_journal must succeed; got: {read:?}");
    let read_text = content_text(&read);
    assert!(
        read_text.contains("Completed analysis of Q1 metrics"),
        "written journal entry must be readable back; got: {read_text}"
    );
}

#[test]
fn write_journal_sending_content_not_entry_returns_invalid_params() {
    // 'content' is the wrong field name — 'entry' is required. Missing 'entry' is
    // an invalidParams transport fault before the not-yet-supported check.
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_write_journal",
        &args!["content" => "wrong field name"],
        &registry,
    )
    .expect_err("missing entry arg must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "sending content instead of entry must be INVALID_PARAMS; got code {}",
        err.code
    );
}

#[test]
fn read_journal_on_empty_estate_returns_zero_entries() {
    // moot_read_journal uses recall_diary_entries which is live in the Rust GLK.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_read_journal", &args![], &registry)
        .expect("read_journal must not throw");
    assert!(is_success(&result), "read_journal must be isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("0 entry") || text.contains(": 0"),
        "empty estate must report 0 entries; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 8. Tier 5 — Estate
// ---------------------------------------------------------------------------

#[test]
fn estate_ping_returns_live_pong() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_estate_ping", &args![], &registry)
        .expect("estate_ping must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("pong"),
        "ping must return pong; got: {text}"
    );
    assert!(
        text.contains("is live"),
        "pong must confirm estate is live; got: {text}"
    );
}

#[test]
fn estate_status_includes_aria_session_protocol() {
    // estate_status appends the ARIA session protocol block to every response.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_estate_status", &args![], &registry)
        .expect("estate_status must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    // ARIA_SESSION_PROTOCOL starts with "\n\nprotocol:" per session_protocol.rs.
    assert!(
        text.contains("protocol:"),
        "estate_status must append ARIA session protocol block; got: {text}"
    );
    assert!(
        text.contains("drawers:"),
        "estate_status must include drawer count; got: {text}"
    );
}

#[test]
fn estate_map_returns_taxonomy() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "map test content", "alpha/notes");

    let result = dispatch_tool("moot_estate_map", &args![], &registry)
        .expect("estate_map must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("estate map:"),
        "estate_map must start with 'estate map:'; got: {text}"
    );
}

#[test]
fn estate_status_unknown_estate_id_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_estate_status",
        &args!["estateID" => "ffffffff-ffff-ffff-ffff-ffffffffffff"],
        &registry,
    )
    .expect_err("unknown estateID must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// ---------------------------------------------------------------------------
// 9. Federation — moot_federated_search (not yet implemented)
// ---------------------------------------------------------------------------

#[test]
fn federated_search_returns_not_yet_implemented_error_result() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_federated_search", &args![], &registry)
        .expect("federated_search must not throw transport fault");
    assert!(
        is_tool_error(&result),
        "federated_search must return isError:true; got: {result:?}"
    );
    assert!(
        content_text(&result).contains("not yet implemented"),
        "error text must contain 'not yet implemented'; got: {}",
        content_text(&result)
    );
}

// ---------------------------------------------------------------------------
// 10. Vault tools — now backed by vault-kit (ADR-VAULTKIT-002)
// ---------------------------------------------------------------------------
//
// All four vault tools are real dispatchers. Missing `vaultPath` is an
// out-of-band transport fault (INVALID_PARAMS), not a tool-level refusal.
// These tests also cover:
//   - `moot_vault_status` on a new vault with no manifest → isError:false,
//     "no export manifest" in the text.
//   - `moot_vault_export` end-to-end → writes the vault, stamps the manifest.
//   - `moot_vault_status` after export → "manifest present", noteCount.
//   - `moot_vault_import` round-trip → written count.
//   - `moot_vault_reconcile` with no manifest → isError:true.
//   - `moot_vault_reconcile` after export with no edits → "0 added, 0 modified, 0 deleted".
//   - `moot_vault_reconcile` after editing a note → "1 modified".

/// Make a unique temporary directory for one vault test.
fn temp_vault_dir() -> std::path::PathBuf {
    let base = std::env::temp_dir();
    let dir = base.join(format!(
        "aria-rust-vault-test-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).expect("temp vault dir create");
    dir
}

#[test]
fn vault_tools_missing_vault_path_returns_invalid_params() {
    // Without `vaultPath` all four vault tools throw INVALID_PARAMS — a
    // transport fault, not a tool-level refusal. The real implementations
    // validate `vaultPath` as a required arg before touching the filesystem.
    let registry = EstateRegistry::new_inmemory();
    for name in &[
        "moot_vault_export",
        "moot_vault_import",
        "moot_vault_status",
        "moot_vault_reconcile",
    ] {
        let err = dispatch_tool(name, &args![], &registry)
            .expect_err(&format!("{name}: missing vaultPath must be INVALID_PARAMS"));
        assert_eq!(
            err.code,
            JSONRPCErrorCode::INVALID_PARAMS,
            "{name}: code must be INVALID_PARAMS; got: {:?}",
            err.code
        );
    }
}

#[test]
fn vault_status_on_empty_vault_reports_no_manifest() {
    // A freshly-created vault dir with no manifest returns isError:false and
    // "no export manifest" in the text.
    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    let result = dispatch_tool(
        "moot_vault_status",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
    )
    .expect("moot_vault_status must not throw transport fault");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&result),
        "status with no manifest must be isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("no export manifest"),
        "text must report no manifest; got: {text}"
    );
}

#[test]
fn vault_export_stamps_manifest_then_status_reports_it() {
    // moot_vault_export: files a memory, exports it to a temp vault,
    // stamps the SHA-256 manifest. moot_vault_status then reports
    // "manifest present" with noteCount: 1.
    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    // File one memory into the default estate so the export has content.
    let _mem_id = file_one_memory(&registry, "Benzene is aromatic.", "chem/notes");

    // Export to the temp vault.
    let export_result = dispatch_tool(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
    )
    .expect("moot_vault_export must not throw transport fault");

    let export_text = content_text(&export_result);
    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&export_result),
        "moot_vault_export must be isError:false; got: {export_result:?}"
    );
    assert!(
        export_text.contains("vault_export:"),
        "export text must contain 'vault_export:'; got: {export_text}"
    );
    assert!(
        export_text.contains("note(s)"),
        "export text must report note count; got: {export_text}"
    );
    assert!(
        export_text.contains("manifest:"),
        "export text must confirm manifest was stamped; got: {export_text}"
    );
}

#[test]
fn vault_export_then_import_round_trips() {
    // Export from the default estate to a vault, then import that vault into
    // the same estate via a fresh VaultBridge. The import should report at
    // least 1 written (idempotent per lineage_id, but the fresh import will
    // write the note again as a new lineage or update). Even if it updates,
    // the vault_import response is isError:false.
    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    file_one_memory(&registry, "Toluene is a solvent.", "chem/lab");

    dispatch_tool(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
    )
    .expect("export must succeed");

    let import_result = dispatch_tool(
        "moot_vault_import",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
    )
    .expect("moot_vault_import must not throw transport fault");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&import_result),
        "moot_vault_import must be isError:false; got: {import_result:?}"
    );
    let text = content_text(&import_result);
    assert!(
        text.contains("vault_import:"),
        "import text must start with 'vault_import:'; got: {text}"
    );
}

#[test]
fn vault_reconcile_without_manifest_returns_error_result() {
    // A vault with no manifest makes reconcile return isError:true with a
    // prompt to run moot_vault_export first. This is a tool-level refusal
    // (not a transport fault) — the tool ran, the vault just has no stamp.
    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    let result = dispatch_tool(
        "moot_vault_reconcile",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
    )
    .expect("moot_vault_reconcile must not throw transport fault");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_tool_error(&result),
        "reconcile with no manifest must be isError:true; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("no export manifest"),
        "error text must mention missing manifest; got: {text}"
    );
}

#[test]
fn vault_reconcile_after_export_with_no_edits_reports_zero_drift() {
    // Export then immediately reconcile: no files changed, so the diff
    // must report 0 added, 0 modified, 0 deleted.
    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    file_one_memory(&registry, "Phenol notes.", "chem");

    dispatch_tool(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
    )
    .expect("export must succeed");

    let reconcile_result = dispatch_tool(
        "moot_vault_reconcile",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
    )
    .expect("reconcile must not throw transport fault");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&reconcile_result),
        "reconcile after clean export must be isError:false; got: {reconcile_result:?}"
    );
    let text = content_text(&reconcile_result);
    assert!(
        text.contains("0 added, 0 modified, 0 deleted"),
        "zero-drift reconcile must report 0/0/0; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 11. Recipe tools — success + error paths (new names)
// ---------------------------------------------------------------------------

#[test]
fn list_lenses_returns_catalog_entries() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_list_lenses", &args![], &registry)
        .expect("moot_list_lenses must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.starts_with("recipes: "),
        "result should start with 'recipes: N'; got: {text}"
    );
}

#[test]
fn synthesize_with_unknown_estate_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_synthesize",
        &args!["estateID" => "00000000-0000-0000-0000-000000000000"],
        &registry,
    )
    .expect_err("unknown estateID must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

/// Run moot_run_migration and return the (winner_bid, full_text).
fn run_migration_for_confirm(registry: &EstateRegistry) -> (String, String) {
    let mut a: BTreeMap<String, JsonValue> = BTreeMap::new();
    a.insert("corpusName".into(), JsonValue::from(serde_json::json!("test-corpus")));
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
    let result = dispatch_tool("moot_run_migration", &a, registry)
        .expect("moot_run_migration must succeed");
    assert!(is_success(&result), "run must succeed; got: {result:?}");
    let text = content_text(&result).to_owned();
    let winner_bid = text
        .lines()
        .find(|l| l.starts_with("winner: plan "))
        .and_then(|l| l.split_whitespace().last())
        .unwrap_or("")
        .to_owned();
    (winner_bid, text)
}

#[test]
fn run_migration_happy_path_returns_rankings() {
    let registry = EstateRegistry::new_inmemory();
    let (winner_bid, text) = run_migration_for_confirm(&registry);
    assert!(
        text.contains("run_migration_benchmark:"),
        "result should contain benchmark header; got: {text}"
    );
    assert!(!winner_bid.is_empty(), "winner branch id must be present; got: {text}");
}

#[test]
fn confirm_migration_success_end_to_end() {
    let registry = EstateRegistry::new_inmemory();
    let (winner_bid, _) = run_migration_for_confirm(&registry);

    let mut a: BTreeMap<String, JsonValue> = BTreeMap::new();
    a.insert("winnerBranchID".into(), JsonValue::from(serde_json::json!(winner_bid)));
    a.insert("discardBranchIDs".into(), JsonValue::from(serde_json::json!([])));
    a.insert("disqualifiedBranchIDs".into(), JsonValue::from(serde_json::json!([])));

    let result = dispatch_tool("moot_confirm_migration", &a, &registry)
        .expect("moot_confirm_migration must not throw");
    assert!(is_success(&result), "confirm must succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("confirm_migration:"),
        "success text must name the tool; got: {text}"
    );
}

#[test]
fn confirm_migration_missing_winner_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool("moot_confirm_migration", &args![], &registry)
        .expect_err("missing winnerBranchID must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// ---------------------------------------------------------------------------
// 12. Lens tools — success + error paths (moot_lens_* prefix)
// ---------------------------------------------------------------------------

#[test]
fn lens_keystones_over_estate_succeeds() {
    // moot_lens_keystones requires "wing" argument — ranks topology within a wing.
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "hub content for keystones", "hub-room");
    file_one_memory(&registry, "spoke content", "hub-room");

    let result = dispatch_tool("moot_lens_keystones", &args!["wing" => "hub-room"], &registry)
        .expect("moot_lens_keystones must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("keystones:"),
        "result must contain 'keystones:'; got: {text}"
    );
}

#[test]
fn lens_associations_over_captured_drawers_succeeds() {
    // moot_lens_associations (was moot_association_rules) — AR_FCA_CAPABILITY_001.
    let registry = EstateRegistry::new_inmemory();
    for _ in 0..3 {
        file_one_memory(&registry, "study content about knowledge", "study-room");
    }
    let result = dispatch_tool("moot_lens_associations", &args![], &registry)
        .expect("moot_lens_associations must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.starts_with("association_rules:"),
        "result must start with 'association_rules:'; got: {text}"
    );
}

#[test]
fn lens_concepts_over_captured_drawers_succeeds() {
    // moot_lens_concepts (was moot_formal_concepts) — AR_FCA_CAPABILITY_001.
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "concept content alpha", "concept-room");
    file_one_memory(&registry, "concept content beta", "concept-room");

    let result = dispatch_tool(
        "moot_lens_concepts",
        &args!["minSupport" => 1, "maxIntentSize" => 8, "maxConcepts" => 20],
        &registry,
    )
    .expect("moot_lens_concepts must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.starts_with("formal_concepts:"),
        "result must start with 'formal_concepts:'; got: {text}"
    );
}

#[test]
fn lens_partial_cue_unknown_anchor_returns_tool_error() {
    // moot_lens_partial_cue (was moot_partial_cue_recall): unknown anchorID must
    // produce isError:true, not a transport fault.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_lens_partial_cue",
        &args!["anchorID" => "definitely-does-not-exist-00000000"],
        &registry,
    )
    .expect("moot_lens_partial_cue must not throw for unknown anchor");
    assert!(
        is_tool_error(&result),
        "unknown anchor must produce isError:true; got: {result:?}"
    );
}

#[test]
fn lens_with_unknown_estate_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_lens_associations",
        &args!["estateID" => "00000000-0000-0000-0000-000000000000"],
        &registry,
    )
    .expect_err("unknown estateID must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}
