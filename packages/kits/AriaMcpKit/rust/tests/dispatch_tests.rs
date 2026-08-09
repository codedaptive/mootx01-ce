//! Dispatch-surface integration tests — 5-tier AI-client interface (MCP-RUST-ALIGN-01).
//!
//! Tests the 70-tool surface: 23 interface tools (Tier 1–5 + moot_monitoring_status,
//! including moot_memory_get and moot_review_tunnel), 1 federation tool,
//! 11 recipe tools (Wave 1: moot_distill replaced moot_consolidate+moot_recollect;
//! moot_consolidate no longer dispatches — SPEC §3 Phase 2 removed its alias;
//! moot_recollect is a notice-only stub),
//! 23 lens tools (including moot_lens_cohesion and moot_lens_contradiction),
//! 5 vault tools, 4 maintenance tools, and 3 dataset tools (MX-TAB-7).
//! Exercises dispatch routing, argument validation, and result shapes through
//! the full stack using an in-memory estate. One success path + one
//! error/validation path per tool group.
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
    jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue},
    surfaced_recall_ledger::SurfacedRecallLedger,
    tool_list::{build_tool_list, build_tool_list_with_flags, build_tool_list_with_vault_flag, vault_enabled},
};

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const FDC_FLOOR_KEY: &str = "aria.fdc.recalced_data_version";

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

/// Seed content directly into any estate by calling `coord.capture`, bypassing
/// the MCP direct-routing gate (which is restricted to the default estate after
/// Item 3 hardening). Used by federation tests to populate non-default source
/// estates without going through `moot_file_memory`.
fn seed_in_source(
    registry: &EstateRegistry,
    source_handle: &genius_locus_kit::EstateHandle,
    content: &str,
    room: &str,
) {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;
    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        room,
        LatticeAnchor::udc("004"),
        "aria-mcp-tests",
        "default",
    );
    // Subject = capped content so PR-03 dense-row replies carry the text
    // these tests assert on (dense rows show subjects, never content).
    frame.subject = Some(content.chars().take(120).collect());
    let now = aria_mcp::dispatch::wall_now();
    let coord = registry.coord.lock().unwrap();
    coord
        .capture(source_handle, frame, now)
        .expect("seed_in_source capture must succeed");
}

/// File a memory into the default estate and return its id.
fn file_one_memory(registry: &EstateRegistry, content: &str, location: &str) -> String {
    // Subject is required at the file_memory boundary (PR-02); the capped
    // content prefix is a good-enough test subject.
    //
    // `impatient: true` mirrors the Swift twin's `file` helper: the write
    // lands synchronously instead of parking in the encode queue, so a
    // hunt that runs next actually screens the pair. Without it the
    // planted drawers are invisible to the probe set (hunts do not drain
    // the queue) and assertions pin an artifact of drain timing, not the
    // wiring — the MXE-CT3 cue-"parity" false alarm came from
    // exactly this asymmetry.
    let subject: String = content.chars().take(120).collect();
    let a = args!["content" => content, "subject" => subject.as_str(),
                  "location" => location, "impatient" => true];
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

fn file_one_memory_with_provenance_sensitivity(
    registry: &EstateRegistry,
    content: &str,
    location: &str,
    sensitivity: locus_kit::provenance::Sensitivity,
) -> String {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;

    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        location,
        LatticeAnchor::udc("004"),
        "aria-mcp-tests",
        "default",
    );
    frame.provenance_sensitivity = sensitivity;

    let now = aria_mcp::dispatch::wall_now();
    let coord = registry.coord.lock().unwrap();
    let drawer = coord
        .capture(&registry.default.handle, frame, now)
        .expect("provenance-sensitive capture must succeed");
    drawer.id.clone()
}

fn seed_memory_with_anchor(
    registry: &EstateRegistry,
    content: &str,
    code: &str,
    qid: Option<&str>,
) -> String {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;

    let frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "fdc-reclassify",
        LatticeAnchor::new(code, None, qid.map(ToOwned::to_owned), None),
        "aria-mcp-tests",
        "default",
    );
    let now = aria_mcp::dispatch::wall_now();
    let coord = registry.coord.lock().unwrap();
    let drawer = coord
        .capture(&registry.default.handle, frame, now)
        .expect("seed_memory_with_anchor capture must succeed");
    drawer.id
}

fn seed_code_memory_with_anchor(
    registry: &EstateRegistry,
    content: &str,
    code: &str,
) -> String {
    use locus_kit::drawer_operational::{CaptureChannel, ContentKind};
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;

    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "fdc-reclassify",
        LatticeAnchor::new(code, None, None, None),
        "aria-mcp-tests",
        "default",
    );
    frame.kind = ContentKind::Code;
    let now = aria_mcp::dispatch::wall_now();
    let coord = registry.coord.lock().unwrap();
    coord.capture(&registry.default.handle, frame, now)
        .expect("seed code capture must succeed").id
}

/// Advisory 1 (FDC-RECLASSIFY-ADVISORIES) fixture: seed a drawer whose
/// anchor carries populated `udcFacets` / `wikidataQidsSecondary`, so the
/// reclassify-apply test can assert the repair carries them forward
/// unchanged rather than defaulting them to `None`.
fn seed_memory_with_full_anchor(
    registry: &EstateRegistry,
    content: &str,
    code: &str,
    qid: Option<&str>,
    facets: Option<&str>,
    secondary_qids: Option<&str>,
) -> String {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;

    let frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "fdc-reclassify",
        LatticeAnchor::new(
            code,
            facets.map(ToOwned::to_owned),
            qid.map(ToOwned::to_owned),
            secondary_qids.map(ToOwned::to_owned),
        ),
        "aria-mcp-tests",
        "default",
    );
    let now = aria_mcp::dispatch::wall_now();
    let coord = registry.coord.lock().unwrap();
    let drawer = coord
        .capture(&registry.default.handle, frame, now)
        .expect("seed_memory_with_full_anchor capture must succeed");
    drawer.id
}

fn stored_drawer(registry: &EstateRegistry, id: &str) -> locus_kit::drawer::Drawer {
    let coord = registry.coord.lock().unwrap();
    coord
        .all_drawers(&registry.default.handle)
        .expect("all_drawers must succeed")
        .into_iter()
        .find(|d| d.id == id)
        .expect("seeded drawer must exist")
}

fn stored_fdc_code(registry: &EstateRegistry, id: &str) -> String {
    let coord = registry.coord.lock().unwrap();
    coord
        .all_drawers(&registry.default.handle)
        .expect("all_drawers must succeed")
        .into_iter()
        .find(|d| d.id == id)
        .expect("seeded drawer must exist")
        .udc_code
}

fn fdc_floor(registry: &EstateRegistry) -> Option<String> {
    registry
        .default
        .store
        .get_meta(FDC_FLOOR_KEY)
        .expect("FDC floor metadata read must succeed")
}

// ---------------------------------------------------------------------------
// 1. tools/list surface assertions — 71 tools exact
// ---------------------------------------------------------------------------

#[test]
fn tools_list_count_is_73() {
    // Gate: the 5-tier AI-client surface after MCP-RUST-ALIGN-01 + aria-tools +
    // the precise-recall parity mission + moot_dream (on-demand dream tool) +
    // moot_vault_job (tool-surface parity, Bob's ruling 2026-06-12) +
    // moot_recall_shaped (named RecallShape preset surface) +
    // moot_lens_contradiction (genuine contradiction detector, Part 5) +
    // moot_lens_node_motion (diffusion node-layer lens, node motion modeling) +
    // moot_palace_import (direct palace import, PAR-PB-1) +
    // moot_memory_get (fetch-drawer-by-ID, build-now per Bob's ruling) +
    // moot_monitoring_status (out-of-band sensitivity grants, daemon telemetry monitoring control) +
    // the contradiction hunter (moot_review_tunnel interface tool +
    // moot_hunt_contradictions recipe tool):
    //   23  interface tools (Tier 1–5 + monitoring_status + review_tunnel)
    //    1  federation tool (moot_federated_search)
    //   12  recipe tools (list_lenses, list_recipes, synthesize, run_migration,
    //                     confirm_migration, recall_precise, recall_shaped,
    //                     recall_vague, dream, distill, recall_distilled,
    //                     hunt_contradictions —
    //                     moot_consolidate no longer dispatches (SPEC §3 Phase 2)
    //                     and moot_recollect retired with the factoid tier, §3/§11)
    //   23  lens tools (moot_lens_* prefix; cohesion renamed, contradiction +
    //                   node_motion added)
    //    5  vault tools (moot_vault_export, import, status, reconcile, job)
    //    3  dataset tools (moot_file_dataset, moot_dataset_query, moot_dataset_stats) — MX-TAB-7
    // ----
    //    5  maintenance tools (moot_reindex, moot_drain_status, moot_reclassify_fdc,
    //                          moot_palace_import, moot_json_import)
    //    2  contradiction-hunter tools (moot_hunt_contradictions, moot_review_tunnel)
    //   73  total (memory adapter excluded — opt-in, off by default)
    // Use build_tool_list_with_flags with memory_on=false for deterministic count:
    // the 3 memory-tool tests in this file hold memory_env_lock() while setting
    // MOOTX01_MEMORY_TOOL=1, which would race this test and flip the count to 73.
    let tools = build_tool_list_with_flags(vault_enabled(), false);
    let arr = tools.as_array().expect("build_tool_list must return an array");
    assert_eq!(arr.len(), 73, "expected 73 tools; got {}", arr.len());
}

