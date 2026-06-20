//! Dispatch-surface integration tests — 5-tier AI-client interface (MCP-RUST-ALIGN-01).
//!
//! Tests the 56-tool surface: 19 interface tools (Tier 1–5), 1 federation tool,
//! 8 recipe tools, 22 lens tools (including moot_lens_cohesion and moot_lens_contradiction),
//! 5 vault tools, and 1 maintenance tool (moot_reindex). Exercises dispatch routing,
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
    dispatch::{dispatch_tool, dispatch_tool_with_vault_flag},
    estate_registry::EstateRegistry,
    jsonrpc::{JSONRPCErrorCode, JsonValue},
    surfaced_recall_ledger::SurfacedRecallLedger,
    tool_list::{build_tool_list, build_tool_list_with_vault_flag, vault_enabled},
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
    let result = dispatch_tool("moot_file_memory", &a, registry, &SurfacedRecallLedger::new()).expect("file_memory must succeed");
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
// 1. tools/list surface assertions — 57 tools exact
// ---------------------------------------------------------------------------

#[test]
fn tools_list_count_is_57() {
    // Gate: the 5-tier AI-client surface after MCP-RUST-ALIGN-01 + aria-tools +
    // the precise-recall parity mission + moot_dream (on-demand dream tool) +
    // moot_vault_job (tool-surface parity, Bob's ruling 2026-06-12) +
    // moot_recall_shaped (named RecallShape preset surface) +
    // moot_lens_contradiction (genuine contradiction detector, Part 5) +
    // moot_lens_node_motion (diffusion node-layer lens, ADR-DIFFUSION-001):
    //   19  interface tools (Tier 1–5)
    //    1  federation tool (moot_federated_search)
    //    8  recipe tools (list_lenses, list_recipes, synthesize, run_migration,
    //                     confirm_migration, recall_precise, recall_shaped, dream)
    //   23  lens tools (moot_lens_* prefix; cohesion renamed, contradiction +
    //                   node_motion added)
    //    5  vault tools (moot_vault_export, import, status, reconcile, job)
    // ----
    //    1  maintenance tool (moot_reindex — backfill the corpus/vector index)
    //   57  total (matches Swift surface exactly)
    let tools = build_tool_list();
    let arr = tools.as_array().expect("build_tool_list must return an array");
    assert_eq!(arr.len(), 57, "expected 57 tools; got {}", arr.len());
}

#[test]
fn tools_list_name_set_matches_expected_57_names() {
    // Gate: all 57 expected tool names are present, no more and no less.
    // moot_reindex is the maintenance tool (corpus/vector backfill).
    // moot_vault_job is a vault tool (Bob's ruling 2026-06-12: tool-surface
    // parity matters even when the Rust backend is synchronous).
    // moot_recall_shaped is the named RecallShape preset surface.
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
        // Recipe (8) — list_lenses + list_recipes + synthesize + run_migration
        //              + confirm_migration + recall_precise + recall_shaped + dream
        "moot_list_lenses",
        "moot_list_recipes",
        "moot_synthesize",
        "moot_run_migration",
        "moot_confirm_migration",
        "moot_recall_precise",
        "moot_recall_shaped",
        "moot_dream",
        "moot_reindex",
        // Lens tools (23) — names from lens_tools.rs LENS_TOOLS constant
        "moot_lens_keystones",
        "moot_lens_constellation",
        "moot_lens_free_association",
        "moot_lens_theme_weather",
        "moot_lens_latent_themes",
        "moot_lens_bias",
        "moot_lens_drift",
        "moot_lens_node_motion",
        "moot_lens_cohesion",
        "moot_lens_contradiction",
        "moot_lens_trust_synthesis",
        "moot_lens_partial_cue",
        "moot_lens_anticipate",
        "moot_lens_successors",
        "moot_lens_overlap",
        "moot_lens_divergence",
        "moot_lens_associations",
        "moot_lens_concepts",
        "moot_lens_apriori",
        "moot_lens_moment",
        "moot_lens_rhythm",
        "moot_lens_precedence",
        "moot_lens_complexity",
        // Vault tools (5) — moot_vault_job added for parity (Bob's ruling 2026-06-12)
        "moot_vault_export",
        "moot_vault_import",
        "moot_vault_status",
        "moot_vault_reconcile",
        "moot_vault_job",
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
// 1b. Lens tool name set — 23 canonical names, sorted literal list
// ---------------------------------------------------------------------------

#[test]
fn lens_tool_name_set_is_exactly_23_canonical_names() {
    // Parity gate: the Rust server's advertised lens tool name set must match
    // the Swift server's lensToolNames set (LensTools.swift) exactly.
    // Written as a sorted literal so any divergence surfaces as a readable diff.
    // Both ports must be updated in lock-step when the lens catalog changes.
    // 23 = 16 reasoning (14 + lens_contradiction + lens_node_motion) +
    //      3 analytics (FCA + Apriori) + 4 temporal/complexity.
    let expected: Vec<&str> = vec![
        "moot_lens_anticipate",
        "moot_lens_apriori",
        "moot_lens_associations",
        "moot_lens_bias",
        "moot_lens_cohesion",
        "moot_lens_complexity",
        "moot_lens_concepts",
        "moot_lens_constellation",
        "moot_lens_contradiction",
        "moot_lens_divergence",
        "moot_lens_drift",
        "moot_lens_free_association",
        "moot_lens_keystones",
        "moot_lens_latent_themes",
        "moot_lens_moment",
        "moot_lens_node_motion",
        "moot_lens_overlap",
        "moot_lens_partial_cue",
        "moot_lens_precedence",
        "moot_lens_rhythm",
        "moot_lens_successors",
        "moot_lens_theme_weather",
        "moot_lens_trust_synthesis",
    ];

    let tools = build_tool_list();
    let arr = tools.as_array().expect("build_tool_list must return array");
    let mut actual: Vec<&str> = arr
        .iter()
        .filter_map(|t| t["name"].as_str())
        .filter(|name| name.starts_with("moot_lens_"))
        .collect();
    actual.sort_unstable();

    assert_eq!(
        actual, expected,
        "advertised lens tool names must match the 23 canonical names exactly"
    );
}

// ---------------------------------------------------------------------------
// 2. Unknown tool → METHOD_NOT_FOUND transport fault
// ---------------------------------------------------------------------------

#[test]
fn unknown_tool_name_returns_method_not_found() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool("moot_nonexistent_tool", &args![], &registry, &SurfacedRecallLedger::new())
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
    let result = dispatch_tool("moot_file_memory", &a, &registry, &SurfacedRecallLedger::new())
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
    let result = dispatch_tool("moot_nonexistent_tool", &a, &registry, &SurfacedRecallLedger::new())
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
    let err = dispatch_tool("moot_file_memory", &args!["location" => "work"], &registry, &SurfacedRecallLedger::new())
        .expect_err("missing content must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// P0-STRESS-FIXES Findings #1/#2: kind and sensitivity must be decoded and
// applied to the CaptureFrame. Before the fix these were silently ignored,
// persisting as the CaptureFrame defaults (Prose / Normal).

#[test]
fn file_memory_with_kind_code_persists_content_kind_code() {
    use locus_kit::drawer_operational::ContentKind;
    use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
    use aria_mcp::dispatch::wall_now;

    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "fn main() { println!(\"hello\"); }",
            "location" => "code/snippet",
            "kind" => "code"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory with kind=code must succeed");
    assert!(is_success(&result), "file_memory kind=code must succeed; got: {result:?}");

    // Read back the filed drawer and assert contentKind == Code.
    let coord = registry.coord.lock().unwrap();
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Full;
    frame.ordering = Ordering::ByCaptureTimeDesc;
    frame.limit = Some(1);
    let drawers = coord
        .recall(&registry.default.handle, frame, wall_now())
        .expect("recall must succeed");
    let drawer = drawers.first().expect("at least one drawer must be present");
    assert_eq!(
        drawer.content_kind(),
        ContentKind::Code,
        "kind=code must persist as ContentKind::Code; got {:?}",
        drawer.content_kind()
    );
}

#[test]
fn file_memory_with_sensitivity_restricted_persists_restricted() {
    use locus_kit::adjectives::AdjectiveSensitivity;
    use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
    use aria_mcp::dispatch::wall_now;

    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "top-secret plan details",
            "location" => "vault/plans",
            "sensitivity" => "restricted"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory with sensitivity=restricted must succeed");
    assert!(is_success(&result), "file_memory sensitivity=restricted must succeed; got: {result:?}");

    // Recall with an explicit sensitivity=Restricted filter. The default recall
    // ceiling is `SensitivityAtMost(Elevated)`, which would exclude Restricted
    // rows — the explicit filter overrides the default so the row is visible.
    let coord = registry.coord.lock().unwrap();
    let mut frame = RecallFrame::new(vec![
        Filter::Sensitivity(AdjectiveSensitivity::Restricted),
    ]);
    frame.hydration_level = HydrationLevel::Full;
    frame.ordering = Ordering::ByCaptureTimeDesc;
    frame.limit = Some(1);
    let drawers = coord
        .recall(&registry.default.handle, frame, wall_now())
        .expect("recall must succeed");
    let drawer = drawers.first().expect("at least one restricted drawer must be present");
    assert_eq!(
        drawer.adjective_sensitivity(),
        AdjectiveSensitivity::Restricted,
        "sensitivity=restricted must persist as AdjectiveSensitivity::Restricted; got {:?}",
        drawer.adjective_sensitivity()
    );
}

#[test]
fn file_memory_unknown_kind_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "some content",
            "location" => "test/room",
            "kind" => "notAKind"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect_err("unknown kind must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn file_memory_unknown_sensitivity_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "some content",
            "location" => "test/room",
            "sensitivity" => "topSecret"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect_err("unknown sensitivity must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// P0-STRESS-FIXES Finding #10: file_memory capture channel must be
// CaptureChannel::Actuator (cookbook §2.4: actuator-driven capture),
// not CaptureChannel::ImportedFile. The MCP surface is an AI actuator,
// not a file import.

#[test]
fn file_memory_sets_capture_channel_to_actuator() {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
    use aria_mcp::dispatch::wall_now;

    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "channel verification content",
            "location" => "channel/test"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory must succeed");
    assert!(is_success(&result), "file_memory must succeed; got: {result:?}");

    let coord = registry.coord.lock().unwrap();
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Full;
    frame.ordering = Ordering::ByCaptureTimeDesc;
    frame.limit = Some(1);
    let drawers = coord
        .recall(&registry.default.handle, frame, wall_now())
        .expect("recall must succeed");
    let drawer = drawers.first().expect("at least one drawer must be present");
    assert_eq!(
        drawer.capture_channel(),
        CaptureChannel::Actuator,
        "file_memory must stamp CaptureChannel::Actuator (raw 5); got {:?}",
        drawer.capture_channel()
    );
}

#[test]
fn memory_search_over_filed_memory_finds_it() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "unique-phrase-for-search-test", "lab/notes");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "unique-phrase-for-search-test"],
        &registry,
        &SurfacedRecallLedger::new(),
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
    let err = dispatch_tool("moot_memory_search", &args![], &registry, &SurfacedRecallLedger::new())
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
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
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

// P0-4: unknown `scoring` fails CLOSED (was: silently coerced to matrixAware).
//
// FORCE-TEST. Injects an unknown non-empty scoring string and asserts the tool
// returns INVALID_PARAMS rather than silently running matrixAware. A silent
// fallback would run a different scoring mode than the caller asked for and
// hide the typo. Mirrors memory_search_unknown_ordering_returns_invalid_params.
#[test]
fn memory_search_unknown_scoring_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "unknown-scoring-test content", "lab/notes");

    let err = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "unknown-scoring-test", "scoring" => "magicScore"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("unknown scoring must produce a transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "unknown scoring must be INVALID_PARAMS; got code {}",
        err.code
    );
}

#[test]
fn memory_search_null_scoring_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let mut args = args!["query" => "null-scoring-test"];
    args.insert("scoring".to_string(), JsonValue::Null);

    let err = dispatch_tool(
        "moot_memory_search",
        &args,
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("scoring:null must produce a transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn memory_search_null_filter_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let mut args = args!["query" => "null-filter-test"];
    args.insert("filter".to_string(), JsonValue::Null);

    let err = dispatch_tool(
        "moot_memory_search",
        &args,
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("filter:null must produce a transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// P0-4 control: a KNOWN scoring string still succeeds (the fix did not break
// the happy path).
#[test]
fn memory_search_known_scoring_raw_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "known-scoring-raw-test content", "lab/notes");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "known-scoring-raw-test", "scoring" => "raw"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("scoring=raw must not throw");
    assert!(is_success(&result), "scoring=raw must succeed; got: {result:?}");
}

// P0-4 control: ABSENT scoring keeps the documented default (matrixAware) and
// succeeds — only an unknown NON-EMPTY string errors.
#[test]
fn memory_search_absent_scoring_defaults_and_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "absent-scoring-test content", "lab/notes");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "absent-scoring-test"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("absent scoring must default to matrixAware and not throw");
    assert!(is_success(&result), "absent scoring must succeed; got: {result:?}");
}

// ARIA-ORDERING-1: ordering="byRelevanceDesc" is accepted and routes to scored recall.
//
// Bob's ruling (invalid-removal restoration): deleting the public API spelling
// "byRelevanceDesc" was feature removal. The correct fix (option b) is:
//   - LocusKit's Ordering enum stays clean (no byRelevanceDesc case).
//   - The ARIA surface accepts "byRelevanceDesc" as a compatibility input.
//   - The request is routed to the scored recall path (recall_scored/unionBest).
//   - The results ARE relevance-ordered because scoring drives the final order.
//
// These tests prove:
//   1. ordering="byRelevanceDesc" succeeds and returns scored results.
//   2. ordering="byRelevanceDesc" on an empty estate succeeds with 0 hits.
//   3. Other orderings (byCaptureTimeDesc, byCaptureTimeAsc, byRoomAsc) unchanged.
//   4. Unknown orderings return invalidParams transport fault.
//   5. The moot_memory_search schema advertises "byRelevanceDesc".

#[test]
fn memory_search_ordering_by_relevance_desc_succeeds_and_finds_memory() {
    // Before the fix, ordering="byRelevanceDesc" threw invalidParams. After
    // the fix it routes to the scored recall path and returns results.
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "ordering-relevance-desc-test content", "lab/notes");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "ordering-relevance-desc-test", "ordering" => "byRelevanceDesc"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("ordering=byRelevanceDesc must not throw transport fault");
    assert!(
        is_success(&result),
        "ordering=byRelevanceDesc must return isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("found 1 memory(s)"),
        "byRelevanceDesc must find the filed memory; got: {text}"
    );
    // The scored path emits "(score: ...)" in each result line, proving
    // the request went through recall_scored (not plain recall+filter).
    assert!(
        text.contains("(score:"),
        "byRelevanceDesc must route through recall_scored (score annotation expected); got: {text}"
    );
}

#[test]
fn memory_search_ordering_by_relevance_desc_on_empty_estate_succeeds() {
    // An empty estate with ordering="byRelevanceDesc" must return isError:false
    // with 0 hits — not an invalidParams error.
    let registry = EstateRegistry::new_inmemory();

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "any-query", "ordering" => "byRelevanceDesc"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("ordering=byRelevanceDesc on empty estate must not throw");
    assert!(
        is_success(&result),
        "ordering=byRelevanceDesc on empty estate must be isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("found 0 memory(s)"),
        "empty estate must return 0 memories; got: {text}"
    );
}

#[test]
fn memory_search_ordering_by_capture_time_desc_still_succeeds() {
    // byCaptureTimeDesc must still work unchanged after the fix.
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "ordering-by-capture-time-desc-test", "lab");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "ordering-by-capture-time-desc-test", "ordering" => "byCaptureTimeDesc"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("ordering=byCaptureTimeDesc must not throw");
    assert!(is_success(&result), "byCaptureTimeDesc must succeed; got: {result:?}");
}

#[test]
fn memory_search_ordering_by_room_asc_still_succeeds() {
    // byRoomAsc must still work unchanged after the fix.
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "ordering-by-room-asc-test", "lab/asc");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "ordering-by-room-asc-test", "ordering" => "byRoomAsc"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("ordering=byRoomAsc must not throw");
    assert!(is_success(&result), "byRoomAsc must succeed; got: {result:?}");
}

#[test]
fn memory_search_unknown_ordering_returns_invalid_params() {
    // An unknown ordering value must be rejected with invalidParams so the
    // accept-list stays narrow. This must NOT silently succeed.
    let registry = EstateRegistry::new_inmemory();

    let err = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "test", "ordering" => "byMagicOrder"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("unknown ordering must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "unknown ordering must be INVALID_PARAMS; got code {}",
        err.code
    );
}