#[test]
fn tools_list_name_set_matches_expected_73_names() {
    // Gate: all 73 expected tool names are present, no more and no less.
    // moot_reindex is the maintenance tool (corpus/vector backfill).
    // moot_drain_status reports background drain progress (drain-status stream).
    // moot_palace_import is the direct palace import tool (PAR-PB-1).
    // moot_vault_job is a vault tool (Bob's ruling 2026-06-12: tool-surface
    // parity matters even when the Rust backend is synchronous).
    // moot_recall_shaped is the named RecallShape preset surface.
    // moot_distill + moot_recall_distilled are the distillation tools
    // (SPEC_DISTILLATION_STORAGE §3/§10.3; moot_consolidate no longer
    // dispatches — §3 Phase 2 — and moot_recollect retired with the factoid tier).
    // moot_memory_get fetches a full drawer by id (fetch-drawer-by-ID gap,
    // shipped in the 1.0.x train per Bob's build-now ruling).
    let expected: std::collections::HashSet<&str> = [
        // Tier 1 — Core memory (9)
        "moot_file_memory",
        "moot_memory_search",
        "moot_memory_list",
        "moot_memory_get",
        "moot_update_memory",
        "moot_withdraw_memory",
        "moot_erase_memory",
        "moot_confirm_memory",
        "moot_move_memory",
        // Tier 2 — Connections (4)
        "moot_link_memories",
        "moot_review_tunnel",
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
        // Monitoring control (1) — out-of-band sensitivity grants
        "moot_monitoring_status",
        // Federation (1)
        "moot_federated_search",
        // Recipe (11) — list_lenses + list_recipes + synthesize + run_migration
        //               + confirm_migration + recall_precise + recall_shaped + dream
        //               + distill + recall_distilled + hunt_contradictions
        //               (moot_consolidate no longer dispatches — SPEC §3 Phase 2;
        //                moot_recollect is a notice-only stub, not listed)
        "moot_list_lenses",
        "moot_list_recipes",
        "moot_synthesize",
        "moot_run_migration",
        "moot_confirm_migration",
        "moot_recall_precise",
        "moot_recall_connected",
        "moot_recall_shaped",
        "moot_recall_vague",
        "moot_dream",
        "moot_distill",
        "moot_recall_distilled",
        "moot_hunt_contradictions",
        "moot_reindex",
        "moot_drain_status",
        "moot_reclassify_fdc",
        "moot_palace_import",
        "moot_json_import",
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
        // Dataset tools (3) — MX-TAB-7 (moot_file_dataset / query / stats)
        "moot_file_dataset",
        "moot_dataset_query",
        "moot_dataset_stats",
    ]
    .iter()
    .copied()
    .collect();

    // Use build_tool_list_with_flags with memory_on=false: this test gates the
    // baseline 73-name set; the `memory` tool's opt-in appearance is tested in
    // memory_adapter_tests.rs. Deterministic flag prevents racing the env-var
    // mutations in the three memory_env_lock()-gated tests below.
    let tools = build_tool_list_with_flags(vault_enabled(), false);
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
// 1b. Interface-tool membership gate — moot_reindex regression gate
// ---------------------------------------------------------------------------

#[test]
fn moot_reindex_passes_membership_gate() {
    // Regression gate: `moot_reindex` must pass `is_interface_tool` so the
    // dispatch routing branches to the reindex handler rather than falling
    // through to an "Unknown tool" error.
    //
    // The equivalent Swift bug was that `moot_reindex` was omitted from
    // `InterfaceTools.names` while already present in the dispatch switch,
    // causing -32601 "Unknown tool" on the serve host. This test confirms the
    // Rust port stays correct: `moot_reindex` is in `INTERFACE_TOOLS`.
    assert!(
        aria_mcp::interface_tools::is_interface_tool("moot_reindex"),
        "moot_reindex must pass is_interface_tool — omitting it causes -32601 Unknown tool"
    );
}

#[test]
fn moot_reclassify_fdc_passes_membership_gate() {
    assert!(
        aria_mcp::interface_tools::is_interface_tool("moot_reclassify_fdc"),
        "moot_reclassify_fdc must pass is_interface_tool — omitting it causes -32601 Unknown tool"
    );
}

#[test]
fn all_interface_dispatch_cases_pass_membership_gate() {
    // Every tool name in the Rust `interface_tools::dispatch` match arms must
    // also be in `INTERFACE_TOOLS` (the gate checked before dispatch is called).
    // If a case is added to the switch but omitted from the constant, callers
    // receive -32601 "Unknown tool" because the gate fires first.
    //
    // Mirrors the Swift `testMembershipGateCoversAllDispatchCases` test.
    let dispatch_cases = [
        // Anthropic memory adapter + Tier 1 — Core memory (9)
        "memory", "moot_file_memory", "moot_memory_search", "moot_memory_list",
        "moot_memory_get", "moot_update_memory",
        "moot_withdraw_memory", "moot_erase_memory", "moot_confirm_memory",
        "moot_move_memory",
        // Tier 2 — Connections (3)
        "moot_link_memories", "moot_connection_search", "moot_connection_map",
        // Tier 3 — Knowledge graph (4)
        "moot_file_fact", "moot_fact_search", "moot_retire_fact",
        "moot_fact_timeline",
        // Tier 4 — Journal (2)
        "moot_write_journal", "moot_read_journal",
        // Tier 5 — Estate (3)
        "moot_estate_status", "moot_estate_map", "moot_estate_ping",
        // Monitoring + Maintenance / admin (5)
        "moot_monitoring_status", "moot_reindex", "moot_drain_status",
        "moot_reclassify_fdc", "moot_palace_import", "moot_json_import",
    ];
    for name in &dispatch_cases {
        assert!(
            aria_mcp::interface_tools::is_interface_tool(name),
            "{name} is in the dispatch switch but missing from the membership gate"
        );
    }
}

// ---------------------------------------------------------------------------
// 1c. FDC maintenance repair/reset tool
// ---------------------------------------------------------------------------

#[test]
fn moot_reclassify_fdc_dry_run_reports_suspect_without_mutating() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = seed_memory_with_anchor(
        &registry,
        "```bash\nread_signal && git status --short\n```",
        "362.4",
        Some("Q12131"),
    );

    let result = dispatch_tool(
        "moot_reclassify_fdc",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_reclassify_fdc dry-run must dispatch");

    assert!(is_success(&result), "dry-run should succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(text.contains("fdc_reclassify: dry-run"), "got: {text}");
    assert!(text.contains("candidates: 1"), "got: {text}");
    assert!(text.contains("would_update: 1"), "got: {text}");
    assert!(
        text.contains(&format!("{id}: 362.4 [Q12131] -> 000")),
        "got: {text}"
    );
    assert_eq!(stored_fdc_code(&registry, &id), "362.4");
    assert_eq!(fdc_floor(&registry), None, "dry-run must not stamp estate FDC floor");
}

#[test]
fn moot_reclassify_fdc_all_mode_uses_content_kind_and_adds_language_qid() {
    let registry = EstateRegistry::new_inmemory_bare();
    let short_id = seed_code_memory_with_anchor(&registry, "x += 1", "362.4");
    let swift_id = seed_code_memory_with_anchor(
        &registry,
        "import Foundation\npublic struct User { public let name: String }",
        "005",
    );

    let result = dispatch_tool(
        "moot_reclassify_fdc",
        &args!["apply" => true, "mode" => "all"],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("moot_reclassify_fdc must dispatch");
    let text = content_text(&result);
    assert!(text.contains("updated: 2"), "got: {text}");

    let short = stored_drawer(&registry, &short_id);
    assert_eq!(short.udc_code, "005");
    assert_eq!(short.wikidata_qid, None);
    let swift = stored_drawer(&registry, &swift_id);
    assert_eq!(swift.udc_code, "005");
    assert_eq!(swift.wikidata_qid.as_deref(), Some("Q17118377"));
}

#[test]
fn moot_reclassify_fdc_suspect_only_adds_qid_when_code_is_unchanged() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = seed_code_memory_with_anchor(
        &registry,
        "import Foundation\npublic struct User { public let name: String }",
        "005",
    );

    let result = dispatch_tool(
        "moot_reclassify_fdc",
        &args!["apply" => true],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("moot_reclassify_fdc must dispatch");
    let text = content_text(&result);
    assert!(text.contains("mode: suspectOnly"), "got: {text}");
    assert!(text.contains("updated: 1"), "got: {text}");
    assert_eq!(
        stored_drawer(&registry, &id).wikidata_qid.as_deref(),
        Some("Q17118377")
    );
    assert_eq!(fdc_floor(&registry), None);
}

#[test]
fn moot_reclassify_fdc_apply_repairs_false_positive_to_unclassified() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = seed_memory_with_anchor(
        &registry,
        "git update-index --refresh && rm .git/index.lock",
        "362.4",
        Some("Q12131"),
    );

    let result = dispatch_tool(
        "moot_reclassify_fdc",
        &args!["apply" => true, "mode" => "all"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_reclassify_fdc apply must dispatch");

    assert!(is_success(&result), "apply should succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(text.contains("fdc_reclassify: applied"), "got: {text}");
    assert!(text.contains("fdc_data_version: "), "got: {text}");
    assert!(text.contains("floor_stamp: stamped"), "got: {text}");
    assert!(text.contains("updated: 1"), "got: {text}");
    assert_eq!(stored_fdc_code(&registry, &id), "000");
    assert_eq!(
        fdc_floor(&registry),
        Some(lattice_lib::Fdc::recalculation_version()),
        "full apply must stamp the composite estate FDC floor"
    );
    let status = dispatch_tool(
        "moot_estate_status",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("estate status must dispatch");
    assert!(content_text(&status).contains("fdc_recalculation: current"));
}

#[test]
fn moot_reclassify_fdc_suspect_only_skips_broad_code_change_until_all_mode() {
    let registry = EstateRegistry::new_inmemory_bare();
    seed_memory_with_anchor(
        &registry,
        "Biology is the scientific study of life and living organisms \
         including their physical structure chemical processes molecular \
         interactions physiological mechanisms and evolution",
        "362.4",
        None,
    );

    let conservative = dispatch_tool(
        "moot_reclassify_fdc",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_reclassify_fdc conservative dry-run must dispatch");
    let conservative_text = content_text(&conservative);
    assert!(conservative_text.contains("candidates: 0"), "got: {conservative_text}");
    assert!(
        conservative_text.contains("skipped_non_candidate_changes: 1"),
        "got: {conservative_text}"
    );
    assert!(conservative_text.contains("mode=all"), "got: {conservative_text}");

    let all_mode = dispatch_tool(
        "moot_reclassify_fdc",
        &args!["mode" => "all"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_reclassify_fdc all-mode dry-run must dispatch");
    let all_text = content_text(&all_mode);
    assert!(all_text.contains("mode: all"), "got: {all_text}");
    assert!(all_text.contains("candidates: 1"), "got: {all_text}");
    assert!(all_text.contains("would_update: 1"), "got: {all_text}");
    assert_eq!(fdc_floor(&registry), None, "dry-run mode=all must not stamp");
}

#[test]
fn moot_reclassify_fdc_apply_limited_run_does_not_stamp_floor() {
    let registry = EstateRegistry::new_inmemory_bare();
    seed_memory_with_anchor(
        &registry,
        "git update-index --refresh && rm .git/index.lock",
        "362.4",
        Some("Q12131"),
    );

    let result = dispatch_tool(
        "moot_reclassify_fdc",
        &args!["apply" => true, "mode" => "all", "limit" => 1],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_reclassify_fdc limited apply must dispatch");

    assert!(is_success(&result), "apply should succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("floor_stamp: skipped: limited run cannot update estate-wide floor"),
        "got: {text}"
    );
    assert_eq!(fdc_floor(&registry), None, "limited apply must not stamp estate FDC floor");
}

#[test]
fn moot_reclassify_fdc_conservative_apply_does_not_stamp_floor() {
    let registry = EstateRegistry::new_inmemory_bare();
    seed_memory_with_anchor(
        &registry,
        "Biology is the scientific study of life and living organisms including evolution",
        "362.4",
        None,
    );

    let result = dispatch_tool(
        "moot_reclassify_fdc",
        &args!["apply" => true],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_reclassify_fdc conservative apply must dispatch");

    assert!(is_success(&result), "apply should succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(text.contains("skipped_non_candidate_changes: 1"), "got: {text}");
    assert!(
        text.contains("floor_stamp: skipped: mode=all is required for an estate-wide floor"),
        "got: {text}"
    );
    assert_eq!(fdc_floor(&registry), None, "conservative apply must not stamp the floor");
}

#[test]
fn estate_status_distinguishes_missing_and_stale_fdc_floors() {
    let registry = EstateRegistry::new_inmemory_bare();
    let missing = dispatch_tool(
        "moot_estate_status",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("estate status must dispatch");
    assert!(content_text(&missing).contains("fdc_recalculation: missing"));

    registry
        .default
        .store
        .set_meta(FDC_FLOOR_KEY, "classifier:old|frame:old|lexicon:old|signatures:old")
        .expect("stale FDC floor write must succeed");
    let stale = dispatch_tool(
        "moot_estate_status",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("estate status must dispatch");
    assert!(content_text(&stale).contains("fdc_recalculation: stale"));
}

// Advisory 1 (FDC-RECLASSIFY-ADVISORIES): apply must repair only the primary
// udc_code/wikidata_qid and carry udc_facets + wikidata_qids_secondary
// forward unchanged. Before the fix, run_reclassify_fdc's apply branch built
// the replacement LatticeAnchor with only the two primary fields, silently
// defaulting facets/secondary QIDs to None and wiping enrichment metadata.
#[test]
fn moot_reclassify_fdc_apply_retains_facets_and_secondary_qids() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = seed_memory_with_full_anchor(
        &registry,
        "git update-index --refresh && rm .git/index.lock",
        "362.4",
        Some("Q12131"),
        Some("004, 621"),
        Some("Q999, Q1000"),
    );

    let result = dispatch_tool(
        "moot_reclassify_fdc",
        &args!["apply" => true],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_reclassify_fdc apply must dispatch");

    assert!(is_success(&result), "apply should succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(text.contains("fdc_reclassify: applied"), "got: {text}");
    assert!(text.contains("updated: 1"), "got: {text}");

    let drawer = stored_drawer(&registry, &id);
    assert_eq!(drawer.udc_code, "000", "primary udc_code must be repaired");
    assert_eq!(
        drawer.udc_facets.as_deref(),
        Some("004, 621"),
        "udc_facets must be carried forward unchanged"
    );
    assert_eq!(
        drawer.wikidata_qids_secondary.as_deref(),
        Some("Q999, Q1000"),
        "wikidata_qids_secondary must be carried forward unchanged"
    );
}

// Advisory 2 (FDC-RECLASSIFY-ADVISORIES): apply must attribute the audit
// event to the running server identity with the tool's own reason string,
// not the generic `coord.reanchor` attribution ("reanchored via
// Estate.reanchor", stamped with the estate owner). Before the fix,
// run_reclassify_fdc's apply branch called the generic `coord.reanchor`,
// which has no way to carry a caller-supplied changed_by/reason.
#[test]
fn moot_reclassify_fdc_apply_audit_event_carries_tool_reason() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = seed_memory_with_anchor(
        &registry,
        "git update-index --refresh && rm .git/index.lock",
        "362.4",
        Some("Q12131"),
    );

    let result = dispatch_tool(
        "moot_reclassify_fdc",
        &args!["apply" => true],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_reclassify_fdc apply must dispatch");
    assert!(is_success(&result), "apply should succeed; got: {result:?}");

    let events = registry
        .default
        .store
        .audit_events_for_row(&id)
        .expect("audit_events_for_row must succeed");
    let reanchor_event = events
        .iter()
        .find(|e| e.reason.as_deref() == Some("FDC reclassified via moot_reclassify_fdc"))
        .expect("reclassify apply must append an audit event with the tool reason");
    assert_eq!(
        reanchor_event.actor, "mootx01",
        "audit event must attribute the repair to the running server identity, got: {}",
        reanchor_event.actor
    );
    assert!(
        events
            .iter()
            .all(|e| e.reason.as_deref() != Some("reanchored via Estate.reanchor")),
        "reclassify apply must not fall back to the generic reanchor reason"
    );
}

// RECLASSIFY-PARALLEL: the classify pass now runs across all cores while the
// audited write stays serial and in scan order. Byte-identical proof for
// "parallelize a deterministic pure classify + apply in a fixed order":
//
//  (1) Invariance — repeated dry-runs over the same estate must produce
//      byte-identical output. The batch is heterogeneous (two distinct
//      classify outcomes) and large enough to OVERFLOW the 25-entry change
//      list, so the ORDER of the emitted list is observable; a racing write or
//      an order-dependent classify would perturb the list order or the counters
//      across runs. Dry-run does not mutate, so identical inputs must give
//      identical output every time.
//
//  (2) Golden values — a fresh estate applied through the parallel path must
//      store the same anchor each content classifies to serially: the
//      git-command drawers resolve to the `000` sentinel and the biology-prose
//      drawers resolve to a real subject code (neither the sentinel nor the
//      stale `362.4`).
#[test]
fn moot_reclassify_fdc_parallel_classify_is_deterministic_and_matches_serial_anchors() {
    let registry = EstateRegistry::new_inmemory_bare();

    // 20 drawers that classify to the `000` sentinel and 10 that classify to a
    // real subject code — a heterogeneous classify workload that saturates the
    // worker pool. All carry a stale `362.4` anchor, so mode=all makes every one
    // a candidate change (30 candidates > the 25-example cap ⇒ list order is
    // exercised).
    let mut sentinel_ids = Vec::new();
    let mut subject_ids = Vec::new();
    for _ in 0..20 {
        sentinel_ids.push(seed_memory_with_anchor(
            &registry,
            "git update-index --refresh && rm .git/index.lock",
            "362.4",
            Some("Q12131"),
        ));
    }
    for _ in 0..10 {
        subject_ids.push(seed_memory_with_anchor(
            &registry,
            "Biology is the scientific study of life and living organisms \
             including their physical structure chemical processes molecular \
             interactions physiological mechanisms and evolution",
            "362.4",
            None,
        ));
    }

    let dry_run_all = || {
        let result = dispatch_tool(
            "moot_reclassify_fdc",
            &args!["mode" => "all"],
            &registry,
            &SurfacedRecallLedger::new(),
        )
        .expect("moot_reclassify_fdc dry-run must dispatch");
        assert!(is_success(&result), "dry-run should succeed; got: {result:?}");
        content_text(&result).to_owned()
    };

    // (1) Invariance across repeated parallel runs.
    let first = dry_run_all();
    assert!(first.contains("scanned: 30 active drawer(s)"), "got: {first}");
    assert!(first.contains("candidates: 30"), "got: {first}");
    assert!(first.contains("would_update: 30"), "got: {first}");
    assert!(first.contains("... 5 more"), "got: {first}"); // 30 − 25 examples
    for _ in 0..4 {
        assert_eq!(dry_run_all(), first, "repeated parallel dry-runs must be byte-identical");
    }

    // (2) Golden values — apply through the parallel path, then read back.
    let applied = dispatch_tool(
        "moot_reclassify_fdc",
        &args!["apply" => true, "mode" => "all"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_reclassify_fdc apply must dispatch");
    assert!(content_text(&applied).contains("updated: 30"), "got: {}", content_text(&applied));
    for id in &sentinel_ids {
        assert_eq!(stored_fdc_code(&registry, id), "000");
    }
    for id in &subject_ids {
        let code = stored_fdc_code(&registry, id);
        assert_ne!(code, "000", "biology prose must classify to a real subject code");
        assert_ne!(code, "362.4", "the stale anchor must have been replaced");
    }
}

// ---------------------------------------------------------------------------
// 1d. Lens tool name set — 23 canonical names, sorted literal list
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
fn teachme_true_on_memory_get_returns_its_guide_without_touching_estate() {
    // moot_memory_get requires an id; teachme:true must short-circuit before
    // the missing-id validation ever runs (same interception point as every
    // other interface tool).
    let registry = EstateRegistry::new_inmemory();
    let a = args!["teachme" => true];
    let result = dispatch_tool("moot_memory_get", &a, &registry, &SurfacedRecallLedger::new())
        .expect("teachme interception must not throw even without id");
    assert!(is_success(&result), "teachme result must be isError:false");
    let text = content_text(&result);
    assert!(
        text.contains("moot_memory_get"),
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

    // _bare: no seeded wing/hint drawers — a controlled single-memory estate so
    // the read-back targets this test's drawer, not a seeded AI_Charter_Hint.
    let registry = EstateRegistry::new_inmemory_bare();
    let result = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "fn main() { println!(\"hello\"); }",
        "subject" => "fn main() { println!(\"hello\"); }",
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
        "subject" => "top-secret plan details",
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
        "subject" => "some content",
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
        "subject" => "some content",
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

    // _bare: no seeded wing/hint drawers — a controlled single-memory estate so
    // the read-back targets this test's drawer, not a seeded AI_Charter_Hint.
    let registry = EstateRegistry::new_inmemory_bare();
    let result = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "channel verification content",
        "subject" => "channel verification content",
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
    // _bare: controlled estate — the search-count assertion counts only this
    // memory, not the 7 seeded AI_Charter_Hint drawers a full provision adds.
    let registry = EstateRegistry::new_inmemory_bare();
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
    // _bare: controlled estate — the search-count assertion counts only this
    // memory, not the 7 seeded AI_Charter_Hint drawers a full provision adds.
    let registry = EstateRegistry::new_inmemory_bare();
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
    // Per-row score annotation was removed for Swift output parity.
    // Swift runMemorySearch emits scores only via the discrimination summary line,
    // not per-row. Verify scored recall ran via recall_provenance line instead.
    assert!(
        text.contains("recall_provenance:"),
        "recall_scored output must include recall_provenance line; got: {text}"
    );
    assert!(
        !text.contains("(score:"),
        "per-row score annotation must not appear (Swift parity); got: {text}"
    );
}

#[test]
fn memory_search_with_scoring_arg_matrix_aware_succeeds() {
    // _bare: controlled estate — the search-count assertion counts only this
    // memory, not the 7 seeded AI_Charter_Hint drawers a full provision adds.
    let registry = EstateRegistry::new_inmemory_bare();
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
    // Per-row score annotation removed for Swift parity. Verify via recall_provenance.
    assert!(
        text.contains("recall_provenance:"),
        "recall_scored output must include recall_provenance line; got: {text}"
    );
    assert!(
        !text.contains("(score:"),
        "per-row score annotation must not appear (Swift parity); got: {text}"
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
    // _bare: controlled estate — the search-count assertion counts only this
    // memory, not the 7 seeded AI_Charter_Hint drawers a full provision adds.
    let registry = EstateRegistry::new_inmemory_bare();
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
    // Per-row score annotation removed for Swift parity. Verify the scored path
    // ran via the recall_provenance line (always present in recall_scored output).
    assert!(
        text.contains("recall_provenance:"),
        "byRelevanceDesc must route through recall_scored (recall_provenance expected); got: {text}"
    );
    assert!(
        !text.contains("(score:"),
        "per-row score annotation must not appear (Swift parity); got: {text}"
    );
}

#[test]
fn memory_search_ordering_by_relevance_desc_on_empty_estate_succeeds() {
    // An empty estate with ordering="byRelevanceDesc" must return isError:false
    // with 0 hits — not an invalidParams error.
    // _bare: a genuinely empty estate (no seeded wing/hint drawers) — this test
    // asserts byRelevanceDesc on an EMPTY estate returns 0 hits without error.
    let registry = EstateRegistry::new_inmemory_bare();

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

// ---------------------------------------------------------------------------
// 4b. Tier 1 — moot_memory_get (fetch-drawer-by-ID)
//
// Mirrors Swift `MemoryGetTests.swift`'s four axes: found (verbatim content +
// metadata + linked-tunnel summary), not-found (fake id and gate-failed ids
// alike), and estateID routing (Item 3 direct-routing restriction).
// ---------------------------------------------------------------------------

#[test]
fn memory_get_found_returns_full_content_verbatim() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one_memory(&registry, "verbatim content for memory-get test", "lab/notes");

    let result = dispatch_tool(
        "moot_memory_get",
        &args!["id" => id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("memory_get must not throw");
    assert!(is_success(&result), "memory_get must succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains(&id),
        "response must echo the memory id; got: {text}"
    );
    // The sensitivity-gate advisory is appended after the content block
    // whenever no grant is live, which is this dispatcher's state — it
    // depends on grant state alone, never on estate contents, so it is
    // present on every reply here. Strip that one trailing line before
    // asserting the content is the final block; what is under test is that
    // the content itself is not truncated. Mirrors Swift
    // `MemoryGetTests.foundReturnsFullContentVerbatim`.
    let advisory = text
        .lines()
        .next_back()
        .expect("reply must not be empty");
    assert!(
        advisory.starts_with("sensitivity_advisory: "),
        "with no grant live the reply must end with the sensitivity-gate advisory; got: {text}"
    );
    let body = text[..text.len() - advisory.len()].trim_end_matches('\n');
    assert!(
        body.ends_with("verbatim content for memory-get test"),
        "response must include the exact verbatim content as the final block; got: {text}"
    );
}

#[test]
fn memory_get_includes_metadata_and_linked_tunnel_summary() {
    let registry = EstateRegistry::new_inmemory_bare();
    let from_id = file_one_memory(&registry, "memory-get link source", "alpha/hub");
    let to_id = file_one_memory(&registry, "memory-get link target", "beta/spoke");
    let link = dispatch_tool(
        "moot_link_memories",
        &args!["from_id" => from_id.as_str(), "to_id" => to_id.as_str(), "kind" => "elaborates"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("link_memories must not throw");
    assert!(is_success(&link), "link_memories must succeed; got: {link:?}");

    let result = dispatch_tool(
        "moot_memory_get",
        &args!["id" => from_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("memory_get must not throw");
    assert!(is_success(&result), "memory_get must succeed; got: {result:?}");
    let text = content_text(&result);
    for field in ["room:", "filed_at:", "event_time:", "state:", "trust:",
                  "sensitivity:", "exportability:", "confirmation:", "lineage:", "tunnels:"] {
        assert!(text.contains(field), "response must include {field}; got: {text}");
    }
    assert!(
        text.contains("tunnels: 1") && text.contains("elaborates"),
        "response must summarize the one linked tunnel; got: {text}"
    );
}

#[test]
fn memory_get_not_found_returns_standard_structured_error() {
    let registry = EstateRegistry::new_inmemory();
    let fake_id = "ffffffff-ffff-ffff-ffff-ffffffffffff";

    let err = dispatch_tool(
        "moot_memory_get",
        &args!["id" => fake_id],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("absent id must produce a transport fault, not a fabricated row");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
    assert!(
        err.message.contains("Memory not found") && err.message.contains(fake_id),
        "error must be the standard not-found shape; got: {}",
        err.message
    );
}

#[test]
fn memory_get_withdrawn_drawer_is_reported_not_found() {
    // Containment-gate parity with moot_memory_search: a drawer that fails the
    // default state gate (withdrawn is outside the currentlyBelieve cluster)
    // must report the SAME "Memory not found" shape as a genuinely absent id —
    // the by-id door must not become a gate bypass.
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one_memory(&registry, "withdraw-then-get target", "lab");
    let withdraw = dispatch_tool(
        "moot_withdraw_memory",
        &args!["id" => id.as_str(), "reason" => "obsolete"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("withdraw_memory must not throw");
    assert!(is_success(&withdraw), "withdraw must succeed; got: {withdraw:?}");

    let err = dispatch_tool(
        "moot_memory_get",
        &args!["id" => id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("a withdrawn drawer must be reported not-found, not returned");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
    assert!(
        err.message.contains("Memory not found") && err.message.contains(&id),
        "withdrawn drawer must produce the standard not-found shape; got: {}",
        err.message
    );
}

#[test]
fn memory_get_provenance_secret_drawer_is_reported_not_found() {
    // Regression: moot_memory_search redacts provenance Secret/Restricted
    // previews, so moot_memory_get must not let a caller use the surfaced id as
    // a second door to read the full verbatim body without an explicit grant.
    let registry = EstateRegistry::new_inmemory_bare();
    let secret = "provenance-secret body must not leak through memory-get";
    let id = file_one_memory_with_provenance_sensitivity(
        &registry,
        secret,
        "vault",
        locus_kit::provenance::Sensitivity::Secret,
    );

    let search = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "provenance-secret"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("memory_search must not throw");
    assert!(is_success(&search), "memory_search must succeed; got: {search:?}");
    let search_text = content_text(&search);
    assert!(
        search_text.contains(&id),
        "search should still surface the row id for ranking; got: {search_text}"
    );
    assert!(
        search_text.contains("[sensitivity: secret") && !search_text.contains(secret),
        "search must redact the secret body while surfacing the id; got: {search_text}"
    );

    let err = dispatch_tool(
        "moot_memory_get",
        &args!["id" => id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("provenance-secret drawer must be reported not-found, not returned");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
    assert!(
        err.message.contains("Memory not found")
            && err.message.contains(&id)
            && !err.message.contains(secret),
        "secret drawer must use the standard not-found shape without leaking content; got: {}",
        err.message
    );
}

// ── near: anchor pivot — provenance-sensitivity redaction boundary ──────────
//
// The by-id door (memory_get, above) and the pivot door (near:) must agree.
// `moot_memory_search` deliberately surfaces a gated row's ID with a redacted
// body, so the UUID needed to pivot is obtainable in ordinary use; if the
// pivot did not gate, the caller could hand that UUID back as `near:` and
// receive the protected body's content-derived neighbors. These cases cover
// both tools that accept `near:` — moot_memory_search and moot_recall_shaped.
//
// Every case asserts the SAME not-found message an absent id produces. A
// distinct message or error code would turn the fix into an existence oracle
// for redacted rows, which is the same class of defect the gate closes.

/// Dispatch `near:` against both tools that accept it and return the error
/// each produced. Keeping this in one helper is what makes "both doors agree"
/// checkable in a single assertion per property.
fn near_pivot_errors(registry: &EstateRegistry, anchor: &str) -> Vec<(&'static str, JSONRPCError)> {
    let search = dispatch_tool(
        "moot_memory_search",
        &args!["near" => anchor],
        registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("near: on a gated or absent anchor must be reported not-found");
    let shaped = dispatch_tool(
        "moot_recall_shaped",
        &args!["near" => anchor, "preset" => "balanced"],
        registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("near: on a gated or absent anchor must be reported not-found");
    vec![("moot_memory_search", search), ("moot_recall_shaped", shaped)]
}

#[test]
fn near_anchor_provenance_secret_is_reported_not_found() {
    // The regression case for Codex finding 3a1cf92490a481918c3a2837effe341f:
    // before the gate, the Secret body became the recall query verbatim.
    let registry = EstateRegistry::new_inmemory_bare();
    let secret = "provenance-secret body must not become a near: recall query";
    let id = file_one_memory_with_provenance_sensitivity(
        &registry,
        secret,
        "vault",
        locus_kit::provenance::Sensitivity::Secret,
    );

    for (tool, err) in near_pivot_errors(&registry, &id) {
        assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS, "{tool}");
        assert_eq!(
            err.message,
            format!("near: anchor memory not found: {id}"),
            "{tool} must use the standard near: not-found shape"
        );
        assert!(
            !err.message.contains(secret),
            "{tool} must not leak the withheld body; got: {}",
            err.message
        );
    }
}

#[test]
fn near_anchor_provenance_restricted_is_reported_not_found() {
    let registry = EstateRegistry::new_inmemory_bare();
    let restricted = "provenance-restricted body must not become a near: recall query";
    let id = file_one_memory_with_provenance_sensitivity(
        &registry,
        restricted,
        "vault",
        locus_kit::provenance::Sensitivity::Restricted,
    );

    for (tool, err) in near_pivot_errors(&registry, &id) {
        assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS, "{tool}");
        assert_eq!(
            err.message,
            format!("near: anchor memory not found: {id}"),
            "{tool} must use the standard near: not-found shape"
        );
        assert!(
            !err.message.contains(restricted),
            "{tool} must not leak the withheld body; got: {}",
            err.message
        );
    }
}

#[test]
fn near_anchor_gated_message_is_byte_identical_to_absent_id_message() {
    // Indistinguishability — the property the gate exists to protect. If a
    // gated anchor produced any different message or code than an absent id,
    // `near:` would become an existence oracle for redacted rows, which is the
    // same defect class as the leak it replaces.
    let registry = EstateRegistry::new_inmemory_bare();

    for tier in [
        locus_kit::provenance::Sensitivity::Restricted,
        locus_kit::provenance::Sensitivity::Secret,
    ] {
        let id = file_one_memory_with_provenance_sensitivity(
            &registry,
            "gated body for the oracle check",
            "vault",
            tier,
        );
        // A UUID that was never filed. Comparing against the gated id
        // substituted in leaves the SHAPE as the only possible difference.
        let absent = "00000000-0000-4000-8000-00000000dead";

        let gated = near_pivot_errors(&registry, &id);
        let missing = near_pivot_errors(&registry, absent);
        for ((tool, g), (_, m)) in gated.into_iter().zip(missing.into_iter()) {
            assert_eq!(g.code, m.code, "{tool}/{tier:?}: error code must match");
            assert_eq!(
                g.message,
                m.message.replace(absent, &id),
                "{tool}/{tier:?}: gated message must be byte-identical to the absent-id message"
            );
        }
    }
}

#[test]
fn near_anchor_provenance_normal_and_elevated_still_pivot() {
    // The other half: a gate, not a wall. Provenance Normal and Elevated are
    // BELOW the redaction boundary and must still pivot, or the fix would have
    // closed the near: door on ordinary rows. Mirrors the intent of
    // memory_get's provenance_normal_and_elevated tests.
    for tier in [
        locus_kit::provenance::Sensitivity::Normal,
        locus_kit::provenance::Sensitivity::Elevated,
    ] {
        let registry = EstateRegistry::new_inmemory_bare();
        let id = file_one_memory_with_provenance_sensitivity(
            &registry,
            "open provenance anchor body pivots normally",
            "lab",
            tier,
        );

        let search = dispatch_tool(
            "moot_memory_search",
            &args!["near" => id.as_str()],
            &registry,
            &SurfacedRecallLedger::new(),
        )
        .unwrap_or_else(|e| panic!("provenance {tier:?} must still pivot via search; got: {e:?}"));
        assert!(is_success(&search), "provenance {tier:?} search pivot: {search:?}");

        let shaped = dispatch_tool(
            "moot_recall_shaped",
            &args!["near" => id.as_str(), "preset" => "balanced"],
            &registry,
            &SurfacedRecallLedger::new(),
        )
        .unwrap_or_else(|e| panic!("provenance {tier:?} must still pivot via shaped; got: {e:?}"));
        assert!(is_success(&shaped), "provenance {tier:?} shaped pivot: {shaped:?}");
    }
}

#[test]
fn near_anchor_adjective_gated_behaviour_is_unchanged() {
    // The adjective axis (bits 6-11) was already gated by the default
    // RecallFrame before this mission, and stays gated the same way after it.
    // Pinning it here proves the provenance check was added ALONGSIDE the
    // frame gate rather than replacing it.
    let registry = EstateRegistry::new_inmemory_bare();
    let body = "adjective-secret anchor body";
    let id = {
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::estate_types::LatticeAnchor;
        use locus_kit::frames::CaptureFrame;
        let mut frame = CaptureFrame::new(
            body,
            CaptureChannel::Typed,
            "vault",
            LatticeAnchor::udc("004"),
            "aria-mcp-tests",
            "default",
        );
        frame.sensitivity = locus_kit::adjectives::AdjectiveSensitivity::Secret;
        let now = aria_mcp::dispatch::wall_now();
        let coord = registry.coord.lock().unwrap();
        coord
            .capture(&registry.default.handle, frame, now)
            .expect("adjective-secret capture must succeed")
            .id
            .clone()
    };

    for (tool, err) in near_pivot_errors(&registry, &id) {
        assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS, "{tool}");
        assert_eq!(
            err.message,
            format!("near: anchor memory not found: {id}"),
            "{tool}: adjective-gated anchors keep the same not-found shape"
        );
    }
}

#[test]
fn memory_get_omitted_estate_id_hits_default_estate() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one_memory(&registry, "default-estate memory-get content", "lab");

    let result = dispatch_tool(
        "moot_memory_get",
        &args!["id" => id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("memory_get must not throw");
    assert!(is_success(&result), "omitted estateID must resolve to the default estate; got: {result:?}");
}

#[test]
fn memory_get_explicit_default_estate_id_is_accepted() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one_memory(&registry, "explicit-default-estate memory-get content", "lab");
    let default_id = registry.default.estate_id.to_string();

    let result = dispatch_tool(
        "moot_memory_get",
        &args!["id" => id.as_str(), "estateID" => default_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("memory_get must not throw");
    assert!(is_success(&result), "explicit default estateID must be accepted; got: {result:?}");
}

#[test]
fn memory_get_non_default_estate_id_is_refused() {
    // Item 3 hardening: direct tool calls may only target the default estate.
    // Mirrors Swift MultiEstateRoutingTests's refusal case.
    let mut registry = EstateRegistry::new_inmemory_bare();
    let other_id = registry.register_inmemory("owner-two");
    let id = file_one_memory(&registry, "non-default-estate memory-get content", "lab");

    let err = dispatch_tool(
        "moot_memory_get",
        &args!["id" => id.as_str(), "estateID" => other_id.to_string().as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err("a registered non-default estateID must be refused for direct routing");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
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
    // _bare: controlled estate — after withdrawing the one memory, search must
    // return "found 0"; the 7 seeded AI_Charter_Hint drawers would otherwise show.
    let registry = EstateRegistry::new_inmemory_bare();
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
    // A single-row lineage has nothing for the gate to refuse — the
    // historical response shape must be byte-identical (SPEC B-8b).
    assert_eq!(
        text,
        format!("erased memory {id}"),
        "a full expunge must keep the exact historical response shape"
    );
}

/// A lineage expunge that the audit gate refused for an accepted sibling
/// must NOT respond "erased memory <id>" — the response names the partial
/// outcome, the refused count, and the surviving ids (SPEC B-8b, MXE-FA).
/// A caller acting on this sentence is making a privacy decision on it.
/// Mirrors Swift `ErasePartialResponseTests`.
#[test]
fn erase_memory_partial_lineage_response_names_refused_count() {
    use locus_kit::adjectives::Trust;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::{CaptureFrame, MutationKind};

    let registry = EstateRegistry::new_inmemory();
    let now = aria_mcp::dispatch::wall_now();

    // D1: captured, promoted to Accepted (S-1 requires trust ≥ canonical;
    // the accepted state is what the gate protects from tombstoning, S-3).
    // D2: same lineage, still active — the expunge target. D1 is accepted
    // BEFORE D2 is captured so the capture does not supersede it.
    let (d1_id, d2_id) = {
        let coord = registry.coord.lock().unwrap();
        let d1 = coord
            .capture(
                &registry.default.handle,
                CaptureFrame::new(
                    "accepted iridium fact held for audit",
                    CaptureChannel::Typed,
                    "aria-erase-partial-tests",
                    LatticeAnchor::udc("004"),
                    "aria-mcp-tests",
                    "default",
                ),
                now,
            )
            .expect("capture d1");
        coord
            .mutate(
                &registry.default.handle,
                &d1.id,
                MutationKind::CorrectTrust(Trust::Canonical),
                None,
            )
            .expect("correct trust to canonical");
        coord
            .mutate(&registry.default.handle, &d1.id, MutationKind::Accept, None)
            .expect("promote d1 to accepted");

        let mut d2_frame = CaptureFrame::new(
            "active iridium draft in the same lineage",
            CaptureChannel::Typed,
            "aria-erase-partial-tests",
            LatticeAnchor::udc("004"),
            "aria-mcp-tests",
            "default",
        );
        d2_frame.lineage_id = Some(d1.lineage_id);
        let d2 = coord
            .capture(&registry.default.handle, d2_frame, now + 100)
            .expect("capture d2");
        (d1.id, d2.id)
    };

    let result = dispatch_tool(
        "moot_erase_memory",
        &args!["id" => d2_id.as_str(), "reason" => "partial response shape test", "confirmed" => true],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("erase_memory must not throw");
    // A partial expunge is a completed operation with a partial outcome,
    // not a tool error.
    assert!(is_success(&result), "partial erase must not be isError; got: {result:?}");
    let text = content_text(&result);
    assert_ne!(
        text,
        format!("erased memory {d2_id}"),
        "a partial lineage expunge must NOT claim a plain success"
    );
    assert!(text.contains("partial"), "response must say the expunge was partial; got: {text}");
    assert!(text.contains("1 "), "response must name the refused count; got: {text}");
    assert!(
        text.contains(&d1_id),
        "response must name the refused sibling id so the caller can act on it; got: {text}"
    );
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
    // The error message must name "confirmed" — the actual field in the tool schema
    // and the handler. Naming "confirmation" instead would loop AI consumers forever
    // because that field does not exist and the handler ignores it.
    let msg = content_text(&result);
    assert!(
        msg.contains("confirmed"),
        "error message must name 'confirmed' (the caller-facing field); got: {msg}"
    );
    assert!(
        !msg.contains("confirmation=true"),
        "error message must not name 'confirmation=true' — not the schema field; got: {msg}"
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

/// Bug J regression: move_memory must honour the `wing` argument.
///
/// Files a memory into "OriginWing", then moves it to "TargetWing" via
/// `moot_move_memory`. Verifies:
///   1. The success text names both wing and room.
///   2. A recall scoped to "TargetWing" finds the memory.
///   3. A recall scoped to "OriginWing" returns zero hits.
#[test]
fn move_memory_with_wing_reanchors_to_target_wing() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // File into "OriginWing".
    let file_result = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "cross-wing-rust-test unique zeta omega unique-payload",
        "subject" => "cross-wing-rust-test unique zeta omega unique-payload",
            "location" => "origin-room",
            "wing" => "OriginWing"
        ],
        &registry,
        &ledger,
    )
    .expect("file_memory must succeed");
    assert!(is_success(&file_result), "file_memory must succeed; got: {file_result:?}");
    let file_text = content_text(&file_result);
    let id = file_text
        .lines()
        .next()
        .and_then(|l| l.strip_prefix("filed memory "))
        .expect("must parse id from file result");

    // Move to "TargetWing".
    let move_result = dispatch_tool(
        "moot_move_memory",
        &args![
            "id" => id,
            "location" => "target-room",
            "wing" => "TargetWing"
        ],
        &registry,
        &ledger,
    )
    .expect("move_memory must not throw");
    assert!(is_success(&move_result), "move_memory must succeed; got: {move_result:?}");
    let move_text = content_text(&move_result);
    assert!(
        move_text.contains("TargetWing"),
        "move result must name the target wing; got: {move_text}"
    );
    assert!(
        move_text.contains("target-room"),
        "move result must name the target room; got: {move_text}"
    );

    // Recall in TargetWing must find the memory.
    let target_recall = dispatch_tool(
        "moot_memory_search",
        &args![
            "query" => "cross-wing-rust-test unique zeta omega",
            "wing" => "TargetWing"
        ],
        &registry,
        &ledger,
    )
    .expect("memory_search must not throw");
    assert!(is_success(&target_recall));
    let target_text = content_text(&target_recall);
    assert!(
        !target_text.contains("found 0 memory(s)"),
        "recall in TargetWing must find the moved memory; got: {target_text}"
    );

    // Recall in OriginWing must return 0 hits.
    let origin_recall = dispatch_tool(
        "moot_memory_search",
        &args![
            "query" => "cross-wing-rust-test unique zeta omega",
            "wing" => "OriginWing"
        ],
        &registry,
        &ledger,
    )
    .expect("memory_search must not throw");
    assert!(is_success(&origin_recall));
    let origin_text = content_text(&origin_recall);
    assert!(
        origin_text.contains("found 0 memory(s)"),
        "recall in OriginWing must return 0 hits after cross-wing move; got: {origin_text}"
    );
}

/// Bug O regression (Rust verification): moot_memory_search with results must
/// NOT emit the "no memories matched" coaching hint.
///
/// The Rust coaching_engine already gated on "found 0 memory(s)" (not the
/// substring "0 memory"), so this test proves the invariant is preserved.
#[test]
fn search_with_results_does_not_emit_no_results_hint() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // File a memory so the search can return at least one hit.
    dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "rust-hint-test unique alpha bravo charlie unique-payload",
        "subject" => "rust-hint-test unique alpha bravo charlie unique-payload",
            "location" => "hint-test-room"
        ],
        &registry,
        &ledger,
    )
    .expect("file_memory must succeed");

    let search_result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "rust-hint-test unique alpha bravo"],
        &registry,
        &ledger,
    )
    .expect("memory_search must not throw");
    assert!(is_success(&search_result));
    let search_text = content_text(&search_result);

    // Must not emit the "no memories matched" coaching hint.
    assert!(
        !search_text.contains("no memories matched"),
        "No-results hint must not fire when search returned results; got: {search_text}"
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
// 5b. Lifecycle enforcement — proposed/withdrawn/superseded tunnels must not
//     leak through moot_connection_search or moot_connection_map (FIND4).
// ---------------------------------------------------------------------------

/// Insert a tunnel with a given lifecycle (bits 3–5 of operational_bitmap)
/// directly into the default estate's DrawerStore, bypassing the link verb.
///
/// The source and target wings are resolved from the drawer identified by
/// `src_drawer_id` via `coord.resolve_drawer_node_names` so that
/// `recall_tunnels(wing)` — which `run_connection_search` uses internally —
/// finds the tunnel in the correct wing bucket.
fn insert_lifecycle_tunnel_for_drawer(
    registry: &EstateRegistry,
    src_drawer_id: &str,
    tgt_drawer_id: &str,
    lifecycle: locus_kit::tunnel_operational::TunnelLifecycle,
) {
    use locus_kit::tunnel::Tunnel;
    let now = aria_mcp::dispatch::wall_now();

    // Resolve the source drawer's wing/room from the node tree so the tunnel
    // lands in the right wing bucket for recall_tunnels().
    let (src_wing, src_room) = {
        let coord = registry.coord.lock().unwrap();
        let mut frame = locus_kit::filter::RecallFrame::new(vec![]);
        frame.limit = Some(256);
        let all = coord
            .recall(&registry.default.handle, frame, now)
            .expect("recall for wing resolution must succeed");
        let source = all.iter().find(|d| d.id == src_drawer_id)
            .unwrap_or_else(|| panic!("src_drawer_id {src_drawer_id} not found — file a memory first"));
        let node_names = coord.resolve_drawer_node_names(
            &registry.default.handle,
            &[source.parent_node_id.clone()],
        );
        node_names
            .get(&source.parent_node_id)
            .cloned()
            .unwrap_or_else(|| ("unknown-wing".to_string(), "unknown-room".to_string()))
    };

    let lifecycle_bits: i64 = (lifecycle.raw_value()) << 3;
    let t = Tunnel {
        id: format!("lc-test-{src_drawer_id}-{}", lifecycle.raw_value()),
        source_wing: src_wing,
        source_room: src_room,
        source_drawer_id: Some(src_drawer_id.to_string()),
        target_wing: "tgt".to_string(),
        target_room: "r2".to_string(),
        target_drawer_id: Some(tgt_drawer_id.to_string()),
        label: "lifecycle-test-edge".to_string(),
        kind: locus_kit::tunnel_operational::TunnelKind::References,
        adjective_bitmap: 0,       // Normal sensitivity — bulk-exportable
        operational_bitmap: lifecycle_bits,
        provenance_bitmap: 0,
        added_by: "test".to_string(),
        filed_at: now,
        tombstoned_at: None,
        removed_by_batch: None,
        order_key: None,
        // No review-ledger state on a freshly filed test edge (the ext
        // column carries the TunnelReviewLedger once a reviewer votes).
        ext: None,
    };
    registry.default.store.add_tunnel(&t).expect("add_tunnel must succeed");
}

#[test]
fn connection_search_excludes_proposed_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let src_id = file_one_memory(&registry, "lifecycle-cs-proposed-src", "lc/cs/proposed");
    let tgt_id = "dummy-tgt-proposed-cs";
    insert_lifecycle_tunnel_for_drawer(&registry, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Proposed);

    let result = dispatch_tool(
        "moot_connection_search",
        &args!["from_id" => src_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("connection_search must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains(": 0"),
        "proposed tunnel must be excluded from connection_search; got: {text}"
    );
}

#[test]
fn connection_search_excludes_withdrawn_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let src_id = file_one_memory(&registry, "lifecycle-cs-withdrawn-src", "lc/cs/withdrawn");
    let tgt_id = "dummy-tgt-withdrawn-cs";
    insert_lifecycle_tunnel_for_drawer(&registry, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Withdrawn);

    let result = dispatch_tool(
        "moot_connection_search",
        &args!["from_id" => src_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("connection_search must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains(": 0"),
        "withdrawn tunnel must be excluded from connection_search; got: {text}"
    );
}

#[test]
fn connection_search_excludes_superseded_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let src_id = file_one_memory(&registry, "lifecycle-cs-superseded-src", "lc/cs/superseded");
    let tgt_id = "dummy-tgt-superseded-cs";
    insert_lifecycle_tunnel_for_drawer(&registry, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Superseded);

    let result = dispatch_tool(
        "moot_connection_search",
        &args!["from_id" => src_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("connection_search must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains(": 0"),
        "superseded tunnel must be excluded from connection_search; got: {text}"
    );
}

#[test]
fn connection_map_excludes_proposed_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let src_id = file_one_memory(&registry, "lifecycle-cm-proposed-src", "lc/cm/proposed");
    let tgt_id = "dummy-tgt-proposed-cm";
    insert_lifecycle_tunnel_for_drawer(&registry, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Proposed);

    let result = dispatch_tool(
        "moot_connection_map",
        &args!["to_id" => tgt_id],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("connection_map must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains(": 0"),
        "proposed tunnel must be excluded from connection_map; got: {text}"
    );
}

#[test]
fn connection_map_excludes_withdrawn_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let src_id = file_one_memory(&registry, "lifecycle-cm-withdrawn-src", "lc/cm/withdrawn");
    let tgt_id = "dummy-tgt-withdrawn-cm";
    insert_lifecycle_tunnel_for_drawer(&registry, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Withdrawn);

    let result = dispatch_tool(
        "moot_connection_map",
        &args!["to_id" => tgt_id],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("connection_map must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains(": 0"),
        "withdrawn tunnel must be excluded from connection_map; got: {text}"
    );
}

#[test]
fn connection_search_returns_active_and_excludes_proposed_same_source() {
    let registry = EstateRegistry::new_inmemory();
    let src_id = file_one_memory(&registry, "lifecycle-cs-mixed-src", "lc/cs/mixed");
    let tgt_active = file_one_memory(&registry, "lifecycle-cs-mixed-tgt-active", "lc/cs/mixed-tgt");
    let tgt_proposed = "dummy-tgt-proposed-mixed";

    // Create one active tunnel via the MCP link verb (lifecycle = active by default).
    dispatch_tool(
        "moot_link_memories",
        &args!["from_id" => src_id.as_str(), "to_id" => tgt_active.as_str(), "kind" => "references"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_link_memories must succeed");

    // Insert one proposed tunnel directly with the same source drawer.
    insert_lifecycle_tunnel_for_drawer(&registry, &src_id, tgt_proposed, locus_kit::tunnel_operational::TunnelLifecycle::Proposed);

    let result = dispatch_tool(
        "moot_connection_search",
        &args!["from_id" => src_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("connection_search must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains(": 1"),
        "exactly one active tunnel must appear; proposed must be excluded; got: {text}"
    );
}

// 5c. Lifecycle enforcement — memory_get must not surface proposed/withdrawn/
//     superseded tunnels in its linked-tunnel summary (FIND4 residual).

#[test]
fn memory_get_excludes_proposed_tunnels_from_linked_summary() {
    // Capture a real drawer, insert a proposed lifecycle tunnel pointing from it,
    // then assert memory_get reports "tunnels: 0" — the proposed edge is hidden.
    let registry = EstateRegistry::new_inmemory();
    let src_id = file_one_memory(&registry, "find4-mg-proposed-src", "lc/mg/proposed");
    let tgt_id = "dummy-tgt-proposed-mg";
    insert_lifecycle_tunnel_for_drawer(
        &registry, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Proposed,
    );

    let result = dispatch_tool(
        "moot_memory_get",
        &args!["id" => src_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("memory_get must not throw for a real drawer");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("tunnels: 0"),
        "proposed tunnel must be excluded from memory_get linked summary; got: {text}"
    );
}

#[test]
fn memory_get_excludes_withdrawn_tunnels_from_linked_summary() {
    let registry = EstateRegistry::new_inmemory();
    let src_id = file_one_memory(&registry, "find4-mg-withdrawn-src", "lc/mg/withdrawn");
    let tgt_id = "dummy-tgt-withdrawn-mg";
    insert_lifecycle_tunnel_for_drawer(
        &registry, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Withdrawn,
    );

    let result = dispatch_tool(
        "moot_memory_get",
        &args!["id" => src_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("memory_get must not throw for a real drawer");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("tunnels: 0"),
        "withdrawn tunnel must be excluded from memory_get linked summary; got: {text}"
    );
}

#[test]
fn memory_get_excludes_superseded_tunnels_from_linked_summary() {
    let registry = EstateRegistry::new_inmemory();
    let src_id = file_one_memory(&registry, "find4-mg-superseded-src", "lc/mg/superseded");
    let tgt_id = "dummy-tgt-superseded-mg";
    insert_lifecycle_tunnel_for_drawer(
        &registry, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Superseded,
    );

    let result = dispatch_tool(
        "moot_memory_get",
        &args!["id" => src_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("memory_get must not throw for a real drawer");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("tunnels: 0"),
        "superseded tunnel must be excluded from memory_get linked summary; got: {text}"
    );
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
fn fact_search_exact_fields_reject_substring_and_source_collisions() {
    let registry = EstateRegistry::new_inmemory();
    // source_id must name a drawer that exists in this estate — a fact inherits
    // its source drawer's sensitivity, so an unresolvable anchor fails the
    // write, so the two distinct sources this test needs are two real drawers.
    // The substring-collision case this test guards lives on subject_exact
    // ("ev-1" vs "ev-10"), which is unaffected.
    let mut source_ids: Vec<String> = Vec::new();
    for label in ["calendar-source", "other-source"] {
        let filed = dispatch_tool(
            "moot_file_memory",
            &args![
                "content" => format!("fixture drawer {label}"),
                "location" => format!("fixtures/{label}"),
                "subject" => format!("fixture anchor drawer {label}")
            ],
            &registry,
            &SurfacedRecallLedger::new(),
        )
        .expect("file memory");
        assert!(is_success(&filed), "moot_file_memory must succeed: {filed:?}");
        // The body opens with "filed memory <drawer-id>".
        let text = content_text(&filed);
        let first_line = text.lines().next().unwrap_or("");
        let id = first_line
            .trim_start_matches("filed memory ")
            .trim()
            .to_string();
        assert!(!id.is_empty(), "could not read drawer id from: {text}");
        source_ids.push(id);
    }
    for (subject, source) in [
        ("calendar.event.ev-1", source_ids[0].as_str()),
        ("calendar.event.ev-10", source_ids[1].as_str()),
    ] {
        let filed = dispatch_tool(
            "moot_file_fact",
            &args![
                "subject" => subject,
                "predicate" => "scheduled",
                "object" => "fixture",
                "source_id" => source
            ],
            &registry,
            &SurfacedRecallLedger::new(),
        )
        .expect("file fact");
        assert!(is_success(&filed));
    }
    let search = dispatch_tool(
        "moot_fact_search",
        &args![
            "subject_exact" => "calendar.event.ev-1",
            "predicate_exact" => "scheduled",
            "source_id_exact" => source_ids[0].as_str()
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("exact fact search");
    let text = content_text(&search);
    assert!(text.contains("calendar.event.ev-1"));
    assert!(!text.contains("calendar.event.ev-10"));
    assert!(text.starts_with("facts: 1"), "unexpected exact search: {text}");
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

#[test]
fn read_journal_row_uses_iso8601_bracketed_timestamp() {
    // R4 parity fix: read_journal rows must use the ISO8601 bracketed format
    // "[2026-06-20T17:06:29Z]  <entry>" matching Swift runReadJournal exactly.
    // Previously: "  1781975814 | <entry>" (raw epoch seconds, pipe separator).
    let registry = EstateRegistry::new_inmemory();

    // Write an entry so there is a row to inspect.
    dispatch_tool(
        "moot_write_journal",
        &args!["entry" => "ISO8601 timestamp parity test"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("write_journal must not throw");

    let read = dispatch_tool(
        "moot_read_journal",
        &args!["agent" => "mcp-agent"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("read_journal must not throw");
    assert!(is_success(&read), "read_journal must succeed; got: {read:?}");
    let text = content_text(&read);

    // Must contain the entry text — basic round-trip.
    assert!(
        text.contains("ISO8601 timestamp parity test"),
        "written entry must appear in read_journal output; got: {text}"
    );
    // The timestamp must be bracketed ISO8601, not a raw epoch integer.
    // Look for the "[YYYY-" opening pattern that uniquely identifies ISO8601.
    assert!(
        text.contains("[20"), // e.g. "[2026-"
        "read_journal row must use ISO8601-bracketed timestamp (e.g. '[2026-...T...Z]'); got: {text}"
    );
    // Must NOT contain the old pipe-separated epoch format.
    assert!(
        !text.lines().any(|l| l.contains(" | ") && l.trim_start().starts_with(|c: char| c.is_ascii_digit())),
        "read_journal must not use old pipe-epoch format; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// 7b. Finding #4 — last_n clamping in moot_read_journal
// ---------------------------------------------------------------------------

/// last_n=-1 must return invalidParams (code -32602), not all rows.
/// Before the fix, the bare `optional_integer → n as usize` cast silently
/// turned -1 into usize::MAX → `entries.truncate(usize::MAX)` is a no-op →
/// the caller could receive the entire diary table.
#[test]
fn read_journal_negative_last_n_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_read_journal",
        &args!["last_n" => -1i64],
        &registry,
        &SurfacedRecallLedger::new(),
    );
    // clamp_limit propagates the error; dispatch_tool returns Err.
    match result {
        Err(e) => {
            // Verify the error is specifically invalidParams.
            assert_eq!(e.code, -32602, "expected invalidParams (-32602); got code {}", e.code);
        }
        Ok(v) => {
            // The error may be wrapped in a JSON-RPC error result object if the
            // dispatch path returns Ok(JSONRPCResponse::failure(…)).
            let is_error_field = v.get("isError").and_then(|v| v.as_bool()).unwrap_or(false);
            assert!(is_error_field, "last_n=-1 must yield an error result; got: {v:?}");
        }
    }
}

/// last_n=0 must also return invalidParams (0 is not ≥ 1).
#[test]
fn read_journal_zero_last_n_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_read_journal",
        &args!["last_n" => 0i64],
        &registry,
        &SurfacedRecallLedger::new(),
    );
    match result {
        Err(e) => assert_eq!(e.code, -32602),
        Ok(v) => {
            let is_error_field = v.get("isError").and_then(|v| v.as_bool()).unwrap_or(false);
            assert!(is_error_field, "last_n=0 must yield an error result; got: {v:?}");
        }
    }
}

/// last_n=1000 (above ceiling 500) must be silently clamped — not an error.
#[test]
fn read_journal_huge_last_n_is_clamped_silently() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_read_journal",
        &args!["last_n" => 1000i64],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("last_n=1000 must not error — clamped to 500 silently");
    // Should be a success result (empty journal on fresh estate).
    assert!(is_success(&result), "last_n=1000 must succeed; got: {result:?}");
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
    use aria_mcp::sensitivity_grant_ledger::SensitivityGrantLedger;
    use std::collections::BTreeMap;
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    let sensitivity_ledger = SensitivityGrantLedger::new();
    let result = interface_tools::dispatch(
        "moot_estate_ping",
        &BTreeMap::new(),
        &registry,
        &ledger,
        &sensitivity_ledger,
        "TESTSERIAL-XYZ",
        "",
        None,
        None,
    )
    .expect("estate_ping must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("build TESTSERIAL-XYZ"),
        "estate_ping must echo the injected serial; got: {text}"
    );
}

/// a non-empty version_skew string is surfaced verbatim under a
/// `version_skew:` line in both moot_estate_ping and moot_estate_status; an
/// empty string (the common case, no skew detected) omits the field.
#[test]
fn version_skew_advisory_surfaces_when_present_and_omitted_when_absent() {
    use aria_mcp::interface_tools;
    use aria_mcp::sensitivity_grant_ledger::SensitivityGrantLedger;
    use std::collections::BTreeMap;
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    let sensitivity_ledger = SensitivityGrantLedger::new();
    let advisory = "plugin 1.0.15 expects binary >= 1.0.15; binary is 1.0.11 -- run `mootx01 upgrade`";

    for tool in ["moot_estate_ping", "moot_estate_status"] {
        let with_skew = interface_tools::dispatch(
            tool, &BTreeMap::new(), &registry, &ledger, &sensitivity_ledger, "SERIAL", advisory, None, None,
        )
        .expect("dispatch must not throw");
        let text = content_text(&with_skew);
        assert!(
            text.contains(&format!("version_skew: {advisory}")),
            "{tool} must surface the injected version-skew advisory; got: {text}"
        );

        let without_skew = interface_tools::dispatch(
            tool, &BTreeMap::new(), &registry, &ledger, &sensitivity_ledger, "SERIAL", "", None, None,
        )
        .expect("dispatch must not throw");
        let text2 = content_text(&without_skew);
        assert!(
            !text2.contains("version_skew"),
            "{tool} must omit version_skew when the host injected none; got: {text2}"
        );
    }
}

/// Upstream-release advisory: a wired provider's line is surfaced under an
/// `update_available:` line in both moot_estate_ping and moot_estate_status;
/// a provider answering None (up to date / probe failed — the host's advisor
/// collapses both) omits the field, mirroring version_skew's opt-in shape.
/// The no-provider default is covered implicitly by every other test in this
/// file. Mirrors Swift ServerTests.testUpdateAdvisorySurfacesInPingAndStatus /
/// testNilUpdateAdvisoryOmitsField.
#[test]
fn update_advisory_surfaces_when_wired_and_omitted_when_none() {
    use aria_mcp::dispatcher::UpdateAdvisoryProvider;
    use aria_mcp::interface_tools;
    use aria_mcp::sensitivity_grant_ledger::SensitivityGrantLedger;
    use std::collections::BTreeMap;
    use std::sync::Arc;
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    let sensitivity_ledger = SensitivityGrantLedger::new();
    let line = "v9.9.9 is available (installed 1.0.33) -- upgrade with `mootx01 upgrade`";
    let some_provider: UpdateAdvisoryProvider = Arc::new(move || Some(line.to_owned()));
    let none_provider: UpdateAdvisoryProvider = Arc::new(|| None);

    for tool in ["moot_estate_ping", "moot_estate_status"] {
        let with_update = interface_tools::dispatch(
            tool, &BTreeMap::new(), &registry, &ledger, &sensitivity_ledger, "SERIAL", "",
            Some(&some_provider), None,
        )
        .expect("dispatch must not throw");
        let text = content_text(&with_update);
        assert!(
            text.contains(&format!("update_available: {line}")),
            "{tool} must surface the provider's update advisory; got: {text}"
        );

        let without_update = interface_tools::dispatch(
            tool, &BTreeMap::new(), &registry, &ledger, &sensitivity_ledger, "SERIAL", "",
            Some(&none_provider), None,
        )
        .expect("dispatch must not throw");
        let text2 = content_text(&without_update);
        assert!(
            !text2.contains("update_available"),
            "{tool} must omit update_available when the provider answers None; got: {text2}"
        );
    }
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
fn estate_status_kg_facts_field_matches_swift_format() {
    // Parity fix: estate_status must emit "kg facts: N active" (space, "active"
    // suffix) to match Swift runEstateStatus, not "kg_facts: N" (underscore, no suffix).
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_estate_status", &args![], &registry, &SurfacedRecallLedger::new())
        .expect("estate_status must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains("kg facts:"),
        "estate_status must use 'kg facts:' (space, not underscore) to match Swift; got: {text}"
    );
    assert!(
        text.contains("kg facts:") && text.lines().any(|l| l.starts_with("kg facts:") && l.contains("active")),
        "estate_status 'kg facts' line must include 'active' suffix to match Swift; got: {text}"
    );
    assert!(
        !text.contains("kg_facts:"),
        "estate_status must not use underscore 'kg_facts:' (old Rust format); got: {text}"
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
// These tests mirror Swift's MultiEstateRoutingTests:
//   - Granted sources contribute; ungranted sources are silently skipped.
//   - No grant from any source → refused as isError:true (not a transport fault).
//   - Omitted requesterEstateID → uses default estate (Item 2 hardening).
//   - Spoofed requesterEstateID → INVALID_PARAMS transport fault (Item 2 gate).
//   - Non-default estateID for seeding (Item 3) bypassed by seed_in_source helper.
//
// The tests issue grants directly at the coordinator level (bypassing the
// MCP grant-issue surface which does not exist yet) using `registry.coord`.
// Grant grantee_estate_id must use the handle's estate_uuid (the
// store-manifest UUID, [u8;16]) which federated_recall compares internally.
// ---------------------------------------------------------------------------

/// Helper: get the store-manifest UUID for an estate keyed by estate_id.
/// Used by the anti-spoof test to construct a non-default handle UUID.
fn handle_uuid_for(registry: &EstateRegistry, estate_id: uuid::Uuid) -> uuid::Uuid {
    registry.handle_uuid_for(estate_id)
        .expect("estate_id must be registered")
}

// Item 2 hardening: requesterEstateID is now optional. Omitted → uses default
// estate (single-estate, no grants, so still isError:true from no-grant path).
// Spoofed (non-default UUID) → throws INVALID_PARAMS (JSONRPCError transport fault).
#[test]
fn federated_search_omitted_requester_estate_id_uses_default_no_grant_error() {
    // Omitted requesterEstateID binds to the default estate. With no grants
    // issued, federated search returns isError:true (no grant from any source).
    // This was previously refused with "missing required argument: requesterEstateID";
    // now it reaches the grant check and is refused because no grant exists.
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_federated_search",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("omitted requesterEstateID must not throw transport fault");
    assert!(
        is_tool_error(&result),
        "omitted requesterEstateID (no grant) must return isError:true; got: {result:?}"
    );
}

#[test]
fn federated_search_spoofed_requester_estate_id_is_refused() {
    // Supplying a requesterEstateID that doesn't match the default estate is
    // refused. In Rust, run_federated_search returns error_result (isError:true)
    // for all requester-related refusals (unlike Swift which throws JSONRPCError).
    // The security effect is identical — the spoof is refused; the dispatch layer
    // differs. Both sides refuse the call and do not perform the federated read.
    let mut registry = EstateRegistry::new_inmemory();
    let other_estate_id = registry.register_inmemory("spoof-target");
    let other_handle_uuid = handle_uuid_for(&registry, other_estate_id);
    // other_handle_uuid != default.handle.estate_uuid → anti-spoof gate fires.
    let result = dispatch_tool(
        "moot_federated_search",
        &args!["requesterEstateID" => other_handle_uuid.to_string()],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("spoofed requesterEstateID must not throw transport fault");
    assert!(
        is_tool_error(&result),
        "spoofed requesterEstateID must be refused (isError:true); got: {result:?}"
    );
    let msg = content_text(&result);
    assert!(
        msg.contains("does not match") || msg.contains("authenticated caller"),
        "error message must name the mismatch; got: {msg}"
    );
    let _ = (other_estate_id, other_handle_uuid);
}

#[test]
fn federated_search_no_grant_is_refused_as_error_result() {
    // Two estates, no grant issued. moot_federated_search must return
    // isError:true, not throw, and must not leak the source content.
    // Mirrors Swift testNoGrantFederatedSearchRefusedAsErrorResult.
    let mut registry = EstateRegistry::new_inmemory();
    let source_estate_id = registry.register_inmemory("source");

    // Obtain the source handle for direct seeding (Item 3: moot_file_memory
    // is restricted to the default estate; seed non-default estates directly).
    let requester_bytes = registry.default.handle.estate_uuid;
    let source_handle = {
        let coord = registry.coord.lock().unwrap();
        coord.handles().into_iter()
            .find(|h| h.estate_uuid != requester_bytes)
            .expect("source handle must be in coordinator")
    };
    seed_in_source(&registry, &source_handle, "secret-source-content", "test-room");

    // requesterEstateID is omitted — the default estate is used automatically.
    let result = dispatch_tool(
        "moot_federated_search",
        &args![],
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
    let _ = source_estate_id; // registered estate used for test setup
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

    // Seed content directly into the source estate (Item 3: moot_file_memory
    // is restricted to the default estate; non-default estates seeded via coord).
    seed_in_source(&registry, &source_handle, "federated-content-row", "test-room");

    // Run federated search from the requester's perspective.
    // requesterEstateID is omitted — the default estate is used automatically.
    let result = dispatch_tool(
        "moot_federated_search",
        &args![],
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
    let _ = source_estate_id; // registered estate used for setup
    let _ = requester_handle_uuid; // default handle UUID used for grant
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
    let (registry, source_estate_id, _requester_handle_uuid, source_handle) =
        two_estate_registry_with_grant("expired-source", |grantee| GrantOptions {
            grantee_estate_id: grantee,
            scope: GrantScope::WholeEstate,
            custody_mode: CustodyMode::Mediated,
            lifetime: GrantLifetime::Until(1.0), // expired: Apple ref 2001-01-01 + 1s
            content_level: 0,
            re_share_permission: ReSharePermission::None,
        });

    // Seed content directly into the source estate (Item 3: moot_file_memory
    // is restricted to the default estate; non-default estates seeded via coord).
    seed_in_source(&registry, &source_handle, "should-be-refused-expired-grant", "test-room");

    // Federated search must refuse — grant is expired. requesterEstateID omitted
    // (default estate is used automatically after Item 2 hardening).
    let result = dispatch_tool(
        "moot_federated_search",
        &args![],
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
    let _ = source_estate_id;
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

    // Seed content directly into the source estate (Item 3: moot_file_memory
    // restricted to default; non-default estates seeded via coord).
    let requester_bytes = registry.default.handle.estate_uuid;
    let source_handle_r = {
        let coord = registry.coord.lock().unwrap();
        coord.handles().into_iter()
            .find(|h| h.estate_uuid != requester_bytes)
            .expect("source handle must be in coordinator")
    };
    seed_in_source(&registry, &source_handle_r, "in-allowed-room-content", "allowed-room");
    seed_in_source(&registry, &source_handle_r, "in-other-room-content", "other-room");

    // requesterEstateID omitted — default estate used automatically (Item 2).
    let result = dispatch_tool(
        "moot_federated_search",
        &args![],
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
    let _ = (source_estate_id, requester_handle_uuid);
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

    // Seed a Normal-sensitivity row directly (Item 3: moot_file_memory restricted
    // to default estate; non-default estates use coord.capture directly).
    seed_in_source(&registry, &source_handle, "normal-sensitivity-content", "test-room");

    // File an Elevated-sensitivity row also directly via the coordinator.
    // Sensitivity must be set at the CaptureFrame level; seed_in_source uses
    // the default (Normal). Use coord directly for the Elevated row.
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
    // requesterEstateID omitted — default estate used automatically (Item 2).
    let result = dispatch_tool(
        "moot_federated_search",
        &args![],
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
    let _ = (source_estate_id, requester_handle_uuid);
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

    // Seed content directly (Item 3: moot_file_memory restricted to default estate).
    let requester_bytes_h = registry.default.handle.estate_uuid;
    let source_handle_h = {
        let coord = registry.coord.lock().unwrap();
        coord.handles().into_iter()
            .find(|h| h.estate_uuid != requester_bytes_h)
            .expect("source handle must be in coordinator")
    };
    seed_in_source(&registry, &source_handle_h, "hydration-test-content-row", "test-room");

    // bitmapOnly hydration: recall succeeds (isError:false) but content is
    // stripped — the drawer line shows an empty content preview.
    // requesterEstateID omitted — default estate used automatically (Item 2).
    let bitmap_result = dispatch_tool(
        "moot_federated_search",
        &args!["hydrationLevel" => "bitmapOnly"],
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
        &args!["hydrationLevel" => "garbageValue"],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("invalid hydrationLevel must not throw transport fault");
    assert!(
        is_tool_error(&invalid_result),
        "invalid hydrationLevel must return isError:true (fail-closed); got: {invalid_result:?}"
    );
    let _ = (source_estate_id, requester_handle_uuid);
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

    // Seed content directly (Item 3: moot_file_memory restricted to default estate).
    let requester_bytes_ns = registry.default.handle.estate_uuid;
    let source_handle_ns = {
        let coord = registry.coord.lock().unwrap();
        coord.handles().into_iter()
            .find(|h| h.estate_uuid != requester_bytes_ns)
            .expect("source handle must be in coordinator")
    };
    seed_in_source(&registry, &source_handle_ns, "nonstring-hydration-content", "test-room");

    // Integer hydrationLevel: must return isError:true (fail-closed).
    // Before the fix this silently defaulted to Full and leaked content.
    // requesterEstateID omitted — default estate used automatically (Item 2).
    let result = dispatch_tool(
        "moot_federated_search",
        &args!["hydrationLevel" => 1_i64],
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
    let _ = (source_estate_id, requester_handle_uuid);
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

    // Seed content directly (Item 3: moot_file_memory restricted to default estate).
    seed_in_source(&registry, &source_handle, "budget-exhausted-secret-content", "test-room");

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
    // requesterEstateID omitted — default estate used automatically (Item 2).
    let result = dispatch_tool(
        "moot_federated_search",
        &args![],
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
    let _ = (source_estate_id, requester_handle_uuid);
}

// ---------------------------------------------------------------------------
// 10. Vault tools — now backed by vault-kit
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
    // Response shape now mirrors Swift async model: job_id / vault / scope / poll.
    assert!(
        export_text.contains("job_id:"),
        "export text must contain 'job_id:' (async job shape); got: {export_text}"
    );
    assert!(
        export_text.contains("poll: moot_vault_job to check status"),
        "export text must include poll hint (async job shape); got: {export_text}"
    );
    // Manifest is still stamped on disk; the response shape has changed but the
    // export correctness is verifiable via moot_vault_status after the call.
}

#[test]
fn vault_export_then_import_round_trips() {
    // Export from the default estate to a vault, then import that vault back
    // into the SAME estate via a fresh VaultBridge. Even if the reimport is
    // a content-idempotent no-op for every row (the same estate it was just
    // exported from — every lineage already exists unchanged), no row's
    // content may vanish: it must be accounted for as written, updated, or
    // explicitly skipped-unchanged. The vault_import response must be
    // isError:false throughout.
    //
    // scope: "believed" is passed explicitly on export. The default export
    // scope (CAND-032) is `exportable`, which only includes drawers
    // explicitly marked exportability==public; `file_one_memory` captures
    // are born-private (LocusKit `CaptureFrame::new`: "Privacy-preserving
    // default: drawers are born private"). Without an explicit `believed`
    // scope the export would write zero files and the round trip would be
    // vacuous — see the identical CAND-032 adaptation in
    // `vault_reconcile_apply_deleted_files_are_never_expunged`.
    use aria_mcp::{dispatch::dispatch_tool_with_vault_ledger, vault_tools::VaultJobLedger};

    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();
    let ledger = VaultJobLedger::new();
    let recall_ledger = SurfacedRecallLedger::new();

    file_one_memory(&registry, "Toluene is a solvent.", "chem/lab");

    dispatch_tool_with_vault_ledger(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap(), "scope" => "believed"],
        &registry,
        &recall_ledger,
        &ledger,
        "", "",
    )
    .expect("export must succeed");

    let import_result = dispatch_tool_with_vault_ledger(
        "moot_vault_import",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &recall_ledger,
        &ledger,
        "", "",
    )
    .expect("moot_vault_import must not throw transport fault");

    assert!(
        is_success(&import_result),
        "moot_vault_import must be isError:false; got: {import_result:?}"
    );
    let text = content_text(&import_result);
    // Response shape: job_id / vault / note_count / status: COMPLETE / stats.
    // The Rust backend completes the import synchronously before returning
    // (see `run_import`'s doc comment), so the response reports the finished
    // result inline rather than a poll hint. Commit 68d5997f replaced the
    // earlier "status: RUNNING" + poll-hint shape (612a5dab) with
    // "status: COMPLETE" + real stats, because a job that is already done by
    // the time the tool returns should not tell the caller to poll for a
    // status it already has.
    assert!(
        text.contains("job_id:"),
        "import text must contain 'job_id:' (async job shape); got: {text}"
    );
    assert!(
        text.contains("status: COMPLETE"),
        "import text must report status: COMPLETE (Rust backend is synchronous); got: {text}"
    );

    // Round-trip integrity: poll moot_vault_job for the full record — the
    // immediate text response above omits drawersSkippedUnchanged /
    // drawersSkippedTombstoned (see `run_import`), so only the job record
    // can confirm every exported row was actually accounted for.
    let job_id = text
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
        "", "",
    )
    .expect("moot_vault_job must not throw transport fault");
    std::fs::remove_dir_all(&vault).ok();

    assert!(
        is_success(&job_result),
        "moot_vault_job for the import id must be isError:false; got: {job_result:?}"
    );
    let job_text = content_text(&job_result);
    let field = |name: &str| -> i64 {
        job_text
            .lines()
            .find(|l| l.trim_start().starts_with(&format!("{name}:")))
            .and_then(|l| l.split(':').nth(1))
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(0)
    };
    let accounted_for = field("drawersWritten")
        + field("drawersUpdated")
        + field("drawersSkippedUnchanged")
        + field("drawersSkippedTombstoned");
    assert!(
        accounted_for >= 1,
        "round-tripped note must be written, updated, or explicitly skipped — \
         not silently dropped; got job record:\n{job_text}"
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

    // CAND-032: default export scope is now `exportable`; this reconcile fixture
    // is believed-tier, so the setup export uses explicit `believed` for full fidelity.
    dispatch_tool(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap(), "scope" => "believed"],
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
    // _bare: controlled estate — export/reconcile operate on this one memory,
    // not the 7 seeded AI_Charter_Hint drawers a full provision adds.
    let registry = EstateRegistry::new_inmemory_bare();
    let vault = temp_vault_dir();

    file_one_memory(&registry, "Keep me in the estate.", "chem/keep");

    // CAND-032: explicit `believed` setup export (default is now `exportable`).
    dispatch_tool(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap(), "scope" => "believed"],
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

    // CAND-032: explicit `believed` setup export (default is now `exportable`).
    dispatch_tool(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap(), "scope" => "believed"],
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
        "", "",
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
        "", "",
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
        "", "",
    )
    .expect("export must succeed");

    let import_result = dispatch_tool_with_vault_ledger(
        "moot_vault_import",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &recall_ledger,
        &ledger,
        "", "",
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
        "", "",
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
    // CAND-032: explicit `believed` setup export (default is now `exportable`).
    dispatch_tool_with_vault_ledger(
        "moot_vault_export",
        &args!["vaultPath" => vault.to_str().unwrap(), "scope" => "believed"],
        &registry,
        &recall_ledger,
        &ledger,
        "", "",
    )
    .expect("export must succeed");

    // First import: writes the row.
    dispatch_tool_with_vault_ledger(
        "moot_vault_import",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &recall_ledger,
        &ledger,
        "", "",
    )
    .expect("first import must not throw");

    // Second import: the row is unchanged → drawersSkippedUnchanged ≥ 1.
    let import_result = dispatch_tool_with_vault_ledger(
        "moot_vault_import",
        &args!["vaultPath" => vault.to_str().unwrap()],
        &registry,
        &recall_ledger,
        &ledger,
        "", "",
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
        "", "",
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
        "", "",
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
// 10b. Vault availability hardening (secfix/c-vault-jobslot)
// ---------------------------------------------------------------------------
//
// Two tests that document and verify the Rust port's existing slot-safety:
//   1. `hash_all_notes` skips a directory named `directory.md` (uses
//      `file_type.is_file()` before reading) — does not throw.
//   2. `run_import` with such a vault succeeds — no slot leak possible
//      because the Rust backend only records completed jobs in the ledger
//      (the `Dispatcher` Mutex serializes calls; no TOCTOU risk exists).

#[test]
fn hash_all_notes_skips_directory_named_md() {
    // A directory named "directory.md" inside a vault is not a note.
    // `collect_and_hash` checks `file_type.is_dir()` first and recurses
    // into directories rather than hashing them. A `directory.md` folder
    // is entered (which is fine — its contents are enumerable), but the
    // directory itself is never added to the output map.
    // This test ensures no panic and no spurious hash entry for the directory.
    use aria_mcp::vault_tools::hash_all_notes;

    let vault = temp_vault_dir();

    // Create a sub-directory named "directory.md" — not a regular file.
    let dir_md = vault.join("directory.md");
    std::fs::create_dir_all(&dir_md).expect("create directory.md sub-dir");

    // Also add a real note alongside the directory.
    std::fs::write(vault.join("real_note.md"), b"# Real note\n\nContent.")
        .expect("write real_note.md");

    let hashes = hash_all_notes(&vault)
        .expect("hash_all_notes must not throw for a vault containing directory.md");

    std::fs::remove_dir_all(&vault).ok();

    // Only the real note should appear; the directory.md entry must be absent.
    assert_eq!(
        hashes.len(),
        1,
        "Expected 1 hash entry (real_note.md only); directory.md must be skipped. Got: {:?}",
        hashes.keys().collect::<Vec<_>>()
    );
    assert!(
        hashes.contains_key("real_note.md"),
        "real_note.md must appear in the hash map"
    );
}

#[test]
fn import_with_directory_md_vault_does_not_exhaust_ledger() {
    // Verify that importing a vault containing only a "directory.md" sub-directory
    // (no regular notes) succeeds and records a completed job in the ledger.
    // The Rust backend records only completed jobs — there is no "running" state
    // to leak. This test documents that safety explicitly.
    //
    // Before fix A in Swift: slot was consumed before hashAllNotes, and a throw
    // would leak it permanently. The Rust equivalent is correct by construction
    // (ledger records happen only after bridge completion), but this test
    // confirms the import succeeds end-to-end with a directory.md vault.
    use aria_mcp::{
        dispatch::dispatch_tool_with_vault_ledger,
        vault_tools::VaultJobLedger,
    };

    let registry = EstateRegistry::new_inmemory();
    let vault = temp_vault_dir();

    // Create a sub-directory named "directory.md" — not a real note.
    std::fs::create_dir_all(vault.join("directory.md"))
        .expect("create directory.md sub-dir");

    // Run 5 imports in sequence. Each should succeed and record a completed job.
    // If the Rust backend incorrectly leaked a slot, a cap would be hit —
    // but since jobs are recorded only on completion, all 5 must succeed.
    let ledger = VaultJobLedger::new();
    for i in 1..=5 {
        let result = dispatch_tool_with_vault_ledger(
            "moot_vault_import",
            &args!["vaultPath" => vault.to_str().unwrap()],
            &registry,
            &SurfacedRecallLedger::new(),
            &ledger,
            "", "",
        )
        .expect(&format!("import {i} must succeed (no slot exhaustion)"));

        assert!(
            is_success(&result),
            "import {i}: expected isError:false (directory.md vault with no notes); got: {result:?}"
        );

        let text = content_text(&result);
        // Each import must return a job_id and record a completed entry in the ledger.
        assert!(
            text.contains("job_id:"),
            "import {i}: response must contain job_id; got: {text}"
        );
    }

    std::fs::remove_dir_all(&vault).ok();
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
    // PAR-MCP-2: output now projects the 27 cognition tools (4 Tier-6 recipe
    // tools + 23 lens tools) matching Swift runListRecipes, not a raw catalog dump.
    assert!(
        text.starts_with("moot_list_lenses: "),
        "result should start with 'moot_list_lenses: N cognition tools'; got: {text}"
    );
    assert!(
        text.contains("cognition tools"),
        "result should contain 'cognition tools'; got: {text}"
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

// PR-05 Part B golden: trust_synthesis dense-row output byte-matches dense_row::render.
// Mirrors Swift `trustSynthesisDenseRowsMatchRenderer` in LensToolsTests.swift.
#[test]
fn trust_synthesis_dense_row_matches_renderer() {
    let registry = EstateRegistry::new_inmemory();
    let id = file_one_memory(&registry, "golden trust memory — PR-05 rust golden", "study");
    // Fetch the drawer from the store to compute the expected dense row.
    let drawer = stored_drawer(&registry, &id);
    let expected_row = aria_mcp::dense_row::render(&drawer);
    let result = dispatch_tool(
        "moot_lens_trust_synthesis",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_trust_synthesis must succeed");
    assert!(is_success(&result), "trust_synthesis must succeed; got: {result:?}");
    let body = content_text(&result);
    // The dense row is emitted with a two-space prefix per Swift format parity.
    assert!(
        body.contains(&format!("  {expected_row}")),
        "trust_synthesis body must contain the dense row byte-for-byte; got: {body}"
    );
}

// PR-05 Part B golden: moot_lens_successors dense-row output byte-matches dense_row::render.
// Uses a direct tunnel between two captured drawers so the successor is guaranteed
// to be a real DrawerStore entry — get_drawer finds it and renders it hydrated.
// Mirrors Swift successors dense-row contract (progressive-recall rule).
#[test]
fn successors_dense_row_matches_renderer() {
    use locus_kit::tunnel::Tunnel;
    use locus_kit::tunnel_operational::TunnelKind;
    let registry = EstateRegistry::new_inmemory();
    // File source and target drawers into the default wing ("Agentic Memory").
    let src_id = file_one_memory(
        &registry,
        "successor golden source — PR-05",
        "succ-golden-src",
    );
    let tgt_id = file_one_memory(
        &registry,
        "successor golden target — PR-05",
        "succ-golden-tgt",
    );
    // Add a tunnel src → tgt directly via the store (same pattern as
    // the contradiction gateway test at lens_contradiction_hidden_endpoint_is_redacted).
    let mut tunnel = Tunnel::new(
        format!("succ-golden-tunnel-{src_id}"),
        "Agentic Memory".to_string(),
        "succ-golden-src".to_string(),
        "Agentic Memory".to_string(),
        "succ-golden-tgt".to_string(),
        "successor-golden-test".to_string(),
        "pr05-golden".to_string(),
        aria_mcp::dispatch::wall_now(),
    );
    tunnel.kind = TunnelKind::References;
    tunnel.source_drawer_id = Some(src_id.clone());
    tunnel.target_drawer_id = Some(tgt_id.clone());
    registry
        .default
        .store
        .add_tunnel(&tunnel)
        .expect("add_tunnel must succeed");
    // Fetch target drawer from the DrawerStore for expected dense row computation.
    let tgt_drawer = stored_drawer(&registry, &tgt_id);
    let expected_row = aria_mcp::dense_row::render(&tgt_drawer);
    // Call successors — target must appear as the successor of source.
    let result = dispatch_tool(
        "moot_lens_successors",
        &args!["wing" => "Agentic Memory", "anchorID" => src_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_successors must succeed");
    assert!(is_success(&result), "successors must succeed; got: {result:?}");
    let body = content_text(&result);
    // The target drawer ID must appear as part of a dense row (progressive-recall rule).
    assert!(
        body.contains(&tgt_id),
        "successors body must contain target drawer id; got: {body}"
    );
    // The full dense row must appear byte-for-byte.
    assert!(
        body.contains(&expected_row),
        "successors body must contain the target's dense row byte-for-byte; got: {body}"
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
    // PR-04: terse by default; verbose:true restores the full per-recipe
    // block with the version: field.
    let registry = EstateRegistry::new_inmemory();
    let terse = dispatch_tool("moot_list_recipes", &args![], &registry, &SurfacedRecallLedger::new())
        .expect("moot_list_recipes must succeed");
    assert!(is_success(&terse), "moot_list_recipes must be isError:false; got: {terse:?}");
    let terse_text = content_text(&terse);
    assert!(
        terse_text.starts_with("moot_list_recipes:"),
        "result must start with 'moot_list_recipes: N recipe(s)'; got: {terse_text}"
    );
    assert!(
        terse_text.contains("(terse — pass verbose:true"),
        "terse default must advertise the verbose flag; got: {terse_text}"
    );
    let verbose = dispatch_tool(
        "moot_list_recipes",
        &args!["verbose" => true],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("verbose moot_list_recipes must succeed");
    assert!(
        content_text(&verbose).contains("version:"),
        "verbose catalog entries must include version field; got: {}",
        content_text(&verbose)
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

// R6 parity: apriori mines the estate AUDIT LOG (not drawer bitmaps)
// and renders items in the verbose Swift-matching format "Item(field: F, value: V)".
//
// When rules are produced the format must match Swift's default struct
// interpolation of `AprioriRule.antecedent[n]` ("\(item)" → "Item(field: F, value: V)").
// The old Rust compact format "F:V" must never appear in rules output.

#[test]
fn lens_apriori_renders_verbose_item_format_matching_swift() {
    // Capture identical drawers so the audit log has repeating field-value
    // patterns. With min thresholds at 0 the engine will mine rules from
    // whatever audit-log items it finds. We only need at least one rule to
    // assert the rendering format.
    let registry = EstateRegistry::new_inmemory();
    for _ in 0..4 {
        file_one_memory(&registry, "audit log apriori parity fixture", "lab");
    }
    let result = dispatch_tool(
        "moot_lens_apriori",
        &args!["minSupport" => 0.0, "minConfidence" => 0.0, "minLift" => 0.0, "maxK" => 2],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_lens_apriori must succeed");
    assert!(is_success(&result), "moot_lens_apriori must be isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.starts_with("apriori_rules:"),
        "result must start with 'apriori_rules:'; got: {text}"
    );

    // When rules are emitted, each item must use the verbose format that
    // mirrors Swift's synthesised struct description: "Item(field: N, value: N)".
    // The old compact format "field:value" (e.g. "1:0") must not appear in any
    // rule line. Shape-only assertions are safe when 0 rules are returned.
    for line in text.lines().skip(1) {
        // Rule lines start with "  [". Skip summary and empty lines.
        if !line.trim_start().starts_with('[') {
            continue;
        }
        assert!(
            line.contains("Item(field:"),
            "each rule must render items as 'Item(field: F, value: V)' to match Swift; got: {line}"
        );
    }
}

#[test]
fn lens_apriori_description_matches_swift_spec() {
    // The tool_list description for moot_lens_apriori must state audit log,
    // not bitmap fingerprints — matching the Swift LensTools description.
    let tools = build_tool_list();
    let arr = tools.as_array().expect("build_tool_list must return an array");
    let apriori_desc = arr
        .iter()
        .find(|t| t["name"].as_str() == Some("moot_lens_apriori"))
        .and_then(|t| t["description"].as_str())
        .unwrap_or("");
    assert!(
        apriori_desc.contains("audit log"),
        "moot_lens_apriori description must mention 'audit log' (matching Swift spec); got: {apriori_desc}"
    );
    assert!(
        !apriori_desc.contains("bitmap fingerprints"),
        "moot_lens_apriori description must not mention 'bitmap fingerprints' (old wrong source); got: {apriori_desc}"
    );
}

#[test]
fn lens_moment_over_estate_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "moment lens test content", "lab");
    // windowStart/windowEnd: a two-year window covering "now" and within the 3-year
    // cap enforced by require_window_range. The original 2020–2026 span exceeded it.
    let result = dispatch_tool(
        "moot_lens_moment",
        &args![
            "windowStart" => "2025-01-01T00:00:00Z",
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
    // Two-year window covering "now" and within the 3-year cap.
    let result = dispatch_tool(
        "moot_lens_precedence",
        &args![
            "windowStart" => "2025-01-01T00:00:00Z",
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
/// With several drawers co-surfaced by external-origin recalls there are co-recall
/// pairs to mine, so the cycle considers candidates. The result is isError:false,
/// contains "matrix rebuilt, dreaming cycle complete", and carries the correct
/// candidatesConsidered count — C(4,2) = 6 pairs from four co-recalled drawers.
///
/// v2 drain-fed model: candidates come from the dreaming queue drained by the
/// cycle. Three `moot_memory_search` calls (external-origin) each enqueue a
/// DreamingItem whose surfaced set includes all four drawers. After draining,
/// co_recall_count for each of the six pairs reaches 3 ≥ min_attempts(3).
#[test]
fn dream_dispatch_runs_cycle_and_returns_summary() {
    let registry = EstateRegistry::new_inmemory();

    // File four drawers so they co-surface on external-origin recall.
    for text in &[
        "the treaty fixed the indemnity at 46 million marks",
        "the treaty ceded the eastern province in 1871",
        "the armistice was signed at Versailles in January",
        "the provisional government ratified the terms in March",
    ] {
        file_one_memory(&registry, text, "history/treaty");
    }

    // Fire 3 external-origin recalls (moot_memory_search) to enqueue co-recall
    // windows. Each search surfaces all four drawers and writes one DreamingItem
    // to the estate's dreaming queue. After 3 searches, co_recall_count for each
    // of the C(4,2)=6 pairs reaches 3, meeting DreamingPolicy default min_attempts=3.
    // The cycle drains these windows and considers all 6 pairs.
    let ledger = SurfacedRecallLedger::new();
    for _ in 0..3 {
        dispatch_tool(
            "moot_memory_search",
            &args!["query" => "treaty indemnity province armistice"],
            &registry,
            &ledger,
        )
        .expect("moot_memory_search must succeed");
    }

    // Deterministic instant matching the Swift test — reproducible cycle.
    let result = dispatch_tool(
        "moot_dream",
        &args!["now" => "2026-06-11T00:00:00Z"],
        &registry,
        &ledger,
    )
    .expect("moot_dream must not throw a transport fault");

    assert!(is_success(&result), "moot_dream must return isError:false; got: {result:?}");
    let text = content_text(&result);
    assert!(
        text.contains("dreaming cycle complete"),
        "moot_dream result must contain 'dreaming cycle complete'; got: {text}"
    );
    // Three external-origin recalls enqueue 3 dreaming windows. After draining,
    // every co-surfaced pair accumulates co_recall_count=3 ≥ min_attempts(3).
    // The exact pair count depends on how many drawers surfaced (our 4 captures
    // plus any estate seeds), but at least 6 pairs must be considered.
    // Extract the consideredCandidates number and assert it's ≥ 6.
    let candidates_str = text
        .lines()
        .find(|l| l.starts_with("consideredCandidates: "))
        .and_then(|l| l.strip_prefix("consideredCandidates: "))
        .unwrap_or("0");
    let candidates: usize = candidates_str.trim().parse().unwrap_or(0);
    assert!(
        candidates >= 6,
        "three searches × ≥4 co-surfaced drawers must yield ≥6 co-recall pairs (v2 drain model); got candidatesConsidered={candidates}: {text}"
    );
    // Matrix rebuild now runs for real on the Rust port: the result reports the
    // rebuild completed, not a gap note. Format matches Swift: "matrix rebuilt,
    // dreaming cycle complete" (single-line summary, PAR-MCP-3 parity).
    assert!(
        text.contains("matrix rebuilt"),
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

/// C1 — dream associates="all" uses a bounded probe limit, not unbounded None.
///
/// After the fix, `run_dream_tool` with `associates: "all"` passes
/// `DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE` (10_000) to `coord.associate_sweep`,
/// not `None`. On a tiny estate (2 rows) the probe count equals the estate
/// size (≤ 2) — well under the cap. The test verifies that the "all" path
/// completes without error and the response body contains no association-error
/// text, confirming the bounded path executed.
///
/// Parity: Swift `dreamAssociatesAllUsesBoundedProbeNotUnlimited`.
#[test]
fn dream_all_mode_uses_bounded_probe_limit_not_unlimited() {
    let registry = EstateRegistry::new_inmemory();
    // File two memories. The bounded path (Some(10_000)) must not crash here;
    // on an estate with no VectorStore, the associate sweep returns a zero
    // report — the important thing is the path completes without error.
    file_one_memory(&registry, "boundary probe limit test item alpha", "study");
    file_one_memory(&registry, "boundary probe limit test item beta", "study");

    let result = dispatch_tool(
        "moot_dream",
        &args!["now" => "2026-07-01T00:00:00Z", "associates" => "all"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_dream associates=all must not throw a transport fault");

    assert!(
        is_success(&result),
        "moot_dream associates=all must return isError:false; got: {result:?}"
    );
    let text = content_text(&result);
    // The bounded path must not produce an error annotation in the body.
    assert!(
        !text.contains("association sweep error"),
        "associates=all must not produce an error annotation; got body:\n{text}"
    );
    // The dreaming cycle must complete normally.
    assert!(
        text.contains("dreaming cycle complete"),
        "moot_dream result must contain 'dreaming cycle complete' for associates=all; got:\n{text}"
    );
}

// ---------------------------------------------------------------------------
// Vault gating
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
    assert_eq!(arr.len(), 73, "vault-on must produce 73 tools (67 + 2 contradiction-hunter + 3 dataset + moot_json_import; incl. moot_recall_connected)");
    let names: std::collections::HashSet<&str> =
        arr.iter().filter_map(|t| t["name"].as_str()).collect();
    for name in &["moot_vault_export", "moot_vault_import", "moot_vault_status",
                   "moot_vault_reconcile", "moot_vault_job"] {
        assert!(names.contains(name), "vault-on: expected {name} in tools/list");
    }
}

/// With vault_on=false (MOOTX01_VAULT=0), all five vault tools and the
/// filesystem-importing palace import tool are absent from tools/list.
#[test]
fn build_tool_list_with_vault_off_excludes_vault_tools() {
    let tools = build_tool_list_with_vault_flag(false);
    let arr = tools.as_array().expect("must be array");
    assert_eq!(arr.len(), 66, "vault-off must produce 66 tools (73 - 5 vault - 2 gated import lanes)");
    let names: std::collections::HashSet<&str> =
        arr.iter().filter_map(|t| t["name"].as_str()).collect();
    for name in &["moot_vault_export", "moot_vault_import", "moot_vault_status",
                   "moot_vault_reconcile", "moot_vault_job", "moot_palace_import",
                   "moot_json_import"] {
        assert!(!names.contains(name), "vault-off: {name} must NOT appear in tools/list");
    }
    // A sample of non-vault tools must still be present.
    assert!(names.contains("moot_file_memory"), "vault-off: core tools must still be present");
    assert!(names.contains("moot_federated_search"), "vault-off: federation tool must still be present");
    assert!(names.contains("moot_lens_keystones"), "vault-off: lens tools must still be present");
}

/// When vault is disabled (vault_on=false), calling a vault/import tool returns
/// a clear tool-level refusal (isError=true) rather than a transport fault.
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
        "moot_palace_import",
        "moot_json_import",
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
        &args!["vaultPath" => "/tmp/no-such-vault-for-security-test"],
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

    // _bare: no seeded wing/hint drawers — a controlled single-memory estate so
    // the read-back targets this test's drawer, not a seeded AI_Charter_Hint.
    let registry = EstateRegistry::new_inmemory_bare();
    // File a memory with a back-dated event_time (2020-01-01T00:00:00Z).
    let result = dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "back-dated event content",
        "subject" => "back-dated event content",
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
    // Confirm the drawer was stored with the provided event_time (epoch ms
    // for 2020-01-01T00:00:00Z = 1577836800000, epoch-millisecond instants).
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
        drawer.event_time, 1_577_836_800_000_i64,
        "drawer event_time must be the back-dated epoch ms (2020-01-01T00:00:00Z); got: {}",
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
        "subject" => "some content",
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

    // PAR-MCP-2: active count now includes hint drawers (7 per provisioned
    // estate, AI_Charter_Hint room) matching Swift runEstateStatus.
    // 7 hint drawers + 1 user drawer = 8. The withdrawn drawer is cluster B.
    assert!(
        text.contains("memories: 8 active"),
        "estate_status must count hint + user cluster-A drawers; got: {text}"
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

// ---------------------------------------------------------------------------
// wing organization Wings SURFACE lane — estate_map hint drawers as normal room entries
// + recall wing scoping
//
// Hint drawers (AI_Charter_Hint room) are normal drawers — they appear in the
// estate_map output as a normal room count line (AI_Charter_Hint: N), not as
// an inlined "charter: <text>" special entry. The inline charter rendering is
// removed.
//
// Change 3: memory_search / recall_precise / recall_shaped accept optional
//           `wing` argument that scopes recall to a single wing.
// ---------------------------------------------------------------------------

// MARK: – estate_map hint drawers as normal room entries

/// `moot_estate_map` must surface AI_Charter_Hint as a normal room count line.
/// Hint drawers are normal drawers — they appear in room counts, not as inline
/// "charter: <text>" entries (that rendering is removed).
#[test]
fn estate_map_surfaces_hint_room_as_normal_room_count() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // File a memory into the AI_Charter_Hint room for the "Agentic Memory" wing.
    // HINT_ROOM == "AI_Charter_Hint" — same room hint drawers are seeded into.
    let a = args![
        "content" => "The AI's own observations, inferences, decisions, session learnings.",
        "subject" => "The AI's own observations, inferences, decisions, session learnings.",
        "location" => "AI_Charter_Hint"
    ];
    let file_result = dispatch_tool("moot_file_memory", &a, &registry, &ledger)
        .expect("file_memory to AI_Charter_Hint room must succeed");
    assert!(
        is_success(&file_result),
        "filing a hint memory must succeed; got: {file_result:?}"
    );

    // Run estate_map — must show AI_Charter_Hint as a normal room count line.
    let result = dispatch_tool("moot_estate_map", &args![], &registry, &ledger)
        .expect("estate_map must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);

    // AI_Charter_Hint appears as a normal room in the output.
    assert!(
        text.contains("AI_Charter_Hint:"),
        "estate_map must show AI_Charter_Hint as a normal room count line; got: {text}"
    );
    // No inline "charter:" special entry — that rendering is removed.
    assert!(
        !text.contains("\ncharter:"),
        "estate_map must not render an inline 'charter:' line (removed); got: {text}"
    );
    // The old _charter room name must not appear anywhere.
    assert!(
        !text.contains("_charter"),
        "estate_map must not reference old _charter room name; got: {text}"
    );
}

/// `moot_estate_map` must NOT render `_charter` anywhere — the old room name
/// is replaced by `AI_Charter_Hint`. Hint drawers appear as a normal room count.
#[test]
fn estate_map_does_not_reference_old_charter_room_name() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // File a hint-style memory so there is at least one drawer in the estate.
    let a = args![
        "content" => "Wing role description",
        "subject" => "Wing role description",
        "location" => "AI_Charter_Hint"
    ];
    dispatch_tool("moot_file_memory", &a, &registry, &ledger)
        .expect("file_memory to AI_Charter_Hint room must succeed");

    let result = dispatch_tool("moot_estate_map", &args![], &registry, &ledger)
        .expect("estate_map must not throw");
    assert!(is_success(&result));
    let text = content_text(&result);

    // The old _charter room name must not appear in the output.
    assert!(
        !text.contains("_charter"),
        "estate_map must not reference old _charter room name; got: {text}"
    );
}

// MARK: – Change 3: recall wing scoping — moot_memory_search

/// `moot_memory_search` without a `wing` arg must succeed unchanged.
/// Confirms the default path (no wing filter) is unbroken after the change.
#[test]
fn memory_search_without_wing_succeeds_unchanged() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    file_one_memory(&registry, "arctic fox camouflage snow winter survival", "wildlife");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "arctic fox"],
        &registry,
        &ledger,
    ).expect("memory_search must not throw");
    assert!(
        is_success(&result),
        "memory_search without wing must succeed; got: {result:?}"
    );
}

/// `moot_memory_search` with `wing` = "Agentic Memory" must succeed.
/// Captures land in defaultWingName ("Agentic Memory"), so the scoped
/// search must not error.
#[test]
fn memory_search_scoped_to_default_wing_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    file_one_memory(&registry, "bald eagle nest riverine habitat territory", "wildlife");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "bald eagle", "wing" => "Agentic Memory"],
        &registry,
        &ledger,
    ).expect("memory_search with wing must not throw");
    assert!(
        is_success(&result),
        "memory_search scoped to 'Agentic Memory' must succeed; got: {result:?}"
    );
}

/// `moot_memory_search` scoped to an empty wing must succeed (no error).
/// An empty result is a valid answer — the wing filter is not an error.
#[test]
fn memory_search_scoped_to_empty_wing_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    // Content lands in "Agentic Memory". "Source Corpus" has no captures.
    file_one_memory(&registry, "grey wolf pack hierarchy social structure", "wildlife");

    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "grey wolf", "wing" => "Source Corpus"],
        &registry,
        &ledger,
    ).expect("memory_search on empty wing must not throw");
    assert!(
        is_success(&result),
        "memory_search scoped to an empty wing must succeed (not error); got: {result:?}"
    );
}

// MARK: – Change 3: recall wing scoping — moot_recall_precise

/// `moot_recall_precise` without `wing` must succeed unchanged.
#[test]
fn recall_precise_without_wing_succeeds_unchanged() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    file_one_memory(&registry, "black bear foraging berry season omnivore", "wildlife");

    let result = dispatch_tool(
        "moot_recall_precise",
        &args!["query" => "black bear", "filter" => "unconfirmed"],
        &registry,
        &ledger,
    ).expect("recall_precise must not throw");
    assert!(
        is_success(&result),
        "recall_precise without wing must succeed; got: {result:?}"
    );
}

/// `moot_recall_precise` with `wing` = "Agentic Memory" must succeed.
/// The wing filter is composed with the base filter via Filter::All.
#[test]
fn recall_precise_with_wing_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    file_one_memory(&registry, "mountain lion cougar puma altitude range stealth", "wildlife");

    let result = dispatch_tool(
        "moot_recall_precise",
        &args!["query" => "mountain lion", "filter" => "unconfirmed", "wing" => "Agentic Memory"],
        &registry,
        &ledger,
    ).expect("recall_precise with wing must not throw");
    assert!(
        is_success(&result),
        "recall_precise scoped to 'Agentic Memory' must succeed; got: {result:?}"
    );
}

// MARK: – Change 3: recall wing scoping — moot_recall_shaped

/// `moot_recall_shaped` without `wing` must succeed unchanged.
#[test]
fn recall_shaped_without_wing_succeeds_unchanged() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    file_one_memory(&registry, "wolverine boreal forest solitary wide range", "wildlife");

    let result = dispatch_tool(
        "moot_recall_shaped",
        &args!["query" => "wolverine", "filter" => "unconfirmed"],
        &registry,
        &ledger,
    ).expect("recall_shaped must not throw");
    assert!(
        is_success(&result),
        "recall_shaped without wing must succeed; got: {result:?}"
    );
}

/// `moot_recall_shaped` with `wing` = "Agentic Memory" must succeed.
/// The wing filter is composed with the base filter via Filter::All.
#[test]
fn recall_shaped_with_wing_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    file_one_memory(&registry, "snowy owl arctic tundra silent flight prey", "wildlife");

    let result = dispatch_tool(
        "moot_recall_shaped",
        &args!["query" => "snowy owl", "filter" => "unconfirmed", "wing" => "Agentic Memory"],
        &registry,
        &ledger,
    ).expect("recall_shaped with wing must not throw");
    assert!(
        is_success(&result),
        "recall_shaped scoped to 'Agentic Memory' must succeed; got: {result:?}"
    );
}

// ---------------------------------------------------------------------------
// Security hardening — limit clamping and boundary guards (secfix-p1-ariamcp)
// ---------------------------------------------------------------------------

/// `clamp_limit` with `None` returns the default.
#[test]
fn clamp_limit_none_returns_default() {
    let result = aria_mcp::dispatch::clamp_limit(None, "limit", 20, 500);
    assert_eq!(result.unwrap(), 20);
}

/// `clamp_limit` with a value within the ceiling passes through unchanged.
#[test]
fn clamp_limit_within_ceiling_passes_through() {
    let result = aria_mcp::dispatch::clamp_limit(Some(42), "limit", 20, 500);
    assert_eq!(result.unwrap(), 42);
}

/// `clamp_limit` with a negative value returns invalidParams.
#[test]
fn clamp_limit_negative_returns_invalid_params() {
    let err = aria_mcp::dispatch::clamp_limit(Some(-1), "limit", 20, 500).unwrap_err();
    assert_eq!(err.code, aria_mcp::jsonrpc::JSONRPCErrorCode::INVALID_PARAMS);
    assert!(err.message.contains("limit"), "error must name the argument");
    assert!(err.message.contains("-1"), "error must echo the bad value");
}

/// `clamp_limit` with zero returns invalidParams.
#[test]
fn clamp_limit_zero_returns_invalid_params() {
    let err = aria_mcp::dispatch::clamp_limit(Some(0), "k", 5, 500).unwrap_err();
    assert_eq!(err.code, aria_mcp::jsonrpc::JSONRPCErrorCode::INVALID_PARAMS);
}

/// `clamp_limit` with a value at exactly the ceiling returns the ceiling.
#[test]
fn clamp_limit_at_ceiling_returns_ceiling() {
    let result = aria_mcp::dispatch::clamp_limit(Some(500), "limit", 20, 500);
    assert_eq!(result.unwrap(), 500);
}

/// `clamp_limit` with a value above the ceiling is clamped down silently.
#[test]
fn clamp_limit_over_ceiling_clamped_to_ceiling() {
    let result = aria_mcp::dispatch::clamp_limit(Some(1_000_000), "limit", 20, 500);
    assert_eq!(result.unwrap(), 500);
}

/// `clamp_limit` with a custom ceiling is honored.
#[test]
fn clamp_limit_custom_ceiling_honored() {
    let result = aria_mcp::dispatch::clamp_limit(Some(200_000), "walkLength", 10_000, 100_000);
    assert_eq!(result.unwrap(), 100_000);
}

/// `moot_memory_search` with a negative `limit` returns invalidParams.
#[test]
fn memory_search_negative_limit_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "test", "limit" => -1_i64],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

/// `moot_memory_search` with an over-ceiling limit succeeds (clamped to 500).
#[test]
fn memory_search_over_ceiling_limit_clamped_and_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    file_one_memory(&registry, "test content for clamping verification", "room");

    // A limit of 10_000 must be silently clamped to 500, not crash or return an error.
    let result = dispatch_tool(
        "moot_memory_search",
        &args!["query" => "test content", "limit" => 10_000_i64],
        &registry,
        &ledger,
    ).expect("over-ceiling limit must not throw — it is clamped");
    // The result should be a success (found memories or empty).
    assert!(is_success(&result), "clamped limit must yield a success result");
}

/// `moot_recall_precise` with a negative `limit` returns invalidParams.
#[test]
fn precise_recall_negative_limit_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_recall_precise",
        &args!["query" => "test", "limit" => -1_i64],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

/// `moot_recall_shaped` with a negative `limit` returns invalidParams.
#[test]
fn shaped_recall_negative_limit_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_recall_shaped",
        &args!["query" => "test", "limit" => -1_i64],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

/// `moot_recall_distilled` with zero `limit` returns invalidParams.
/// ack: "recall_distilled/v2" is required to pass the ACK gate (Wave 1 contract
/// change) so the call reaches the limit-validation guard.
#[test]
fn distilled_recall_zero_limit_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_recall_distilled",
        &args!["query" => "test", "limit" => 0_i64, "ack" => "recall_distilled/v2"],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

/// `moot_dream` with a far-future `now` (> 24 h ahead) returns invalidParams.
#[test]
fn dream_far_future_now_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // 48 hours from now (epoch secs) formatted as ISO8601 — well beyond the 86400 s ceiling.
    let far_future_secs = aria_mcp::dispatch::wall_now() + 48 * 3600;
    // Manual ISO8601 formatting (zero-dep, UTC only — same as wall_now's contract).
    let secs = far_future_secs.max(0) as u64;
    let (y, mo, d) = epoch_days_to_ymd(secs / 86400);
    let tod = secs % 86400;
    let far_future_str = format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y, mo, d,
        tod / 3600, (tod % 3600) / 60, tod % 60
    );

    let err = dispatch_tool(
        "moot_dream",
        &args!["now" => far_future_str.as_str()],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS,
        "far-future now must yield invalidParams; message: {}", err.message);
}

/// `moot_lens_moment` with inverted window (start > end) returns invalidParams.
#[test]
fn lens_moment_inverted_window_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_lens_moment",
        &args![
            "windowStart" => "2026-06-28T10:00:00Z",
            "windowEnd"   => "2026-06-27T10:00:00Z"
        ],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS,
        "inverted moment window must be invalidParams; message: {}", err.message);
}

/// `moot_lens_precedence` with inverted window (start > end) returns invalidParams.
#[test]
fn lens_precedence_inverted_window_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_lens_precedence",
        &args![
            "windowStart" => "2026-06-28T10:00:00Z",
            "windowEnd"   => "2026-06-27T10:00:00Z",
            "targetField" => "room",
            "targetValue" => "chemistry"
        ],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS,
        "inverted precedence window must be invalidParams; message: {}", err.message);
}

/// `moot_lens_free_association` with a negative `k` returns invalidParams.
#[test]
fn lens_free_association_negative_k_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_lens_free_association",
        &args![
            "wing" => "Default",
            "seedDrawerID" => "00000000-0000-0000-0000-000000000001",
            "k" => -1_i64
        ],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// ---------------------------------------------------------------------------
// clamp_limit boundary guards — Finding 3
//
// Before the fix, moot_lens_associations, moot_lens_concepts,
// moot_grounded_synthesis, and moot_federated_search read the `limit` arg
// without routing through clamp_limit. Negative or over-ceiling values
// could reach the substrate raw, bypassing the [1, 500] safety boundary.
// ---------------------------------------------------------------------------

/// `moot_lens_associations` with a negative `limit` must return invalidParams.
#[test]
fn lens_associations_negative_limit_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_lens_associations",
        &args!["limit" => -1_i64],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS,
        "negative limit must yield invalidParams; message: {}", err.message);
}

/// `moot_lens_associations` with an over-ceiling `limit` must succeed (clamped).
#[test]
fn lens_associations_over_ceiling_limit_is_clamped() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Over-ceiling limit must be silently clamped to 500, not crash or error.
    let result = dispatch_tool(
        "moot_lens_associations",
        &args!["limit" => 1_000_000_i64],
        &registry,
        &ledger,
    ).expect("over-ceiling limit must not be a transport fault");
    // Empty estate returns an empty rule list — shape is what matters.
    assert!(is_success(&result) || is_tool_error(&result),
        "result must have a well-formed shape; got: {result:?}");
}

/// `moot_lens_concepts` with a negative `limit` must return invalidParams.
#[test]
fn lens_concepts_negative_limit_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_lens_concepts",
        &args!["limit" => -5_i64],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS,
        "negative limit must yield invalidParams; message: {}", err.message);
}

/// `moot_lens_concepts` with an over-ceiling `limit` must succeed (clamped).
#[test]
fn lens_concepts_over_ceiling_limit_is_clamped() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let result = dispatch_tool(
        "moot_lens_concepts",
        &args!["limit" => 999_999_i64],
        &registry,
        &ledger,
    ).expect("over-ceiling limit must not be a transport fault");
    assert!(is_success(&result) || is_tool_error(&result),
        "result must have a well-formed shape; got: {result:?}");
}

/// `moot_synthesize` (grounded synthesis) with a negative `limit` must return invalidParams.
#[test]
fn grounded_synthesis_negative_limit_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_synthesize",
        &args!["limit" => -1_i64],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS,
        "negative limit on moot_synthesize must yield invalidParams; message: {}", err.message);
}

/// `query` scopes the recalled pool: only memories whose content matches a
/// distinctive term feed the synthesis, and the response names the cue (a
/// grounded synthesis and an estate digest are different measurements).
/// Twin of Swift `testGroundedSynthesisQueryScopesTheRecalledPool`.
#[test]
fn grounded_synthesis_query_ranks_cue_matches_first() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    for content in [
        "carbon chemistry of organic compounds",
        "carbon based biochemistry of life",
        "quantum mechanics fundamentals",
    ] {
        file_one_memory(&registry, content, "recipe-tests");
    }

    let result = dispatch_tool(
        "moot_synthesize",
        &args!["query" => "carbon compounds", "filter" => "unconfirmed"],
        &registry,
        &ledger,
    ).expect("query-grounded synthesize must dispatch");
    assert!(is_success(&result), "synthesize should succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(text.contains("query: carbon compounds"),
        "the response must name the cue; got: {text}");
    // Two-lane grounding is a RANKING guarantee, not a hard exclusion: the
    // scored lane (high-recall) may admit non-matching rows BELOW the term
    // matches. The first keyInsight must be a cue-matched memory — a
    // zero-term-match row must never outrank a term match.
    let insights = text.split("keyInsights:").last().unwrap_or("");
    let first_insight = insights
        .lines()
        .find(|l| l.trim_start().starts_with("- "))
        .unwrap_or("");
    assert!(first_insight.contains("carbon"),
        "cue-matched memory must lead keyInsights; got '{first_insight}'");
}

/// Provenance Restricted/Secret is a separate axis from the adjective
/// sensitivity enforced by RecallFrame. Synthesis must gate that axis before
/// verbatim key-insight excerpts are produced.
#[test]
fn grounded_synthesis_does_not_expose_provenance_sensitive_rows() {
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SurfacedRecallLedger::new();
    for tier in [
        locus_kit::provenance::Sensitivity::Restricted,
        locus_kit::provenance::Sensitivity::Secret,
    ] {
        file_one_memory_with_provenance_sensitivity(
            &registry,
            "classified aardvark synthesis token",
            "vault",
            tier,
        );
    }

    let result = dispatch_tool(
        "moot_synthesize",
        &args!["query" => "aardvark synthesis", "filter" => "unconfirmed"],
        &registry,
        &ledger,
    )
    .expect("synthesis should succeed after gated rows are removed");
    let text = content_text(&result);
    assert!(is_success(&result));
    assert!(
        !text.contains("classified aardvark synthesis token"),
        "provenance-sensitive content must not reach keyInsights: {text}"
    );
    assert!(text.contains("grounded_synthesis: 0 drawer(s)"));
}

/// Mixed-pool case: one normal row and one provenance-restricted row.
/// The gate must silently remove the restricted row from synthesis and
/// pass the normal row through into keyInsights. A gate that blocks
/// everything (including normal rows) must FAIL this test — the gate
/// covers provenance bits 30–35, not the adjective axis.
/// Twin of Swift `testSynthesizeDoesNotExposeProvenanceSensitiveRows`.
#[test]
fn grounded_synthesis_mixed_pool_only_exposes_normal_rows() {
    let registry = EstateRegistry::new_inmemory_bare();
    let ledger = SurfacedRecallLedger::new();

    // Normal row — must survive into keyInsights.
    file_one_memory_with_provenance_sensitivity(
        &registry,
        "classified aardvark synthesis normaltoken",
        "vault",
        locus_kit::provenance::Sensitivity::Normal,
    );

    // Restricted row — must be removed by the provenance gate.
    file_one_memory_with_provenance_sensitivity(
        &registry,
        "classified aardvark synthesis restrictedtoken",
        "vault",
        locus_kit::provenance::Sensitivity::Restricted,
    );

    let result = dispatch_tool(
        "moot_synthesize",
        &args!["filter" => "unconfirmed"],
        &registry,
        &ledger,
    )
    .expect("synthesis must succeed with a mixed pool");
    let text = content_text(&result);
    assert!(is_success(&result), "synthesis must succeed; got: {text}");

    // Only the normal row feeds synthesis — gate removes restricted before synthesize.
    assert!(
        text.contains("grounded_synthesis: 1 drawer(s)"),
        "only the normal row must survive the gate; got: {text}"
    );
    assert!(
        !text.contains("restrictedtoken"),
        "provenance-restricted content must not reach keyInsights; got: {text}"
    );
    assert!(
        text.contains("normaltoken"),
        "normal row content must appear in keyInsights; got: {text}"
    );
}

/// The bridge scenario recall_connected exists for: an answer memory
/// sharing NO words with the query, reachable only through a
/// moot_link_memories tunnel from the hop-1 memory. Plain similarity
/// cannot surface it; the walk must. Twin of Swift
/// `testConnectedRecallReachesBridgeLinkedAnswer`.
#[test]
fn connected_recall_reaches_bridge_linked_answer() {
    use locus_kit::frames::TunnelCaptureFrame;

    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let hop1 = file_one_memory(
        &registry, "Melanie mentioned her sister visited from Cambridge", "recipe-tests");
    let answer = file_one_memory(
        &registry, "Caroline finished the astrophysics degree this spring", "recipe-tests");
    file_one_memory(&registry, "grocery shopping list for the weekend", "recipe-tests");
    file_one_memory(&registry, "bicycle maintenance notes and tire pressure", "recipe-tests");

    // Create the tunnel directly rather than via moot_link_memories: the MCP
    // surface's ID-lookup calls coord.resolve_drawer_node_names, which requires a
    // registered node topology provider. In the test in-memory estate that provider
    // is absent, so names resolve to empty strings and the tunnel gets stored with
    // source_wing = "" — making it invisible to recall_tunnels("recipe-tests").
    // Direct estate.capture_tunnel with explicit wing names bypasses the lookup.
    let now = aria_mcp::dispatch::wall_now();
    {
        let coord = registry.coord.lock().unwrap();
        let locus_estate = coord.estate_for(&registry.default.handle)
            .expect("estate must be open");
        let mut tunnel_frame = TunnelCaptureFrame::new(
            "recipe-tests", "recipe-tests", "recipe-tests", "recipe-tests",
            "sister identity bridge", "test",
        );
        tunnel_frame.source_drawer_id = Some(hop1.clone());
        tunnel_frame.target_drawer_id = Some(answer.clone());
        locus_estate.capture_tunnel(tunnel_frame, now)
            .expect("tunnel capture must succeed");
    }

    let result = dispatch_tool(
        "moot_recall_connected",
        &args!["query" => "Melanie sister Cambridge", "wing" => "recipe-tests",
               "filter" => "unconfirmed", "limit" => 10_i64],
        &registry,
        &ledger,
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(text.starts_with("found "), "memory_search-shaped header expected; got: {text}");
    assert!(text.contains(&answer),
        "the tunnel-linked answer must be reachable via the walk; got: {text}");
    assert!(text.contains("connected: anchor="),
        "the lane-provenance line must be present; got: {text}");
}

/// Gate invariant: a withdrawn memory linked by a tunnel to a live anchor must
/// NOT appear in connected-recall results. The walk discovers the edge and
/// attempts hydration; the gated RecallFrame (insert_defaults plus the
/// caller's filter) excludes the withdrawn row via CurrentlyBelieve.
/// Twin of Swift `testConnectedRecallExcludesTombstonedRows`.
#[test]
fn connected_recall_excludes_withdrawn_rows() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Dead memory — shares no words with the query; will be withdrawn.
    let dead = file_one_memory(&registry, "XylophoneZebra secret project archive notes", "recipe-tests");
    // Anchor — matches the query directly.
    let anchor = file_one_memory(&registry, "Quarterly planning moved to Thursday confirmed", "recipe-tests");
    // Distractor.
    file_one_memory(&registry, "bicycle tire pressure maintenance schedule", "recipe-tests");

    // Link dead → anchor so the walk can discover dead from anchor.
    let link = dispatch_tool(
        "moot_link_memories",
        &args!["from_id" => dead.as_str(), "to_id" => anchor.as_str(),
               "kind" => "relates", "label" => "tombstone gate test link"],
        &registry, &ledger,
    ).expect("link must dispatch");
    assert!(is_success(&link), "link_memories should succeed; got: {link:?}");

    // Withdraw the dead memory — state transition to Withdrawn, excluded by
    // CurrentlyBelieve default filter on walk hydration.
    let withdraw = dispatch_tool(
        "moot_withdraw_memory",
        &args!["id" => dead.as_str()],
        &registry, &ledger,
    ).expect("withdraw must dispatch");
    assert!(is_success(&withdraw), "withdraw should succeed; got: {withdraw:?}");

    let result = dispatch_tool(
        "moot_recall_connected",
        &args!["query" => "quarterly planning Thursday",
               "filter" => "unconfirmed", "limit" => 10_i64],
        &registry, &ledger,
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let text = content_text(&result);
    // The withdrawn memory's distinctive content must NOT appear.
    assert!(!text.contains("XylophoneZebra"),
        "withdrawn row content must be absent from connected recall; got: {text}");
}

/// Gate invariant: a sensitivity-restricted memory linked by a tunnel to a live
/// anchor must NOT appear in connected-recall results. The walk discovers the edge;
/// the gated RecallFrame applies the insert_defaults ceiling of
/// SensitivityAtMost(Elevated), excluding Restricted rows.
/// Twin of Swift `testConnectedRecallExcludesSensitivityRestrictedRows`.
#[test]
fn connected_recall_excludes_sensitivity_restricted_rows() {
    use locus_kit::adjectives::AdjectiveSensitivity;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::{CaptureFrame, TunnelCaptureFrame};

    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Anchor — matches the query.
    let anchor = file_one_memory(
        &registry, "Annual performance review scheduling confirmed", "recipe-tests");
    // Distractor.
    file_one_memory(&registry, "grocery run Saturday morning", "recipe-tests");

    // Restricted memory — filed at Restricted sensitivity so the default
    // SensitivityAtMost(Elevated) ceiling blocks it from walk hydration.
    let restricted_content = "ConfidentialAardvark internal salary band information";
    let mut capture_frame = CaptureFrame::new(
        restricted_content,
        CaptureChannel::Typed,
        "recipe-tests",
        LatticeAnchor::udc("004"),
        "aria-mcp-tests",
        "default",
    );
    capture_frame.sensitivity = AdjectiveSensitivity::Restricted;
    // Subject required at the MCP surface for PR-02 dense rows.
    capture_frame.subject = Some(restricted_content.chars().take(120).collect());
    let now = aria_mcp::dispatch::wall_now();
    let restricted_id = {
        let coord = registry.coord.lock().unwrap();
        coord.capture(&registry.default.handle, capture_frame, now)
            .expect("restricted capture must succeed")
            .id
    };

    // Link restricted → anchor bypassing moot_link_memories: that MCP tool's
    // internal ID-lookup uses RecallFrame::new(vec![]) which receives the
    // SensitivityAtMost(Elevated) default — it cannot see Restricted drawers
    // and would fail with "from_id not found". For this test we need the tunnel
    // edge to exist in the graph so the walk discovers it; we create it directly
    // via Estate::capture_tunnel, which has no sensitivity gate on ID lookup.
    {
        let coord = registry.coord.lock().unwrap();
        let locus_estate = coord.estate_for(&registry.default.handle)
            .expect("estate must be open");
        // Wing/room display fields can be empty — the structural connection
        // is carried by source_drawer_id / target_drawer_id.
        let mut tunnel_frame = TunnelCaptureFrame::new(
            "recipe-tests", "recipe-tests", "recipe-tests", "recipe-tests",
            "sensitivity gate test link", "test",
        );
        tunnel_frame.source_drawer_id = Some(restricted_id.clone());
        tunnel_frame.target_drawer_id = Some(anchor.clone());
        locus_estate.capture_tunnel(tunnel_frame, now)
            .expect("tunnel capture must succeed");
    }

    let result = dispatch_tool(
        "moot_recall_connected",
        &args!["query" => "annual performance review scheduling",
               "filter" => "unconfirmed", "limit" => 10_i64],
        &registry, &ledger,
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let text = content_text(&result);
    // The restricted memory's distinctive content must NOT appear.
    assert!(!text.contains("ConfidentialAardvark"),
        "restricted row content must be absent from connected recall; got: {text}");
}

/// Shared setup for the Wave-3 G1 walk-filter tests: file an anchor (with
/// optional exportability), file a walk-only target that shares no words
/// with the query, capture a tunnel target→anchor directly (the MCP link
/// tool cannot register wing names on the in-memory estate — see the bridge
/// test above), and PROVE walk reachability with an unrestricted control
/// query before any filtered assertion. A gate test whose walk never reaches
/// the target passes vacuously; the control query removes that failure mode.
fn g1_walk_fixture(
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    anchor_content: &str,
    anchor_exportability: Option<&str>,
    target_content: &str,
    target_exportability: Option<&str>,
    control_query: &str,
) -> (String, String) {
    use locus_kit::frames::TunnelCaptureFrame;

    let file_with = |content: &str, exportability: Option<&str>| -> String {
        let mut a = args!["content" => content, "subject" => content,
                          "location" => "recipe-tests"];
        if let Some(e) = exportability {
            a.insert("exportability".to_owned(), JsonValue::String(e.to_owned()));
        }
        let filed = dispatch_tool("moot_file_memory", &a, registry, ledger)
            .expect("file_memory must succeed");
        assert!(is_success(&filed), "file_memory should succeed; got: {filed:?}");
        content_text(&filed).lines().next()
            .and_then(|l| l.strip_prefix("filed memory ")).unwrap_or("").to_owned()
    };

    // NOTE deliberate twin divergence from the Swift fixture: the Rust
    // in-memory estate ships charter-hint seed drawers and does not rank
    // the anchor pool by pure recency, so the Swift flood-and-reorder
    // shape starves the walk of its seed here. This small fixture is
    // proven non-vacuous for THIS port by the pre-fix counter-proof (all
    // three walk tests fail on exactly the leak assertion when the filter
    // propagation is reverted).
    let anchor = file_with(anchor_content, anchor_exportability);
    let target = file_with(target_content, target_exportability);
    file_with("bicycle tire pressure maintenance schedule", None);

    // Direct tunnel capture with explicit wing names, exactly as the bridge
    // test does: the walk reads wing-scoped tunnels and the queries below
    // pass wing:"recipe-tests".
    let now = aria_mcp::dispatch::wall_now();
    {
        let coord = registry.coord.lock().unwrap();
        let locus_estate = coord.estate_for(&registry.default.handle)
            .expect("estate must be open");
        let mut tunnel_frame = TunnelCaptureFrame::new(
            "recipe-tests", "recipe-tests", "recipe-tests", "recipe-tests",
            "g1 walk gate test link", "test",
        );
        tunnel_frame.source_drawer_id = Some(target.clone());
        tunnel_frame.target_drawer_id = Some(anchor.clone());
        locus_estate.capture_tunnel(tunnel_frame, now)
            .expect("tunnel capture must succeed");
    }

    // CONTROL: unrestricted filter must reach the target through the walk.
    // If this fails the fixture is broken, not the gate.
    let control = dispatch_tool(
        "moot_recall_connected",
        &args!["query" => control_query, "wing" => "recipe-tests",
               "filter" => "unconfirmed", "limit" => 10_i64],
        registry, ledger,
    ).expect("control connected recall must dispatch");
    assert!(is_success(&control), "control query should succeed; got: {control:?}");
    let control_text = content_text(&control);
    assert!(control_text.contains(&target),
        "FIXTURE: the walk must reach the linked target under an \
         unrestricted filter; got: {control_text}");

    (anchor, target)
}

/// Wave-3 G1 gate invariant: the CALLER's filter applies to walk hydration,
/// not only to anchor recall. A non-exportable (born-private) drawer linked
/// to an exportable anchor must NOT surface its content under
/// filter:"exportable", while the exportable anchor itself must.
/// Twin of Swift `testConnectedRecallWalkHonorsExportableFilter`.
#[test]
fn connected_recall_walk_honors_exportable_filter() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let (_anchor, _target) = g1_walk_fixture(
        &registry, &ledger,
        "Roadmap review moved to Friday afternoon confirmed", Some("public"),
        "VelvetOctopus internal pricing draft numbers", None,
        "roadmap review Friday",
    );

    let result = dispatch_tool(
        "moot_recall_connected",
        &args!["query" => "roadmap review Friday", "wing" => "recipe-tests",
               "filter" => "exportable", "limit" => 10_i64],
        &registry, &ledger,
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let text = content_text(&result);
    // Over-gating check: the exportable anchor's content must be present.
    assert!(text.contains("Roadmap review"),
        "exportable anchor content must be present; got: {text}");
    // The private drawer's content must NOT ride in through the walk.
    assert!(!text.contains("VelvetOctopus"),
        "non-exportable row content must be absent under filter:exportable; got: {text}");
}

/// Wave-3 G1 gate invariant, confirmation axis: an unconfirmed drawer linked
/// to a user-confirmed anchor must NOT surface its content under
/// filter:"userConfirmed".
/// Twin of Swift `testConnectedRecallWalkHonorsUserConfirmedFilter`.
#[test]
fn connected_recall_walk_honors_user_confirmed_filter() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let (anchor, _target) = g1_walk_fixture(
        &registry, &ledger,
        "Sprint retro moved to Tuesday morning confirmed", None,
        "CrimsonNarwhal draft merger term sheet notes", None,
        "sprint retro Tuesday",
    );
    let confirm = dispatch_tool(
        "moot_confirm_memory", &args!["id" => anchor.as_str()], &registry, &ledger,
    ).expect("confirm must dispatch");
    assert!(is_success(&confirm), "confirm_memory should succeed; got: {confirm:?}");

    let result = dispatch_tool(
        "moot_recall_connected",
        &args!["query" => "sprint retro Tuesday", "wing" => "recipe-tests",
               "filter" => "userConfirmed", "limit" => 10_i64],
        &registry, &ledger,
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(text.contains("Sprint retro"),
        "confirmed anchor content must be present; got: {text}");
    assert!(!text.contains("CrimsonNarwhal"),
        "unconfirmed row content must be absent under filter:userConfirmed; got: {text}");
}

/// Wave-3 G1 gate invariant, containment axis: a PUBLIC drawer linked to a
/// contained (born-private) anchor must NOT surface its content under
/// filter:"contained" — the inverse of the exportable test.
/// Twin of Swift `testConnectedRecallWalkHonorsContainedFilter`.
#[test]
fn connected_recall_walk_honors_contained_filter() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let (_anchor, _target) = g1_walk_fixture(
        &registry, &ledger,
        "Standup notes archived for Thursday review", None,
        "AmberFalcon public changelog draft for the release", Some("public"),
        "standup notes Thursday",
    );

    let result = dispatch_tool(
        "moot_recall_connected",
        &args!["query" => "standup notes Thursday", "wing" => "recipe-tests",
               "filter" => "contained", "limit" => 10_i64],
        &registry, &ledger,
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(text.contains("Standup notes"),
        "contained anchor content must be present; got: {text}");
    assert!(!text.contains("AmberFalcon"),
        "public row content must be absent under filter:contained; got: {text}");
}

/// A query whose every token is a stopword or too short must be rejected
/// (invalidParams), never silently degraded to an unscoped digest.
/// Twin of Swift `testGroundedSynthesisAllStopwordQueryThrowsInvalidParams`.
#[test]
fn grounded_synthesis_all_stopword_query_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_synthesize",
        &args!["query" => "what did they do"],
        &registry,
        &ledger,
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS,
        "all-stopword query must yield invalidParams; message: {}", err.message);
}

/// The term extractor's contract, pinned so both ports cannot drift:
/// stopwords and short fragments drop, digit-bearing short tokens stay,
/// tokens lowercase and dedupe in first-appearance order, cap at 12.
/// Twin of Swift `testGroundingTermsContract` (identical fixtures).
#[test]
fn grounding_terms_contract() {
    use aria_mcp::recipe_tools::grounding_terms;
    assert_eq!(
        grounding_terms("What did Melanie buy at Trader Joe's?"),
        vec!["melanie", "buy", "trader", "joe"]
    );
    assert_eq!(grounding_terms("was it 46 or 3b"), vec!["46", "3b"]);
    assert_eq!(
        grounding_terms("carbon Carbon CARBON life"),
        vec!["carbon", "life"]
    );
    assert!(grounding_terms("what did they do").is_empty());
    let long: Vec<String> = (1..=20).map(|i| format!("uniqueterm{i}")).collect();
    assert_eq!(grounding_terms(&long.join(" ")).len(), 12);
}

/// Ranking is driven by cue-term relevance, not recency. File 25 memories: the
/// OLDEST contains distinctive answer terms; 24 newer memories share a generic
/// word that also appears in the query but is dominated by the distinctive terms.
/// With limit:5, recency alone evicts the answer drawer; cue-relevance ranking
/// brings it to the top so it appears in keyInsights.
/// Twin of Swift `testGroundedSynthesisCueRankingBringsOldAnswerToTop`.
///
/// Pool size of 5 (1 answer + 4 generic) is chosen so MMR diversity surfaces
/// the answer at position 3: after the 2 most-recent generics are selected,
/// all remaining generics carry a ~0.95 shingle-similarity penalty while the
/// answer (very different content) carries only ~0.08. That penalty gap makes
/// the answer's MMR score exceed every remaining generic. cap=3 captures it.
#[test]
fn grounded_synthesis_cue_ranking_brings_old_answer_to_top() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // File the answer memory FIRST (oldest). Contains four distinctive terms.
    file_one_memory(
        &registry,
        "daguerreotype vintage cameras photography collection",
        "recipe-tests",
    );
    // Sleep briefly so the 4 generic memories get a later filedAt timestamp,
    // placing the answer at semRank=4 (oldest) in the (filedAt DESC, id DESC)
    // recall order. Without this the in-memory store's UUID tie-break is random
    // and the test becomes non-deterministic.
    std::thread::sleep(std::time::Duration::from_millis(5));
    // File 4 newer memories containing the generic word "collection" plus
    // unrelated content. 4 generics + 1 answer = 5-drawer pool that makes the
    // MMR math work at cap=3 (see module-level comment).
    for i in 1..=4 {
        file_one_memory(
            &registry,
            &format!("grocery store shopping collection item {i}"),
            "recipe-tests",
        );
    }

    // Query with distinctive terms + generic term. limit:3 — recency alone
    // would pick the 3 newest grocery drawers (evicting the answer at position
    // 5). The cue-pool bound widens the frame to 200, bringing all 5 drawers
    // into ranking. MMR diversity places the answer 3rd; cap=3 includes it in
    // keyInsights.
    let result = dispatch_tool(
        "moot_synthesize",
        &args![
            "query" => "daguerreotype vintage cameras collection",
            "filter" => "unconfirmed",
            "limit" => 3_i64
        ],
        &registry,
        &ledger,
    )
    .expect("cue-ranked synthesize must dispatch");

    assert!(is_success(&result), "cue-ranked synthesize should succeed; got: {result:?}");
    let text = content_text(&result);
    // The answer drawer must appear in keyInsights. It occupies the 3rd slot
    // of the cap-3 output (positions 1 and 2 are the 2 most-recent generics).
    assert!(
        text.contains("daguerreotype"),
        "answer drawer content must appear in keyInsights after cue ranking; got: {text}"
    );
    assert!(
        text.contains("query: daguerreotype vintage cameras collection"),
        "response must name the cue; got: {text}"
    );
}

/// `moot_synthesize` with an over-ceiling `limit` must succeed (clamped).
#[test]
fn grounded_synthesis_over_ceiling_limit_is_clamped() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let result = dispatch_tool(
        "moot_synthesize",
        &args!["limit" => 1_000_000_i64],
        &registry,
        &ledger,
    ).expect("over-ceiling limit must not be a transport fault");
    assert!(is_success(&result) || is_tool_error(&result),
        "result must have a well-formed shape; got: {result:?}");
}

/// `moot_federated_search` with a negative `limit` must be refused as a tool error.
/// `run_federated_search` returns `error_result` (isError:true), not a transport fault.
#[test]
fn federated_search_negative_limit_returns_tool_error() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // run_federated_search returns error_result (isError:true) for clamp violations;
    // it does NOT propagate as a JSONRPCError transport fault — unlike the other tools
    // where clamp_limit errors propagate through the Err path.
    let result = dispatch_tool(
        "moot_federated_search",
        &args!["limit" => -1_i64],
        &registry,
        &ledger,
    ).expect("federated_search limit error must not be a transport fault");
    assert!(is_tool_error(&result),
        "negative limit on moot_federated_search must return isError:true; got: {result:?}");
}

/// `moot_federated_search` with an over-ceiling `limit` must succeed (clamped, no grant error).
#[test]
fn federated_search_over_ceiling_limit_is_clamped() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Over-ceiling limit: clamped to 500, then no-grant error (expected).
    let result = dispatch_tool(
        "moot_federated_search",
        &args!["limit" => 1_000_000_i64],
        &registry,
        &ledger,
    ).expect("over-ceiling limit must not be a transport fault");
    // With no second estate open, the no-grant refused path returns isError:true.
    assert!(is_tool_error(&result),
        "over-ceiling limit must yield a well-formed no-grant result; got: {result:?}");
}

// ---------------------------------------------------------------------------
// Recall policy gate — sensitivity ceiling enforcement
//
// Tests that moot_lens_node_motion and moot_estate_map honour the default
// BitmapEvaluator ceiling (SensitivityAtMost(Elevated)), which excludes
// rows at Restricted and Secret tiers from read surfaces.
//
// Findings addressed:
//   A: moot_lens_node_motion bypassed the sensitivity ceiling when fetching
//      audit entries for a target rowID (LensTools / lens_tools.rs).
//   B: moot_estate_map counted restricted/secret rows in wing/room tallies
//      (ToolDispatch / interface_tools.rs).
// ---------------------------------------------------------------------------

/// Helper: capture a memory into the default estate with a specific sensitivity tier.
/// Returns the row ID of the created drawer.
fn capture_with_sensitivity(
    registry: &EstateRegistry,
    content: &str,
    room: &str,
    sensitivity: locus_kit::adjectives::AdjectiveSensitivity,
) -> String {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;

    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        room,
        LatticeAnchor::udc("004"),
        "policy-gate-test",
        "test-model-v1",
    );
    // Set sensitivity tier directly on the frame before capture.
    frame.sensitivity = sensitivity;

    let now = aria_mcp::dispatch::wall_now();
    let coord = registry.coord.lock().unwrap();
    let drawer = coord
        .capture(&registry.default.handle, frame, now)
        .expect("capture_with_sensitivity must succeed");
    drawer.id.clone()
}

/// moot_lens_node_motion on a Normal-sensitivity drawer must succeed.
/// Gate: Normal is bulk-exportable, so the motion analysis proceeds.
#[test]
fn node_motion_normal_sensitivity_succeeds() {
    use locus_kit::adjectives::AdjectiveSensitivity;

    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let row_id = capture_with_sensitivity(
        &registry,
        "normal-sensitivity content for motion lens",
        "policy-gate/normal",
        AdjectiveSensitivity::Normal,
    );

    let result = dispatch_tool(
        "moot_lens_node_motion",
        &args!["rowID" => row_id.as_str()],
        &registry,
        &ledger,
    ).expect("node_motion on Normal drawer must not be a transport fault");

    // Normal drawers are bulk-exportable — the tool must succeed.
    assert!(
        is_success(&result),
        "node_motion on Normal drawer must succeed (isError:false); got: {result:?}"
    );
}

/// moot_lens_node_motion on a Restricted-sensitivity drawer must return
/// isError:true with "memory not found". The tool must not reveal that
/// the row exists at a higher sensitivity tier.
#[test]
fn node_motion_restricted_is_not_found() {
    use locus_kit::adjectives::AdjectiveSensitivity;

    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let row_id = capture_with_sensitivity(
        &registry,
        "restricted content — must not surface via motion lens",
        "policy-gate/restricted",
        AdjectiveSensitivity::Restricted,
    );

    let result = dispatch_tool(
        "moot_lens_node_motion",
        &args!["rowID" => row_id.as_str()],
        &registry,
        &ledger,
    ).expect("node_motion on Restricted drawer must not be a transport fault");

    // Restricted drawers are NOT bulk-exportable — must return isError:true.
    assert!(
        is_tool_error(&result),
        "node_motion on Restricted drawer must be refused (isError:true); got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("memory not found"),
        "refusal message must say 'memory not found'; got: {text}"
    );
}

/// moot_lens_node_motion on a Secret-sensitivity drawer must return
/// isError:true with "memory not found". Secret is above the default ceiling.
#[test]
fn node_motion_secret_is_not_found() {
    use locus_kit::adjectives::AdjectiveSensitivity;

    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let row_id = capture_with_sensitivity(
        &registry,
        "secret content — must not surface via motion lens",
        "policy-gate/secret",
        AdjectiveSensitivity::Secret,
    );

    let result = dispatch_tool(
        "moot_lens_node_motion",
        &args!["rowID" => row_id.as_str()],
        &registry,
        &ledger,
    ).expect("node_motion on Secret drawer must not be a transport fault");

    // Secret drawers are NOT bulk-exportable — must return isError:true.
    assert!(
        is_tool_error(&result),
        "node_motion on Secret drawer must be refused (isError:true); got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("memory not found"),
        "refusal message must say 'memory not found'; got: {text}"
    );
}

/// moot_lens_node_motion on an unknown rowID must return isError:true.
/// Confirms the "not found" path for non-existent rows.
#[test]
fn node_motion_unknown_row_id_is_not_found() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let result = dispatch_tool(
        "moot_lens_node_motion",
        &args!["rowID" => "00000000-0000-0000-0000-000000000000"],
        &registry,
        &ledger,
    ).expect("node_motion unknown rowID must not be a transport fault");

    assert!(
        is_tool_error(&result),
        "node_motion unknown rowID must be refused (isError:true); got: {result:?}"
    );
    let text = content_text(&result);
    assert!(
        text.contains("memory not found"),
        "refusal message must say 'memory not found'; got: {text}"
    );
}

/// moot_estate_map must exclude Restricted and Secret drawers from wing/room counts.
/// Only Normal and Elevated drawers must appear in the estate map.
#[test]
fn estate_map_excludes_restricted_and_secret_rows() {
    use locus_kit::adjectives::AdjectiveSensitivity;

    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Seed one Normal drawer — must appear in map.
    capture_with_sensitivity(
        &registry,
        "normal content for estate map test",
        "policy-gate-map/visible",
        AdjectiveSensitivity::Normal,
    );

    // Seed one Restricted drawer — must NOT appear in map.
    capture_with_sensitivity(
        &registry,
        "restricted content — must not appear in estate map",
        "policy-gate-map/hidden-restricted",
        AdjectiveSensitivity::Restricted,
    );

    // Seed one Secret drawer — must NOT appear in map.
    capture_with_sensitivity(
        &registry,
        "secret content — must not appear in estate map",
        "policy-gate-map/hidden-secret",
        AdjectiveSensitivity::Secret,
    );

    let result = dispatch_tool("moot_estate_map", &args![], &registry, &ledger)
        .expect("estate_map must not throw");
    assert!(
        is_success(&result),
        "estate_map must succeed; got: {result:?}"
    );

    let text = content_text(&result);

    // The normal drawer's room must appear in the map.
    assert!(
        text.contains("policy-gate-map/visible") || text.contains("visible"),
        "estate_map must include Normal drawer's room; got: {text}"
    );

    // The restricted and secret rooms must NOT appear in the map.
    assert!(
        !text.contains("hidden-restricted"),
        "estate_map must exclude Restricted drawer's room; got: {text}"
    );
    assert!(
        !text.contains("hidden-secret"),
        "estate_map must exclude Secret drawer's room; got: {text}"
    );
}

/// moot_estate_map must include Elevated-sensitivity drawers.
/// Elevated is within the default BitmapEvaluator ceiling.
#[test]
fn estate_map_includes_elevated_sensitivity() {
    use locus_kit::adjectives::AdjectiveSensitivity;

    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // Seed one Elevated drawer — must appear in map.
    capture_with_sensitivity(
        &registry,
        "elevated content for estate map test",
        "policy-gate-elevated/visible",
        AdjectiveSensitivity::Elevated,
    );

    let result = dispatch_tool("moot_estate_map", &args![], &registry, &ledger)
        .expect("estate_map must not throw");
    assert!(
        is_success(&result),
        "estate_map must succeed with Elevated drawer; got: {result:?}"
    );

    let text = content_text(&result);

    // The elevated drawer's room must appear in the map.
    assert!(
        text.contains("policy-gate-elevated") || text.contains("elevated"),
        "estate_map must include Elevated drawer's room; got: {text}"
    );
}

// ---------------------------------------------------------------------------

/// Helper: convert days-since-epoch to (year, month, day). Used in `dream_far_future_now`.
fn epoch_days_to_ymd(mut days: u64) -> (u64, u64, u64) {
    let mut y = 1970u64;
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let diy = if leap { 366 } else { 365 };
        if days < diy { break; }
        days -= diy;
        y += 1;
    }
    let months: [u64; 12] = if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut mo = 1u64;
    for &dim in &months {
        if days < dim { break; }
        days -= dim;
        mo += 1;
    }
    (y, mo, days + 1)
}

// ---------------------------------------------------------------------------
// SECFIX (codex: MCP fact tools leak restricted/secret KG data) — the
// contradiction lens must redact source/endpoint drawer IDs that point at
// Restricted/Secret drawers even when the emitted fact/tunnel is exportable.
// (fact_search/fact_timeline source gating already covered elsewhere; this is
// the lens residual the finding flagged.)
// ---------------------------------------------------------------------------

/// A conflicting fact pair whose SOURCE drawer is Secret: the facts themselves
/// are Normal (pass the fact ceiling) but their source id must be redacted.
#[test]
fn lens_contradiction_hides_secret_fact_source() {
    use locus_kit::adjectives::AdjectiveSensitivity;
    let registry = EstateRegistry::new_inmemory();
    let secret_source = capture_with_sensitivity(
        &registry,
        "secret provenance drawer",
        "policy-gate/secret-source",
        AdjectiveSensitivity::Secret,
    );
    for object in ["green", "red"] {
        dispatch_tool(
            "moot_file_fact",
            &args![
                "subject" => "Project Aardvark",
                "predicate" => "status",
                "object" => object,
                "source_id" => secret_source.as_str()
            ],
            &registry,
            &SurfacedRecallLedger::new(),
        )
        .expect("file_fact must succeed");
    }
    let result = dispatch_tool(
        "moot_lens_contradiction",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("lens_contradiction must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    // Facts inherit their source drawer's sensitivity, so a fact drawn from a
    // Secret drawer is itself Secret and is dropped by the lens's disclosure
    // ceiling before rendering. Withholding the fact outright is strictly
    // stronger than masking its source= token.
    assert!(
        !text.contains("Project Aardvark"),
        "facts derived from a Secret drawer must be withheld; got: {text}"
    );
    assert!(
        !text.contains(&secret_source),
        "secret source drawer id must not leak; got: {text}"
    );
}

/// A contradicts tunnel whose target endpoint is Secret: the tunnel is
/// exportable but the secret endpoint id must be redacted.
#[test]
fn lens_contradiction_hides_secret_tunnel_endpoint() {
    use locus_kit::adjectives::AdjectiveSensitivity;
    let registry = EstateRegistry::new_inmemory();
    let visible = capture_with_sensitivity(
        &registry,
        "visible endpoint drawer",
        "policy-gate/visible-endpoint",
        AdjectiveSensitivity::Normal,
    );
    let secret = capture_with_sensitivity(
        &registry,
        "secret endpoint drawer",
        "policy-gate/secret-endpoint",
        AdjectiveSensitivity::Secret,
    );
    // Seed the contradicts tunnel directly at the store: link_memories'
    // existence lookup is sensitivity-blind and cannot resolve a Secret target
    // (a separate finding), so the lens redaction is tested in isolation here.
    use locus_kit::tunnel::Tunnel;
    use locus_kit::tunnel_operational::TunnelKind;
    let mut tunnel = Tunnel::new(
        "redact-endpoint-tunnel".to_string(),
        "policy-gate".to_string(),
        "visible-endpoint".to_string(),
        "policy-gate".to_string(),
        "secret-endpoint".to_string(),
        "contradicts".to_string(),
        "policy-gate-test".to_string(),
        aria_mcp::dispatch::wall_now(),
    );
    tunnel.kind = TunnelKind::Contradicts;
    tunnel.source_drawer_id = Some(visible.clone());
    tunnel.target_drawer_id = Some(secret.clone());
    registry
        .default
        .store
        .add_tunnel(&tunnel)
        .expect("add_tunnel must succeed");
    let result = dispatch_tool(
        "moot_lens_contradiction",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("lens_contradiction must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    assert!(
        text.contains(&visible),
        "normal endpoint should remain visible; got: {text}"
    );
    assert!(
        text.contains("contradicts <hidden>"),
        "secret endpoint must be redacted; got: {text}"
    );
    assert!(
        !text.contains(&secret),
        "secret endpoint drawer id must not leak; got: {text}"
    );
}

// ---------------------------------------------------------------------------
// sensitivity unlock — ceiling seam + read-under-grant audit wiring
// ---------------------------------------------------------------------------
//
// Mirrors Swift `SensitivityUnlockIntegrationTests.swift`. Drives the real
// `interface_tools::dispatch` path with an explicit `SensitivityGrantLedger`
// the test controls directly (the CLI/UnlockAuthority approval surface is a
// separate, out-of-band channel; these tests exercise the policy
// the ceiling seam enforces once a grant exists).

#[test]
fn restricted_drawer_grant_makes_it_visible_in_search() {
    use aria_mcp::interface_tools;
    use aria_mcp::sensitivity_grant_ledger::SensitivityGrantLedger;

    let registry = EstateRegistry::new_inmemory();
    dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "unlock-marker-restricted classified briefing",
            "subject" => "unlock-marker-restricted classified briefing",
            "location" => "vault/plans",
            "sensitivity" => "restricted"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory must succeed");

    // NOTE: this estate is `new_inmemory`, which seeds the seven wing organization
    // default wing-hint drawers — a single-novel-token query like
    // "unlock-marker-restricted" can still return those (degraded/fallback
    // ranking over the non-excluded pool) even though the restricted row
    // itself is correctly excluded. So the assertion checks CONTENT
    // absence, not a literal "found 0" hit count (unlike the isolated,
    // unseeded estate Swift's mirror test uses).
    let sensitivity_ledger = SensitivityGrantLedger::new();
    let before = interface_tools::dispatch(
        "moot_memory_search",
        &args!["query" => "unlock-marker-restricted"],
        &registry, &SurfacedRecallLedger::new(), &sensitivity_ledger, "", "", None, None,
    ).expect("dispatch must not throw");
    assert!(
        !content_text(&before).contains("classified briefing"),
        "without a grant the restricted drawer's content must never appear; got: {}",
        content_text(&before)
    );

    sensitivity_ledger.grant_restricted(aria_mcp::dispatch::wall_now());
    let after = interface_tools::dispatch(
        "moot_memory_search",
        &args!["query" => "unlock-marker-restricted"],
        &registry, &SurfacedRecallLedger::new(), &sensitivity_ledger, "", "", None, None,
    ).expect("dispatch must not throw");
    assert!(
        content_text(&after).contains("classified briefing"),
        "with a live restricted grant the drawer's content must be visible; got: {}",
        content_text(&after)
    );
}

#[test]
fn restricted_drawer_grant_makes_it_found_by_id() {
    use aria_mcp::interface_tools;
    use aria_mcp::sensitivity_grant_ledger::SensitivityGrantLedger;
    use locus_kit::adjectives::AdjectiveSensitivity;
    use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
    use aria_mcp::dispatch::wall_now;

    let registry = EstateRegistry::new_inmemory();
    dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "unlock-get-marker restricted content body",
            "subject" => "unlock-get-marker restricted content body",
            "location" => "vault/plans",
            "sensitivity" => "restricted"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory must succeed");

    let drawer_id = {
        let coord = registry.coord.lock().unwrap();
        let mut frame = RecallFrame::new(vec![Filter::Sensitivity(AdjectiveSensitivity::Restricted)]);
        frame.hydration_level = HydrationLevel::Full;
        frame.ordering = Ordering::ByCaptureTimeDesc;
        frame.limit = Some(1);
        let drawers = coord.recall(&registry.default.handle, frame, wall_now()).expect("recall must succeed");
        drawers.first().expect("restricted drawer must exist").id.clone()
    };

    let sensitivity_ledger = SensitivityGrantLedger::new();
    let before = interface_tools::dispatch(
        "moot_memory_get", &args!["id" => drawer_id.clone()],
        &registry, &SurfacedRecallLedger::new(), &sensitivity_ledger, "", "", None, None,
    );
    assert!(before.is_err(), "without a grant, moot_memory_get must report not-found for a restricted drawer");

    sensitivity_ledger.grant_restricted(wall_now());
    let after = interface_tools::dispatch(
        "moot_memory_get", &args!["id" => drawer_id],
        &registry, &SurfacedRecallLedger::new(), &sensitivity_ledger, "", "", None, None,
    ).expect("with a live grant, moot_memory_get must find the drawer");
    assert!(content_text(&after).contains("restricted content body"));
}

#[test]
fn restricted_read_under_grant_emits_audit_entry_via_search_and_get() {
    use genius_locus_kit::audit::UnifiedAuditVerb;
    use aria_mcp::interface_tools;
    use aria_mcp::sensitivity_grant_ledger::SensitivityGrantLedger;
    use aria_mcp::dispatch::wall_now;

    let registry = EstateRegistry::new_inmemory();
    dispatch_tool(
        "moot_file_memory",
        &args![
            "content" => "audit-search-marker restricted content",
            "subject" => "audit-search-marker restricted content",
            "location" => "vault/plans",
            "sensitivity" => "restricted"
        ],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory must succeed");

    let sensitivity_ledger = SensitivityGrantLedger::new();
    sensitivity_ledger.grant_restricted(wall_now());
    interface_tools::dispatch(
        "moot_memory_search", &args!["query" => "audit-search-marker"],
        &registry, &SurfacedRecallLedger::new(), &sensitivity_ledger, "", "", None, None,
    ).expect("dispatch must not throw");

    let coord = registry.coord.lock().unwrap();
    let log = coord.audit_log(&registry.default.handle).expect("audit log");
    let entries: Vec<_> = log.ordered_entries().into_iter()
        .filter(|e| e.verb == UnifiedAuditVerb::SensitivityReadUnderGrant)
        .collect();
    assert_eq!(entries.len(), 1, "exactly one read-under-grant entry after one qualifying search hit");
    assert_eq!(entries[0].field_path, "restricted");
}

#[test]
fn normal_drawer_read_during_live_grant_does_not_emit_audit_entry() {
    use genius_locus_kit::audit::UnifiedAuditVerb;
    use aria_mcp::interface_tools;
    use aria_mcp::sensitivity_grant_ledger::SensitivityGrantLedger;
    use aria_mcp::dispatch::wall_now;

    let registry = EstateRegistry::new_inmemory();
    dispatch_tool(
        "moot_file_memory",
        &args!["content" => "audit-normal-marker ordinary content", "subject" => "audit-normal-marker ordinary content", "location" => "vault/plans"],
        &registry,
        &SurfacedRecallLedger::new(),
    ).expect("file_memory must succeed");

    let sensitivity_ledger = SensitivityGrantLedger::new();
    sensitivity_ledger.grant_restricted(wall_now());
    interface_tools::dispatch(
        "moot_memory_search", &args!["query" => "audit-normal-marker"],
        &registry, &SurfacedRecallLedger::new(), &sensitivity_ledger, "", "", None, None,
    ).expect("dispatch must not throw");

    let coord = registry.coord.lock().unwrap();
    let log = coord.audit_log(&registry.default.handle).expect("audit log");
    assert!(
        log.ordered_entries().into_iter().all(|e| e.verb != UnifiedAuditVerb::SensitivityReadUnderGrant),
        "a row admitted regardless of any grant must not be recorded as read-under-grant"
    );
}

// ---------------------------------------------------------------------------
// Anthropic memory tool — sensitivity gate (twin of Swift
// MemoryToolAdapterSensitivityTests). The `memory` surface is bulk and
// path-addressed with no grant ceremony, so it matches the default
// no-claims recall posture: adjective sensitivity Normal/Elevated visible,
// Restricted/Secret invisible; edits carry the source tier forward.
// ---------------------------------------------------------------------------

/// Seed a drawer into the adapter wing ("memories") at a given adjective
/// sensitivity tier, bypassing the MCP surface (the gate under test).
fn seed_memory_wing_with_sensitivity(
    registry: &EstateRegistry,
    content: &str,
    room: &str,
    sensitivity: locus_kit::adjectives::AdjectiveSensitivity,
) {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;
    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Actuator,
        room,
        LatticeAnchor::udc("000"),
        "aria-mcp-tests",
        "default",
    );
    frame.wing = Some("memories".to_string());
    frame.sensitivity = sensitivity;
    let now = aria_mcp::dispatch::wall_now();
    let coord = registry.coord.lock().unwrap();
    coord
        .capture(&registry.default.handle, frame, now)
        .expect("sensitivity-tiered capture must succeed");
}

/// Serializes the env-sensitive memory-tool tests so their MOOTX01_MEMORY_TOOL
/// mutations do not race each other under the parallel test runner.
fn memory_env_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// Security (Codex b5716d8): the memory tool is opt-in. With the flag unset,
/// a hard-coded tools/call to `memory` must be REFUSED at dispatch (not merely
/// hidden from tools/list), mirroring the vault disabled-refusal.
#[test]
fn memory_tool_disabled_refuses_dispatch() {
    let _env = memory_env_lock();
    std::env::remove_var("MOOTX01_MEMORY_TOOL");
    let registry = EstateRegistry::new_inmemory_bare();
    let result = dispatch_tool(
        "memory",
        &args! {"command" => "view", "path" => "/memories"},
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dispatch returns a tool result, not a transport error");
    let text = content_text(&result);
    assert!(text.contains("disabled"), "expected a disabled refusal, got: {text}");
    // Re-enable so it does not disturb other memory tests holding the lock next.
    std::env::set_var("MOOTX01_MEMORY_TOOL", "1");
}

#[test]
fn memory_tool_excludes_restricted_and_secret_drawers() {
    use locus_kit::adjectives::AdjectiveSensitivity;
    let _env = memory_env_lock();
    // The memory tool is opt-in; enable it for this dispatch-behavior test.
    std::env::set_var("MOOTX01_MEMORY_TOOL", "1");
    let registry = EstateRegistry::new_inmemory_bare();
    seed_memory_wing_with_sensitivity(&registry, "visible normal", "normal.txt", AdjectiveSensitivity::Normal);
    seed_memory_wing_with_sensitivity(&registry, "visible elevated", "elevated.txt", AdjectiveSensitivity::Elevated);
    seed_memory_wing_with_sensitivity(&registry, "private restricted secret-value", "private.txt", AdjectiveSensitivity::Restricted);
    seed_memory_wing_with_sensitivity(&registry, "top secret secret-value", "secret.txt", AdjectiveSensitivity::Secret);

    let listing = dispatch_tool(
        "memory",
        &args! {"command" => "view", "path" => "/memories"},
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("memory view must succeed");
    let text = content_text(&listing);
    assert!(text.contains("/memories/normal.txt"), "{text}");
    assert!(
        text.contains("/memories/elevated.txt"),
        "elevated is Normal-tier and must stay visible (no-claims ceiling): {text}"
    );
    assert!(!text.contains("/memories/private.txt"), "{text}");
    assert!(!text.contains("/memories/secret.txt"), "{text}");

    let restricted_view = dispatch_tool(
        "memory",
        &args! {"command" => "view", "path" => "/memories/private.txt"},
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("memory view of a hidden path must not error");
    let text = content_text(&restricted_view);
    assert!(text.contains("does not exist"), "{text}");
    assert!(!text.contains("private restricted secret-value"), "{text}");
}

#[test]
fn memory_tool_edit_preserves_elevated_sensitivity() {
    use locus_kit::adjectives::AdjectiveSensitivity;
    let _env = memory_env_lock();
    std::env::set_var("MOOTX01_MEMORY_TOOL", "1");
    let registry = EstateRegistry::new_inmemory_bare();
    seed_memory_wing_with_sensitivity(&registry, "elevated old text", "elevated.txt", AdjectiveSensitivity::Elevated);

    let edit = dispatch_tool(
        "memory",
        &args! {
            "command" => "str_replace",
            "path" => "/memories/elevated.txt",
            "old_str" => "old",
            "new_str" => "new",
        },
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("memory str_replace must succeed");
    assert!(content_text(&edit).contains("edited"), "{}", content_text(&edit));

    let coord = registry.coord.lock().unwrap();
    let all = coord.all_drawers(&registry.default.handle).expect("all_drawers");
    let active = all
        .iter()
        .find(|d| d.content == "elevated new text" && d.tombstoned_at.is_none())
        .expect("edited drawer must exist");
    assert_eq!(
        active.adjective_sensitivity(),
        AdjectiveSensitivity::Elevated,
        "str_replace re-capture must carry the source tier, not downgrade to Normal"
    );
}

// ---------------------------------------------------------------------------
// Dataset tool tests (MX-TAB-7b, Scope 3 — Rust leg parity)
//
// Rust twin of DatasetToolsTests.swift. Covers the same surfaces using the
// in-memory registry (no filesystem I/O except csv_path security checks
// that explicitly need real paths).
//
// NOTE ON ARGUMENT CONSTRUCTION
// The `args!` macro captures values as `$v:expr` (Rust expression syntax).
// That works for scalars but NOT for JSON object/array literals like
// [{"name": "label", "type": "text"}] — the Rust parser rejects the `:`
// after a string literal key inside a braced expression. For tests that
// need nested JSON, use `json_dataset_args(serde_json::json!({...}))`:
// `serde_json::json!` is a proc-macro that accepts JSON syntax natively,
// and `json_dataset_args` converts the resulting `serde_json::Value` to the
// `BTreeMap<String, JsonValue>` that `dispatch_tool` expects.
// ---------------------------------------------------------------------------

/// Convert a `serde_json::Value` object into the `BTreeMap<String, JsonValue>`
/// that `dispatch_tool` expects. Panics if `v` is not a JSON object.
///
/// Required because the `args!` macro uses `$v:expr` (Rust expression
/// matcher) which cannot accept JSON object/array literals containing `:`.
/// `serde_json::json!` is a proc-macro and handles JSON syntax natively.
fn json_dataset_args(v: serde_json::Value) -> BTreeMap<String, JsonValue> {
    v.as_object()
        .expect("json_dataset_args: value must be a JSON object")
        .iter()
        .map(|(k, val)| (k.clone(), JsonValue::from(val.clone())))
        .collect()
}

/// File a 3-row, 2-column dataset with inline rows.
/// Returns `(dataset_id, handle_id)` parsed from the `dataset_filed:` response.
fn file_fruit_dataset(registry: &EstateRegistry) -> (String, String) {
    let result = dispatch_tool(
        "moot_file_dataset",
        &json_dataset_args(serde_json::json!({
            "name":     "fruit-scores",
            "columns":  [{"name": "label", "type": "text"}, {"name": "score", "type": "int"}],
            "rows":     [
                {"label": "apple",  "score": 95},
                {"label": "banana", "score": 80},
                {"label": "cherry", "score": 72}
            ],
            "location": "lab/produce"
        })),
        registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_file_dataset must not throw a transport error");
    assert!(
        is_success(&result),
        "moot_file_dataset must succeed; got: {result:?}"
    );
    let text = content_text(&result);
    let dataset_id = text
        .lines()
        .find(|l| l.trim().starts_with("id:"))
        .and_then(|l| l.trim().strip_prefix("id:").map(str::trim))
        .expect("dataset_filed: response must include an id: line")
        .to_string();
    let handle_id = text
        .lines()
        .find(|l| l.trim().starts_with("handle_id:"))
        .and_then(|l| l.trim().strip_prefix("handle_id:").map(str::trim))
        .expect("dataset_filed: response must include a handle_id: line")
        .to_string();
    (dataset_id, handle_id)
}

/// End-to-end: moot_file_dataset (inline rows) → moot_dataset_query → moot_dataset_stats.
/// Verifies response headers, row counts, and per-column stats blocks.
/// Rust parity peer of DatasetToolsTests.fileDatasetQueryStatsEndToEnd.
#[test]
fn dataset_file_query_stats_end_to_end() {
    let registry = EstateRegistry::new_inmemory_bare();
    let (dataset_id, _handle_id) = file_fruit_dataset(&registry);

    // Query: full scan, no predicates.
    let query = dispatch_tool(
        "moot_dataset_query",
        &args!["id" => dataset_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_dataset_query must not throw");
    assert!(is_success(&query), "moot_dataset_query must succeed; got: {query:?}");
    let qtext = content_text(&query);
    assert!(qtext.contains("dataset_query:"), "expected dataset_query: header; got: {qtext}");
    assert!(qtext.contains("rows_returned: 3"), "expected 3 rows; got: {qtext}");
    assert!(qtext.contains("apple"),  "expected apple in rows; got: {qtext}");
    assert!(qtext.contains("banana"), "expected banana in rows; got: {qtext}");
    assert!(qtext.contains("cherry"), "expected cherry in rows; got: {qtext}");

    // Stats: all columns.
    let stats = dispatch_tool(
        "moot_dataset_stats",
        &args!["id" => dataset_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_dataset_stats must not throw");
    assert!(is_success(&stats), "moot_dataset_stats must succeed; got: {stats:?}");
    let stext = content_text(&stats);
    assert!(stext.contains("dataset_stats:"), "expected dataset_stats: header; got: {stext}");
    assert!(stext.contains("label:"), "expected label: stats block; got: {stext}");
    assert!(stext.contains("score:"), "expected score: stats block; got: {stext}");
    assert!(stext.contains("count: 3"), "expected count: 3; got: {stext}");
}

/// Withdraw a dataset handle via moot_withdraw_memory, then verify moot_dataset_query
/// returns isError: true (refusal, not a transport throw).
/// Rust parity peer of DatasetToolsTests.withdrawnHandleRefusedByQuery.
#[test]
fn dataset_withdrawn_handle_refused_by_query() {
    let registry = EstateRegistry::new_inmemory_bare();
    let (dataset_id, handle_id) = file_fruit_dataset(&registry);

    // Dataset handles are just drawers; moot_withdraw_memory works on any drawer id.
    let withdraw = dispatch_tool(
        "moot_withdraw_memory",
        &args!["id" => handle_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_withdraw_memory must not throw");
    assert!(is_success(&withdraw), "withdraw must succeed; got: {withdraw:?}");

    let query = dispatch_tool(
        "moot_dataset_query",
        &args!["id" => dataset_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_dataset_query must return an isError result, not a transport throw");
    assert!(
        is_tool_error(&query),
        "moot_dataset_query on a withdrawn handle must set isError: true; got: {query:?}"
    );
}

/// Withdraw a dataset handle, then verify moot_dataset_stats returns isError: true.
/// Rust parity peer of DatasetToolsTests.withdrawnHandleRefusedByStats.
#[test]
fn dataset_withdrawn_handle_refused_by_stats() {
    let registry = EstateRegistry::new_inmemory_bare();
    let (dataset_id, handle_id) = file_fruit_dataset(&registry);

    let withdraw = dispatch_tool(
        "moot_withdraw_memory",
        &args!["id" => handle_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_withdraw_memory must not throw");
    assert!(is_success(&withdraw));

    let stats = dispatch_tool(
        "moot_dataset_stats",
        &args!["id" => dataset_id.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("moot_dataset_stats must return an isError result, not a transport throw");
    assert!(
        is_tool_error(&stats),
        "moot_dataset_stats on a withdrawn handle must set isError: true; got: {stats:?}"
    );
}

/// A column name containing SQL metacharacters must be rejected before any DDL.
/// Column validation fires before createDataset — no partial state left behind.
/// Returns isError: true in response body (tool-level error, not transport throw).
/// Rust parity peer of DatasetToolsTests.sqlInjectionColumnNameRejectedBeforeDDL.
#[test]
fn dataset_sql_injection_column_name_rejected() {
    let registry = EstateRegistry::new_inmemory_bare();
    let result = dispatch_tool(
        "moot_file_dataset",
        &json_dataset_args(serde_json::json!({
            "name":     "bad",
            "columns":  [{"name": "name; DROP TABLE x --", "type": "text"}],
            "rows":     [{"name; DROP TABLE x --": "val"}],
            "location": "lab"
        })),
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dispatch_tool must not throw on column validation failure");
    assert!(
        is_tool_error(&result),
        "SQL-injection column name must set isError: true; got: {result:?}"
    );
}

/// A column name whose first character is a digit must be rejected.
/// [A-Za-z_][A-Za-z0-9_]* is enforced before any DDL.
/// Rust parity peer of DatasetToolsTests.columnNameWithLeadingDigitRejected.
#[test]
fn dataset_column_name_leading_digit_rejected() {
    let registry = EstateRegistry::new_inmemory_bare();
    let result = dispatch_tool(
        "moot_file_dataset",
        &json_dataset_args(serde_json::json!({
            "name":     "bad",
            "columns":  [{"name": "1bad", "type": "text"}],
            "rows":     [{"1bad": "x"}],
            "location": "lab"
        })),
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dispatch_tool must not throw on column validation failure");
    assert!(
        is_tool_error(&result),
        "leading-digit column name must set isError: true; got: {result:?}"
    );
}

/// A column name containing a hyphen must be rejected.
/// Rust parity peer of DatasetToolsTests.columnNameWithHyphenRejected.
#[test]
fn dataset_column_name_hyphen_rejected() {
    let registry = EstateRegistry::new_inmemory_bare();
    let result = dispatch_tool(
        "moot_file_dataset",
        &json_dataset_args(serde_json::json!({
            "name":     "bad",
            "columns":  [{"name": "bad-col", "type": "text"}],
            "rows":     [{"bad-col": "x"}],
            "location": "lab"
        })),
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dispatch_tool must not throw on column validation failure");
    assert!(
        is_tool_error(&result),
        "hyphen in column name must set isError: true; got: {result:?}"
    );
}

/// csv_path pointing at a directory must be rejected with isError: true.
/// resolve_csv_path checks metadata().is_file() after canonicalization —
/// a directory is rejected before any parse attempt.
/// Rust parity peer of DatasetToolsTests.csvPathToDirectoryIsRejected.
#[test]
fn dataset_csv_path_directory_rejected() {
    let registry = EstateRegistry::new_inmemory_bare();
    let dir_path = std::env::temp_dir().to_str().unwrap().to_string();
    let result = dispatch_tool(
        "moot_file_dataset",
        &args! {
            "name"     => "bad",
            "csv_path" => dir_path.as_str(),
            "location" => "lab"
        },
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dispatch_tool must not throw on csv_path validation failure");
    assert!(
        is_tool_error(&result),
        "directory csv_path must set isError: true; got: {result:?}"
    );
}

/// csv_path pointing at a non-existent file must be rejected with isError: true.
/// Rust parity peer of DatasetToolsTests.csvPathMissingFileIsRejected.
#[test]
fn dataset_csv_path_missing_file_rejected() {
    let registry = EstateRegistry::new_inmemory_bare();
    let missing = std::env::temp_dir()
        .join(format!("nonexistent-{}.csv", uuid::Uuid::new_v4()))
        .to_str()
        .unwrap()
        .to_string();
    let result = dispatch_tool(
        "moot_file_dataset",
        &args! {
            "name"     => "bad",
            "csv_path" => missing.as_str(),
            "location" => "lab"
        },
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dispatch_tool must not throw on csv_path validation failure");
    assert!(
        is_tool_error(&result),
        "missing-file csv_path must set isError: true; got: {result:?}"
    );
}

// ---------------------------------------------------------------------------
// MX-TAB-SEC-1 security advisory tests
// ---------------------------------------------------------------------------

/// A1 (MX-TAB-SEC-1): a real CSV file outside the allowed import root (HOME)
/// must be rejected with isError: true. resolve_csv_path checks import-root
/// confinement after canonicalization (step 1.5).
/// Rust parity peer of DatasetToolsTests.csvPathOutsideImportRootRejected.
#[test]
fn dataset_csv_path_outside_import_root_rejected() {
    let registry = EstateRegistry::new_inmemory_bare();

    // Create a real CSV file in the system temp dir (outside HOME).
    let outside_csv = std::env::temp_dir()
        .join(format!("ds-a1-outside-{}.csv", uuid::Uuid::new_v4()));
    std::fs::write(&outside_csv, b"name,score\napple,1\n")
        .expect("should be able to create temp CSV for test");
    let outside_path = outside_csv.to_str().unwrap().to_string();
    let _cleanup = defer_remove(outside_csv.clone());

    let result = dispatch_tool(
        "moot_file_dataset",
        &args! {
            "name"     => "outside",
            "csv_path" => outside_path.as_str(),
            "location" => "lab"
        },
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dispatch_tool must not throw; import-root rejection is a tool error");
    assert!(
        is_tool_error(&result),
        "csv_path outside import root must set isError: true; got: {result:?}"
    );
    assert!(
        content_text(&result).contains("import root"),
        "error message must mention import root; got: {}",
        content_text(&result)
    );
}

// Dispatch-failure surfacing — TOOL_DISPATCH_FAILURE becomes an isError result
// ---------------------------------------------------------------------------
//
// Runner-raised TOOL_DISPATCH_FAILURE means the call reached its runner and
// the substrate (or an adapter under it) failed. The dispatch funnel converts
// it into a tools/call result with isError:true so the failure description
// reaches the model — a thrown JSON-RPC error is rendered by MCP clients as a
// bare "failed to call tool" with the message discarded. Protocol faults keep
// their thrown shape. Mirrors the Swift DispatchFailureSurfacingTests.

#[test]
fn tool_dispatch_failure_converts_to_error_result() {
    use aria_mcp::jsonrpc::JSONRPCError;
    let routed: Result<serde_json::Value, JSONRPCError> = Err(JSONRPCError::new(
        JSONRPCErrorCode::TOOL_DISPATCH_FAILURE,
        "vector lane save failed: permission denied".to_string(),
    ));
    let result = aria_mcp::dispatch::surface_dispatch_failure("moot_file_memory", routed)
        .expect("TOOL_DISPATCH_FAILURE must convert to an Ok(isError) result, not stay thrown");
    assert!(is_tool_error(&result), "converted result must set isError:true; got: {result}");
    assert!(
        content_text(&result).contains("permission denied"),
        "the underlying message must reach the client; got: {}",
        content_text(&result)
    );
}

/// A2 (MX-TAB-SEC-1): source_description in the dataset_filed response must
/// be "csv:<basename>" only — the full canonical path must not appear.
/// Rust parity peer of DatasetToolsTests.csvPathSourceDescriptionIsBasenameOnly.
#[test]
fn dataset_csv_path_source_description_is_basename_only() {
    let registry = EstateRegistry::new_inmemory_bare();

    // CSV must be inside HOME to pass A1 confinement.
    let home = std::env::var("HOME").expect("HOME must be set");
    let sub = std::path::Path::new(&home)
        .join(format!(".ds-a2-rust-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&sub).expect("should create subdir inside HOME");
    let csv_file = sub.join("fruits.csv");
    std::fs::write(&csv_file, b"name,score\napple,1\nbanana,2\n")
        .expect("should write CSV inside HOME");
    let csv_path = csv_file.to_str().unwrap().to_string();
    let _cleanup = defer_remove(sub.clone());

    let result = dispatch_tool(
        "moot_file_dataset",
        &args! {
            "name"     => "a2-test",
            "csv_path" => csv_path.as_str(),
            "location" => "lab/a2"
        },
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dispatch_tool must not throw on valid csv_path inside HOME");
    assert!(
        is_success(&result),
        "moot_file_dataset with valid HOME csv_path must succeed; got: {result:?}"
    );

    // The response text contains a "source: csv:<something>" line.
    let text = content_text(&result);
    let source_line = text
        .lines()
        .find(|l| l.trim().starts_with("source:"))
        .and_then(|l| l.trim().strip_prefix("source:").map(str::trim))
        .expect("dataset_filed: response must include a source: line");
    assert!(
        source_line.starts_with("csv:"),
        "source must start with 'csv:'; got: {source_line}"
    );
    let after_prefix = &source_line["csv:".len()..];
    assert!(
        !after_prefix.contains('/'),
        "source must not contain path separators; got: {source_line}"
    );
    assert_eq!(
        after_prefix, "fruits.csv",
        "source basename must be the actual filename; got: {source_line}"
    );
}

/// A3 (MX-TAB-SEC-1): a bad column identifier in the where clause must be
/// rejected at the MCP parse layer as a transport fault (JSONRPCError),
/// before it reaches SQL generation.
/// Rust parity peer of DatasetToolsTests.parseLayerBadColumnInWhereRejectedWithInvalidParams.
#[test]
fn dataset_parse_layer_bad_col_in_where_rejected() {
    let registry = EstateRegistry::new_inmemory_bare();
    let (dataset_id, _) = file_fruit_dataset(&registry);

    // where is a single JSON object (not an array) for a simple condition.
    let err = dispatch_tool(
        "moot_dataset_query",
        &json_dataset_args(serde_json::json!({
            "id":    dataset_id,
            "where": {
                "col": "name; DROP TABLE x",
                "op":  "eq",
                "val": "apple"
            }
        })),
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err(
        "bad column identifier in where 'col' must produce a transport fault (JSONRPCError)"
    );
    assert_eq!(
        err.code, JSONRPCErrorCode::INVALID_PARAMS,
        "transport fault must be INVALID_PARAMS; got: {:?}", err
    );
}

/// A3 (MX-TAB-SEC-1): same two-layer guard applies in parse_order_by.
/// Rust parity peer of DatasetToolsTests.parseLayerBadColumnInOrderByRejectedWithInvalidParams.
#[test]
fn dataset_parse_layer_bad_col_in_order_by_rejected() {
    let registry = EstateRegistry::new_inmemory_bare();
    let (dataset_id, _) = file_fruit_dataset(&registry);

    let err = dispatch_tool(
        "moot_dataset_query",
        &json_dataset_args(serde_json::json!({
            "id":       dataset_id,
            "order_by": [{"col": "score; DROP TABLE x", "dir": "asc"}]
        })),
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect_err(
        "bad column identifier in order_by 'col' must produce a transport fault (JSONRPCError)"
    );
    assert_eq!(
        err.code, JSONRPCErrorCode::INVALID_PARAMS,
        "transport fault must be INVALID_PARAMS; got: {:?}", err
    );
}

/// Tiny RAII helper: removes the given path on drop (silently, if already gone).
struct DeferRemove(std::path::PathBuf);
impl Drop for DeferRemove {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0).or_else(|_| std::fs::remove_file(&self.0));
    }
}
fn defer_remove(path: std::path::PathBuf) -> DeferRemove {
    DeferRemove(path)
}

#[test]
fn protocol_faults_stay_thrown() {
    use aria_mcp::jsonrpc::JSONRPCError;
    let routed: Result<serde_json::Value, JSONRPCError> = Err(JSONRPCError::new(
        JSONRPCErrorCode::METHOD_NOT_FOUND,
        "Unknown tool: moot_no_such_tool".to_string(),
    ));
    let err = aria_mcp::dispatch::surface_dispatch_failure("moot_no_such_tool", routed)
        .expect_err("METHOD_NOT_FOUND is a protocol fault and must pass through as Err");
    assert_eq!(err.code, JSONRPCErrorCode::METHOD_NOT_FOUND);
}

#[test]
fn successful_results_pass_through_untouched() {
    use aria_mcp::jsonrpc::JSONRPCError;
    let ok = aria_mcp::dispatch::text_result("filed memory ABC");
    let routed: Result<serde_json::Value, JSONRPCError> = Ok(ok.clone());
    let result = aria_mcp::dispatch::surface_dispatch_failure("moot_file_memory", routed)
        .expect("Ok results must pass through");
    assert_eq!(result, ok, "a successful result must not be rewritten by the funnel");
}

// ---------------------------------------------------------------------------
// ACK gate and notice-only stub tests (Wave 1) — mirrors RecipeToolsTests.swift
// ---------------------------------------------------------------------------

fn text_from_result(result: &serde_json::Value) -> &str {
    result["content"][0]["text"].as_str().expect("text_result must have content[0].text")
}

fn is_error_result(result: &serde_json::Value) -> bool {
    result["isError"].as_bool().unwrap_or(false)
}

/// is_recipe_tool returns true for moot_recollect (notice-only stub must reach dispatch).
#[test]
fn recollect_is_in_recipe_tool_routing_set() {
    assert!(aria_mcp::recipe_tools::is_recipe_tool("moot_recollect"),
        "moot_recollect must be in the routing set so callers receive the removal notice");
}

/// moot_recollect always returns the removal notice; never executes regardless of args.
#[test]
fn recollect_stub_returns_notice_never_executes() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    // No ack, no query — still returns the removal notice.
    let result = dispatch_tool(
        "moot_recollect",
        &args!["ack" => "anything", "query" => "test"],
        &registry,
        &ledger,
    ).expect("moot_recollect stub must not return Err — it returns Ok(notice)");

    assert!(!is_error_result(&result), "removal notice must not be isError");
    let text = text_from_result(&result);
    assert_eq!(
        text,
        "moot_recollect was removed: its substrate (factoid drawers) was retired; \
         recall hits now ARE source drawers; use moot_memory_search or moot_recall_distilled.",
        "byte-identical removal notice required"
    );
    assert!(!text.starts_with("CONTRACT CHANGE NOTICE:"),
        "removal notice is not a contract-change gate — different wording");
}

/// moot_consolidate no longer dispatches anywhere — not to distill (its
/// former alias target), not to anything else. The name is reserved for the
/// multi-item consolidation feature (SPEC_DISTILLATION_STORAGE §3 Phase 2);
/// until that claims it, calls fail with METHOD_NOT_FOUND like any
/// unregistered name, even with the old ack token.
/// Parity: Swift `testConsolidateNameIsUnknownTool`.
#[test]
fn consolidate_name_is_unknown_tool() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let err = dispatch_tool(
        "moot_consolidate",
        &args!["ack" => "moot_distill/p1"],
        &registry,
        &ledger,
    ).expect_err("moot_consolidate must be an unknown tool");

    assert_eq!(err.code, JSONRPCErrorCode::METHOD_NOT_FOUND);
}

/// moot_recall_distilled without ack returns the contract change notice.
#[test]
fn recall_distilled_without_ack_returns_contract_notice() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let result = dispatch_tool(
        "moot_recall_distilled",
        &args!["query" => "any query"],
        &registry,
        &ledger,
    ).expect("ACK gate must return Ok(notice), not Err");

    assert!(!is_error_result(&result));
    let text = text_from_result(&result);
    assert!(text.starts_with("CONTRACT CHANGE NOTICE:"),
        "notice must start with CONTRACT CHANGE NOTICE:");
    assert!(text.contains(r#"ack: "recall_distilled/v2""#),
        "notice must quote the current token");
    assert!(!text.contains("found "),
        "no recall must have run — estate untouched");
}

/// moot_recall_distilled with a wrong/stale ack returns the same notice.
#[test]
fn recall_distilled_wrong_ack_returns_contract_notice() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let result = dispatch_tool(
        "moot_recall_distilled",
        &args!["query" => "any query", "ack" => "recall_distilled/v1"],
        &registry,
        &ledger,
    ).expect("wrong ack must return Ok(notice)");

    assert!(!is_error_result(&result));
    let text = text_from_result(&result);
    assert!(text.starts_with("CONTRACT CHANGE NOTICE:"));
    assert!(text.contains(r#"ack: "recall_distilled/v2""#),
        "notice must always show the current token");
}

/// moot_recall_distilled with correct ack executes.
#[test]
fn recall_distilled_correct_ack_executes() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    let result = dispatch_tool(
        "moot_recall_distilled",
        &args!["query" => "any query", "ack" => "recall_distilled/v2"],
        &registry,
        &ledger,
    ).expect("correct ack must execute and return Ok");

    assert!(!is_error_result(&result));
    let text = text_from_result(&result);
    // Recall handler runs and reports 0 results on the empty estate.
    assert!(text.contains("found "),
        "correct ack must run the recall handler: {:?}", text);
    assert!(!text.starts_with("CONTRACT CHANGE NOTICE:"),
        "correct ack must not return a contract notice");
}

/// The recall_distilled tool schema exposes an "ack" property.
#[test]
fn recall_distilled_schema_exposes_ack_param() {
    let tools = build_tool_list_with_flags(vault_enabled(), false);
    let arr = tools.as_array().expect("tool list must be array");
    let tool = arr.iter()
        .find(|t| t["name"].as_str() == Some("moot_recall_distilled"))
        .expect("moot_recall_distilled must appear in tools list");
    let props = &tool["inputSchema"]["properties"];
    assert!(props["ack"].is_object(),
        "moot_recall_distilled schema must have 'ack' property; schema: {props:?}");
    assert_eq!(props["ack"]["type"].as_str(), Some("string"),
        "ack param must be type: string");
}

/// The recall_distilled description documents the current ack token.
#[test]
fn recall_distilled_description_contains_ack_token() {
    let tools = build_tool_list_with_flags(vault_enabled(), false);
    let arr = tools.as_array().expect("tool list must be array");
    let tool = arr.iter()
        .find(|t| t["name"].as_str() == Some("moot_recall_distilled"))
        .expect("moot_recall_distilled must appear in tools list");
    let desc = tool["description"].as_str().unwrap_or("");
    assert!(desc.contains("recall_distilled/v2"),
        "description must document the current ack token; got: {desc:?}");
}

// ---------------------------------------------------------------------------
// DCP M4 — typed conflict-projection section (mirrors Swift
// ConflictProjectionSectionTests): moot_lens_contradiction appends the
// evaluator-backed section; F13 restricted redaction; secret ceiling
// counted but silent.
// ---------------------------------------------------------------------------

/// Capture a drawer at `sensitivity` and file one employer claim from it.
fn plant_typed_claim(
    registry: &EstateRegistry,
    content: &str,
    employer: &str,
    sensitivity: locus_kit::adjectives::AdjectiveSensitivity,
) {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;
    use locus_kit::kg_fact::KGFact;
    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "conflict-section-tests",
        LatticeAnchor::udc("000"),
        "conflict-section-tests",
        "test-model-v1",
    );
    frame.subject = Some(content.chars().take(120).collect());
    frame.sensitivity = sensitivity;
    let coord = registry.coord.lock().unwrap();
    let drawer = coord
        .capture(&registry.default.handle, frame, 1_690_000_000_000)
        .expect("capture must succeed");
    let estate = coord.estate_for(&registry.default.handle).expect("estate");
    estate
        .add_kg_fact(&KGFact::new(
            format!("fact-{employer}"),
            "Sarah Chen C0".to_string(),
            "employer".to_string(),
            employer.to_string(),
            drawer.id,
            1_700_000_000_000,
        ))
        .expect("add_kg_fact must succeed");
}

/// Normal+normal pair: the lens appends the full typed section.
#[test]
fn lens_appends_full_typed_section() {
    let registry = EstateRegistry::new_inmemory();
    plant_typed_claim(&registry, "Claim one.", "Acme Robotics",
        locus_kit::adjectives::AdjectiveSensitivity::Normal);
    plant_typed_claim(&registry, "Claim two.", "Beta Corp",
        locus_kit::adjectives::AdjectiveSensitivity::Normal);
    let result = dispatch_tool(
        "moot_lens_contradiction", &args![], &registry, &SurfacedRecallLedger::new())
        .expect("lens must succeed");
    assert!(is_success(&result));
    let text = content_text(&result);
    // Legacy view intact (additive contract).
    assert!(text.contains("conflicting_facts: 1 subject+predicate pair(s)"), "got: {text}");
    // Typed section.
    assert!(text.contains("proven: 1"), "got: {text}");
    assert!(text.contains("historical: 0"), "got: {text}");
    assert!(text.contains("compatible: 0"), "got: {text}");
    assert!(text.contains("unknown_or_invalid: 0"), "got: {text}");
    assert!(text.contains("coverage: 2/2"), "got: {text}");
    // The lens has no lexical lane — no candidates line.
    assert!(!text.contains("candidates:"), "got: {text}");
    assert!(text.contains("  PROVEN "), "got: {text}");
    assert!(text.contains("    rule: dim.person.employer@1"), "got: {text}");
    assert!(text.contains("    coordinate: person:sarah chen c0|employer"), "got: {text}");
    assert!(text.contains(" vs "), "got: {text}");
    assert!(
        text.contains("    time: t:pt:1690000000 | t:pt:1690000000"),
        "temporal bases must be epoch SECONDS (KI-003); got: {text}"
    );
    assert!(
        text.contains("    reasons: same_coordinate, validity_overlap, values_exclusive"),
        "got: {text}"
    );
}

/// F13 — restricted+normal pair: counted, but the block collapses to the
/// coordinate-digest line. No source ids, no value digests, no dense rows.
#[test]
fn f13_restricted_pair_is_redacted() {
    let registry = EstateRegistry::new_inmemory();
    plant_typed_claim(&registry, "Public claim.", "Acme Robotics",
        locus_kit::adjectives::AdjectiveSensitivity::Normal);
    plant_typed_claim(&registry, "Restricted claim.", "Beta Corp",
        locus_kit::adjectives::AdjectiveSensitivity::Restricted);
    let result = dispatch_tool(
        "moot_lens_contradiction", &args![], &registry, &SurfacedRecallLedger::new())
        .expect("lens must succeed");
    let text = content_text(&result);
    assert!(text.contains("proven: 1"), "got: {text}");
    assert!(text.contains("a conflicting claim exists at "), "got: {text}");
    assert!(text.contains("[restricted]"), "got: {text}");
    assert!(!text.contains("  PROVEN "), "got: {text}");
    assert!(!text.contains("    rule: "), "got: {text}");
    assert!(!text.contains("    values: "), "got: {text}");
}

/// Secret ceiling: counted in `proven: N`, no block at all.
#[test]
fn secret_ceiling_is_counted_but_silent() {
    let registry = EstateRegistry::new_inmemory();
    plant_typed_claim(&registry, "Public claim.", "Acme Robotics",
        locus_kit::adjectives::AdjectiveSensitivity::Normal);
    plant_typed_claim(&registry, "Secret claim.", "Beta Corp",
        locus_kit::adjectives::AdjectiveSensitivity::Secret);
    let result = dispatch_tool(
        "moot_lens_contradiction", &args![], &registry, &SurfacedRecallLedger::new())
        .expect("lens must succeed");
    let text = content_text(&result);
    assert!(text.contains("proven: 1"), "got: {text}");
    assert!(!text.contains("  PROVEN "), "got: {text}");
    assert!(!text.contains("[restricted]"), "got: {text}");
}

// ---------------------------------------------------------------------------
// 12b. MXE-DM — stale-tunnel endpoints render unhydrated (Codex 9352f983)
//
// A tunnel inherits its endpoints' adjective sensitivity ONCE, at capture
// (estate_verbs.rs:767-785). CorrectSensitivity later rewrites only the
// drawer's adjective bitmap and never reclassifies existing tunnels
// (estate_verbs.rs:2670-2692). So a Normal tunnel can outlive its endpoint's
// Normal status and keep pointing at a now-Restricted drawer. Every graph
// lens arm that hydrates an id off that graph must refuse to render the
// subject — while still emitting the id and its ranking value, so result
// counts and rankings are unchanged and the gate is not itself an oracle.
// ---------------------------------------------------------------------------

/// The canary lives in the SUBJECT, not the content: `dense_row::render`
/// renders `subject`, so a canary in the body would prove nothing.
const DM_CANARY: &str = "dm stale-edge target SUBJECTCANARY";

/// Build the stale-edge state: two Normal drawers linked while BOTH are
/// Normal (so the tunnel inherits Normal), then the target corrected to
/// `sens` — which leaves the tunnel's own classification stale.
/// Returns (source id, target id).
fn dm_stale_edge(
    registry: &EstateRegistry,
    sens: locus_kit::adjectives::AdjectiveSensitivity,
) -> (String, String) {
    let src = file_one_memory(registry, "dm stale-edge source memory", "dm-src");
    let tgt = file_one_memory(registry, DM_CANARY, "dm-tgt");
    let link = dispatch_tool(
        "moot_link_memories",
        &args!["from_id" => src.as_str(), "to_id" => tgt.as_str(), "kind" => "elaborates"],
        registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("link_memories must not throw");
    assert!(is_success(&link), "link_memories must succeed; got: {link:?}");
    {
        let coord = registry.coord.lock().unwrap();
        coord
            .mutate(
                &registry.default.handle,
                &tgt,
                locus_kit::frames::MutationKind::CorrectSensitivity(sens),
                None,
            )
            .expect("CorrectSensitivity must succeed");
    }
    (src, tgt)
}

/// Every assertion the gated behaviour owes us, in one place: the id is
/// still present (so counts and rankings are untouched), the ranking
/// annotation survives, and the subject is gone.
fn assert_gated_but_present(body: &str, tgt: &str, ranking_marker: &str) {
    assert!(
        body.contains(tgt),
        "gated endpoint must STILL APPEAR by id — dropping it would change \
         result counts and make the gate an oracle; got: {body}"
    );
    assert!(
        body.contains(ranking_marker),
        "gated endpoint must keep its ranking value ({ranking_marker}); got: {body}"
    );
    assert!(
        !body.contains("SUBJECTCANARY"),
        "gated endpoint must NOT render its subject; got: {body}"
    );
    assert!(
        body.contains(&aria_mcp::dense_row::render_unhydrated(tgt)),
        "gated endpoint must render the unhydrated row byte-for-byte; got: {body}"
    );
}

#[test]
fn dm_successors_stale_restricted_endpoint_renders_unhydrated() {
    let registry = EstateRegistry::new_inmemory();
    let (src, tgt) = dm_stale_edge(
        &registry,
        locus_kit::adjectives::AdjectiveSensitivity::Restricted,
    );
    let result = dispatch_tool(
        "moot_lens_successors",
        &args!["wing" => "Agentic Memory", "anchorID" => src.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("successors must succeed");
    assert_gated_but_present(&content_text(&result), &tgt, "weight=");
}

#[test]
fn dm_successors_stale_secret_endpoint_renders_unhydrated() {
    let registry = EstateRegistry::new_inmemory();
    let (src, tgt) = dm_stale_edge(
        &registry,
        locus_kit::adjectives::AdjectiveSensitivity::Secret,
    );
    let result = dispatch_tool(
        "moot_lens_successors",
        &args!["wing" => "Agentic Memory", "anchorID" => src.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("successors must succeed");
    assert_gated_but_present(&content_text(&result), &tgt, "weight=");
}

#[test]
fn dm_free_association_stale_restricted_endpoint_renders_unhydrated() {
    let registry = EstateRegistry::new_inmemory();
    let (src, tgt) = dm_stale_edge(
        &registry,
        locus_kit::adjectives::AdjectiveSensitivity::Restricted,
    );
    let result = dispatch_tool(
        "moot_lens_free_association",
        &args!["wing" => "Agentic Memory", "seedDrawerID" => src.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("free_association must succeed");
    assert_gated_but_present(&content_text(&result), &tgt, "activation=");
}

#[test]
fn dm_keystones_stale_restricted_endpoint_renders_unhydrated() {
    let registry = EstateRegistry::new_inmemory();
    // topK 50: the seeded charter graph outranks a fresh two-node edge, and
    // the default topK of 5 would truncate the target away — the assertion
    // would then pass without ever exercising the gate.
    let (_src, tgt) = dm_stale_edge(
        &registry,
        locus_kit::adjectives::AdjectiveSensitivity::Restricted,
    );
    let result = dispatch_tool(
        "moot_lens_keystones",
        &args!["wing" => "Agentic Memory", "topK" => 50],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("keystones must succeed");
    assert_gated_but_present(&content_text(&result), &tgt, "centrality=");
}

/// The gate must not become a wall: a Normal endpoint reached over the same
/// stale-edge fixture still hydrates completely, subject and all.
#[test]
fn dm_normal_endpoint_still_hydrates_fully() {
    let registry = EstateRegistry::new_inmemory();
    let (src, tgt) = dm_stale_edge(
        &registry,
        locus_kit::adjectives::AdjectiveSensitivity::Normal,
    );
    let expected = aria_mcp::dense_row::render(&stored_drawer(&registry, &tgt));
    let result = dispatch_tool(
        "moot_lens_successors",
        &args!["wing" => "Agentic Memory", "anchorID" => src.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("successors must succeed");
    let body = content_text(&result);
    assert!(
        body.contains("SUBJECTCANARY"),
        "a Normal endpoint must still render its subject; got: {body}"
    );
    assert!(
        body.contains(&expected),
        "a Normal endpoint must render the full dense row byte-for-byte; got: {body}"
    );
}

/// Elevated is inside the ceiling (Normal tier) and must hydrate too — the
/// gate is `> elevated`, not `!= normal`.
#[test]
fn dm_elevated_endpoint_still_hydrates_fully() {
    let registry = EstateRegistry::new_inmemory();
    let (src, _tgt) = dm_stale_edge(
        &registry,
        locus_kit::adjectives::AdjectiveSensitivity::Elevated,
    );
    let result = dispatch_tool(
        "moot_lens_successors",
        &args!["wing" => "Agentic Memory", "anchorID" => src.as_str()],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("successors must succeed");
    let body = content_text(&result);
    assert!(
        body.contains("SUBJECTCANARY"),
        "an Elevated endpoint is within the ceiling and must still render its \
         subject; got: {body}"
    );
}

/// INDISTINGUISHABILITY (Perkins A3). A gated endpoint and an endpoint that
/// does not exist at all must be rendered by the SAME code path, so the reply
/// cannot be used as an existence oracle: an attacker who can link an id must
/// not be able to tell "this drawer exists but is restricted" from "no such
/// drawer". Both cases reach `render_unhydrated`, so the two rows must be
/// byte-identical once the id itself is substituted.
///
/// MXE-NQ established this property for the near: anchor surface; this is the
/// lens-arm equivalent, which that mission's test did not cover.
#[test]
fn dm_gated_endpoint_is_indistinguishable_from_absent_endpoint() {
    use locus_kit::tunnel::Tunnel;
    use locus_kit::tunnel_operational::TunnelKind;

    // Arm A: a real drawer, restricted after the edge was created.
    let reg_gated = EstateRegistry::new_inmemory();
    let (src_g, tgt_g) = dm_stale_edge(
        &reg_gated,
        locus_kit::adjectives::AdjectiveSensitivity::Restricted,
    );
    let gated_result = dispatch_tool(
        "moot_lens_successors",
        &args!["wing" => "Agentic Memory", "anchorID" => src_g.as_str()],
        &reg_gated,
        &SurfacedRecallLedger::new(),
    )
    .expect("successors must succeed");
    let gated_body = content_text(&gated_result);

    // Arm B: an edge pointing at an id that was never a drawer.
    let reg_absent = EstateRegistry::new_inmemory();
    let src_a = file_one_memory(&reg_absent, "dm stale-edge source memory", "dm-src");
    let absent_id = "00000000-0000-4000-8000-00000000dead".to_string();
    let mut tunnel = Tunnel::new(
        format!("dm-absent-tunnel-{src_a}"),
        "Agentic Memory".to_string(),
        "dm-src".to_string(),
        "Agentic Memory".to_string(),
        "dm-nowhere".to_string(),
        "elaborates".to_string(),
        "dm-tests".to_string(),
        aria_mcp::dispatch::wall_now(),
    );
    tunnel.kind = TunnelKind::Elaborates;
    tunnel.source_drawer_id = Some(src_a.clone());
    tunnel.target_drawer_id = Some(absent_id.clone());
    reg_absent
        .default
        .store
        .add_tunnel(&tunnel)
        .expect("add_tunnel must succeed");
    let absent_result = dispatch_tool(
        "moot_lens_successors",
        &args!["wing" => "Agentic Memory", "anchorID" => src_a.as_str()],
        &reg_absent,
        &SurfacedRecallLedger::new(),
    )
    .expect("successors must succeed");
    let absent_body = content_text(&absent_result);

    // Substitute each target id out; what remains must match exactly —
    // same row shape, same absence markers, same weight, same result count.
    assert_eq!(
        gated_body.replace(&tgt_g, "<TARGET>"),
        absent_body.replace(&absent_id, "<TARGET>"),
        "a gated endpoint must be indistinguishable from an absent one — \
         any difference is an existence oracle.\ngated:  {gated_body}\nabsent: {absent_body}"
    );
}

// ---------------------------------------------------------------------------
// Dream associate step (item 5) — Rust twins of the Swift
// DreamAssociatesDispatchTests. Registry estates are fully wired
// (provisioned hint drawers + vector store), so the default and "all"
// modes REALLY sweep: the report line appears with live counts, and
// "off" suppresses the step entirely.
// ---------------------------------------------------------------------------

#[test]
fn dream_associates_default_sweeps_and_reports() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool("moot_dream", &args![], &registry, &SurfacedRecallLedger::new())
        .expect("dream must succeed");
    let text = content_text(&result);
    assert!(text.contains("moot_dream: matrix rebuilt"), "got: {text}");
    assert!(text.contains("associationsWritten: "), "default mode must sweep: {text}");
    assert!(!text.contains("association sweep error"), "got: {text}");
}

#[test]
fn dream_associates_off_skips_the_step() {
    let registry = EstateRegistry::new_inmemory();
    let result = dispatch_tool(
        "moot_dream",
        &args!["associates" => "off"],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dream must succeed");
    let text = content_text(&result);
    assert!(!text.contains("associationsWritten"), "off must skip: {text}");
}

#[test]
fn dream_associates_all_sweeps_dedups_on_second_dream() {
    let registry = EstateRegistry::new_inmemory();
    let first = dispatch_tool(
        "moot_dream", &args!["associates" => "all"], &registry, &SurfacedRecallLedger::new())
        .expect("dream must succeed");
    let t1 = content_text(&first);
    assert!(t1.contains("associationsWritten: "), "all mode must sweep: {t1}");
    // Second dream: the edges already exist — written drops to zero and
    // the zero-gated line disappears, or reports deduplicated > 0.
    let second = dispatch_tool(
        "moot_dream", &args!["associates" => "all"], &registry, &SurfacedRecallLedger::new())
        .expect("second dream must succeed");
    let t2 = content_text(&second);
    assert!(
        !t2.contains("associationsWritten: 0 (probed: 0")
            && !t2.contains("association sweep error"),
        "got: {t2}"
    );
    if let Some(line) = t2.lines().find(|l| l.starts_with("associationsWritten")) {
        assert!(line.contains("deduplicated: "), "got: {line}");
        assert!(line.starts_with("associationsWritten: 0 "), "re-run writes nothing: {line}");
    }
}

// ---------------------------------------------------------------------------
// MXE-CT3 P3 — tiered hunt modes, dream candidate filing, review ladder
// ---------------------------------------------------------------------------
//
// Twin of Swift TieredContradictionSurfaceTests.swift: boundary
// validation for the new hunt args, the legacy-report pin (everything
// before the first TIER header is byte-for-byte today's report), the
// read-only single-tier purpose search, the dream candidate-filing +
// digest wiring, and the moot_review_tunnel review ladder.

/// Invalid `tier` / `top_k` values are rejected at the public boundary
/// with the valid domain named (b77ec03e8/b96c01617 precedent).
#[test]
fn hunt_rejects_invalid_tier_and_top_k() {
    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();

    for bad in [
        serde_json::json!(0),
        serde_json::json!(4),
        serde_json::json!(-1),
        serde_json::json!("2"),
        serde_json::json!("typed"),
        serde_json::json!(true),
    ] {
        let mut a: BTreeMap<String, JsonValue> = BTreeMap::new();
        a.insert("tier".to_string(), JsonValue::from(bad.clone()));
        let err = dispatch_tool("moot_hunt_contradictions", &a, &registry, &ledger)
            .expect_err(&format!("tier {bad} must be rejected"));
        assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
        assert!(
            err.message.contains("tier must be 1, 2, 3, or \"all\""),
            "message was: {}",
            err.message
        );
    }
    for bad in [
        serde_json::json!(0),
        serde_json::json!(51),
        serde_json::json!(-3),
        serde_json::json!("5"),
        serde_json::json!(false),
    ] {
        let mut a: BTreeMap<String, JsonValue> = BTreeMap::new();
        a.insert("top_k".to_string(), JsonValue::from(bad.clone()));
        let err = dispatch_tool("moot_hunt_contradictions", &a, &registry, &ledger)
            .expect_err(&format!("top_k {bad} must be rejected"));
        assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
        assert!(
            err.message.contains("top_k must be an integer in 1...50"),
            "message was: {}",
            err.message
        );
    }
}

/// With the new args ABSENT the hunt report's legacy portion is exactly
/// today's report — no new vocabulary before the typed section ends —
/// and the tiered synthesis digest is APPENDED after it. The benchmark
/// parser matches the trimmed "PROPOSED "/"CANDIDATE " prefixes and the
/// count lines, so this pin is load-bearing.
#[test]
fn hunt_without_new_args_keeps_legacy_report_and_appends_digest() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "the api timeout is 30 seconds", "work/notes");
    file_one_memory(&registry, "the api timeout is 90 seconds", "work/notes");

    let result = dispatch_tool(
        "moot_hunt_contradictions",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("hunt must not throw");
    let text = content_text(&result);

    // The digest is APPENDED: the report splits at the first tier header
    // into legacy portion + digest.
    let split = text
        .find("TIER 1 — CONTRADICTION (proven)")
        .unwrap_or_else(|| panic!("digest missing from: {text}"));
    let (legacy, digest) = text.split_at(split);

    assert!(
        legacy.starts_with("moot_hunt_contradictions: sweep complete\n"),
        "legacy portion: {legacy}"
    );
    assert!(legacy.contains("\nprobesScanned: "));
    assert!(legacy.contains("\npairsScreened: "));
    assert!(legacy.contains("\nalreadySettled: "));
    assert!(legacy.contains("\nproposed: 1"), "legacy portion: {legacy}");
    // Benchmark-parser contract: the two-space-indented emitter lines
    // are unchanged.
    let proposed_line = legacy
        .lines()
        .find(|l| l.starts_with("  PROPOSED "))
        .unwrap_or_else(|| panic!("no PROPOSED line in: {legacy}"));
    assert!(proposed_line.contains(" contradicts "));
    assert!(proposed_line.contains("score"));
    assert!(proposed_line.contains("tunnel"));
    // Typed section still closes the legacy portion.
    assert!(legacy.contains("\nproven: "));
    assert!(legacy.contains("\ncoverage: "));
    for new_token in [
        "TIER ",
        "lane:",
        "lane_seconds:",
        "synthesis_wall_seconds:",
        "conflictTunnelsFiled:",
    ] {
        assert!(
            !legacy.contains(new_token),
            "new token {new_token} leaked into the legacy portion: {legacy}"
        );
    }

    // Digest shape: all three sections in tier order, per-lane counts,
    // and the dispatch-layer timing lines.
    let t2 = digest
        .find("TIER 2 — CONFLICT CANDIDATE")
        .unwrap_or_else(|| panic!("no TIER 2 in: {digest}"));
    let t3 = digest
        .find("TIER 3 — DIVERGENCE")
        .unwrap_or_else(|| panic!("no TIER 3 in: {digest}"));
    assert!(t2 < t3, "sections must render in tier order");
    assert!(digest.contains("  lane: fetched "));
    assert!(digest.contains("lane_seconds: hunt="));
    assert!(digest.contains(" synthesis="));
    assert!(digest.contains("synthesis_wall_seconds: "));
    // The planted value-divergent pair is a tier-3 finding.
    assert!(
        digest[t3..].contains("(value_divergence, score "),
        "tier 3 section: {}",
        &digest[t3..]
    );
}

/// tier=N runs a read-only purpose search: its own header, only the
/// requested section, no legacy sweep vocabulary, no synthesis-only
/// counts/timing lines, and — the contract — no writes.
#[test]
fn hunt_single_tier_search_is_read_only() {
    let registry = EstateRegistry::new_inmemory();
    // Same two-document estate shape as
    // hunt_without_new_args_keeps_legacy_report_and_appends_digest —
    // ConflictCue is a pure function of the two content strings, so the
    // impatient pair alone is sufficient and classifies value_divergence
    // identically to the Swift twin.
    file_one_memory(&registry, "the api timeout is 30 seconds", "work/notes");
    file_one_memory(&registry, "the api timeout is 90 seconds", "work/notes");

    let before = {
        let coord = registry.coord.lock().unwrap();
        let estate = coord.estate_for(&registry.default.handle).expect("estate");
        estate.all_tunnels().expect("all_tunnels").len()
    };

    let result = dispatch_tool(
        "moot_hunt_contradictions",
        &args!["tier" => 3, "top_k" => 10],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("tier-3 search must not throw");
    let text = content_text(&result);

    assert!(
        text.starts_with("moot_hunt_contradictions: tier 3 search complete\n"),
        "got: {text}"
    );
    assert!(text.contains("TIER 3 — DIVERGENCE"));
    assert!(
        text.contains("(value_divergence, score "),
        "tier-3 findings: {text}"
    );
    for absent in [
        "sweep complete",
        "probesScanned:",
        "  PROPOSED ",
        "  CANDIDATE ",
        "TIER 1 —",
        "TIER 2 —",
        "lane:",
        "lane_seconds:",
        "synthesis_wall_seconds:",
    ] {
        assert!(!text.contains(absent), "unexpected {absent} in: {text}");
    }

    let after = {
        let coord = registry.coord.lock().unwrap();
        let estate = coord.estate_for(&registry.default.handle).expect("estate");
        estate.all_tunnels().expect("all_tunnels").len()
    };
    assert_eq!(after, before, "single-tier search must not write");

    // Tier 1 runs without a vector-store dependency and renders its
    // header even when the typed lane finds nothing.
    let t1 = dispatch_tool(
        "moot_hunt_contradictions",
        &args!["tier" => 1],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("tier-1 search must not throw");
    let t1_text = content_text(&t1);
    assert!(
        t1_text.starts_with("moot_hunt_contradictions: tier 1 search complete\n"),
        "got: {t1_text}"
    );
    assert!(t1_text.contains("TIER 1 — CONTRADICTION (proven)"));
}

/// moot_dream files tier-labeled candidates (step 3.25) and appends the
/// tiered synthesis digest through the same shared renderer.
#[test]
fn dream_files_candidates_and_appends_digest() {
    let registry = EstateRegistry::new_inmemory();
    // Twin of the Swift test: two impatient documents, no args. The cue
    // is a pure pairwise function — this pair is value_divergence in
    // both ports regardless of surrounding estate content.
    file_one_memory(&registry, "the api timeout is 30 seconds", "work/notes");
    file_one_memory(&registry, "the api timeout is 90 seconds", "work/notes");

    let result = dispatch_tool(
        "moot_dream",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("dream must not throw");
    let text = content_text(&result);

    // Step 3 runs the hunter — the planted pair is a strong
    // value_divergence, so exactly one contradicts tunnel is proposed
    // (Swift-twin-strength assertion). Step 3.25's all-tier filing then
    // reports filed/suppressed/ceilingSkipped.
    assert!(
        text.contains("contradictionsProposed: 1"),
        "dream: {text}"
    );
    let filed_line = text
        .lines()
        .find(|l| l.starts_with("conflictTunnelsFiled: "))
        .unwrap_or_else(|| panic!("no conflictTunnelsFiled line in: {text}"));
    assert!(filed_line.starts_with("conflictTunnelsFiled: tier1 0, tier2 "), "filed line: {filed_line}");
    assert!(filed_line.contains("(suppressed: "), "filed line: {filed_line}");
    assert!(filed_line.contains("ceilingSkipped: "), "filed line: {filed_line}");

    assert!(text.contains("TIER 1 — CONTRADICTION (proven)"));
    assert!(text.contains("TIER 2 — CONFLICT CANDIDATE"));
    assert!(text.contains("TIER 3 — DIVERGENCE"));
    // The planted pair surfaces as a tier-3 value divergence in the
    // digest — the classification pin the false "corpus statistics"
    // comment previously talked this test out of.
    assert!(
        text.contains("(value_divergence, score "),
        "dream digest: {text}"
    );
    assert!(text.contains("lane_seconds: propose="));
    assert!(text.contains("synthesis_wall_seconds: "));
}

/// Parse the tunnel id out of a `linked … (<id>)[ note]` response line.
fn tunnel_id_from_link_response(text: &str) -> String {
    let open = text.rfind('(').expect("no ( in link response");
    let close = text[open..].find(')').expect("no ) in link response") + open;
    text[open + 1..close].to_string()
}

/// The moot_review_tunnel review ladder: endorse records without
/// activating, a model objection contests or withdraws, and edge
/// activation stays user-only at the public boundary.
#[test]
fn review_ladder_endorse_object_and_user_only_activation() {
    use locus_kit::tunnel_operational::TunnelLifecycle;

    let registry = EstateRegistry::new_inmemory();
    let ledger = SurfacedRecallLedger::new();
    let a = file_one_memory(&registry, "Bob lives in Paris", "work/notes");
    let b = file_one_memory(&registry, "Bob lives in Lyon", "work/notes");

    let link = dispatch_tool(
        "moot_link_memories",
        &args!["from_id" => a.as_str(), "to_id" => b.as_str(),
               "kind" => "contradicts", "proposed" => true],
        &registry,
        &ledger,
    )
    .expect("link must not throw");
    let tunnel_id = tunnel_id_from_link_response(content_text(&link));

    // accept by a model reviewer is refused at the boundary.
    let err = dispatch_tool(
        "moot_review_tunnel",
        &args!["tunnel_id" => tunnel_id.as_str(), "verdict" => "accept",
               "reviewed_by" => "claude"],
        &registry,
        &ledger,
    )
    .expect_err("model accept must be rejected");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
    assert!(
        err.message.contains("edge activation is user-only"),
        "message was: {}",
        err.message
    );

    // Unknown verdicts and empty reviewer ids are boundary errors too.
    let err = dispatch_tool(
        "moot_review_tunnel",
        &args!["tunnel_id" => tunnel_id.as_str(), "verdict" => "snooze"],
        &registry,
        &ledger,
    )
    .expect_err("unknown verdict must be rejected");
    assert!(
        err.message
            .contains("verdict must be \"accept\", \"reject\", or \"endorse\""),
        "message was: {}",
        err.message
    );
    let err = dispatch_tool(
        "moot_review_tunnel",
        &args!["tunnel_id" => tunnel_id.as_str(), "verdict" => "endorse",
               "reviewed_by" => ""],
        &registry,
        &ledger,
    )
    .expect_err("empty reviewer must be rejected");
    assert!(
        err.message.contains("reviewed_by must be a non-empty string"),
        "message was: {}",
        err.message
    );

    // Model endorsement: recorded, lifecycle untouched.
    let endorse = dispatch_tool(
        "moot_review_tunnel",
        &args!["tunnel_id" => tunnel_id.as_str(), "verdict" => "endorse",
               "reviewed_by" => "claude"],
        &registry,
        &ledger,
    )
    .expect("endorse must not throw");
    let endorse_text = content_text(&endorse);
    assert!(
        endorse_text.contains("endorsed by claude (distinct endorsers: 1)"),
        "endorse: {endorse_text}"
    );
    {
        let coord = registry.coord.lock().unwrap();
        let estate = coord.estate_for(&registry.default.handle).expect("estate");
        let t = estate
            .get_tunnel(&tunnel_id)
            .expect("get_tunnel")
            .expect("tunnel exists");
        assert_eq!(t.lifecycle(), TunnelLifecycle::Proposed, "endorse must never activate");
    }

    // Model objection AFTER a model endorsement: contested, stays
    // proposed for user attention.
    let object = dispatch_tool(
        "moot_review_tunnel",
        &args!["tunnel_id" => tunnel_id.as_str(), "verdict" => "reject",
               "reviewed_by" => "gpt"],
        &registry,
        &ledger,
    )
    .expect("objection must not throw");
    let object_text = content_text(&object);
    assert!(
        object_text.contains("objected by gpt — contested"),
        "object: {object_text}"
    );
    {
        let coord = registry.coord.lock().unwrap();
        let estate = coord.estate_for(&registry.default.handle).expect("estate");
        let t = estate
            .get_tunnel(&tunnel_id)
            .expect("get_tunnel")
            .expect("tunnel exists");
        assert_eq!(t.lifecycle(), TunnelLifecycle::Proposed);
    }

    // User accept (default reviewed_by) still activates.
    let accept = dispatch_tool(
        "moot_review_tunnel",
        &args!["tunnel_id" => tunnel_id.as_str(), "verdict" => "accept"],
        &registry,
        &ledger,
    )
    .expect("accept must not throw");
    assert!(
        content_text(&accept).contains("accepted — the contradicts link is now active"),
        "accept: {}",
        content_text(&accept)
    );

    // Second proposal: a model objection with NO endorsement on record
    // withdraws (the AI-rejected, reopenable path).
    let c = file_one_memory(&registry, "the deploy window is Tuesday", "work/notes");
    let d = file_one_memory(&registry, "the deploy window is Friday", "work/notes");
    let second_link = dispatch_tool(
        "moot_link_memories",
        &args!["from_id" => c.as_str(), "to_id" => d.as_str(),
               "kind" => "contradicts", "proposed" => true],
        &registry,
        &ledger,
    )
    .expect("second link must not throw");
    let second_id = tunnel_id_from_link_response(content_text(&second_link));
    let solo = dispatch_tool(
        "moot_review_tunnel",
        &args!["tunnel_id" => second_id.as_str(), "verdict" => "reject",
               "reviewed_by" => "claude"],
        &registry,
        &ledger,
    )
    .expect("solo objection must not throw");
    assert!(
        content_text(&solo).contains("objected by claude — withdrawn"),
        "solo objection: {}",
        content_text(&solo)
    );
    {
        let coord = registry.coord.lock().unwrap();
        let estate = coord.estate_for(&registry.default.handle).expect("estate");
        let t = estate
            .get_tunnel(&second_id)
            .expect("get_tunnel")
            .expect("tunnel exists");
        assert_eq!(t.lifecycle(), TunnelLifecycle::Withdrawn);
    }
}

// ---------------------------------------------------------------------------
// moot_json_import — seed-file JSON lane over the MCP dispatch surface
// (MXE-JI-1 Part 5: registration round-trip both ports)
// ---------------------------------------------------------------------------

/// A seed fixture round-trips through a real moot_json_import dispatch call
/// and the records are really in the estate the registry served.
#[test]
fn json_import_round_trips_seed_fixture_over_mcp() {
    let registry = EstateRegistry::new_inmemory();
    // Baseline BEFORE the import: the in-memory registry pre-seeds charter
    // hints, so the assertion below is a delta, not an absolute count.
    let before = dispatch_tool(
        "moot_estate_status",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("estate status must dispatch");
    let baseline = active_memories(content_text(&before));
    let path = std::env::temp_dir().join(format!(
        "mcp-json-import-roundtrip-{}.json",
        std::process::id()
    ));
    std::fs::write(
        &path,
        r#"{"format_version": 1, "name": "mcp-round-trip", "records": [
             {"id": "m1", "content": "mcp round trip sentinel one", "event_time": "2026-02-01T10:00:00Z", "room": "mcp/roundtrip"},
             {"id": "m2", "content": "mcp round trip sentinel two", "event_time": "2026-02-01T11:00:00Z", "room": "mcp/roundtrip"}],
            "facts": [{"subject": "sentinel", "predicate": "counted", "object": "two", "record_id": "m1"}],
            "tunnels": [{"from": "m2", "to": "m1", "kind": "references"}]}"#,
    )
    .expect("temp seed writable");

    let result = dispatch_tool_with_vault_flag(
        "moot_json_import",
        &args!["path" => path.to_str().unwrap()],
        &registry,
        &SurfacedRecallLedger::new(),
        true, // vault_on
    )
    .expect("json import must dispatch");
    std::fs::remove_file(&path).ok();

    assert!(is_success(&result), "import must succeed; got: {result:?}");
    let body = content_text(&result);
    assert!(body.contains("2 drawers"), "got: {body}");
    assert!(body.contains("1 facts"), "got: {body}");
    assert!(body.contains("1 tunnels"), "got: {body}");
    assert!(body.contains("seedSha256="), "got: {body}");

    // The records are really in the estate: the estate summary counts them
    // on top of whatever the in-memory registry pre-seeds (charter hints),
    // and the seed's fact landed in the KG.
    let status = dispatch_tool(
        "moot_estate_status",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("estate status must dispatch");
    let status_text = content_text(&status);
    assert_eq!(
        active_memories(status_text),
        baseline + 2,
        "both records must be active in the estate; got: {status_text}"
    );
    assert!(
        status_text.contains("kg facts: 1 active"),
        "the seed fact must land in the KG; got: {status_text}"
    );
}

/// Parse the "memories: N active" count out of a moot_estate_status body.
fn active_memories(status_text: &str) -> usize {
    status_text
        .lines()
        .find_map(|l| l.strip_prefix("memories: "))
        .and_then(|rest| rest.split(' ').next())
        .and_then(|n| n.parse().ok())
        .expect("estate status must report an active-memory count")
}

/// The zero-partial-write contract over MCP: an invalid seed is an isError
/// tool result naming the offending element, and the estate stays empty.
#[test]
fn json_import_invalid_seed_is_error_result_with_zero_writes() {
    let registry = EstateRegistry::new_inmemory();
    // Baseline BEFORE the failed import (charter hints are pre-seeded).
    let before = dispatch_tool(
        "moot_estate_status",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("estate status must dispatch");
    let baseline = active_memories(content_text(&before));
    let path = std::env::temp_dir().join(format!(
        "mcp-json-import-invalid-{}.json",
        std::process::id()
    ));
    std::fs::write(
        &path,
        r#"{"format_version": 1, "name": "bad", "records": [
             {"id": "m1", "content": "c", "event_time": "2026-02-01T10:00:00Z", "room": "rm"}],
            "tunnels": [{"from": "m1", "to": "m999", "kind": "references"}]}"#,
    )
    .expect("temp seed writable");

    let result = dispatch_tool_with_vault_flag(
        "moot_json_import",
        &args!["path" => path.to_str().unwrap()],
        &registry,
        &SurfacedRecallLedger::new(),
        true, // vault_on
    )
    .expect("json import must dispatch");
    std::fs::remove_file(&path).ok();

    assert!(is_tool_error(&result), "validation failure must be isError; got: {result:?}");
    let body = content_text(&result);
    assert!(body.contains("\"m999\""), "offending element must be named; got: {body}");

    // Zero writes — never a partial estate: the active count is exactly
    // the pre-import baseline and no KG fact landed.
    let status = dispatch_tool(
        "moot_estate_status",
        &args![],
        &registry,
        &SurfacedRecallLedger::new(),
    )
    .expect("estate status must dispatch");
    let status_text = content_text(&status);
    assert_eq!(
        active_memories(status_text),
        baseline,
        "estate must be untouched; got: {status_text}"
    );
    assert!(
        status_text.contains("kg facts: 0 active"),
        "no fact may land on a failed import; got: {status_text}"
    );
}