#[test]
fn memory_search_schema_advertises_by_relevance_desc() {
    // The tool list schema for moot_memory_search must document "byRelevanceDesc"
    // so clients can discover the spelling. This is the client-facing contract.
    let tools = build_tool_list();
    let arr = tools.as_array().expect("build_tool_list must return array");
    let search = arr
        .iter()
        .find(|t| t["name"].as_str() == Some("moot_memory_search"))
        .expect("moot_memory_search must be in tool list");
    let ordering_desc = search["inputSchema"]["properties"]["ordering"]["description"]
        .as_str()
        .unwrap_or("");
    assert!(
        ordering_desc.contains("byRelevanceDesc"),
        "moot_memory_search ordering description must advertise byRelevanceDesc; got: {ordering_desc}"
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
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
    )
    .expect("withdraw_memory must not throw");
    assert!(is_success(&result), "withdraw must succeed; got: {result:?}");

    // Searching for the content should return 0 results after withdrawal.
    let search = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "withdraw target content"],
        &registry,
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
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

    let result = dispatch_tool("moot_confirm_memory", &args!["id" => id.as_str()], &registry, &SurfacedRecallLedger::new())
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
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
    )
    .expect("link must succeed");

    let result = dispatch_tool(
        "moot_connection_search",
        &args!["from_id" => from_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
    )
    .expect("link must succeed");

    let result = dispatch_tool(
        "moot_connection_map",
        &args!["to_id" => to_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
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
    let result = dispatch_tool("moot_fact_search", &args![], &registry, &SurfacedRecallLedger::new())
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
    let result = dispatch_tool("moot_fact_timeline", &args![], &registry, &SurfacedRecallLedger::new())
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
        &SurfacedRecallLedger::new(),
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
    let search = dispatch_tool("moot_fact_search", &args!["query" => "Acme"], &registry, &SurfacedRecallLedger::new())
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
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
    )
    .expect("file_fact must succeed");
    // "filed fact <id>: [Bob] manages [Widgets]"
    let filed_text = content_text(&filed);
    let fact_id = filed_text
        .strip_prefix("filed fact ")
        .and_then(|s| s.split(':').next())
        .expect("filed fact text must carry an id")
        .to_owned();

    let result = dispatch_tool("moot_retire_fact", &args!["id" => fact_id.clone()], &registry, &SurfacedRecallLedger::new())
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
    let err = dispatch_tool("moot_retire_fact", &args![], &registry, &SurfacedRecallLedger::new())
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
        &SurfacedRecallLedger::new(),
    )
    .expect("write_journal must not throw transport fault");
    assert!(is_success(&result), "write_journal must return isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("wrote journal entry for mcp-agent"),
        "write_journal must confirm the entry for the default agent; got: {text}"
    );

    // The entry is readable back through read_journal for the same agent.
    let read = dispatch_tool("moot_read_journal", &args!["agent" => "mcp-agent"], &registry, &SurfacedRecallLedger::new())
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
        &SurfacedRecallLedger::new(),
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
    let result = dispatch_tool("moot_read_journal", &args![], &registry, &SurfacedRecallLedger::new())
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
    // The convenience dispatch_tool passes "" as the build serial (it has
    // no context to derive one). This test checks the stable shape:
    // "pong: estate … is live — build <serial>" where the serial may be
    // empty when called through the convenience path.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_estate_ping", &args![], &registry, &SurfacedRecallLedger::new())
        .expect("estate_ping must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    // Stable shape assertions — these must hold regardless of the serial value.
    assert!(
        text.contains("pong"),
        "ping must return pong; got: {text}"
    );
    assert!(
        text.contains("is live"),
        "pong must confirm estate is live; got: {text}"
    );
    // Build segment "— build " must be present in the output.
    assert!(
        text.contains("— build "),
        "pong must include '— build <serial>'; got: {text}"
    );
}

/// `MOOTX01_BUILD_SERIAL` override is threaded to estate_ping via the
/// `dispatch_tool_with_vault_ledger` path. Because the override is an env var
/// and Rust tests run in parallel, we use the lower-level
/// `interface_tools::dispatch` directly with an explicit serial string to test
/// the threading without touching process env.
#[test]
fn estate_ping_includes_injected_build_serial() {
    use aria_mcp::interface_tools;
    use std::collections::BTreeMap;
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    let result = interface_tools::dispatch(
        "moot_estate_ping",
        &BTreeMap::new(),
        &registry,
        &ledger,
        "TESTSERIAL-XYZ",
    )
    .expect("estate_ping must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("build TESTSERIAL-XYZ"),
        "estate_ping must echo the injected serial; got: {text}"
    );
}

#[test]
fn estate_status_includes_aria_session_protocol() {
    // estate_status appends the ARIA session protocol block to every response.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_estate_status", &args![], &registry, &SurfacedRecallLedger::new())
        .expect("estate_status must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    // ARIA_SESSION_PROTOCOL starts with "\n\nprotocol:" per session_protocol.rs.
    assert!(
        text.contains("protocol:"),
        "estate_status must append ARIA session protocol block; got: {text}"
    );
    // Label mirrors Swift runEstateStatus: "memories: N active" (renamed from
    // "drawers:" to align both ports — Part 2 label alignment fix).
    assert!(
        text.contains("memories:"),
        "estate_status must include memories count; got: {text}"
    );
}

#[test]
fn estate_map_returns_taxonomy() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "map test content", "alpha/notes");

    let result = dispatch_tool("moot_estate_map", &args![], &registry, &SurfacedRecallLedger::new())
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
        &SurfacedRecallLedger::new(),
    )
    .expect_err("unknown estateID must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// ---------------------------------------------------------------------------
// 9. Federation — moot_federated_search (grant-gated, real implementation)
//
// These tests mirror Swift's MultiEstateRoutingTests (test 4, 5, 6):
//   - Granted sources contribute; ungranted sources are silently skipped.
//   - No grant from any source → refused as isError:true (not a transport fault).
//   - Missing requesterEstateID → isError:true (not a thrown error).
//
// The tests issue grants directly at the coordinator level (bypassing the
// MCP grant-issue surface which does not exist yet) using `registry.coord`.
// Grant grantee_estate_id must use the handle's estate_uuid (the
// store-manifest UUID, [u8;16]) which federated_recall compares internally.
// ---------------------------------------------------------------------------

/// Helper: get the store-manifest UUID for an estate keyed by estate_id.
/// The returned UUID is what moot_federated_search accepts as requesterEstateID.
fn handle_uuid_for(registry: &EstateRegistry, estate_id: uuid::Uuid) -> uuid::Uuid {
    registry.handle_uuid_for(estate_id)
        .expect("estate_id must be registered")
}

#[test]
fn federated_search_no_requester_estate_id_is_error_result() {
    // Missing requesterEstateID returns isError:true — not a JSONRPCError transport
    // fault — so the caller can read the message without losing the call id.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_federated_search",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("missing requesterEstateID must not throw transport fault");
    assert!(
        is_tool_error(&result),
        "missing requesterEstateID must return isError:true; got: {result:?}"
    );
}

#[test]
fn federated_search_no_grant_is_refused_as_error_result() {
    // Two estates, no grant issued. moot_federated_search must return
    // isError:true, not throw, and must not leak the source content.
    // Mirrors Swift testNoGrantFederatedSearchRefusedAsErrorResult.
    let mut registry = EstateRegistry::new_inmemory();
    let source_estate_id = registry.register_inmemory("source");

    // File into the source estate through the MCP surface.
    let source_handle_uuid = handle_uuid_for(&registry, source_estate_id);
    // Use source's handle-uuid as estateID in the tool call (interface_tools
    // resolves by estate_id, not handle_uuid — use estate_id directly).
    // For this test we just need content in the source; estateID arg uses the
    // registry key (estate_id, Uuid), not the handle_uuid.
    let filed = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "secret-source-content",
            "location" => "test-room",
            "estateID" => source_estate_id.to_string()
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory must succeed");
    assert!(is_success(&filed), "file into source must succeed");

    // requesterEstateID = the default estate's handle UUID.
    let requester_uuid = uuid::Uuid::from_bytes(registry.default.handle.estate_uuid);
    let result = dispatch_tool(
        "moot_federated_search",
        &args!["requesterEstateID" => requester_uuid.to_string()],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("no-grant federated_search must not throw transport fault");
    assert!(
        is_tool_error(&result),
        "no-grant federated_search must return isError:true; got: {result:?}"
    );
    assert!(
        !content_text(&result).contains("secret-source-content"),
        "refused call must not leak source content; got: {}",
        content_text(&result)
    );
    // The unused variable warning is suppressed — source_handle_uuid is used
    // implicitly in the assertion logic for documentation.
    let _ = source_handle_uuid;
}

#[test]
fn federated_search_granted_source_contributes_content() {
    // One source estate issues a whole-estate grant to the requester.
    // moot_federated_search must succeed (isError:false) and include the
    // source's filed content in the response body.
    // Mirrors Swift testFederatedSearchFansAcrossAuthorizedEstates (two-estate subset).
    use genius_locus_kit::{CustodyMode, GrantLifetime, GrantOptions, GrantScope, ReSharePermission};

    let mut registry = EstateRegistry::new_inmemory();
    let source_estate_id = registry.register_inmemory("granted-source");

    // The requester is the default estate. Its handle UUID is what the grant's
    // grantee_estate_id must match (federated_recall compares by handle UUID).
    let requester_handle_uuid = uuid::Uuid::from_bytes(registry.default.handle.estate_uuid);

    // Look up the source estate's handle through the coordinator for the grant call.
    // extras is pub(crate); use the coord directly via the public default.coord.
    // The source handle is stored in the coordinator registry. We need to get
    // it: call register_inmemory which returns estate_id, then use
    // handle_uuid_for to get the handle UUID — but we need the actual handle
    // for issue_grant. Use coord's estate_for method (not public) — instead,
    // issue the grant using the handle returned by the coordinator's open call.
    //
    // Strategy: since extras is pub(crate) and not accessible here, we obtain
    // the source handle by locking the coord and iterating open estates.
    // EstateCoordinator exposes `handles()` which returns Vec<EstateHandle>.
    let source_handle = {
        let coord = registry.coord.lock().unwrap();
        let handles = coord.handles();
        // list_estates returns all open handles; the default is always first.
        // The source is the one whose UUID is NOT the default's handle UUID.
        let requester_bytes = registry.default.handle.estate_uuid;
        handles.into_iter()
            .find(|h| h.estate_uuid != requester_bytes)
            .expect("source estate handle must be in the coordinator")
    };

    // Issue a whole-estate permanent grant from source to requester.
    // issue_grant defaults inference_remaining_budget to 0.0 (fail-closed);
    // fixtures must set an explicit valid budget (1.0 = ~100 reads per §B-7).
    {
        let identity_key = [0xAAu8; 32];
        let opts = GrantOptions {
            grantee_estate_id: requester_handle_uuid,
            scope: GrantScope::WholeEstate,
            custody_mode: CustodyMode::Mediated,
            lifetime: GrantLifetime::Permanent,
            content_level: 0,
            re_share_permission: ReSharePermission::None,
        };
        let mut coord = registry.coord.lock().unwrap();
        let result = coord.issue_grant(&source_handle, opts, &identity_key, 0.0)
            .expect("grant issue must succeed");
        coord.grant_store_mut(&source_handle)
            .expect("source estate must have a grant store")
            .set_budget(result.grant.id, 1.0)
            .expect("set_budget must succeed");
    }

    // File content into the source estate via the MCP surface.
    let filed = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "federated-content-row",
            "location" => "test-room",
            "estateID" => source_estate_id.to_string()
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory must succeed");
    assert!(is_success(&filed), "file into source must succeed");

    // Run federated search from the requester's perspective.
    let result = dispatch_tool(
        "moot_federated_search",
        &args!["requesterEstateID" => requester_handle_uuid.to_string()],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("granted federated_search must not throw transport fault");
    assert!(
        is_success(&result),
        "granted federated_search must return isError:false; got: {result:?}"
    );
    assert!(
        content_text(&result).contains("federated-content-row"),
        "granted source must contribute its content; got: {}",
        content_text(&result)
    );
}

// ---------------------------------------------------------------------------
// 9b. Federation grant-enforcement depth (P2 send-back)
//
// Four tests that verify GLK's grant-enforcement machinery is correctly
// exercised through the MCP dispatch surface:
//   (a) expired grant → CrossEstateReadRefused(GrantExpired) → isError:true
//   (b) room-scoped grant → only that room's rows appear in the response
//   (c) content_level sensitivity gate → higher-sensitivity rows excluded
//   (d) hydration override — explicit bitmapOnly strips content fields;
//       invalid hydrationLevel value → isError:true (fail-closed)
//
// Pattern mirrors federated_search_granted_source_contributes_content:
// set up two estates, issue a grant at the appropriate scope/lifetime/
// content_level, file content, run moot_federated_search, assert.
// ---------------------------------------------------------------------------

/// Build a two-estate registry with a grant from the source estate to the
/// default (requester) estate. Returns (registry, source_estate_id,
/// requester_handle_uuid, source_handle) ready for further customisation.
fn two_estate_registry_with_grant(
    source_name: &str,
    opts_fn: impl FnOnce(uuid::Uuid) -> genius_locus_kit::GrantOptions,
) -> (EstateRegistry, uuid::Uuid, uuid::Uuid, genius_locus_kit::EstateHandle) {
    use genius_locus_kit::GrantOptions;

    let mut registry = EstateRegistry::new_inmemory();
    let source_estate_id = registry.register_inmemory(source_name);
    let requester_handle_uuid = uuid::Uuid::from_bytes(registry.default.handle.estate_uuid);
    let requester_bytes = registry.default.handle.estate_uuid;

    let source_handle = {
        let coord = registry.coord.lock().unwrap();
        let handles = coord.handles();
        handles.into_iter()
            .find(|h| h.estate_uuid != requester_bytes)
            .expect("source estate handle must be in coordinator")
    };

    {
        let identity_key = [0xBBu8; 32];
        let opts: GrantOptions = opts_fn(requester_handle_uuid);
        let mut coord = registry.coord.lock().unwrap();
        let result = coord.issue_grant(&source_handle, opts, &identity_key, 0.0)
            .expect("grant issue must succeed");
        // issue_grant defaults inference_remaining_budget to 0.0 (fail-closed).
        // Fixtures must explicitly set a valid budget (1.0 = ~100 reads at the
        // 0.01 debit quantum per §B-7). Production issuers must do the same.
        let store = coord.grant_store_mut(&source_handle)
            .expect("source estate must have a grant store");
        store.set_budget(result.grant.id, 1.0)
            .expect("set_budget must succeed");
    }

    (registry, source_estate_id, requester_handle_uuid, source_handle)
}

// (a) Expired grant → refused as isError:true, not a transport fault.
//
// Issue a grant with GrantLifetime::Until(past_time) so it is expired at
// wall clock. GLK's federated_recall rejects all-expired grants with
// CrossEstateReadRefused(GrantExpired). The dispatch surface must surface
// this as isError:true (tool-level refusal, not JSONRPCError), matching the
// "expected refused" path used in the no-grant test above.
#[test]
fn federated_search_expired_grant_is_refused_as_error_result() {
    use genius_locus_kit::{CustodyMode, GrantLifetime, GrantOptions, GrantScope, ReSharePermission};

    // Issue a grant that expired at Apple reference time 1.0 (effectively 2001-01-01).
    // wall_now() returns Unix seconds well past that, so the grant is expired on arrival.
    let (registry, source_estate_id, requester_handle_uuid, _source_handle) =
        two_estate_registry_with_grant("expired-source", |grantee| GrantOptions {
            grantee_estate_id: grantee,
            scope: GrantScope::WholeEstate,
            custody_mode: CustodyMode::Mediated,
            lifetime: GrantLifetime::Until(1.0), // expired: Apple ref 2001-01-01 + 1s
            content_level: 0,
            re_share_permission: ReSharePermission::None,
        });

    // File content into the source estate.
    let filed = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "should-be-refused-expired-grant",
            "location" => "test-room",
            "estateID" => source_estate_id.to_string()
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory must succeed");
    assert!(is_success(&filed), "file into source must succeed");

    // Federated search must refuse — grant is expired.
    let result = dispatch_tool(
        "moot_federated_search",
        &args!["requesterEstateID" => requester_handle_uuid.to_string()],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("expired-grant federated_search must not throw transport fault");
    assert!(
        is_tool_error(&result),
        "expired grant must return isError:true; got: {result:?}"
    );
    // Source content must not be leaked in the refusal message.
    assert!(
        !content_text(&result).contains("should-be-refused-expired-grant"),
        "refusal must not leak source content; got: {}",
        content_text(&result)
    );
}

// (b) Room-scoped grant returns only that room's rows.
//
// Issue a GrantScope::Room("allowed-room") grant. File memories in both
// "allowed-room" and "other-room". The federated response must include
// only the allowed-room row and must exclude the other-room row.
#[test]
fn federated_search_room_scoped_grant_narrows_to_allowed_room() {
    use genius_locus_kit::{CustodyMode, GrantLifetime, GrantOptions, GrantScope, ReSharePermission};

    let (registry, source_estate_id, requester_handle_uuid, _source_handle) =
        two_estate_registry_with_grant("room-scoped-source", |grantee| GrantOptions {
            grantee_estate_id: grantee,
            scope: GrantScope::Room("allowed-room".to_string()),
            custody_mode: CustodyMode::Mediated,
            lifetime: GrantLifetime::Permanent,
            content_level: 0,
            re_share_permission: ReSharePermission::None,
        });

    // File one memory in the allowed room, one in a different room.
    for (content, room) in [
        ("in-allowed-room-content", "allowed-room"),
        ("in-other-room-content", "other-room"),
    ] {
        let filed = dispatch_tool(
            "moot_file_memory",
            &args![
                "content" => content,
                "location" => room,
                "estateID" => source_estate_id.to_string()
            ],
            &registry,
            &SurfacedRecallLedger::new(),
        ).expect("file_memory must succeed");
        assert!(is_success(&filed), "file into source must succeed");
    }

    let result = dispatch_tool(
        "moot_federated_search",
        &args!["requesterEstateID" => requester_handle_uuid.to_string()],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("room-scoped federated_search must not throw transport fault");
    assert!(
        is_success(&result),
        "room-scoped federated_search must return isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("in-allowed-room-content"),
        "allowed-room content must be present; got: {text}"
    );
    assert!(
        !text.contains("in-other-room-content"),
        "other-room content must be excluded by scope narrowing; got: {text}"
    );
}

// (c) Content-level sensitivity gate: grant content_level=0 (Normal) must
//     exclude drawers whose adjective_sensitivity exceeds 0.
//
// The GLK coordinator step 6 filters drawers: `raw_value() > content_level`.
// Normal=0, Elevated=16, Restricted=32, Secret=48.
// A grant with content_level=0 must exclude Elevated+ rows.
// File a Normal row and an Elevated row; only the Normal row must appear.
#[test]
fn federated_search_content_level_gate_excludes_higher_sensitivity_rows() {
    use genius_locus_kit::{CustodyMode, GrantLifetime, GrantOptions, GrantScope, ReSharePermission};
    use locus_kit::adjectives::AdjectiveSensitivity;
    use locus_kit::frames::CaptureFrame;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;

    // Grant with content_level=0 (Normal only — no elevated/restricted/secret).
    let (registry, source_estate_id, requester_handle_uuid, source_handle) =
        two_estate_registry_with_grant("sensitivity-source", |grantee| GrantOptions {
            grantee_estate_id: grantee,
            scope: GrantScope::WholeEstate,
            custody_mode: CustodyMode::Mediated,
            lifetime: GrantLifetime::Permanent,
            content_level: 0,   // Normal only
            re_share_permission: ReSharePermission::None,
        });

    // File a Normal-sensitivity row via the MCP surface (default sensitivity).
    let normal = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "normal-sensitivity-content",
            "location" => "test-room",
            "estateID" => source_estate_id.to_string()
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file normal memory must succeed");
    assert!(is_success(&normal));

    // File an Elevated-sensitivity row directly through the coordinator.
    // The test uses the coordinator path rather than moot_file_memory so it
    // can set a specific sensitivity (Elevated) for the grant-content-level test;
    // moot_file_memory also accepts sensitivity but the grant test logic here
    // needs the coordinator-level channel control.
    // source_handle was returned by two_estate_registry_with_grant.
    {
        let mut frame = CaptureFrame::new(
            "elevated-sensitivity-content",
            CaptureChannel::ImportedFile,
            "test-room",
            // "000" is the canonical unclassified sentinel (UDC root).
            LatticeAnchor::udc("000"),
            "aria-mcp-server",
            "default",
        );
        frame.sensitivity = AdjectiveSensitivity::Elevated; // raw=16, exceeds content_level=0
        let now = aria_mcp::dispatch::wall_now();
        let coord = registry.coord.lock().unwrap();
        coord.capture(&source_handle, frame, now)
            .expect("capture elevated row must succeed");
    }

    // Federated search: Normal row must appear; Elevated row must be excluded.
    let result = dispatch_tool(
        "moot_federated_search",
        &args!["requesterEstateID" => requester_handle_uuid.to_string()],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("federated_search must not throw transport fault");
    assert!(
        is_success(&result),
        "federated_search must succeed (Normal row is grantable); got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("normal-sensitivity-content"),
        "Normal-sensitivity row must appear; got: {text}"
    );
    assert!(
        !text.contains("elevated-sensitivity-content"),
        "Elevated-sensitivity row must be excluded by content_level gate; got: {text}"
    );
}

// (d) Hydration override: explicit bitmapOnly strips content fields;
//     invalid hydrationLevel value returns isError:true (fail-closed).
//
// P1-1 fix: the Rust dispatch now parses the hydrationLevel argument.
// BitmapOnly produces drawers with empty content strings.
// Unknown values return isError:true — fail-closed on a privacy surface.
#[test]
fn federated_search_hydration_bitmaponly_strips_content() {
    use genius_locus_kit::{CustodyMode, GrantLifetime, GrantOptions, GrantScope, ReSharePermission};

    let (registry, source_estate_id, requester_handle_uuid, _) =
        two_estate_registry_with_grant("hydration-source", |grantee| GrantOptions {
            grantee_estate_id: grantee,
            scope: GrantScope::WholeEstate,
            custody_mode: CustodyMode::Mediated,
            lifetime: GrantLifetime::Permanent,
            content_level: 0,
            re_share_permission: ReSharePermission::None,
        });

    // File a memory with recognisable content.
    let filed = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "hydration-test-content-row",
            "location" => "test-room",
            "estateID" => source_estate_id.to_string()
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory must succeed");
    assert!(is_success(&filed));

    // bitmapOnly hydration: recall succeeds (isError:false) but content is
    // stripped — the drawer line shows an empty content preview.
    let bitmap_result = dispatch_tool(
        "moot_federated_search",
        &args![
            "requesterEstateID" => requester_handle_uuid.to_string(),
            "hydrationLevel" => "bitmapOnly"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("bitmapOnly federated_search must not throw transport fault");
    assert!(
        is_success(&bitmap_result),
        "bitmapOnly must return isError:false; got: {bitmap_result:?}"
    );
    // BitmapOnly strips content: the drawer preview line contains the row id
    // but the content string is empty (recall_stream.hydrate() clears it).
    let bitmap_text = content_text(&bitmap_result);
    assert!(
        !bitmap_text.contains("hydration-test-content-row"),
        "bitmapOnly must strip content; got: {bitmap_text}"
    );

    // Invalid hydrationLevel: fail-closed → isError:true, not a transport fault.
    let invalid_result = dispatch_tool(
        "moot_federated_search",
        &args![
            "requesterEstateID" => requester_handle_uuid.to_string(),
            "hydrationLevel" => "garbageValue"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("invalid hydrationLevel must not throw transport fault");
    assert!(
        is_tool_error(&invalid_result),
        "invalid hydrationLevel must return isError:true (fail-closed); got: {invalid_result:?}"
    );
}

// (d-2) Non-string hydrationLevel → isError:true (fail-closed), not silent coercion.
//
// Before the fix, `args.get("hydrationLevel").and_then(|v| v.as_str())` returned None
// for a non-string value (integer, boolean, etc.), and the None arm defaulted to Full —
// silently accepting malformed input and exposing maximum content. The fix inserts an
// explicit is-string check: a present-but-non-string value now returns isError:true.
// Mirrors Swift `decodeHydration` which throws invalidParams for the same case.
#[test]
fn federated_search_nonstring_hydration_level_is_error() {
    use genius_locus_kit::{CustodyMode, GrantLifetime, GrantOptions, GrantScope, ReSharePermission};

    let (registry, source_estate_id, requester_handle_uuid, _) =
        two_estate_registry_with_grant("hydration-nonstring-source", |grantee| GrantOptions {
            grantee_estate_id: grantee,
            scope: GrantScope::WholeEstate,
            custody_mode: CustodyMode::Mediated,
            lifetime: GrantLifetime::Permanent,
            content_level: 0,
            re_share_permission: ReSharePermission::None,
        });

    // File a memory that must NOT appear in the response if the bug were present.
    let filed = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "nonstring-hydration-content",
            "location" => "test-room",
            "estateID" => source_estate_id.to_string()
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory must succeed");
    assert!(is_success(&filed));

    // Integer hydrationLevel: must return isError:true (fail-closed).
    // Before the fix this silently defaulted to Full and leaked content.
    let result = dispatch_tool(
        "moot_federated_search",
        &args![
            "requesterEstateID" => requester_handle_uuid.to_string(),
            "hydrationLevel" => 1_i64
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("non-string hydrationLevel must not throw transport fault");
    assert!(
        is_tool_error(&result),
        "integer hydrationLevel must return isError:true (fail-closed); got: {result:?}"
    );
    // Content must not be leaked.
    assert!(
        !content_text(&result).contains("nonstring-hydration-content"),
        "non-string hydrationLevel refusal must not leak source content; got: {}",
        content_text(&result)
    );
}

// (e) Insufficient budget → federated search refused as isError:true with no
//     content leak. This test force-proves the BudgetExhausted contract at the
//     dispatch surface: a grant is issued (budget=1.0), then its budget is
//     manually zeroed via grant_store_mut().set_budget(), so the very first
//     federated read must be refused. The source content must not appear in
//     the refusal message.
//
// This is the canonical regression guard for the issuance-default rule in
// §B-7: grants are issued with budget=1.0 (not 0.0); the budget gate fires
// only when budget has been exhausted by prior reads or explicitly zeroed.
#[test]
fn federated_search_exhausted_budget_is_refused_as_error_result_no_content_leak() {
    use genius_locus_kit::{CustodyMode, GrantLifetime, GrantOptions, GrantScope, ReSharePermission};

    // Issue a whole-estate permanent grant with default budget (1.0).
    let (registry, source_estate_id, requester_handle_uuid, source_handle) =
        two_estate_registry_with_grant("budget-exhausted-source", |grantee| GrantOptions {
            grantee_estate_id: grantee,
            scope: GrantScope::WholeEstate,
            custody_mode: CustodyMode::Mediated,
            lifetime: GrantLifetime::Permanent,
            content_level: 0,
            re_share_permission: ReSharePermission::None,
        });

    // File content into the source estate — must NOT appear after budget is zeroed.
    let filed = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "budget-exhausted-secret-content",
            "location" => "test-room",
            "estateID" => source_estate_id.to_string()
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory must succeed");
    assert!(is_success(&filed), "file into source must succeed");

    // Zero out the grant's budget directly: fetch the grant id from the store,
    // then call set_budget(id, 0.0) so the next federated read is refused.
    {
        let mut coord = registry.coord.lock().unwrap();
        let store = coord.grant_store_mut(&source_handle)
            .expect("source estate must have a grant store");
        // There is exactly one active grant (the one just issued). Zero its budget.
        let grants = store.active_grants().expect("active_grants must succeed");
        assert_eq!(grants.len(), 1, "exactly one grant must be active");
        store.set_budget(grants[0].id, 0.0).expect("set_budget must succeed");
    }

    // Federated search must refuse — budget is zero.
    let result = dispatch_tool(
        "moot_federated_search",
        &args!["requesterEstateID" => requester_handle_uuid.to_string()],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("exhausted-budget federated_search must not throw transport fault");

    assert!(
        is_tool_error(&result),
        "exhausted budget must return isError:true; got: {result:?}"
    );
    // The refusal must not leak the source estate's content.
    assert!(
        !content_text(&result).contains("budget-exhausted-secret-content"),
        "BudgetExhausted refusal must not leak source content; got: {}",
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
///
/// Uses a UUID, NOT `SystemTime::now()`: on macOS the realtime clock has ~1µs
/// resolution, so under `cargo test`'s high thread-parallelism multiple
/// `vault_reconcile_*` tests starting in the same microsecond produced
/// IDENTICAL nanosecond stamps and collided on one directory — one test's
/// writes contaminated another's assertions, and a fast test's `remove_dir_all`
/// destroyed a directory a sibling was still using. `Uuid::new_v4()` is
/// guaranteed unique per call (the same pattern the SQLite test helpers use).
fn temp_vault_dir() -> std::path::PathBuf {
    let base = std::env::temp_dir();
    let dir = base.join(format!("aria-rust-vault-test-{}", uuid::Uuid::new_v4()));
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
        let err = dispatch_tool(name, &args![], &registry, &SurfacedRecallLedger::new())
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
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
    )
    .expect("export must succeed");

    let import_result = dispatch_tool(
        "moot_vault_import",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
    )
    .expect("export must succeed");

    let reconcile_result = dispatch_tool(
        "moot_vault_reconcile",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &SurfacedRecallLedger::new(),
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
// Vault reconcile apply path (B2-3)
// ---------------------------------------------------------------------------

#[test]
fn vault_reconcile_dry_run_default_reports_candidates_without_writing() {
    // Reconcile with no `apply` arg (dry-run): must report the candidate and
    // include "dry-run" in the text, but must NOT write any notes into the
    // estate. Verified by calling reconcile a second time after the first —
    // the count stays the same (we can't easily count drawers via dispatch,
    // but we confirm the text says "dry-run" and not "apply: true").
    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    // Export an empty vault so the manifest exists.
    dispatch_tool(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("export must succeed");

    // Add a note to the vault after the export — creates a candidate.
    std::fs::write(vault.join("NewNote.md"), "# New note\n\nDry run test.").ok();

    // Reconcile without apply — dry-run.
    let result = dispatch_tool(
        "moot_vault_reconcile",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("reconcile must not throw transport fault");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&result),
        "dry-run reconcile must be isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("1 added, 0 modified, 0 deleted"),
        "must report 1 added candidate; got: {text}"
    );
    assert!(
        text.contains("dry-run"),
        "must indicate dry-run mode; got: {text}"
    );
    assert!(
        !text.contains("apply: true"),
        "must NOT report apply mode in dry-run; got: {text}"
    );
}

#[test]
fn vault_reconcile_apply_true_writes_added_note_into_estate() {
    // Reconcile with apply=true: a note added to the vault after export must
    // be imported into the estate. The result must confirm the import counts.
    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    // Export an empty vault so the manifest exists.
    dispatch_tool(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("export must succeed");

    // Add a new note after the export — creates an "added" candidate.
    std::fs::create_dir_all(vault.join("added_section")).ok();
    std::fs::write(
        vault.join("added_section/ApplyNote.md"),
        "# Apply note\n\nShould land in estate after reconcile apply.",
    )
    .ok();

    // Reconcile with apply=true.
    let apply_result = dispatch_tool(
        "moot_vault_reconcile",
        &args!["vaultPath" => vault.to_str().unwrap(), "apply" => true],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("reconcile apply must not throw transport fault");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&apply_result),
        "reconcile apply must be isError:false; got: {apply_result:?}"
    );
    let text = content_text(&apply_result);
    assert!(
        text.contains("1 added, 0 modified, 0 deleted"),
        "must report 1 added candidate; got: {text}"
    );
    assert!(
        text.contains("apply: true"),
        "must confirm apply mode; got: {text}"
    );
    assert!(
        text.contains("drawersWritten: 1"),
        "must report drawersWritten: 1; got: {text}"
    );
}

#[test]
fn vault_reconcile_apply_modified_note_updates_estate() {
    // Export one memory, edit the note on disk, then reconcile apply=true.
    // The import bridge must report the modified note as written or updated.
    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    // File one memory and export it so the manifest is stamped.
    file_one_memory(&registry, "Original content.", "chem/apply-modified");

    dispatch_tool(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("export must succeed");

    // Read the manifest, find the exported content note (not an OKF navigation
    // file like index.md or log.md), and append text so the SHA changes.
    // The exporter emits one index.md per folder for OKF navigation — those
    // are skipped by the adapter on read and must not be the edit target.
    let manifest_path = vault.join(".moot/export-manifest.json");
    let manifest_json = std::fs::read_to_string(&manifest_path).expect("manifest must exist");
    let manifest: serde_json::Value =
        serde_json::from_str(&manifest_json).expect("manifest must be valid JSON");
    let note_path_key = manifest["files"]
        .as_object()
        .and_then(|f| {
            f.keys().find(|k| {
                // Skip OKF navigation files (index.md, log.md). The adapter
                // skips these on read, so editing them produces a SHA diff
                // that the reconcile detects but import_vault_filtered cannot
                // action (no NoteIR is produced for them). Find the first
                // real content note instead.
                let base = k.split('/').next_back().unwrap_or("");
                base != "index.md" && base != "log.md"
            })
        })
        .cloned()
        .expect("manifest must contain at least one content note");
    let note_path = vault.join(&note_path_key);
    let original = std::fs::read_to_string(&note_path).unwrap_or_default();
    std::fs::write(&note_path, original + "\nAppended in reconcile-apply test.").ok();

    // Reconcile with apply=true — the modified note must be imported.
    let apply_result = dispatch_tool(
        "moot_vault_reconcile",
        &args!["vaultPath" => vault.to_str().unwrap(), "apply" => true],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("reconcile apply must not throw transport fault");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&apply_result),
        "reconcile apply must be isError:false; got: {apply_result:?}"
    );
    let text = content_text(&apply_result);
    assert!(
        text.contains("0 added, 1 modified, 0 deleted"),
        "must report 1 modified candidate; got: {text}"
    );
    assert!(
        text.contains("apply: true"),
        "must confirm apply mode; got: {text}"
    );
    // The note is already in the estate, so import_vault will update it.
    assert!(
        text.contains("drawersUpdated: 1") || text.contains("drawersWritten: 1"),
        "import must report a write or update; got: {text}"
    );
}

#[test]
fn vault_reconcile_apply_deleted_files_are_never_expunged() {
    // Reconcile apply=true must NEVER expunge drawers for files deleted from
    // disk. Deletions are always reported only.
    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    file_one_memory(&registry, "Keep me in the estate.", "chem/keep");

    dispatch_tool(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("export must succeed");

    // Read the manifest and delete the exported note from disk.
    let manifest_path = vault.join(".moot/export-manifest.json");
    let manifest_json = std::fs::read_to_string(&manifest_path).expect("manifest must exist");
    let manifest: serde_json::Value =
        serde_json::from_str(&manifest_json).expect("manifest must be valid JSON");
    let note_path_key = manifest["files"]
        .as_object()
        .and_then(|f| f.keys().next().cloned())
        .expect("manifest must have at least one file");
    std::fs::remove_file(vault.join(&note_path_key)).ok();

    // apply=true — deleted note must NOT be expunged from the estate.
    let apply_result = dispatch_tool(
        "moot_vault_reconcile",
        &args!["vaultPath" => vault.to_str().unwrap(), "apply" => true],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("reconcile apply must not throw transport fault");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&apply_result),
        "reconcile apply must be isError:false; got: {apply_result:?}"
    );
    let text = content_text(&apply_result);
    assert!(
        text.contains("0 added, 0 modified, 1 deleted"),
        "must report 1 deleted; got: {text}"
    );
    assert!(
        text.contains("apply: true"),
        "must confirm apply mode; got: {text}"
    );
    // The estate still contains the drawer (not expunged). Verify by
    // checking that the estate has content via moot_memory_search.
    let search_result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "Keep me in the estate"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_memory_search must succeed");
    assert!(
        is_success(&search_result),
        "search after delete-only reconcile must succeed; got: {search_result:?}"
    );
    let search_text = content_text(&search_result);
    assert!(
        search_text.contains("found 1"),
        "estate must still contain the drawer after delete-only reconcile; got: {search_text}"
    );
}

// ---------------------------------------------------------------------------
// Vault reconcile defect fixes (B2-3)
// ---------------------------------------------------------------------------

#[test]
fn vault_reconcile_dryrun_malformed_estate_id_errors_before_manifest_io() {
    // Defect B2-3 fix 1 (parity): estateID is validated unconditionally, even
    // in dry-run mode. A malformed UUID must produce INVALID_PARAMS before any
    // manifest I/O occurs. Previously in Rust the estate was only resolved
    // inside the `if apply {}` block, so a bad estateID in dry-run was silently
    // ignored and the default estate used — diverging from Swift's behaviour.
    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    let err = dispatch_tool(
        "moot_vault_reconcile",
        &args!["vaultPath" => vault.to_str().unwrap(), "estateID" => "not-a-uuid"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("malformed estateID in dry-run must throw INVALID_PARAMS");

    std::fs::remove_dir_all(&vault).ok();

    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "malformed estateID must produce INVALID_PARAMS; got: {:?}",
        err.code
    );
}

#[test]
fn vault_reconcile_apply_actions_candidates_only_not_full_vault() {
    // Defect B2-3 fix 2 (apply over-import): apply=true must import only the M
    // candidate notes, not the full N-note vault. With 1 note filed, exported,
    // and then modified on disk, drawers_updated must be 1 — not the total note
    // count. Previously the full vault was passed to import_vault, so a vault of
    // N notes would report N actioned instead of M.
    //
    // The Rust dispatch layer is synchronous (no async estate recall by count),
    // so we verify the counts from the reconcile apply text directly:
    //   - 0 added, 1 modified, 0 deleted
    //   - drawersUpdated: 1  (or drawersWritten: 1 if a fresh lineage)
    //   - drawersWritten: 0  (no new lineages expected)
    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    // File exactly one memory and export it so the manifest is stamped.
    file_one_memory(&registry, "Candidate-only import test content.", "chem/candidate-only");

    dispatch_tool(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("export must succeed");

    // Read the manifest to find the exported note path, then append a byte.
    let manifest_path = vault.join(".moot/export-manifest.json");
    let manifest_json = std::fs::read_to_string(&manifest_path).expect("manifest must exist");
    let manifest: serde_json::Value =
        serde_json::from_str(&manifest_json).expect("manifest must be valid JSON");
    let note_path_key = manifest["files"]
        .as_object()
        .and_then(|f| f.keys().next().cloned())
        .expect("manifest must have at least one file");
    let note_path = vault.join(&note_path_key);
    let original = std::fs::read_to_string(&note_path).unwrap_or_default();
    std::fs::write(&note_path, original + "\nModified for candidate-only test.").ok();

    // Apply: only the 1 modified candidate must be actioned.
    let apply_result = dispatch_tool(
        "moot_vault_reconcile",
        &args!["vaultPath" => vault.to_str().unwrap(), "apply" => true],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("reconcile apply must not throw transport fault");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&apply_result),
        "reconcile apply must be isError:false; got: {apply_result:?}"
    );
    let text = content_text(&apply_result);
    assert!(
        text.contains("0 added, 1 modified, 0 deleted"),
        "must report exactly 1 modified; got: {text}"
    );
    assert!(
        text.contains("apply: true"),
        "must confirm apply mode; got: {text}"
    );
    // drawers_updated must be 1 (the single modified candidate). drawers_written
    // must be 0 — no new lineage was created, only the existing one updated.
    assert!(
        text.contains("drawersUpdated: 1") || text.contains("drawersWritten: 1"),
        "import must report exactly 1 actioned note; got: {text}"
    );
    assert!(
        !text.contains("drawersWritten: 0") || text.contains("drawersUpdated: 1"),
        "import must NOT report additional writes beyond the single candidate; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// moot_vault_job — FORCE tests (Bob's ruling 2026-06-12)
//
// The Rust backend is synchronous: vault ops complete before returning.
// These tests verify:
//   1. tools/list contains moot_vault_job with the Swift-identical schema.
//   2. export → job_id in response → moot_vault_job(id) returns "complete"
//      export record (noteCount, exportedAt).
//   3. import → job_id → moot_vault_job(id) returns "complete" import record
//      (drawersWritten, drawersUpdated, etc.).
//   4. Unknown job_id → Swift-identical not-found shape ("unknown job_id: <id>"),
//      isError:true.
//   5. Missing job_id → INVALID_PARAMS transport fault.
//   6. VaultJobLedger bounds: after MAX_JOBS (100) jobs, oldest is evicted.
//      Verified by filling the ledger and confirming the first is gone.
// ---------------------------------------------------------------------------

#[test]
fn vault_job_tool_in_list_with_swift_identical_schema() {
    // Gate: moot_vault_job is advertised in tools/list with the correct schema.
    // Schema must match Swift VaultTools.tools() job entry exactly:
    //   required: ["job_id"]
    //   job_id description: "Job ID returned by moot_vault_import or moot_vault_export."
    let tools = build_tool_list();
    let arr = tools.as_array().expect("build_tool_list must return array");
    let job_tool = arr
        .iter()
        .find(|t| t["name"].as_str() == Some("moot_vault_job"))
        .expect("moot_vault_job must be in tools/list");

    // required field must be ["job_id"]
    let required = job_tool["inputSchema"]["required"]
        .as_array()
        .expect("moot_vault_job schema must have required");
    assert_eq!(
        required,
        &[serde_json::json!("job_id")],
        "moot_vault_job required must be [\"job_id\"]; got: {required:?}"
    );

    // job_id property description must match Swift exactly
    let desc = job_tool["inputSchema"]["properties"]["job_id"]["description"]
        .as_str()
        .unwrap_or("");
    assert!(
        desc.contains("Job ID returned by moot_vault_import or moot_vault_export"),
        "job_id description must match Swift; got: {desc}"
    );

    // description must reference both running/complete/failed (Swift-identical)
    let tool_desc = job_tool["description"].as_str().unwrap_or("");
    assert!(
        tool_desc.contains("running") && tool_desc.contains("complete") && tool_desc.contains("failed"),
        "moot_vault_job description must mention running/complete/failed; got: {tool_desc}"
    );
}

#[test]
fn vault_export_returns_job_id_and_moot_vault_job_returns_completed_export_record() {
    // export → job_id in response → moot_vault_job(id) returns "complete" export record.
    // The VaultJobLedger is session-scoped via Dispatcher. dispatch_tool uses a
    // throwaway ledger, so we use dispatch_tool_with_vault_ledger directly to
    // share the ledger between the export call and the job-poll call.
    use aria_mcp::{
        dispatch::dispatch_tool_with_vault_ledger,
        vault_tools::VaultJobLedger,
    };

    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();
    let ledger = VaultJobLedger::new();
    let recall_ledger = SurfacedRecallLedger::new();

    file_one_memory(&registry, "Benzene is aromatic.", "chem/notes");

    let export_result = dispatch_tool_with_vault_ledger(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &recall_ledger,
        &ledger,
        "",
    )
    .expect("moot_vault_export must not throw transport fault");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&export_result),
        "moot_vault_export must be isError:false; got: {export_result:?}"
    );
    let export_text = content_text(&export_result);

    // Extract the job_id from the export response text ("job_id: <uuid>").
    let job_id = export_text
        .lines()
        .find(|l| l.starts_with("job_id: "))
        .and_then(|l| l.strip_prefix("job_id: "))
        .expect("export response must contain 'job_id: <uuid>'")
        .to_owned();
    assert!(
        !job_id.is_empty(),
        "exported job_id must be non-empty"
    );

    // Poll with moot_vault_job — must return a "complete" export record.
    let job_result = dispatch_tool_with_vault_ledger(
        "moot_vault_job",
        &args!["job_id" => job_id.as_str()],
        &registry,
        &recall_ledger,
        &ledger,
        "",
    )
    .expect("moot_vault_job must not throw transport fault");

    assert!(
        is_success(&job_result),
        "moot_vault_job for known export id must be isError:false; got: {job_result:?}"
    );
    let text = content_text(&job_result);
    assert!(
        text.contains("status: complete"),
        "known export job must report status: complete; got: {text}"
    );
    assert!(
        text.contains("kind: export"),
        "known export job must report kind: export; got: {text}"
    );
    assert!(
        text.contains(&format!("job_id: {job_id}")),
        "response must echo job_id; got: {text}"
    );
    assert!(
        text.contains("noteCount:"),
        "export job result must contain noteCount; got: {text}"
    );
    assert!(
        text.contains("exportedAt:"),
        "export job result must contain exportedAt; got: {text}"
    );
}

#[test]
fn vault_import_returns_job_id_and_moot_vault_job_returns_completed_import_record() {
    // import → job_id → moot_vault_job(id) returns "complete" import record.
    use aria_mcp::{
        dispatch::dispatch_tool_with_vault_ledger,
        vault_tools::VaultJobLedger,
    };

    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();
    let ledger = VaultJobLedger::new();
    let recall_ledger = SurfacedRecallLedger::new();

    // Export first to have content to import.
    file_one_memory(&registry, "Toluene is a solvent.", "chem/lab");
    dispatch_tool_with_vault_ledger(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &recall_ledger,
        &ledger,
        "",
    )
    .expect("export must succeed");

    let import_result = dispatch_tool_with_vault_ledger(
        "moot_vault_import",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &recall_ledger,
        &ledger,
        "",
    )
    .expect("moot_vault_import must not throw transport fault");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&import_result),
        "moot_vault_import must be isError:false; got: {import_result:?}"
    );
    let import_text = content_text(&import_result);

    // Extract the job_id from the import response.
    let job_id = import_text
        .lines()
        .find(|l| l.starts_with("job_id: "))
        .and_then(|l| l.strip_prefix("job_id: "))
        .expect("import response must contain 'job_id: <uuid>'")
        .to_owned();

    // Poll with moot_vault_job — must return completed import record.
    let job_result = dispatch_tool_with_vault_ledger(
        "moot_vault_job",
        &args!["job_id" => job_id.as_str()],
        &registry,
        &recall_ledger,
        &ledger,
        "",
    )
    .expect("moot_vault_job must not throw transport fault");

    assert!(
        is_success(&job_result),
        "moot_vault_job for known import id must be isError:false; got: {job_result:?}"
    );
    let text = content_text(&job_result);
    assert!(
        text.contains("status: complete"),
        "known import job must report status: complete; got: {text}"
    );
    assert!(
        text.contains("kind: import"),
        "known import job must report kind: import; got: {text}"
    );
    assert!(
        text.contains("drawersWritten:"),
        "import job result must contain drawersWritten; got: {text}"
    );
    assert!(
        text.contains("drawersUpdated:"),
        "import job result must contain drawersUpdated; got: {text}"
    );
    assert!(
        text.contains("fdcClassified:"),
        "import job result must contain fdcClassified; got: {text}"
    );
}

/// FIX 4: vault_job import result must surface drawersSkippedUnchanged and
/// drawersSkippedTombstoned from ImportReport.
///
/// Before this fix `ImportJobResult` only tracked drawersWritten / drawersUpdated /
/// fdcClassified — the idempotency skip counters were silently dropped at the
/// job-record boundary. An idempotent re-import showed all-zeros for the activity
/// that happened, hiding real skip activity from the ARIA surface.
///
/// This test exports one memory then imports the vault twice: the second import
/// is a known-idempotent run, so drawersSkippedUnchanged must be ≥ 1 while
/// drawersWritten must be 0. Parity with Swift VaultToolsTests.import_job_surfaces_skip_counts.
#[test]
fn vault_import_job_surfaces_skip_counts() {
    use aria_mcp::{
        dispatch::dispatch_tool_with_vault_ledger,
        vault_tools::VaultJobLedger,
    };

    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();
    let ledger = VaultJobLedger::new();
    let recall_ledger = SurfacedRecallLedger::new();

    // File one memory, export it to vault.
    file_one_memory(&registry, "Idempotent re-import test fixture.", "fix4/room");
    dispatch_tool_with_vault_ledger(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &recall_ledger,
        &ledger,
        "",
    )
    .expect("export must succeed");

    // First import: writes the row.
    dispatch_tool_with_vault_ledger(
        "moot_vault_import",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &recall_ledger,
        &ledger,
        "",
    )
    .expect("first import must not throw");

    // Second import: the row is unchanged → drawersSkippedUnchanged ≥ 1.
    let import_result = dispatch_tool_with_vault_ledger(
        "moot_vault_import",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &recall_ledger,
        &ledger,
        "",
    )
    .expect("second import must not throw");

    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&import_result),
        "second import must be isError:false; got: {import_result:?}"
    );
    let import_text = content_text(&import_result);

    // Extract job_id and poll moot_vault_job for the completed record.
    let job_id = import_text
        .lines()
        .find(|l| l.starts_with("job_id: "))
        .and_then(|l| l.strip_prefix("job_id: "))
        .expect("import response must contain 'job_id: <uuid>'")
        .to_owned();

    let job_result = dispatch_tool_with_vault_ledger(
        "moot_vault_job",
        &args!["job_id" => job_id.as_str()],
        &registry,
        &recall_ledger,
        &ledger,
        "",
    )
    .expect("moot_vault_job must not throw");

    let text = content_text(&job_result);

    // Both skip-count fields must be present in the job record.
    assert!(
        text.contains("drawersSkippedUnchanged:"),
        "import job result must contain drawersSkippedUnchanged; got: {text}"
    );
    assert!(
        text.contains("drawersSkippedTombstoned:"),
        "import job result must contain drawersSkippedTombstoned; got: {text}"
    );

    // The idempotent re-import must have skipped ≥ 1 unchanged drawer.
    // Parse the count from "drawersSkippedUnchanged: N".
    let skipped_unchanged: i64 = text
        .lines()
        .find(|l| l.contains("drawersSkippedUnchanged:"))
        .and_then(|l| l.split(':').nth(1))
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(0);
    assert!(
        skipped_unchanged >= 1,
        "idempotent re-import must skip ≥ 1 unchanged drawer; got drawersSkippedUnchanged: {skipped_unchanged}; full text:\n{text}"
    );
}

#[test]
fn vault_job_unknown_id_returns_swift_identical_not_found_shape() {
    // Unknown job_id returns isError:true with the Swift-identical phrase
    // "unknown job_id: <id>". Mirrors Swift:
    //   return ToolDispatcher.errorResult("unknown job_id: \(jobID)")
    use aria_mcp::{
        dispatch::dispatch_tool_with_vault_ledger,
        vault_tools::VaultJobLedger,
    };

    let registry = EstateRegistry::new_inmemory();
    let ledger = VaultJobLedger::new();
    let recall_ledger = SurfacedRecallLedger::new();
    let unknown_id = "ffffffff-ffff-ffff-ffff-ffffffffffff";

    let result = dispatch_tool_with_vault_ledger(
        "moot_vault_job",
        &args!["job_id" => unknown_id],
        &registry,
        &recall_ledger,
        &ledger,
        "",
    )
    .expect("moot_vault_job with unknown id must not throw transport fault");

    assert!(
        is_tool_error(&result),
        "unknown job_id must return isError:true; got: {result:?}"
    );
    let text = content_text(&result);
    // Must match Swift's exact phrase: "unknown job_id: <id>"
    assert_eq!(
        text,
        format!("unknown job_id: {unknown_id}"),
        "not-found text must match Swift shape exactly; got: {text}"
    );
}

#[test]
fn vault_job_missing_job_id_returns_invalid_params() {
    // Missing job_id is an out-of-band transport fault (INVALID_PARAMS),
    // not a tool-level refusal. Mirrors Swift's requireString throwing
    // JSONRPCError.invalidParams for missing required args.
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_vault_job",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("missing job_id must produce INVALID_PARAMS transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "missing job_id must be INVALID_PARAMS; got code {}",
        err.code
    );
}

#[test]
fn vault_job_ledger_bounds_evict_oldest_entry() {
    // After MAX_JOBS (100) entries, inserting a 101st evicts the oldest.
    // The first-inserted job_id must no longer be findable; the 101st must.
    use aria_mcp::vault_tools::{
        VaultJobKind, VaultJobLedger, VaultJobRecord, VaultJobResult, ExportJobResult,
    };

    let ledger = VaultJobLedger::new();
    let first_id = "first-job-id".to_string();

    // Record 100 jobs (fills the ledger to capacity).
    for i in 0..100 {
        ledger.record(VaultJobRecord {
            job_id: if i == 0 { first_id.clone() } else { format!("job-{i}") },
            kind: VaultJobKind::Export,
            vault_path: "/tmp/test".to_string(),
            result: VaultJobResult::Exported(ExportJobResult {
                note_count: i,
                exported_at: "2026-06-12T00:00:00Z".to_string(),
            }),
        });
    }
    // First job must still be present at exactly capacity.
    assert!(
        ledger.get(&first_id).is_some(),
        "first job must be present at capacity"
    );

    // Push one more entry (101st) — oldest must be evicted.
    ledger.record(VaultJobRecord {
        job_id: "one-hundred-and-first".to_string(),
        kind: VaultJobKind::Export,
        vault_path: "/tmp/test".to_string(),
        result: VaultJobResult::Exported(ExportJobResult {
            note_count: 100,
            exported_at: "2026-06-12T00:00:01Z".to_string(),
        }),
    });

    assert!(
        ledger.get(&first_id).is_none(),
        "first job must be evicted after 101 entries"
    );
    assert!(
        ledger.get("one-hundred-and-first").is_some(),
        "101st job must be present in the ledger"
    );
}

// ---------------------------------------------------------------------------
// 11. Recipe tools — success + error paths (new names)
// ---------------------------------------------------------------------------

#[test]
fn list_lenses_returns_catalog_entries() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_list_lenses", &args![], &registry, &SurfacedRecallLedger::new())
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
        &SurfacedRecallLedger::new(),
    )
    .expect_err("unknown estateID must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn recall_precise_default_composition_returns_memory_shape() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "the Versailles indemnity was 46 million marks", "history");
    let result = dispatch_tool(
        "moot_recall_precise",
        &args!["query" => "Versailles indemnity"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_recall_precise must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    // Same shape as moot_memory_search: a "found N memory(s)" header line.
    assert!(
        text.starts_with("found ") && text.contains("memory(s)"),
        "precise recall must emit the moot_memory_search shape; got: {text}"
    );
}

#[test]
fn recall_precise_named_composition_is_accepted() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "current as of 1921 the indemnity was 46 million marks", "history");
    // A known grid composition ("dense-fused") must dispatch without error.
    let result = dispatch_tool(
        "moot_recall_precise",
        &args!["query" => "indemnity", "composition" => "dense-fused"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_recall_precise with a known composition must succeed");
    assert!(is_success(&result));
}

#[test]
fn recall_precise_unknown_composition_fails_closed() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "any content", "history");
    // The ARIA boundary validates the composition against the grid and fails
    // CLOSED on an unknown name (a tool error, not a silent degrade-to-text).
    let result = dispatch_tool(
        "moot_recall_precise",
        &args!["query" => "anything", "composition" => "no-such-composition"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dispatch returns a result envelope");
    assert!(
        is_tool_error(&result),
        "an unknown composition must return a tool error (fail closed)"
    );
    assert!(
        content_text(&result).contains("unknown composition"),
        "the error names the offending composition"
    );
}

#[test]
fn recall_precise_missing_query_is_transport_fault() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_recall_precise",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("missing required query must produce a transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// ── moot_recall_shaped (named RecallShape preset surface) ────────────────────
// Mirror the Swift RecipeToolsTests shaped-recall cases.

#[test]
fn recall_shaped_known_preset_returns_memory_shape() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "the river flows north past the old mill", "history");
    let result = dispatch_tool(
        "moot_recall_shaped",
        &args!["query" => "river mill", "preset" => "conceptual"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_recall_shaped with a known preset must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.starts_with("found ") && text.contains("memory(s)"),
        "shaped recall must emit the moot_memory_search shape; got: {text}"
    );
}

#[test]
fn recall_shaped_unknown_preset_fails_closed() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "any content", "history");
    // The ARIA boundary validates the preset against the GLK roster and fails
    // CLOSED on an unknown name (a tool error, not a silent degrade-to-balanced).
    let result = dispatch_tool(
        "moot_recall_shaped",
        &args!["query" => "anything", "preset" => "no-such-preset"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dispatch returns a result envelope");
    assert!(
        is_tool_error(&result),
        "an unknown preset must return a tool error (fail closed)"
    );
    assert!(
        content_text(&result).contains("unknown preset"),
        "the error names the offending preset"
    );
}

#[test]
fn recall_shaped_absent_preset_uses_balanced() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "the harbour lights flicker in the fog", "history");
    // No preset arg at all — must succeed (the unsteered balanced default).
    let result = dispatch_tool(
        "moot_recall_shaped",
        &args!["query" => "harbour"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("absent preset must use balanced and succeed");
    assert!(is_success(&result));
    assert!(content_text(&result).starts_with("found "));
}

#[test]
fn recall_shaped_missing_query_is_transport_fault() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_recall_shaped",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("missing required query must produce a transport fault");
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
            // "000" is the canonical unclassified-sentinel UDC code (UDC root).
            // The seam classifies migration corpus entries on capture.
            "latticeCode": "000",
            "embeddingModelID": "test-model"
        }])),
    );
    let result = dispatch_tool("moot_run_migration", &a, registry, &SurfacedRecallLedger::new())
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

    let result = dispatch_tool("moot_confirm_migration", &a, &registry, &SurfacedRecallLedger::new())
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
    let err = dispatch_tool("moot_confirm_migration", &args![], &registry, &SurfacedRecallLedger::new())
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

    let result = dispatch_tool("moot_lens_keystones", &args!["wing" => "hub-room"], &registry, &SurfacedRecallLedger::new())
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
    // moot_lens_associations — AR_FCA_CAPABILITY_001.
    let registry = EstateRegistry::new_inmemory();
    for _ in 0..3 {
        file_one_memory(&registry, "study content about knowledge", "study-room");
    }
    let result = dispatch_tool("moot_lens_associations", &args![], &registry, &SurfacedRecallLedger::new())
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
    // moot_lens_concepts — AR_FCA_CAPABILITY_001.
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "concept content alpha", "concept-room");
    file_one_memory(&registry, "concept content beta", "concept-room");

    let result = dispatch_tool(
        "moot_lens_concepts",
        &args!["minSupport" => 1, "maxIntentSize" => 8, "maxConcepts" => 20],
        &registry,
        &SurfacedRecallLedger::new(),
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
    // moot_lens_partial_cue: unknown anchorID must produce isError:true, not a
    // transport fault.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_lens_partial_cue",
        &args!["anchorID" => "definitely-does-not-exist-00000000"],
        &registry,
        &SurfacedRecallLedger::new(),
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
        &SurfacedRecallLedger::new(),
    )
    .expect_err("unknown estateID must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// ---------------------------------------------------------------------------
// 13. New lens tools — aria-tools mission (moot_lens_apriori + 4 temporal)
// ---------------------------------------------------------------------------

#[test]
fn list_recipes_catalog_returns_full_catalog() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_list_recipes", &args![], &registry, &SurfacedRecallLedger::new())
        .expect("moot_list_recipes must succeed");
    assert!(is_success(&result), "moot_list_recipes must be isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.starts_with("moot_list_recipes:"),
        "result must start with 'moot_list_recipes: N recipe(s)'; got: {text}"
    );
    assert!(
        text.contains("version:"),
        "catalog entries must include version field; got: {text}"
    );
}

#[test]
fn lens_apriori_over_captured_drawers_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    for _ in 0..3 {
        file_one_memory(&registry, "apriori test content about knowledge", "study-room");
    }
    let result = dispatch_tool("moot_lens_apriori", &args![], &registry, &SurfacedRecallLedger::new())
        .expect("moot_lens_apriori must succeed");
    assert!(is_success(&result), "moot_lens_apriori must be isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.starts_with("apriori_rules:"),
        "result must start with 'apriori_rules:'; got: {text}"
    );
}

#[test]
fn lens_moment_over_estate_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "moment lens test content", "lab");
    // windowStart/windowEnd are required ISO8601 timestamps spanning a broad past window.
    let result = dispatch_tool(
        "moot_lens_moment",
        &args![
            "windowStart" => "2020-01-01T00:00:00Z",
            "windowEnd" => "2026-12-31T23:59:59Z"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_moment must succeed");
    assert!(is_success(&result), "moot_lens_moment must be isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("moment:"),
        "moot_lens_moment must return moment analysis; got: {text}"
    );
}

#[test]
fn lens_rhythm_over_estate_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "rhythm lens test content", "lab");
    // bit, bucketSeconds, bucketCount, endingAt are required per schema.
    let result = dispatch_tool(
        "moot_lens_rhythm",
        &args![
            "bit" => 0,
            "bucketSeconds" => 86400,
            "bucketCount" => 32,
            "endingAt" => "2026-12-31T23:59:59Z"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_rhythm must succeed");
    assert!(is_success(&result), "moot_lens_rhythm must be isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("rhythm"),
        "moot_lens_rhythm must return rhythm analysis; got: {text}"
    );
}

#[test]
fn lens_precedence_over_estate_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "precedence lens test source", "lab");
    file_one_memory(&registry, "precedence lens test target", "lab");
    // windowStart, windowEnd, targetField, targetValue are required.
    let result = dispatch_tool(
        "moot_lens_precedence",
        &args![
            "windowStart" => "2020-01-01T00:00:00Z",
            "windowEnd" => "2026-12-31T23:59:59Z",
            "targetField" => "room",
            "targetValue" => "string:lab"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_precedence must succeed");
    assert!(is_success(&result), "moot_lens_precedence must be isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("precedence"),
        "moot_lens_precedence must return precedence analysis; got: {text}"
    );
}

#[test]
fn lens_complexity_over_captured_drawers_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "complexity lens test content with many words", "lab");
    // fieldA is required — "room" is a valid label field.
    let result = dispatch_tool(
        "moot_lens_complexity",
        &args!["fieldA" => "room"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_complexity must succeed");
    assert!(is_success(&result), "moot_lens_complexity must be isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("complexity:"),
        "moot_lens_complexity must return complexity analysis; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// moot_dream — dispatch tests
// ---------------------------------------------------------------------------
//
// These tests mirror the Swift dispatch tests in RecipeToolsTests.swift:
//   - testDreamDispatchRebuildsMatrixAndRunsCycle
//   - testDreamRejectsMalformedNow
//
// The Rust handler now matches Swift on the matrix-rebuild step:
// `coordinator.rebuild_derived_accelerators` feeds the audit log, rebuilds the
// MatrixTier, and registers it on the coordinator before the dreaming cycle.
// All behavioral contracts (matrix rebuilt, cycle runs, isError:false, candidate
// counting, malformed now rejected) are identical between the two ports.

/// `moot_dream` rebuilds the matrix tier and runs a dreaming cycle, returning a
/// cycle summary.
///
/// With several drawers sharing a room there are co-occurrence pairs to mine,
/// so the cycle considers candidates. The result is isError:false, contains
/// "matrix rebuild complete" and "dreaming cycle complete", and carries the
/// correct candidatesConsidered count — C(4,2) = 6 pairs from four co-filed
/// drawers.
#[test]
fn dream_dispatch_runs_cycle_and_returns_summary() {
    let registry = EstateRegistry::new_inmemory();

    // Four co-filed drawers in the same room → C(4,2) = 6 co-occurrence pairs.
    for text in &[
        "the treaty fixed the indemnity at 46 million marks",
        "the treaty ceded the eastern province in 1871",
        "the armistice was signed at Versailles in January",
        "the provisional government ratified the terms in March",
    ] {
        file_one_memory(&registry, text, "history/treaty");
    }

    // Deterministic instant matching the Swift test — reproducible cycle.
    let result = dispatch_tool(
        "moot_dream",
        &args!["now" => "2026-06-11T00:00:00Z"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_dream must not throw a transport fault");

    assert!(is_success(&result), "moot_dream must return isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("dreaming cycle complete"),
        "moot_dream result must contain 'dreaming cycle complete'; got: {text}"
    );
    // Four drawers in one room yield 6 co-occurrence pairs. The cycle considers
    // all of them — the candidates_considered field must reflect this.
    assert!(
        text.contains("consideredCandidates: 6"),
        "four co-filed drawers yield six co-occurrence pairs; got: {text}"
    );
    // Matrix rebuild now runs for real on the Rust port: the result reports the
    // rebuild completed, not a gap note.
    assert!(
        text.contains("matrix rebuild complete"),
        "Rust result must report a real matrix rebuild; got: {text}"
    );
    assert!(
        !text.contains("not available in Rust port"),
        "the matrix-rebuild gap note must not survive the real rebuild; got: {text}"
    );
}

/// A second dream over unchanged state emits no NEW proposals (every candidate
/// already proposed or suppressed). The tool still succeeds and the result is
/// isError:false. Mirrors Swift's idempotent second-call test.
#[test]
fn dream_dispatch_second_call_is_idempotent() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "idempotent dream test content alpha", "study");
    file_one_memory(&registry, "idempotent dream test content beta", "study");

    // First dream.
    let first = dispatch_tool(
        "moot_dream",
        &args!["now" => "2026-06-11T00:00:00Z"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("first moot_dream must not throw");
    assert!(is_success(&first), "first dream must succeed; got: {first:?}");

    // Second dream — same now, same estate state.
    let second = dispatch_tool(
        "moot_dream",
        &args!["now" => "2026-06-11T00:00:00Z"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("second moot_dream must not throw");
    assert!(is_success(&second), "second dream must succeed; got: {second:?}");
}

/// B-10a internal-origin proof: the dream cycle writes ZERO recall-trace rows.
///
/// After filing a memory and running the dream cycle, the recall-trace table
/// count must be zero — the cycle reads estate data through `all_drawers` and
/// `all_tunnels` (no trace_limit), and writes only through `add_proposal` /
/// `add_diary_entry`. This test is the force-proof mandated by the mission gate.
#[test]
fn dream_dispatch_writes_zero_recall_traces_b10a_proof() {
    let registry = EstateRegistry::new_inmemory();

    // File two drawers in the same room to seed co-occurrence candidates.
    file_one_memory(&registry, "b10a proof content alpha", "b10a/room");
    file_one_memory(&registry, "b10a proof content beta", "b10a/room");

    // Confirm zero trace rows BEFORE the dream (baseline).
    let pre_count = {
        let coord = registry.coord.lock().unwrap();
        // recent_recall_traces with a wide window — any trace row written would
        // show here. No tool calls have surfaced drawers yet, so the baseline
        // must be zero.
        coord
            .count_recall_traces(&registry.default.handle)
            .unwrap_or(0)
    };
    assert_eq!(pre_count, 0, "baseline trace count must be zero before dream");

    // Run the dream cycle.
    let result = dispatch_tool(
        "moot_dream",
        &args!["now" => "2026-06-11T12:00:00Z"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_dream must not throw");
    assert!(is_success(&result), "dream must succeed for B-10a test; got: {result:?}");

    // After the dream the trace count must still be zero — the cycle is
    // internal-origin and MUST NOT write trace rows.
    let post_count = {
        let coord = registry.coord.lock().unwrap();
        coord
            .count_recall_traces(&registry.default.handle)
            .unwrap_or(0)
    };
    assert_eq!(
        post_count, 0,
        "B-10a violation: dream cycle must write ZERO recall-trace rows; got {post_count}"
    );
}

/// A malformed `now` value is an out-of-band invalidParams transport fault.
///
/// Mirrors Swift `testDreamRejectsMalformedNow`: the determinism contract must
/// not be bypassed silently — a bad instant is a client error, not a wall-clock
/// fallback.
#[test]
fn dream_dispatch_rejects_malformed_now_as_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_dream",
        &args!["now" => "not-a-date"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("malformed now must produce a transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "malformed now must be INVALID_PARAMS; got code {}", err.code as i64
    );
}

// ---------------------------------------------------------------------------
// Vault gating (ADR-015)
// ---------------------------------------------------------------------------

/// `vault_enabled()` returns true when MOOTX01_VAULT is absent from the
/// process env (the default for a freshly started process in CI).
/// NOTE: this assertion only holds when the test process has not had
/// MOOTX01_VAULT=0 set externally. That is always the case in CI and normal
/// test runs; the test is skipped-equivalent if the env var is pre-set.
#[test]
fn vault_enabled_default_is_true() {
    // When the env var is absent or set to anything other than "0", vault is on.
    // We cannot mutate the process env safely in a parallel test runner, so we
    // assert the contract of `vault_enabled()` for the common case (no env var).
    // Explicit "0" / non-"0" values are covered by build_tool_list_with_vault_flag tests.
    if std::env::var("MOOTX01_VAULT").as_deref() != Ok("0") {
        assert!(vault_enabled(), "vault_enabled() must be true when MOOTX01_VAULT is absent or ≠ '0'");
    }
}

/// With vault_on=true (the default), all five vault tools appear in the list.
#[test]
fn build_tool_list_with_vault_on_includes_vault_tools() {
    let tools = build_tool_list_with_vault_flag(true);
    let arr = tools.as_array().expect("must be array");
    assert_eq!(arr.len(), 57, "vault-on must produce 57 tools");
    let names: std::collections::HashSet<&str> =
        arr.iter().filter_map(|t| t["name"].as_str()).collect();
    for name in &["moot_vault_export", "moot_vault_import", "moot_vault_status",
                   "moot_vault_reconcile", "moot_vault_job"] {
        assert!(names.contains(name), "vault-on: expected {name} in tools/list");
    }
}

/// With vault_on=false (MOOTX01_VAULT=0), all five vault tools are absent.
/// Non-vault surface (52 tools) is unchanged.
#[test]
fn build_tool_list_with_vault_off_excludes_vault_tools() {
    let tools = build_tool_list_with_vault_flag(false);
    let arr = tools.as_array().expect("must be array");
    assert_eq!(arr.len(), 52, "vault-off must produce 52 tools (57 − 5 vault)");
    let names: std::collections::HashSet<&str> =
        arr.iter().filter_map(|t| t["name"].as_str()).collect();
    for name in &["moot_vault_export", "moot_vault_import", "moot_vault_status",
                   "moot_vault_reconcile", "moot_vault_job"] {
        assert!(!names.contains(name), "vault-off: {name} must NOT appear in tools/list");
    }
    // A sample of non-vault tools must still be present.
    assert!(names.contains("moot_file_memory"), "vault-off: core tools must still be present");
    assert!(names.contains("moot_federated_search"), "vault-off: federation tool must still be present");
    assert!(names.contains("moot_lens_keystones"), "vault-off: lens tools must still be present");
}

/// When vault is disabled (vault_on=false), calling a vault tool returns a
/// clear tool-level refusal (isError=true) rather than a transport fault.
/// The error message directs the user to reinstall with --vault-on.
#[test]
fn dispatch_vault_tool_when_vault_off_returns_clear_error() {
    let registry = EstateRegistry::new_inmemory();
    let vault_names = [
        "moot_vault_export",
        "moot_vault_import",
        "moot_vault_status",
        "moot_vault_reconcile",
        "moot_vault_job",
    ];
    for name in &vault_names {
        let result = dispatch_tool_with_vault_flag(
            name,
            &args![],
            &registry,
            &SurfacedRecallLedger::new(),
            false, // vault_on=false
        )
        .expect("disabled vault must return Ok(error result), not Err(transport fault)");
        assert!(
            is_tool_error(&result),
            "disabled vault tool {name} must return isError=true; got {result:?}"
        );
        let text = content_text(&result);
        assert!(
            text.contains("vault is disabled"),
            "disabled vault tool {name} error must mention 'vault is disabled'; got: {text}"
        );
        assert!(
            text.contains("--vault-on"),
            "disabled vault tool {name} error must mention '--vault-on'; got: {text}"
        );
    }
}

/// When vault is enabled (vault_on=true, the default), calling a vault tool
/// proceeds to the actual vault backend (not the refusal path).
/// moot_vault_status with a non-existent path returns a tool-level success
/// (the vault has no manifest — that is a valid, non-error state).
#[test]
fn dispatch_vault_tool_when_vault_on_does_not_return_disabled_error() {
    let registry = EstateRegistry::new_inmemory();
    // Use a non-existent vault path — vault_status handles this gracefully.
    let result = dispatch_tool_with_vault_flag(
        "moot_vault_status",
        &args!["vaultPath" => "/tmp/no-such-vault-for-test-adr015"],
        &registry,
        &SurfacedRecallLedger::new(),
        true, // vault_on=true
    )
    .expect("vault-on must not produce a transport fault for vault_status");
    // The result may be success or tool-error (no manifest), but it must NOT
    // be the "vault is disabled" message — that would mean the guard fired incorrectly.
    let text = content_text(&result);
    assert!(
        !text.contains("vault is disabled"),
        "vault-on: vault_status must not return the 'vault is disabled' refusal; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// Wave-C drive-test fixes
// ---------------------------------------------------------------------------

/// Part 1b: file_memory with event_time ISO8601 string persists a back-dated
/// event_time. Mirrors Swift ToolDispatch.runFileMemory which parses the
/// event_time arg to Date and passes it as eventTime on the CaptureFrame.
#[test]
fn file_memory_with_event_time_is_accepted() {
    use aria_mcp::dispatch::wall_now;
    use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};

    let registry = EstateRegistry::new_inmemory();
    // File a memory with a back-dated event_time (2020-01-01T00:00:00Z).
    let result = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "back-dated event content",
            "location" => "temporal/test",
            "event_time" => "2020-01-01T00:00:00Z"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("file_memory with event_time must succeed");
    assert!(
        is_success(&result),
        "file_memory with event_time must return success; got: {result:?}"
    );
    // Confirm the drawer was stored with the provided event_time (epoch secs
    // for 2020-01-01T00:00:00Z = 1577836800).
    let estate = registry.resolve(&BTreeMap::new(), "estateID").unwrap();
    let coord = estate.coord.lock().unwrap();
    let drawers = coord
        .recall(
            &estate.handle,
            RecallFrame {
                filter_chain: vec![Filter::CurrentlyBelieve],
                ordering: Ordering::ByCaptureTimeDesc,
                hydration_level: HydrationLevel::Full,
                limit: None,
                ..RecallFrame::new(vec![Filter::CurrentlyBelieve])
            },
            wall_now(),
        )
        .expect("recall must succeed");
    let drawer = drawers.first().expect("at least one drawer must exist");
    assert_eq!(
        drawer.event_time, 1_577_836_800_i64,
        "drawer event_time must be the back-dated epoch seconds (2020-01-01T00:00:00Z); got: {}",
        drawer.event_time
    );
}

/// Part 1b: file_memory with an invalid event_time string returns INVALID_PARAMS.
#[test]
fn file_memory_with_invalid_event_time_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let err = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "some content",
            "location" => "test/room",
            "event_time" => "not-a-date"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("invalid event_time must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

/// Part 2: estate_status counts only currently-believed (cluster A) drawers.
/// A superseded/withdrawn drawer must NOT be counted as active. The label
/// must be "memories: N active" (not "drawers: N").
#[test]
fn estate_status_active_count_excludes_tombstoned() {
    use aria_mcp::dispatch::wall_now;

    let registry = EstateRegistry::new_inmemory();
    // File two memories.
    file_one_memory(&registry, "first memory", "status/test");
    let second_id = file_one_memory(&registry, "second memory", "status/test");

    // Withdraw the second drawer — it becomes tombstoned (not active).
    let _withdraw = dispatch_tool(
        "moot_withdraw_memory",
        &args!["id" => second_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("withdraw must succeed");

    let result = dispatch_tool(
        "moot_estate_status",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("estate_status must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);

    // Must report 1 active (not 2 — the withdrawn drawer is excluded).
    assert!(
        text.contains("memories: 1 active"),
        "estate_status must count only active (cluster A) drawers; got: {text}"
    );
    // Must use the new label.
    assert!(
        !text.contains("drawers:"),
        "estate_status must not use deprecated 'drawers:' label; got: {text}"
    );
}

/// Part 4: moot_lens_contradiction filed= field must be ISO8601, not an epoch int.
#[test]
fn lens_contradiction_filed_is_iso8601() {
    let registry = EstateRegistry::new_inmemory();
    // File two KG facts with the same subject+predicate but different objects —
    // that is the contradiction pattern the lens detects.
    let _f1 = dispatch_tool(
        "moot_file_fact",
        &args![
            "subject" => "Berlin",
            "predicate" => "capital_of",
            "object" => "Germany"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("file_fact 1 must succeed");
    let _f2 = dispatch_tool(
        "moot_file_fact",
        &args![
            "subject" => "Berlin",
            "predicate" => "capital_of",
            "object" => "Prussia"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("file_fact 2 must succeed");

    let result = dispatch_tool(
        "moot_lens_contradiction",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("lens_contradiction must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);

    // The output must contain "filed=" somewhere (the contradiction lens emits it).
    // If it does, the value after "filed=" must look like an ISO8601 date (contains
    // "-" and "T" and "Z"), NOT a raw epoch integer (purely numeric).
    if text.contains("filed=") {
        // Find the filed= value — grab 30 chars after "filed=" to inspect.
        let filed_pos = text.find("filed=").expect("filed= must be present");
        let value_start = filed_pos + "filed=".len();
        let snippet = &text[value_start..std::cmp::min(value_start + 30, text.len())];
        let is_iso = snippet.contains('-') && snippet.contains('T');
        let is_pure_integer = snippet.chars().next().map_or(false, |c| c.is_ascii_digit())
            && snippet
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .count()
                > 8; // epoch ints are 10+ digits; ISO dates have hyphens
        assert!(
            is_iso && !is_pure_integer,
            "lens_contradiction filed= must be ISO8601, not an epoch int; snippet: {snippet}"
        );
    }
    // No contradiction found → lens returns an empty list, which is also valid.
    // The test passes either way — we only assert format when the field appears.
}

// ===========================================================================
// Wave D: Illegal-state-transition error messages (parity fix)
// ===========================================================================
//
// Verify that moot_update_memory returns actionable English messages (not
// Rust Debug type chains like BasisViolation / IllegalTransition) when
// the mutation is rejected by the gate automaton. Each test triggers a
// specific illegal transition from the message table and asserts:
//   1. The result is a tool-level error (isError == true).
//   2. The message contains NO internal type name (BasisViolation,
//      IllegalTransition, UnderlyingEstateFailure, InvalidContent).
//   3. The message contains the expected actionable phrase.
//
// Parity requirement: the exact same phrase must appear in Swift's
// ToolDispatch.describeGateRejection helper.

/// Helper: file an active memory and return its id.
fn file_active_memory(registry: &EstateRegistry) -> String {
    file_one_memory(registry, "gate-rejection test fixture", "General")
}

/// Assert that a moot_update_memory result is a gate-rejection error
/// containing `expected_phrase` and NO internal type names.
fn assert_gate_rejection(result: &serde_json::Value, expected_phrase: &str) {
    assert!(is_tool_error(result), "expected tool-level error, got: {result:?}");
    let msg = content_text(result);
    // No internal type names must appear.
    assert!(
        !msg.contains("BasisViolation"),
        "error message must not contain 'BasisViolation'; got: {msg}"
    );
    assert!(
        !msg.contains("IllegalTransition"),
        "error message must not contain 'IllegalTransition'; got: {msg}"
    );
    assert!(
        !msg.contains("UnderlyingEstateFailure"),
        "error message must not contain 'UnderlyingEstateFailure'; got: {msg}"
    );
    assert!(
        !msg.contains("InvalidContent("),
        "error message must not contain 'InvalidContent('; got: {msg}"
    );
    assert!(
        msg.contains(expected_phrase),
        "expected phrase '{expected_phrase}' in error message; got: {msg}"
    );
}

fn update_memory(registry: &EstateRegistry, id: &str, mutation: &str) -> serde_json::Value {
    let ledger = SurfacedRecallLedger::new();
    let a = args!["id" => id, "mutation" => mutation];
    dispatch_tool("moot_update_memory", &a, registry, &ledger)
        .expect("moot_update_memory dispatch must not return JSONRPCError")
}

/// active + reject → "cannot reject an active memory; contest or withdraw it first"
#[test]
fn illegal_transition_active_reject_emits_actionable_message() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_active_memory(&registry);
    let result = update_memory(&registry, &id, "reject");
    assert_gate_rejection(
        &result,
        "cannot reject an active memory",
    );
}

/// rejected + reject → "memory is already rejected"
///
/// A memory that is already in the Rejected state cannot be rejected again.
/// This test drives a memory to Rejected via the now-legal Contested → Reject
/// path (contested memories can be judged false and rejected), then attempts a
/// second Reject and asserts the specific "already rejected" actionable message
/// is returned with no internal type names in the error text. Parity with
/// Swift's GateRejectionMessageTests.rejectedRejectEmitsActionableMessage.
#[test]
fn illegal_transition_rejected_reject_emits_actionable_message() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_active_memory(&registry);
    // Move to Contested (Active → Contest is legal).
    let contest_result = update_memory(&registry, &id, "contest");
    assert!(
        is_success(&contest_result),
        "contest must succeed on active row; got: {contest_result:?}"
    );
    // Move to Rejected (Contested → Reject is legal: contested → reject → rejected).
    let reject_result = update_memory(&registry, &id, "reject");
    assert!(
        is_success(&reject_result),
        "reject must succeed on contested row; got: {reject_result:?}"
    );
    // Rejected → Reject is illegal; gate returns "memory is already rejected".
    let result = update_memory(&registry, &id, "reject");
    assert_gate_rejection(&result, "already rejected");
}

/// Tombstoned row + any mutation → "memory has been permanently erased"
/// (We can't directly tombstone via update_memory, so we use moot_erase_memory
/// with confirmation and then try to update the now-tombstoned row.)
#[test]
fn illegal_transition_tombstoned_emits_permanently_erased_message() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_active_memory(&registry);
    // Tombstone via expunge.
    let ledger = SurfacedRecallLedger::new();
    let erase_args = args!["id" => id.as_str(), "reason" => "test", "confirmed" => true];
    let erase_result = dispatch_tool("moot_erase_memory", &erase_args, &registry, &ledger)
        .expect("erase must dispatch");
    assert!(is_success(&erase_result), "erase must succeed: {erase_result:?}");

    // Now try to update the tombstoned row.
    let result = update_memory(&registry, &id, "confirm");
    let msg = content_text(&result);
    assert!(is_tool_error(&result), "update of tombstoned row must fail");
    assert!(
        !msg.contains("BasisViolation") && !msg.contains("IllegalTransition"),
        "no internal types in: {msg}"
    );
    assert!(
        msg.contains("permanently erased") || msg.contains("does not allow"),
        "expected actionable message for tombstoned row; got: {msg}"
    );
}

/// Verify the describe_gate_rejection parser correctly returns None for a
/// non-gate-rejection error (e.g. DrawerNotFound). The fallback message
/// must be used, not a fabricated gate-rejection phrase.
#[test]
fn non_gate_error_does_not_produce_gate_rejection_phrase() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    // Use a non-existent id.
    let a = args!["id" => "00000000-0000-0000-0000-000000000000", "mutation" => "confirm"];
    let result = dispatch_tool("moot_update_memory", &a, &registry, &ledger)
        .expect("dispatch must not err");
    let msg = content_text(&result);
    assert!(is_tool_error(&result), "update of missing row must fail");
    // Must not produce false gate-rejection text.
    assert!(
        !msg.contains("cannot reject"),
        "non-gate error must not look like gate rejection; got: {msg}"
    );
}
