//! Dispatch-surface integration tests — 5-tier AI-client interface (MCP-RUST-ALIGN-01).
//!
//! Tests the 70-tool surface: 23 interface tools (Tier 1–5 + moot_monitoring_status,
//! including moot_memory_get and moot_review_tunnel), 1 federation tool,
//! 11 recipe tools,
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
mod test_support;
use test_support::SelectedV2Session;

use aria_mcp::estate_posture::EstatePosture;
use aria_mcp::{
    dispatcher::Dispatcher,
    estate_registry::{EstateOpening, EstateRegistry},
    jsonrpc::{JSONRPCError, JSONRPCErrorCode, JSONRPCRequest, JsonValue},
    tool_list::{build_tool_list, vault_enabled},
    v2::catalog::{selected_tools_for_registry, selected_registry_with_vault},
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

fn selected_data(result: &serde_json::Value) -> &serde_json::Value {
    let data = &result["structuredContent"]["data"];
    assert!(data.is_object(), "selected-v2 result must carry structured data: {result:?}");
    data
}

/// Re-enters the public selected-v2 dispatcher while preserving the old tests'
/// shared in-memory estate. The cloned registry carries the same Arc-backed
/// coordinator and stores; only the dispatcher wrapper is per invocation.

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
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;

    // This fixture establishes state for a later public operation. Capture
    // directly through the live coordinator seam so fixture setup never
    // re-enters the retired v1 dispatch wire. `capture` is synchronous, the
    // same observable setup property the old `impatient: true` request had.
    let subject: String = content.chars().take(120).collect();
    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        location,
        LatticeAnchor::udc("004"),
        "aria-mcp-tests",
        "default",
    );
    frame.subject = Some(subject);
    let coord = registry.coord.lock().unwrap();
    coord
        .capture(&registry.default.handle, frame, aria_mcp::dispatch::wall_now())
        .expect("fixture capture must succeed")
        .id
}

/// Selected-v2 counterpart for fixtures that need their writes and reads to
/// share one dispatcher-owned session.
fn file_one_memory_v2(session: &SelectedV2Session, content: &str, location: &str) -> String {
    let subject: String = content.chars().take(120).collect();
    let result = session
        .call(
            "moot_file_memory",
            &args![
                "content" => content,
                "subject" => subject.as_str(),
                "location" => location,
                "impatient" => true
            ],
        )
        .expect("selected-v2 file_memory must succeed");
    assert!(is_success(&result), "file_memory should succeed; got: {result:?}");
    selected_data(&result)["memory_id"]
        .as_str()
        .expect("file_memory must return structured memory_id")
        .to_owned()
}

fn file_one_memory_at(
    registry: &EstateRegistry,
    content: &str,
    location: &str,
    event_time: &str,
) -> String {
    let session = SelectedV2Session::new(registry.clone());
    let subject: String = content.chars().take(120).collect();
    let result = session
        .call(
            "moot_file_memory",
            &args![
                "content" => content,
                "subject" => subject.as_str(),
                "location" => location,
                "event_time" => event_time,
                "impatient" => true
            ],
        )
        .expect("selected-v2 fixture file must succeed");
    selected_data(&result)["memory_id"]
        .as_str()
        .expect("selected-v2 file response must include memory_id")
        .to_owned()
}

fn file_one_memory_v2_with_exportability(
    session: &SelectedV2Session,
    content: &str,
    location: &str,
    exportability: Option<&str>,
) -> String {
    let subject: String = content.chars().take(120).collect();
    let mut arguments = args![
        "content" => content,
        "subject" => subject.as_str(),
        "location" => location,
        "impatient" => true
    ];
    if let Some(exportability) = exportability {
        arguments.insert(
            "exportability".to_owned(),
            JsonValue::String(exportability.to_owned()),
        );
    }
    let result = session
        .call("moot_file_memory", &arguments)
        .expect("selected-v2 file_memory must succeed");
    assert!(is_success(&result), "file_memory should succeed; got: {result:?}");
    selected_data(&result)["memory_id"]
        .as_str()
        .expect("file_memory must return structured memory_id")
        .to_owned()
}

fn selected_result_ids(result: &serde_json::Value) -> Vec<&str> {
    selected_data(result)["results"]
        .as_array()
        .expect("selected-v2 recall must return results array")
        .iter()
        .filter_map(|row| row["id"].as_str())
        .collect()
}

/// Like [`file_one_memory`] but accepts an explicit ISO-8601 `event_time` to pin
/// each drawer's `event_time` column (temporal scoring; distinct from `filed_at`).
/// `filed_at` is capture time, set by the bench clock at ingest; probe selection
/// in `recent_item_ids` orders by `filed_at DESC, item_id ASC`.

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

fn session_stored_drawer(session: &SelectedV2Session, id: &str) -> locus_kit::drawer::Drawer {
    let coord = session.coord.lock().unwrap();
    coord
        .all_drawers(&session.default.handle)
        .expect("all_drawers must succeed")
        .into_iter()
        .find(|d| d.id == id)
        .expect("seeded drawer must exist")
}

fn session_stored_fdc_code(session: &SelectedV2Session, id: &str) -> String {
    session_stored_drawer(session, id).udc_code
}

fn session_fdc_floor(session: &SelectedV2Session) -> Option<String> {
    session
        .default
        .store
        .get_meta(FDC_FLOOR_KEY)
        .expect("FDC floor metadata read must succeed")
}

// ---------------------------------------------------------------------------
// 1. tools/list surface assertions — 80 tools exact (v2 catalog)
// ---------------------------------------------------------------------------

#[test]
fn tools_list_count_is_80() {
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
    // moot_hunt_contradictions recipe tool) +
    // moot_recall_walk (D10: escalation-ladder recall):
    //   23  interface tools (Tier 1–5 + monitoring_status + review_tunnel)
    //    1  federation tool (moot_federated_search)
    //   14  recipe tools (list_lenses, list_recipes, synthesize, run_migration,
    //                     confirm_migration, recall_precise, recall_connected,
    //                     recall_shaped, recall_vague, dream, recall_temporal,
    //                     recall_distilled, hunt_contradictions, recall_walk —
    //                     moot_consolidate no longer dispatches (SPEC §3 Phase 2);
    //                     moot_distill and moot_redistill retired ENC-W6B)
    //   23  lens tools (moot_lens_* prefix; cohesion renamed, contradiction +
    //                   node_motion added)
    //    5  vault tools (moot_vault_export, import, status, reconcile, job)
    //    3  dataset tools (moot_file_dataset, moot_dataset_query, moot_dataset_stats) — MX-TAB-7
    // ----
    //    6  maintenance tools (moot_reindex, moot_drain_status, moot_reclassify_fdc,
    //                          moot_timing_report, moot_palace_import, moot_json_import)
    //    2  contradiction-hunter tools (moot_hunt_contradictions, moot_review_tunnel)
    //   73  total (memory adapter excluded — opt-in, off by default; D10 added
    //       moot_recall_walk escalation-ladder recall recipe; 2026-08-26 added
    //       moot_rebuild_status, the derived-state rebuild condition surface;
    //       work packets retired V2_PACKETS_RETIRE)
    // v2 catalog: 80 tools with vault-on (the default), 73 without vault.
    // Use selected_tools_for_registry with vault_enabled() for deterministic count.
    let tools = selected_tools_for_registry(&selected_registry_with_vault(vault_enabled()));
    let arr = tools.as_array().expect("selected_tools must return an array");
    assert_eq!(arr.len(), 80, "expected 80 v2 tools; got {}", arr.len());
}

#[test]
fn tools_list_name_set_matches_expected_names() {
    // Gate: all 75 expected tool names are present, no more and no less.
    // moot_reindex is the maintenance tool (corpus/vector backfill).
    // moot_drain_status reports background drain progress (drain-status stream).
    // moot_palace_import is the direct palace import tool (PAR-PB-1).
    // moot_vault_job is a vault tool (Bob's ruling 2026-06-12: tool-surface
    // parity matters even when the Rust backend is synchronous).
    // moot_recall_shaped is the named RecallShape preset surface.
    // moot_distill + moot_recall_distilled are the distillation tools
    // (SPEC_DISTILLATION_STORAGE §3/§10.3; moot_consolidate no longer
    // dispatches — §3 Phase 2).
    // moot_memory_get fetches a full drawer by id (fetch-drawer-by-ID gap,
    // shipped in the 1.0.x train per Bob's build-now ruling).
    // moot_recall_walk (D10): escalation-ladder recall — cheap session_hybrid
    // first, precise hamming+text only when Stage 1 is not confident.
    let expected: std::collections::HashSet<&str> = [
        // Core memory writes (7)
        "moot_file_memory", "moot_update_memory", "moot_withdraw_memory",
        "moot_erase_memory", "moot_confirm_memory", "moot_move_memory", "moot_link_memories",
        // Core memory reads (3)
        "moot_memory_search", "moot_memory_list", "moot_memory_get",
        // Connection writes (1)
        "moot_review_tunnel",
        // Connection reads (2)
        "moot_connection_search", "moot_connection_map",
        // Knowledge graph writes (2)
        "moot_file_fact", "moot_retire_fact",
        // Knowledge graph reads (2)
        "moot_fact_search", "moot_fact_timeline",
        // Journal writes (1)
        "moot_write_journal",
        // Journal reads (1)
        "moot_read_journal",
        // Contradiction writes (2)
        "moot_hunt_contradictions", "moot_propose_contradictions",
        // Transcript recall (1)
        "moot_memory_recall_transcript",
        // Help (1)
        "moot_help",
        // Estate reads (3)
        "moot_estate_status", "moot_estate_map", "moot_estate_ping",
        // Monitoring (2)
        "moot_monitoring_status", "moot_monitoring_set",
        // Recipe tools (8)
        "moot_list_lenses", "moot_list_recipes", "moot_synthesize", "moot_dream",
        "moot_migration_run", "moot_migration_confirm",
        "moot_federated_recall",
        "moot_recall_precise", "moot_recall_temporal", "moot_recall_connected",
        "moot_recall_shaped", "moot_recall_distilled", "moot_recall_vague", "moot_recall_walk",
        // Maintenance tools (6) — reindex, drain, rebuild, reclassify, timing, palace, json
        "moot_reindex", "moot_drain_status", "moot_rebuild_status",
        "moot_reclassify_fdc", "moot_timing_report",
        "moot_palace_import", "moot_json_import",
        // Lens tools (23)
        "moot_lens_keystones", "moot_lens_constellation", "moot_lens_free_association",
        "moot_lens_theme_weather", "moot_lens_latent_themes", "moot_lens_bias",
        "moot_lens_drift", "moot_lens_node_motion", "moot_lens_cohesion",
        "moot_lens_contradiction", "moot_lens_trust_synthesis", "moot_lens_partial_cue",
        "moot_lens_anticipate", "moot_lens_successors", "moot_lens_overlap",
        "moot_lens_divergence", "moot_lens_associations", "moot_lens_concepts",
        "moot_lens_apriori", "moot_lens_moment", "moot_lens_rhythm",
        "moot_lens_precedence", "moot_lens_complexity",
        // Vault tools (5)
        "moot_vault_export", "moot_vault_import", "moot_vault_status",
        "moot_vault_reconcile", "moot_vault_job",
        // Dataset tools (3)
        "moot_file_dataset", "moot_dataset_query", "moot_dataset_stats",
    ]
    .iter()
    .copied()
    .collect();

    // v2 catalog with vault-on (80 tools).
    let tools = selected_tools_for_registry(&selected_registry_with_vault(vault_enabled()));
    let arr = tools.as_array().expect("selected_tools must return an array");
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_reclassify_fdc",
        &args![],
    )
    .expect("moot_reclassify_fdc dry-run must dispatch");

    assert!(is_success(&result), "dry-run should succeed; got: {result:?}");
    let data = selected_data(&result);
    assert_eq!(data["applied"], false);
    assert_eq!(data["mode"], "suspectOnly");
    assert_eq!(data["candidates"], 1);
    assert_eq!(data["would_update"], 1);
    assert_eq!(data["changes"][0]["id"], id);
    assert_eq!(data["changes"][0]["old_code"], "362.4");
    assert_eq!(data["changes"][0]["old_qid"], "Q12131");
    assert_eq!(data["changes"][0]["new_code"], "000");
    assert_eq!(session_stored_fdc_code(&session, &id), "362.4");
    assert_eq!(session_fdc_floor(&session), None, "dry-run must not stamp estate FDC floor");
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_reclassify_fdc",
        &args!["apply" => true, "mode" => "all"],
    ).expect("moot_reclassify_fdc must dispatch");
    assert_eq!(selected_data(&result)["updated"], 2);

    let short = session_stored_drawer(&session, &short_id);
    assert_eq!(short.udc_code, "005");
    assert_eq!(short.wikidata_qid, None);
    let swift = session_stored_drawer(&session, &swift_id);
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_reclassify_fdc",
        &args!["apply" => true],
    ).expect("moot_reclassify_fdc must dispatch");
    let data = selected_data(&result);
    assert_eq!(data["mode"], "suspectOnly");
    assert_eq!(data["updated"], 1);
    assert_eq!(
        session_stored_drawer(&session, &id).wikidata_qid.as_deref(),
        Some("Q17118377")
    );
    assert_eq!(session_fdc_floor(&session), None);
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_reclassify_fdc",
        &args!["apply" => true, "mode" => "all"],
    )
    .expect("moot_reclassify_fdc apply must dispatch");

    assert!(is_success(&result), "apply should succeed; got: {result:?}");
    let data = selected_data(&result);
    assert_eq!(data["applied"], true);
    assert!(data["fdc_data_version"].as_str().is_some_and(|version| !version.is_empty()));
    assert_eq!(data["floor_stamp"], "stamped");
    assert_eq!(data["updated"], 1);
    assert_eq!(session_stored_fdc_code(&session, &id), "000");
    assert_eq!(
        session_fdc_floor(&session),
        Some(lattice_lib::Fdc::recalculation_version()),
        "full apply must stamp the composite estate FDC floor"
    );
    let status = session.call(
        "moot_estate_status",
        &args![],
    )
    .expect("estate status must dispatch");
    assert_eq!(selected_data(&status)["fdc_recalculation"], "current");
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
    let session = SelectedV2Session::new(registry);

    let conservative = session.call(
        "moot_reclassify_fdc",
        &args![],
    )
    .expect("moot_reclassify_fdc conservative dry-run must dispatch");
    let conservative_data = selected_data(&conservative);
    assert_eq!(conservative_data["candidates"], 0);
    assert_eq!(conservative_data["skipped_non_candidate_changes"], 1);
    assert_eq!(conservative_data["mode"], "suspectOnly");

    let all_mode = session.call(
        "moot_reclassify_fdc",
        &args!["mode" => "all"],
    )
    .expect("moot_reclassify_fdc all-mode dry-run must dispatch");
    let all_data = selected_data(&all_mode);
    assert_eq!(all_data["mode"], "all");
    assert_eq!(all_data["candidates"], 1);
    assert_eq!(all_data["would_update"], 1);
    assert_eq!(session_fdc_floor(&session), None, "dry-run mode=all must not stamp");
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_reclassify_fdc",
        &args!["apply" => true, "mode" => "all", "limit" => 1],
    )
    .expect("moot_reclassify_fdc limited apply must dispatch");

    assert!(is_success(&result), "apply should succeed; got: {result:?}");
    assert_eq!(
        selected_data(&result)["floor_stamp"],
        "skipped: limited run cannot update estate-wide floor"
    );
    assert_eq!(session_fdc_floor(&session), None, "limited apply must not stamp estate FDC floor");
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_reclassify_fdc",
        &args!["apply" => true],
    )
    .expect("moot_reclassify_fdc conservative apply must dispatch");

    assert!(is_success(&result), "apply should succeed; got: {result:?}");
    let data = selected_data(&result);
    assert_eq!(data["skipped_non_candidate_changes"], 1);
    assert_eq!(
        data["floor_stamp"],
        "skipped: mode=all is required for an estate-wide floor"
    );
    assert_eq!(session_fdc_floor(&session), None, "conservative apply must not stamp the floor");
}

#[test]
fn estate_status_distinguishes_missing_and_stale_fdc_floors() {
    let registry = EstateRegistry::new_inmemory_bare();
    let session = SelectedV2Session::new(registry);
    let missing = session.call(
        "moot_estate_status",
        &args![],
    )
    .expect("estate status must dispatch");
    assert_eq!(selected_data(&missing)["fdc_recalculation"], "missing");

    session
        .default
        .store
        .set_meta(FDC_FLOOR_KEY, "classifier:old|frame:old|lexicon:old|signatures:old")
        .expect("stale FDC floor write must succeed");
    let stale = session.call(
        "moot_estate_status",
        &args![],
    )
    .expect("estate status must dispatch");
    assert_eq!(selected_data(&stale)["fdc_recalculation"], "stale");
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_reclassify_fdc",
        &args!["apply" => true],
    )
    .expect("moot_reclassify_fdc apply must dispatch");

    assert!(is_success(&result), "apply should succeed; got: {result:?}");
    let text = content_text(&result);
    assert!(text.contains("fdc_reclassify: applied"), "got: {text}");
    assert!(text.contains("updated: 1"), "got: {text}");

    let drawer = session_stored_drawer(&session, &id);
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_reclassify_fdc",
        &args!["apply" => true],
    )
    .expect("moot_reclassify_fdc apply must dispatch");
    assert!(is_success(&result), "apply should succeed; got: {result:?}");

    let events = session
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
    let session = SelectedV2Session::new(registry);

    let dry_run_all = || {
        let result = session.call(
            "moot_reclassify_fdc",
            &args!["mode" => "all"],
        )
        .expect("moot_reclassify_fdc dry-run must dispatch");
        assert!(is_success(&result), "dry-run should succeed; got: {result:?}");
        selected_data(&result).clone()
    };

    // (1) Invariance across repeated parallel runs.
    let first = dry_run_all();
    assert_eq!(first["scanned"], 30);
    assert_eq!(first["candidates"], 30);
    assert_eq!(first["would_update"], 30);
    assert_eq!(first["changes"].as_array().map(Vec::len), Some(25));
    assert_eq!(first["changes_omitted"], 5); // 30 − 25 examples
    for _ in 0..4 {
        assert_eq!(dry_run_all(), first, "repeated parallel dry-runs must be byte-identical");
    }

    // (2) Golden values — apply through the parallel path, then read back.
    let applied = session.call(
        "moot_reclassify_fdc",
        &args!["apply" => true, "mode" => "all"],
    )
    .expect("moot_reclassify_fdc apply must dispatch");
    assert_eq!(selected_data(&applied)["updated"], 30);
    for id in &sentinel_ids {
        assert_eq!(session_stored_fdc_code(&session, id), "000");
    }
    for id in &subject_ids {
        let code = session_stored_fdc_code(&session, id);
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
// 4. Tier 1 — Core memory
// ---------------------------------------------------------------------------

#[test]
fn file_memory_returns_id_and_room() {
    let registry = EstateRegistry::new_inmemory_bare();
    let id = file_one_memory(&registry, "Sprint review notes Q2", "work/meetings");
    assert!(!id.is_empty(), "file_memory must return a non-empty id");
}

#[test]
fn file_memory_missing_content_returns_invalid_params() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let err = session.call("moot_file_memory", &args!["location" => "work"])
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
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let result = session.call(
        "moot_file_memory",
        &args![
            "content" => "fn main() { println!(\"hello\"); }",
        "subject" => "fn main() { println!(\"hello\"); }",
            "location" => "code/snippet",
            "kind" => "code"
        ],
    ).expect("file_memory with kind=code must succeed");
    assert!(is_success(&result), "file_memory kind=code must succeed; got: {result:?}");

    // Read back the filed drawer and assert contentKind == Code.
    let coord = session.coord.lock().unwrap();
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Full;
    frame.ordering = Ordering::ByCaptureTimeDesc;
    frame.limit = Some(1);
    let drawers = coord
        .recall(&session.default.handle, frame, wall_now())
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

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let result = session.call(
        "moot_file_memory",
        &args![
            "content" => "top-secret plan details",
        "subject" => "top-secret plan details",
            "location" => "vault/plans",
            "sensitivity" => "restricted"
        ],
    ).expect("file_memory with sensitivity=restricted must succeed");
    assert!(is_success(&result), "file_memory sensitivity=restricted must succeed; got: {result:?}");

    // Recall with an explicit sensitivity=Restricted filter. The default recall
    // ceiling is `SensitivityAtMost(Elevated)`, which would exclude Restricted
    // rows — the explicit filter overrides the default so the row is visible.
    let coord = session.coord.lock().unwrap();
    let mut frame = RecallFrame::new(vec![
        Filter::Sensitivity(AdjectiveSensitivity::Restricted),
    ]);
    frame.hydration_level = HydrationLevel::Full;
    frame.ordering = Ordering::ByCaptureTimeDesc;
    frame.limit = Some(1);
    let drawers = coord
        .recall(&session.default.handle, frame, wall_now())
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
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let err = session.call(
        "moot_file_memory",
        &args![
            "content" => "some content",
        "subject" => "some content",
            "location" => "test/room",
            "kind" => "notAKind"
        ],
    ).expect_err("unknown kind must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn file_memory_unknown_sensitivity_returns_invalid_params() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let err = session.call(
        "moot_file_memory",
        &args![
            "content" => "some content",
        "subject" => "some content",
            "location" => "test/room",
            "sensitivity" => "topSecret"
        ],
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
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    let result = session.call(
        "moot_file_memory",
        &args![
            "content" => "channel verification content",
        "subject" => "channel verification content",
            "location" => "channel/test"
        ],
    ).expect("file_memory must succeed");
    assert!(is_success(&result), "file_memory must succeed; got: {result:?}");

    let coord = session.coord.lock().unwrap();
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Full;
    frame.ordering = Ordering::ByCaptureTimeDesc;
    frame.limit = Some(1);
    let drawers = coord
        .recall(&session.default.handle, frame, wall_now())
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "unique-phrase-for-search-test"],
    )
    .expect("memory_search must not throw");
    assert!(is_success(&result));
    assert!(
        selected_data(&result)["results"].as_array().is_some_and(|rows| rows.len() == 1),
        "should find the filed memory; got: {result:?}"
    );
}

#[test]
fn memory_search_missing_query_returns_invalid_params() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let err = session.call("moot_memory_search", &args![])
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
// Without CorpusKit/SynapseKit registration (the test estate is locus-only),
// all three paths fall back to rank-normalised locus scoring, producing
// valid results. The score value is present in the output text, proving the
// recall_scored path ran (plain recall + substring did not emit scores).
#[test]
fn memory_search_with_scoring_arg_rrf_succeeds() {
    // _bare: controlled estate — the search-count assertion counts only this
    // memory, not the 7 seeded AI_Charter_Hint drawers a full provision adds.
    let registry = EstateRegistry::new_inmemory_bare();
    file_one_memory(&registry, "scoring-arg-rrf-test content", "lab/notes");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "scoring-arg-rrf-test", "scoring" => "rrf"],
    )
    .expect("memory_search with scoring=rrf must not throw");
    assert!(is_success(&result), "scoring=rrf must succeed; got: {result:?}");
    // recall_scored always returns at least one hit (the locus fallback).
    assert!(
        selected_data(&result)["results"].as_array().is_some_and(|rows| rows.len() == 1),
        "must find the filed memory; got: {result:?}"
    );
    // The scored path is proven by the S1 row's structured `score` field,
    // the same evidence the Swift reply carries (no per-row "(score:" text).
    assert!(
        selected_data(&result)["results"][0]["score"].is_number(),
        "scored recall must carry a structured score field; got: {result:?}"
    );
}

#[test]
fn memory_search_with_scoring_arg_matrix_aware_succeeds() {
    // _bare: controlled estate — the search-count assertion counts only this
    // memory, not the 7 seeded AI_Charter_Hint drawers a full provision adds.
    let registry = EstateRegistry::new_inmemory_bare();
    file_one_memory(&registry, "scoring-arg-matrixAware-test content", "lab/notes");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "scoring-arg-matrixAware-test", "scoring" => "matrixAware"],
    )
    .expect("memory_search with scoring=matrixAware must not throw");
    assert!(is_success(&result), "scoring=matrixAware must succeed; got: {result:?}");
    assert!(
        selected_data(&result)["results"].as_array().is_some_and(|rows| rows.len() == 1),
        "must find the filed memory; got: {result:?}"
    );
    // The scored path is proven by the S1 row's structured `score` field.
    assert!(
        selected_data(&result)["results"][0]["score"].is_number(),
        "scored recall must carry a structured score field; got: {result:?}"
    );
}

// M3: `scoring=discriminative` accepted as a known value and succeeds end-to-end.
//
// Without a corpus the discrimination factor is 1.0 → identical to rrf in score
// magnitude; the important assertion is that the tool does NOT return an error.
#[test]
fn memory_search_with_scoring_arg_discriminative_succeeds() {
    let registry = EstateRegistry::new_inmemory_bare();
    file_one_memory(&registry, "scoring-arg-discriminative-test content", "lab/notes");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "scoring-arg-discriminative-test", "scoring" => "discriminative"],
    )
    .expect("memory_search with scoring=discriminative must not throw");
    assert!(is_success(&result), "scoring=discriminative must succeed; got: {result:?}");
    assert!(
        selected_data(&result)["results"].as_array().is_some_and(|rows| rows.len() == 1),
        "must find the filed memory; got: {result:?}"
    );
    assert!(
        selected_data(&result)["results"][0]["score"].is_number(),
        "scored recall must carry a structured score field; got: {result:?}"
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
    let session = SelectedV2Session::new(registry);

    let err = session.call(
        "moot_memory_search",
        &args!["query" => "unknown-scoring-test", "scoring" => "magicScore"],
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
    let session = SelectedV2Session::new(registry);

    let err = session.call(
        "moot_memory_search",
        &args,
    )
    .expect_err("scoring:null must produce a transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn memory_search_null_filter_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let mut args = args!["query" => "null-filter-test"];
    args.insert("filter".to_string(), JsonValue::Null);
    let session = SelectedV2Session::new(registry);

    let err = session.call(
        "moot_memory_search",
        &args,
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "known-scoring-raw-test", "scoring" => "raw"],
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "absent-scoring-test"],
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "ordering-relevance-desc-test", "ordering" => "byRelevanceDesc"],
    )
    .expect("ordering=byRelevanceDesc must not throw transport fault");
    assert!(
        is_success(&result),
        "ordering=byRelevanceDesc must return isError:false; got: {result:?}"
    );
    assert!(
        selected_data(&result)["results"].as_array().is_some_and(|rows| rows.len() == 1),
        "byRelevanceDesc must find the filed memory; got: {result:?}"
    );
    // The scored path is proven by the S1 row's structured `score` field.
    assert!(
        selected_data(&result)["results"][0]["score"].is_number(),
        "byRelevanceDesc must route through recall_scored (structured score expected); got: {result:?}"
    );
}

#[test]
fn memory_search_ordering_by_relevance_desc_on_empty_estate_succeeds() {
    // An empty estate with ordering="byRelevanceDesc" must return isError:false
    // with 0 hits — not an invalidParams error.
    // _bare: a genuinely empty estate (no seeded wing/hint drawers) — this test
    // asserts byRelevanceDesc on an EMPTY estate returns 0 hits without error.
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "any-query", "ordering" => "byRelevanceDesc"],
    )
    .expect("ordering=byRelevanceDesc on empty estate must not throw");
    assert!(
        is_success(&result),
        "ordering=byRelevanceDesc on empty estate must be isError:false; got: {result:?}"
    );
    assert!(
        selected_data(&result)["results"].as_array().is_some_and(Vec::is_empty),
        "empty estate must return 0 memories; got: {result:?}"
    );
}

#[test]
fn memory_search_ordering_by_capture_time_desc_still_succeeds() {
    // byCaptureTimeDesc must still work unchanged after the fix.
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "ordering-by-capture-time-desc-test", "lab");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "ordering-by-capture-time-desc-test", "ordering" => "byCaptureTimeDesc"],
    )
    .expect("ordering=byCaptureTimeDesc must not throw");
    assert!(is_success(&result), "byCaptureTimeDesc must succeed; got: {result:?}");
}

#[test]
fn memory_search_ordering_by_room_asc_still_succeeds() {
    // byRoomAsc must still work unchanged after the fix.
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "ordering-by-room-asc-test", "lab/asc");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "ordering-by-room-asc-test", "ordering" => "byRoomAsc"],
    )
    .expect("ordering=byRoomAsc must not throw");
    assert!(is_success(&result), "byRoomAsc must succeed; got: {result:?}");
}

#[test]
fn memory_search_unknown_ordering_returns_invalid_params() {
    // An unknown ordering value must be rejected with invalidParams so the
    // accept-list stays narrow. This must NOT silently succeed.
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());

    let err = session.call(
        "moot_memory_search",
        &args!["query" => "test", "ordering" => "byMagicOrder"],
    )
    .expect_err("unknown ordering must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "unknown ordering must be INVALID_PARAMS; got code {}",
        err.code
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
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_get",
        &args!["memory_id" => id.as_str()],
    )
    .expect("memory_get must not throw");
    assert!(is_success(&result), "memory_get must succeed; got: {result:?}");
    assert!(
        selected_data(&result)["memories"][0]["memory_id"] == serde_json::json!(id),
        "response must echo the memory id; got: {result:?}"
    );
    assert!(
        selected_data(&result)["memories"][0]["content"] == serde_json::json!("verbatim content for memory-get test"),
        "response must include exact verbatim content; got: {result:?}"
    );
}

#[test]
fn memory_get_includes_metadata_and_linked_tunnel_summary() {
    let registry = EstateRegistry::new_inmemory_bare();
    let from_id = file_one_memory(&registry, "memory-get link source", "alpha/hub");
    let to_id = file_one_memory(&registry, "memory-get link target", "beta/spoke");
    let session = SelectedV2Session::new(registry);
    let link = session.call(
        "moot_link_memories",
        &args!["from_id" => from_id.as_str(), "to_id" => to_id.as_str(), "relationship" => "elaborates"],
    )
    .expect("link_memories must not throw");
    assert!(is_success(&link), "link_memories must succeed; got: {link:?}");

    let result = session.call(
        "moot_memory_get",
        &args!["memory_id" => from_id.as_str()],
    )
    .expect("memory_get must not throw");
    assert!(is_success(&result), "memory_get must succeed; got: {result:?}");
    assert!(
        selected_data(&result)["memories"][0]["tunnels"].as_array().is_some_and(|rows| rows.len() == 1)
            && selected_data(&result)["memories"][0]["tunnels"][0]["kind"] == serde_json::json!("elaborates"),
        "response must summarize the one linked tunnel; got: {result:?}"
    );
}

#[test]
fn memory_get_not_found_returns_standard_structured_error() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let fake_id = "ffffffff-ffff-ffff-ffff-ffffffffffff";

    let result = session.call(
        "moot_memory_get",
        &args!["memory_id" => fake_id],
    ).expect("selected v2 get returns a tool result");
    assert!(
        is_tool_error(&result) && result["structuredContent"]["error"]["code"] == serde_json::json!("memory_not_found"),
        "error must be the standard not-found shape; got: {result:?}"
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
    let session = SelectedV2Session::new(registry);
    let withdraw = session.call(
        "moot_withdraw_memory",
        &args!["memory_id" => id.as_str(), "reason" => "obsolete"],
    )
    .expect("withdraw_memory must not throw");
    assert!(is_success(&withdraw), "withdraw must succeed; got: {withdraw:?}");

    let result = session.call(
        "moot_memory_get",
        &args!["memory_id" => id.as_str()],
    ).expect("selected v2 get returns a tool result");
    assert!(
        is_tool_error(&result) && result["structuredContent"]["error"]["code"] == serde_json::json!("memory_not_found"),
        "withdrawn drawer must produce the standard not-found shape; got: {result:?}"
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






#[test]
fn memory_get_omitted_estate_id_hits_default_estate() {
    let registry = EstateRegistry::new_inmemory_bare();
    let session = SelectedV2Session::new(registry);
    let id = file_one_memory_v2(&session, "default-estate memory-get content", "lab");

    let result = session.call(
        "moot_memory_get",
        &args!["memory_id" => id.as_str()],
    )
    .expect("memory_get must not throw");
    assert!(is_success(&result), "omitted estateID must resolve to the default estate; got: {result:?}");
}

#[test]
fn memory_get_explicit_default_estate_id_is_accepted() {
    let registry = EstateRegistry::new_inmemory_bare();
    let session = SelectedV2Session::new(registry);
    let id = file_one_memory_v2(&session, "explicit-default-estate memory-get content", "lab");
    let default_id = session.default.estate_id.to_string();

    let result = session.call(
        "moot_memory_get",
        &args!["memory_id" => id.as_str(), "estate_id" => default_id.as_str()],
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
    let session = SelectedV2Session::new(registry);
    let id = file_one_memory_v2(&session, "non-default-estate memory-get content", "lab");

    let result = session.call(
        "moot_memory_get",
        &args!["memory_id" => id.as_str(), "estate_id" => other_id.to_string().as_str()],
    )
    .expect("a registered non-default estate is a public refusal result");
    assert!(is_tool_error(&result));
    assert_eq!(result["structuredContent"]["error"]["code"], "estate_unavailable");
}

#[test]
fn update_memory_confirm_mutation_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let id = file_one_memory_v2(&session, "confirm target", "lab");

    let result = session.call(
        "moot_update_memory",
        &args!["memory_id" => id.as_str(), "mutation" => "confirm"],
    )
    .expect("update_memory must not throw");
    assert!(is_success(&result), "confirm mutation must succeed; got: {result:?}");
    assert_eq!(selected_data(&result)["memory_id"], id);
}

#[test]
fn update_memory_unknown_mutation_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let id = file_one_memory_v2(&session, "mutation kind check", "lab");
    let err = session.call(
        "moot_update_memory",
        &args!["memory_id" => id.as_str(), "mutation" => "explode"],
    )
    .expect_err("unknown mutation must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn withdraw_memory_removes_from_unconfirmed_set() {
    // _bare: controlled estate — after withdrawing the one memory, search must
    // return "found 0"; the 7 seeded AI_Charter_Hint drawers would otherwise show.
    let registry = EstateRegistry::new_inmemory_bare();
    let session = SelectedV2Session::new(registry);
    let id = file_one_memory_v2(&session, "withdraw target content", "lab");

    let result = session.call(
        "moot_withdraw_memory",
        &args!["memory_id" => id.as_str(), "reason" => "obsolete"],
    )
    .expect("withdraw_memory must not throw");
    assert!(is_success(&result), "withdraw must succeed; got: {result:?}");

    // Searching for the content should return 0 results after withdrawal.
    let search = session.call(
        "moot_memory_search",
        &args!["query" => "withdraw target content"],
    )
    .expect("search must succeed");
    assert!(selected_data(&search)["results"].as_array().is_some_and(Vec::is_empty));
}


/// A lineage expunge that the audit gate refused for an accepted sibling
/// must NOT respond "erased memory <id>" — the response names the partial
/// outcome, the refused count, and the surviving ids (SPEC B-8b, MXE-FA).
/// A caller acting on this sentence is making a privacy decision on it.
/// Mirrors Swift `ErasePartialResponseTests`.


#[test]
fn confirm_memory_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let id = file_one_memory_v2(&session, "confirm shortcut target", "lab");

    let result = session.call("moot_confirm_memory", &args!["memory_id" => id.as_str()])
        .expect("confirm_memory must not throw");
    assert!(is_success(&result), "confirm_memory must succeed; got: {result:?}");
    assert_eq!(selected_data(&result)["memory_id"], id);
}

#[test]
fn move_memory_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let id = file_one_memory_v2(&session, "move target content", "old-room");

    let result = session.call(
        "moot_move_memory",
        &args!["memory_id" => id.as_str(), "wing" => "default", "room" => "new-room"],
    )
    .expect("move_memory must not throw");
    assert!(is_success(&result), "move_memory must succeed; got: {result:?}");
    assert_eq!(selected_data(&result)["memory_id"], id);
    assert_eq!(selected_data(&result)["placement"]["room"], "new-room");
}

/// Bug J regression: move_memory must honour the `wing` argument.
///
/// Files a memory into "OriginWing", then moves it to "TargetWing" via
/// `moot_move_memory`. Verifies:
///   1. The success text names both wing and room.
///   2. A recall scoped to "TargetWing" finds the memory.
///   3. A recall scoped to "OriginWing" returns zero hits.
#[test]
fn move_memory_reanchors_to_the_target_wing_durably() {
    let registry = EstateRegistry::new_inmemory_bare();
    let session = SelectedV2Session::new(registry);
    let id = file_one_memory_v2(&session, "durable target wing compass", "origin-room");

    let moved = session.call(
        "moot_move_memory",
        &args!["memory_id" => id.as_str(), "wing" => "TargetWing", "room" => "target-room"],
    ).expect("move_memory must render a public receipt");
    assert!(is_success(&moved), "move must succeed: {moved:?}");
    assert_eq!(selected_data(&moved)["placement"]["wing"], "TargetWing");
    assert_eq!(selected_data(&moved)["placement"]["room"], "target-room");

    let target = session.call(
        "moot_memory_search",
        &args!["query" => "durable target wing compass", "wing" => "TargetWing"],
    ).expect("target-wing search must render a receipt");
    assert!(is_success(&target), "target-wing search must succeed: {target:?}");
    assert!(selected_data(&target)["results"].as_array().expect("target results").iter()
        .any(|row| row["memory_id"] == id), "target wing must retain the moved memory: {target:?}");

    let origin = session.call(
        "moot_memory_search",
        &args!["query" => "durable target wing compass", "wing" => "Agentic Memory"],
    ).expect("origin-wing search must render a receipt");
    assert!(selected_data(&origin)["results"].as_array().expect("origin results").iter()
        .all(|row| row["memory_id"] != id), "origin wing must no longer expose the moved memory: {origin:?}");
}

/// Bug O regression (Rust verification): moot_memory_search with results must
/// NOT emit the "no memories matched" coaching hint.
///
/// The Rust coaching_engine already gated on "found 0 candidate memories" (not the
/// substring "0 memory"), so this test proves the invariant is preserved.
#[test]
fn memory_search_with_results_does_not_emit_a_no_results_hint() {
    let registry = EstateRegistry::new_inmemory_bare();
    let session = SelectedV2Session::new(registry);
    file_one_memory_v2(&session, "coaching-positive-control juniper", "coach-room");

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "coaching-positive-control juniper"],
    ).expect("successful selected search must render a receipt");
    assert!(is_success(&result), "search must succeed: {result:?}");
    assert!(!selected_data(&result)["results"].as_array().expect("results").is_empty(),
        "positive control must return a real row: {result:?}");
    assert!(result["structuredContent"]["hint"].is_null(),
        "a search with results must not carry the no-results hint: {result:?}");
}

// ---------------------------------------------------------------------------
// 5. Tier 2 — Connections
// ---------------------------------------------------------------------------

#[test]
fn link_memories_creates_tunnel() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let from_id = file_one_memory_v2(&session, "source memory for link", "alpha/hub");
    let to_id = file_one_memory_v2(&session, "target memory for link", "beta/spoke");

    let result = session.call(
        "moot_link_memories",
        &args![
            "from_id" => from_id.as_str(),
            "to_id" => to_id.as_str(),
            "relationship" => "elaborates"
        ],
    )
    .expect("link_memories must not throw");
    assert!(is_success(&result), "link_memories must succeed; got: {result:?}");
    assert_eq!(selected_data(&result)["kind"], "elaborates");
}

#[test]
fn link_memories_missing_from_id_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let err = session.call(
        "moot_link_memories",
        &args!["to_id" => "00000000-0000-0000-0000-000000000000", "relationship" => "elaborates"],
    )
    .expect_err("missing from_id must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn connection_search_returns_outgoing_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let from_id = file_one_memory_v2(&session, "connection search source", "search/from");
    let to_id = file_one_memory_v2(&session, "connection search target", "search/to");

    session.call(
        "moot_link_memories",
        &args!["from_id" => from_id.as_str(), "to_id" => to_id.as_str(), "relationship" => "references"],
    )
    .expect("link must succeed");

    let result = session.call(
        "moot_connection_search",
        &args!["memory_id" => from_id.as_str(), "direction" => "outgoing"],
    )
    .expect("connection_search must not throw");
    assert!(is_success(&result));
    let edges = selected_data(&result)["edges"].as_array().expect("edges array");
    assert_eq!(edges.len(), 1, "should find one outgoing connection");
    assert_eq!(edges[0]["to_id"], to_id);
}

#[test]
fn connection_map_returns_incoming_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let from_id = file_one_memory_v2(&session, "connection map source", "map/from");
    let to_id = file_one_memory_v2(&session, "connection map target", "map/to");

    session.call(
        "moot_link_memories",
        &args!["from_id" => from_id.as_str(), "to_id" => to_id.as_str(), "relationship" => "validates"],
    )
    .expect("link must succeed");

    let result = session.call(
        "moot_connection_map",
        &args!["memory_id" => to_id.as_str()],
    )
    .expect("connection_map must not throw");
    assert!(is_success(&result));
    let edges = selected_data(&result)["edges"].as_array().expect("edges array");
    assert_eq!(edges.len(), 1);
    assert_eq!(edges[0]["from_id"], from_id);
}

// ---------------------------------------------------------------------------
// 5b. Lifecycle enforcement — proposed/withdrawn/superseded tunnels must not
//     leak through moot_connection_search or moot_connection_map (FIND4).
// ---------------------------------------------------------------------------

fn insert_lifecycle_tunnel_for_session(
    session: &SelectedV2Session,
    src_drawer_id: &str,
    tgt_drawer_id: &str,
    lifecycle: locus_kit::tunnel_operational::TunnelLifecycle,
) {
    use locus_kit::tunnel::Tunnel;
    let now = aria_mcp::dispatch::wall_now();
    let (src_wing, src_room) = {
        let coord = session.coord.lock().unwrap();
        let mut frame = locus_kit::filter::RecallFrame::new(vec![]);
        frame.limit = Some(256);
        let all = coord
            .recall(&session.default.handle, frame, now)
            .expect("recall for wing resolution must succeed");
        let source = all.iter().find(|d| d.id == src_drawer_id)
            .unwrap_or_else(|| panic!("src_drawer_id {src_drawer_id} not found — file a memory first"));
        let node_names = coord.resolve_drawer_node_names(
            &session.default.handle,
            &[source.parent_node_id.clone()],
        );
        node_names
            .get(&source.parent_node_id)
            .cloned()
            .unwrap_or_else(|| ("unknown-wing".to_string(), "unknown-room".to_string()))
    };
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
        adjective_bitmap: 0,
        operational_bitmap: (lifecycle.raw_value()) << 3,
        provenance_bitmap: 0,
        added_by: "test".to_string(),
        filed_at: now,
        tombstoned_at: None,
        removed_by_batch: None,
        order_key: None,
        ext: None,
    };
    session.default.store.add_tunnel(&t).expect("add_tunnel must succeed");
}

#[test]
fn connection_search_excludes_proposed_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let src_id = file_one_memory_v2(&session, "lifecycle-cs-proposed-src", "lc/cs/proposed");
    let tgt_id = "dummy-tgt-proposed-cs";
    insert_lifecycle_tunnel_for_session(&session, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Proposed);

    let result = session.call(
        "moot_connection_search",
        &args!["memory_id" => src_id.as_str()],
    )
    .expect("connection_search must not throw");
    assert!(is_success(&result));
    assert!(selected_data(&result)["edges"].as_array().is_some_and(Vec::is_empty));
}

#[test]
fn connection_search_excludes_withdrawn_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let src_id = file_one_memory_v2(&session, "lifecycle-cs-withdrawn-src", "lc/cs/withdrawn");
    let tgt_id = "dummy-tgt-withdrawn-cs";
    insert_lifecycle_tunnel_for_session(&session, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Withdrawn);

    let result = session.call(
        "moot_connection_search",
        &args!["memory_id" => src_id.as_str()],
    )
    .expect("connection_search must not throw");
    assert!(is_success(&result));
    assert!(selected_data(&result)["edges"].as_array().is_some_and(Vec::is_empty));
}

#[test]
fn connection_search_excludes_superseded_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let src_id = file_one_memory_v2(&session, "lifecycle-cs-superseded-src", "lc/cs/superseded");
    let tgt_id = "dummy-tgt-superseded-cs";
    insert_lifecycle_tunnel_for_session(&session, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Superseded);

    let result = session.call(
        "moot_connection_search",
        &args!["memory_id" => src_id.as_str()],
    )
    .expect("connection_search must not throw");
    assert!(is_success(&result));
    assert!(selected_data(&result)["edges"].as_array().is_some_and(Vec::is_empty));
}

#[test]
fn connection_map_excludes_proposed_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let src_id = file_one_memory_v2(&session, "lifecycle-cm-proposed-src", "lc/cm/proposed");
    let tgt_id = "dummy-tgt-proposed-cm";
    insert_lifecycle_tunnel_for_session(&session, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Proposed);

    let result = session.call(
        "moot_connection_map",
        &args!["memory_id" => src_id.as_str()],
    )
    .expect("connection_map must not throw");
    assert!(is_success(&result));
    assert!(selected_data(&result)["edges"].as_array().is_some_and(Vec::is_empty));
}

#[test]
fn connection_map_excludes_withdrawn_tunnels() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let src_id = file_one_memory_v2(&session, "lifecycle-cm-withdrawn-src", "lc/cm/withdrawn");
    let tgt_id = "dummy-tgt-withdrawn-cm";
    insert_lifecycle_tunnel_for_session(&session, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Withdrawn);

    let result = session.call(
        "moot_connection_map",
        &args!["memory_id" => src_id.as_str()],
    )
    .expect("connection_map must not throw");
    assert!(is_success(&result));
    assert!(selected_data(&result)["edges"].as_array().is_some_and(Vec::is_empty));
}

#[test]
fn connection_search_returns_active_and_excludes_proposed_same_source() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let src_id = file_one_memory_v2(&session, "lifecycle-cs-mixed-src", "lc/cs/mixed");
    let tgt_active = file_one_memory_v2(&session, "lifecycle-cs-mixed-tgt-active", "lc/cs/mixed-tgt");
    let tgt_proposed = "dummy-tgt-proposed-mixed";

    // Create one active tunnel via the MCP link verb (lifecycle = active by default).
    session.call(
        "moot_link_memories",
        &args!["from_id" => src_id.as_str(), "to_id" => tgt_active.as_str(), "relationship" => "references"],
    )
    .expect("moot_link_memories must succeed");

    // Insert one proposed tunnel directly with the same source drawer.
    insert_lifecycle_tunnel_for_session(&session, &src_id, tgt_proposed, locus_kit::tunnel_operational::TunnelLifecycle::Proposed);

    let result = session.call(
        "moot_connection_search",
        &args!["memory_id" => src_id.as_str()],
    )
    .expect("connection_search must not throw");
    assert!(is_success(&result));
    let edges = selected_data(&result)["edges"].as_array().expect("edges array");
    assert_eq!(edges.len(), 1, "exactly one active tunnel must appear");
    assert_eq!(edges[0]["to_id"], tgt_active);
}

// 5c. Lifecycle enforcement — memory_get must not surface proposed/withdrawn/
//     superseded tunnels in its linked-tunnel summary (FIND4 residual).

#[test]
fn memory_get_excludes_proposed_tunnels_from_linked_summary() {
    // Capture a real drawer, insert a proposed lifecycle tunnel pointing from it,
    // then assert memory_get reports "tunnels: 0" — the proposed edge is hidden.
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let src_id = file_one_memory_v2(&session, "find4-mg-proposed-src", "lc/mg/proposed");
    let tgt_id = "dummy-tgt-proposed-mg";
    insert_lifecycle_tunnel_for_session(
        &session, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Proposed,
    );

    let result = session.call(
        "moot_memory_get",
        &args!["memory_id" => src_id.as_str()],
    )
    .expect("memory_get must not throw for a real drawer");
    assert!(is_success(&result));
    assert!(selected_data(&result)["memories"][0]["tunnels"].as_array().is_some_and(Vec::is_empty));
}

#[test]
fn memory_get_excludes_withdrawn_tunnels_from_linked_summary() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let src_id = file_one_memory_v2(&session, "find4-mg-withdrawn-src", "lc/mg/withdrawn");
    let tgt_id = "dummy-tgt-withdrawn-mg";
    insert_lifecycle_tunnel_for_session(
        &session, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Withdrawn,
    );

    let result = session.call(
        "moot_memory_get",
        &args!["memory_id" => src_id.as_str()],
    )
    .expect("memory_get must not throw for a real drawer");
    assert!(is_success(&result));
    assert!(selected_data(&result)["memories"][0]["tunnels"].as_array().is_some_and(Vec::is_empty));
}

#[test]
fn memory_get_excludes_superseded_tunnels_from_linked_summary() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let src_id = file_one_memory_v2(&session, "find4-mg-superseded-src", "lc/mg/superseded");
    let tgt_id = "dummy-tgt-superseded-mg";
    insert_lifecycle_tunnel_for_session(
        &session, &src_id, tgt_id, locus_kit::tunnel_operational::TunnelLifecycle::Superseded,
    );

    let result = session.call(
        "moot_memory_get",
        &args!["memory_id" => src_id.as_str()],
    )
    .expect("memory_get must not throw for a real drawer");
    assert!(is_success(&result));
    assert!(selected_data(&result)["memories"][0]["tunnels"].as_array().is_some_and(Vec::is_empty));
}

// ---------------------------------------------------------------------------
// 6. Tier 3 — Knowledge graph
// ---------------------------------------------------------------------------

#[test]
fn fact_search_on_empty_estate_returns_zero() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let result = session.call("moot_fact_search", &args![])
        .expect("fact_search must not throw");
    assert!(is_success(&result));
    assert!(selected_data(&result)["facts"].as_array().is_some_and(Vec::is_empty));
}

#[test]
fn fact_timeline_on_empty_estate_returns_zero() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let err = session.call("moot_fact_timeline", &args![])
        .expect_err("selected-v2 fact_timeline requires subject");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn file_fact_round_trips_through_coordinator() {
    // moot_file_fact now calls coordinator.add_kg_fact (landed via the GLK
    // write-path mission). It returns a success result carrying the filed
    // fact id; the fact is then discoverable via moot_fact_search.
    let registry = EstateRegistry::new_inmemory();
    // The substrate requires a non-empty source_drawer_id; file a memory to
    // obtain a real drawer id to use as the fact's source.
    let session = SelectedV2Session::new(registry);
    let source = file_one_memory_v2(&session, "Alice context", "people");
    let result = session.call(
        "moot_file_fact",
        &args![
            "subject" => "Alice",
            "predicate" => "worksAt",
            "object" => "Acme Corp",
            "source_memory_id" => source
        ],
    )
    .expect("file_fact must not throw transport fault");
    assert!(
        is_success(&result),
        "file_fact must return isError:false; got: {result:?}"
    );
    let filed = selected_data(&result);
    assert_eq!(filed["subject"], "Alice");
    assert_eq!(filed["predicate"], "worksAt");
    assert_eq!(filed["object"], "Acme Corp");

    // The fact is now discoverable through fact_search.
    let search = session.call("moot_fact_search", &args!["query" => "Acme"])
        .expect("fact_search must not throw");
    assert!(is_success(&search), "fact_search must succeed; got: {search:?}");
    assert_eq!(selected_data(&search)["facts"][0]["object"], "Acme Corp");
}

#[test]
fn fact_search_exact_fields_reject_substring_and_source_collisions() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    // source_id must name a drawer that exists in this estate — a fact inherits
    // its source drawer's sensitivity, so an unresolvable anchor fails the
    // write, so the two distinct sources this test needs are two real drawers.
    // The substring-collision case this test guards lives on subject_exact
    // ("ev-1" vs "ev-10"), which is unaffected.
    let mut source_ids: Vec<String> = Vec::new();
    for label in ["calendar-source", "other-source"] {
        source_ids.push(file_one_memory_v2(
            &session,
            &format!("fixture drawer {label}"),
            &format!("fixtures/{label}"),
        ));
    }
    for (subject, source) in [
        ("calendar.event.ev-1", source_ids[0].as_str()),
        ("calendar.event.ev-10", source_ids[1].as_str()),
    ] {
        let filed = session.call(
            "moot_file_fact",
            &args![
                "subject" => subject,
                "predicate" => "scheduled",
                "object" => "fixture",
                "source_memory_id" => source
            ],
        )
        .expect("file fact");
        assert!(is_success(&filed));
    }
    let search = session.call(
        "moot_fact_search",
        &args![
            "subject" => "calendar.event.ev-1",
            "predicate" => "scheduled"
        ],
    )
    .expect("exact fact search");
    let facts = selected_data(&search)["facts"].as_array().expect("facts array");
    assert_eq!(facts.len(), 1);
    assert_eq!(facts[0]["subject"], "calendar.event.ev-1");
    assert_eq!(facts[0]["source_memory_id"], source_ids[0]);
}

#[test]
fn file_fact_missing_subject_returns_invalid_params() {
    // Arg validation runs before the not-yet-supported check.
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let err = session.call(
        "moot_file_fact",
        &args!["predicate" => "worksAt", "object" => "Acme"],
    )
    .expect_err("missing subject must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

#[test]
fn retire_fact_round_trips_through_coordinator() {
    // moot_retire_fact now calls coordinator.withdraw_kg_fact. File a fact,
    // extract its id, then retire it and confirm the success message.
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let source = file_one_memory_v2(&session, "Bob context", "people");
    let filed = session.call(
        "moot_file_fact",
        &args![
            "subject" => "Bob",
            "predicate" => "manages",
            "object" => "Widgets",
            "source_memory_id" => source
        ],
    )
    .expect("file_fact must succeed");
    let fact_id = selected_data(&filed)["fact_id"]
        .as_str()
        .expect("filed fact must carry an id")
        .to_owned();

    let result = session.call("moot_retire_fact", &args!["fact_id" => fact_id.clone()])
        .expect("retire_fact must not throw transport fault");
    assert!(is_success(&result), "retire_fact must return isError:false; got: {result:?}");
    assert_eq!(selected_data(&result)["fact_id"], fact_id);
}

#[test]
fn retire_fact_missing_id_returns_invalid_params() {
    // Arg validation runs before the coordinator call.
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let err = session.call("moot_retire_fact", &args![])
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
    let session = SelectedV2Session::new(registry);
    let result = session.call(
        "moot_write_journal",
        &args!["content" => "Completed analysis of Q1 metrics"],
    )
    .expect("write_journal must not throw transport fault");
    assert!(is_success(&result), "write_journal must return isError:false; got: {result:?}");
    assert_eq!(selected_data(&result)["entry"], "Completed analysis of Q1 metrics");

    // The entry is readable back through read_journal for the same agent.
    let read = session.call("moot_read_journal", &args![])
        .expect("read_journal must not throw");
    assert!(is_success(&read), "read_journal must succeed; got: {read:?}");
    assert_eq!(selected_data(&read)["entries"][0]["entry"], "Completed analysis of Q1 metrics");
}

#[test]
fn write_journal_sending_content_not_entry_returns_invalid_params() {
    // `entry` is no longer a public argument; current selected-v2 requires
    // `content` and rejects stale names at its strict boundary.
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let err = session.call(
        "moot_write_journal",
        &args!["entry" => "wrong field name"],
    )
    .expect_err("missing entry arg must produce transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "sending stale entry instead of content must be INVALID_PARAMS; got code {}",
        err.code
    );
}

#[test]
fn read_journal_on_empty_estate_returns_zero_entries() {
    // moot_read_journal uses recall_diary_entries which is live in the Rust GLK.
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let result = session.call("moot_read_journal", &args![])
        .expect("read_journal must not throw");
    assert!(is_success(&result), "read_journal must be isError:false; got: {result:?}");
    assert!(selected_data(&result)["entries"].as_array().is_some_and(Vec::is_empty));
}

#[test]
fn read_journal_row_uses_iso8601_bracketed_timestamp() {
    // R4 parity fix: read_journal rows must use the ISO8601 bracketed format
    // "[2026-06-20T17:06:29Z]  <entry>" matching the Swift v2 result.
    // Previously: "  1781975814 | <entry>" (raw epoch seconds, pipe separator).
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);

    // Write an entry so there is a row to inspect.
    session.call(
        "moot_write_journal",
        &args!["content" => "ISO8601 timestamp parity test"],
    )
    .expect("write_journal must not throw");

    let read = session.call(
        "moot_read_journal",
        &args![],
    )
    .expect("read_journal must not throw");
    assert!(is_success(&read), "read_journal must succeed; got: {read:?}");
    let entry = &selected_data(&read)["entries"][0];
    assert_eq!(entry["entry"], "ISO8601 timestamp parity test");
    assert!(
        entry["written_at"].as_str().is_some_and(|value| value.contains('T') && value.ends_with('Z')),
        "journal row must carry an ISO-8601 timestamp: {entry:?}"
    );
}

// ---------------------------------------------------------------------------
// 7b. Finding #4 — selected-v2 limit clamping in moot_read_journal
// ---------------------------------------------------------------------------

/// limit=-1 must return invalidParams (code -32602), not all rows.
/// Before the fix, the bare `optional_integer → n as usize` cast silently
/// turned -1 into usize::MAX → `entries.truncate(usize::MAX)` is a no-op →
/// the caller could receive the entire diary table.
#[test]
fn read_journal_negative_last_n_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let result = session.call(
        "moot_read_journal",
        &args!["limit" => -1i64],
    );
    // selected-v2 validates the public limit before lower dispatch.
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

/// limit=0 must also return invalidParams (0 is not ≥ 1).
#[test]
fn read_journal_zero_last_n_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let result = session.call(
        "moot_read_journal",
        &args!["limit" => 0i64],
    );
    match result {
        Err(e) => assert_eq!(e.code, -32602),
        Ok(v) => {
            let is_error_field = v.get("isError").and_then(|v| v.as_bool()).unwrap_or(false);
            assert!(is_error_field, "limit=0 must yield an error result; got: {v:?}");
        }
    }
}

/// limit=1000 (above ceiling 500) must be silently clamped — not an error.
#[test]
fn read_journal_huge_last_n_is_clamped_silently() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let result = session.call(
        "moot_read_journal",
        &args!["limit" => 1000i64],
    )
    .expect("limit=1000 must not error — clamped to 500 silently");
    // Should be a success result (empty journal on fresh estate).
    assert!(is_success(&result), "limit=1000 must succeed; got: {result:?}");
}

// ---------------------------------------------------------------------------
// 8. Tier 5 — Estate
// ---------------------------------------------------------------------------

#[test]
fn estate_ping_returns_live_pong() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let result = session.call("moot_estate_ping", &args![])
        .expect("estate_ping must not throw");
    assert!(is_success(&result));
    assert!(
        selected_data(&result)["state"] == serde_json::json!("mounted")
            && selected_data(&result)["build_serial"].is_string(),
        "ping must return the selected-v2 mounted state and build serial; got: {result:?}"
    );
}

/// The public dispatcher accepts an explicit build serial at construction.
#[test]
fn estate_ping_includes_injected_build_serial() {
    let session = SelectedV2Session::new_with_advisories(
        EstateRegistry::new_inmemory(), "TESTSERIAL-XYZ", "", None,
    );
    let result = session.call("moot_estate_ping", &args![]).expect("estate_ping must not throw");
    assert!(is_success(&result));
    assert!(
        selected_data(&result)["build_serial"] == serde_json::json!("TESTSERIAL-XYZ"),
        "estate_ping must echo the injected serial; got: {result:?}"
    );
}

/// a non-empty version_skew string is surfaced verbatim under a
/// `version_skew:` line in both moot_estate_ping and moot_estate_status; an
/// empty string (the common case, no skew detected) omits the field.
#[test]
fn version_skew_advisory_surfaces_when_present_and_omitted_when_absent() {
    let advisory = "plugin 1.0.15 expects binary >= 1.0.15; binary is 1.0.11 -- run `mootx01 upgrade`";

    for tool in ["moot_estate_ping", "moot_estate_status"] {
        let with_skew = SelectedV2Session::new_with_advisories(
            EstateRegistry::new_inmemory(), "SERIAL", advisory, None,
        ).call(tool, &args![]).expect("dispatch must not throw");
        assert!(
            selected_data(&with_skew)["version_skew"] == serde_json::json!(advisory),
            "{tool} must surface injected version skew; got: {with_skew:?}"
        );

        let without_skew = SelectedV2Session::new_with_advisories(
            EstateRegistry::new_inmemory(), "SERIAL", "", None,
        ).call(tool, &args![]).expect("dispatch must not throw");
        assert!(
            selected_data(&without_skew).get("version_skew").is_none(),
            "{tool} must omit version_skew when host injected none; got: {without_skew:?}"
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
    use std::sync::Arc;
    let line = "v9.9.9 is available (installed 1.0.33) -- upgrade with `mootx01 upgrade`";
    let some_provider: UpdateAdvisoryProvider = Arc::new(move || Some(line.to_owned()));
    let none_provider: UpdateAdvisoryProvider = Arc::new(|| None);

    for tool in ["moot_estate_ping", "moot_estate_status"] {
        let with_update = SelectedV2Session::new_with_advisories(
            EstateRegistry::new_inmemory(), "SERIAL", "", Some(Arc::clone(&some_provider)),
        ).call(tool, &args![]).expect("dispatch must not throw");
        assert!(
            selected_data(&with_update)["update_available"] == serde_json::json!(line),
            "{tool} must surface the provider's update advisory; got: {with_update:?}"
        );

        let without_update = SelectedV2Session::new_with_advisories(
            EstateRegistry::new_inmemory(), "SERIAL", "", Some(Arc::clone(&none_provider)),
        ).call(tool, &args![]).expect("dispatch must not throw");
        assert!(
            selected_data(&without_update).get("update_available").is_none(),
            "{tool} must omit update_available when provider answers None; got: {without_update:?}"
        );
    }
}

#[test]
fn estate_map_returns_taxonomy() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    file_one_memory_v2(&session, "map test content", "alpha/notes");

    let result = session.call("moot_estate_map", &args![])
        .expect("estate_map must not throw");
    assert!(is_success(&result));
    let wings = selected_data(&result)["wings"].as_array().expect("wings array");
    assert!(
        wings.iter().flat_map(|wing| wing["rooms"].as_array().into_iter().flatten())
            .any(|room| room["memory_count"].as_u64().is_some_and(|count| count >= 1)),
        "selected estate map must expose the filed memory in its room taxonomy: {wings:?}"
    );
}

#[test]
fn estate_status_unknown_estate_id_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let result = session.call(
        "moot_estate_status",
        &args!["estate_id" => "ffffffff-ffff-ffff-ffff-ffffffffffff"],
    )
    .expect("selected-v2 unknown estate is a public refusal result");
    assert!(is_tool_error(&result));
    assert_eq!(result["structuredContent"]["error"]["code"], "estate_unavailable");
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
    let session = SelectedV2Session::new(registry);
    let result = session.call(
        "moot_federated_recall",
        &args![],
    ).expect("omitted requesterEstateID must not throw transport fault");
    assert!(
        is_tool_error(&result),
        "omitted requesterEstateID (no grant) must return isError:true; got: {result:?}"
    );
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
    let session = SelectedV2Session::new(registry);
    let result = session.call(
        "moot_federated_recall",
        &args![],
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
    // it: call register_inmemory which returns estate_id, then use the actual handle
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
    let session = SelectedV2Session::new(registry);
    let result = session.call(
        "moot_federated_recall",
        &args![],
    ).expect("granted federated_search must not throw transport fault");
    assert!(
        is_success(&result),
        "granted federated_search must return isError:false; got: {result:?}"
    );
    assert!(
        selected_data(&result)["results"].as_array().is_some_and(|rows| rows.iter().any(|row| {
            row["subject"].as_str() == Some("federated-content-row")
        })),
        "granted source must contribute its compact subject row; got: {result:?}"
    );
    let _ = source_estate_id; // registered estate used for setup
    let _ = requester_handle_uuid; // default handle UUID used for grant
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







// ---------------------------------------------------------------------------
// Vault reconcile apply path (B2-3)
// ---------------------------------------------------------------------------





// ---------------------------------------------------------------------------
// Vault reconcile defect fixes (B2-3 / VAULT-FIX-01 V1)
// ---------------------------------------------------------------------------



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


// ---------------------------------------------------------------------------
// 11. Recipe tools — success + error paths (new names)
// ---------------------------------------------------------------------------

/// Run the selected-v2 migration contract and return its winner branch id.
fn run_migration_for_confirm(session: &SelectedV2Session) -> String {
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
    let result = session.call("moot_migration_run", &a)
        .expect("moot_migration_run must succeed");
    assert!(is_success(&result), "run must succeed; got: {result:?}");
    assert!(selected_data(&result)["rankings"].is_array(), "run must project typed rankings: {result:?}");
    selected_data(&result)["winner_branch_id"].as_str()
        .expect("the selected migration run must return the winning branch id")
        .to_owned()
}

#[test]
fn run_migration_happy_path_returns_rankings() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let winner_bid = run_migration_for_confirm(&session);
    assert!(!winner_bid.is_empty(), "winner branch id must be present");
}

#[test]
fn confirm_migration_success_end_to_end() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let winner_bid = run_migration_for_confirm(&session);

    let mut a: BTreeMap<String, JsonValue> = BTreeMap::new();
    a.insert("winner_branch_id".into(), JsonValue::from(serde_json::json!(winner_bid)));
    a.insert("discard_branch_ids".into(), JsonValue::from(serde_json::json!([])));

    let result = session.call("moot_migration_confirm", &a)
        .expect("moot_migration_confirm must not throw");
    assert!(is_success(&result), "confirm must succeed; got: {result:?}");
    assert_eq!(selected_data(&result)["promoted_branch_id"], serde_json::json!(winner_bid));
}

#[test]
fn confirm_migration_missing_winner_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);
    let err = session.call("moot_migration_confirm", &args![])
        .expect_err("missing winner_branch_id must produce transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// ---------------------------------------------------------------------------
// 12. Lens tools — success + error paths (moot_lens_* prefix)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// moot_lens_partial_cue mode argument — discrimination tests
// AR_FCA_PARTIAL_CUE_MODE_001..004
//
// These tests route through the production v2 surface path. The retired lens
// renderer used the old argument key "anchorID" and did not understand
// the "mode" argument.
// The v2 path (surface.rs → V2RecallLensRequest::decode → lens_lower.rs
// CoordinatorRecallLensLower::partial_cue) uses "anchor_memory_id" and wires
// the CueMode argument.
// ---------------------------------------------------------------------------

/// Build a transient (no charter drawers) in-memory registry for partial-cue
/// mode tests.  Charter drawers seeded by `new_inmemory()` carry predictable
/// IDs (`00000000-0000-0000-0000-000000000001` etc.) and normal provenance
/// sensitivity, so they compete with the test memories and can rank first,
/// breaking the ranking assertions.  A TRANSIENT estate starts empty and only
/// contains what the test seeds, giving deterministic results.
fn new_cue_registry() -> EstateRegistry {
    EstateRegistry::new_inmemory_with(EstateOpening::TRANSIENT)
}

/// Build a single-estate v2 Dispatcher from a registry, using the same pattern
/// as aria_v2_lens_dispatch_coverage_tests.  The registry is consumed.
fn make_cue_dispatcher(registry: EstateRegistry) -> Dispatcher {
    Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None)
        .with_posture(EstatePosture::Live)
}

/// Wrap arguments into a well-formed tools/call JSON-RPC 2.0 request for the
/// v2 surface path.
fn cue_tools_call(name: &str, arguments: serde_json::Value) -> JSONRPCRequest {
    JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": { "name": name, "arguments": arguments }
    }))
    .expect("tools/call request must decode")
}

/// Dispatch through Dispatcher::handle, assert no protocol-level error, and
/// return the result value for inspection.  Protocol errors mean the tool was
/// not found or a framing error occurred — either is a hard test failure.
fn cue_dispatch_unwrap(dispatcher: &Dispatcher, request: JSONRPCRequest) -> serde_json::Value {
    let response = serde_json::to_value(dispatcher.handle(&request))
        .expect("JSONRPCResponse must serialize");
    assert!(
        response.get("error").is_none(),
        "expected a result response, not a JSON-RPC protocol error; full response: {response:?}"
    );
    response["result"].clone()
}

/// Seed a memory with a specific UDC lattice anchor and provenance sensitivity
/// directly into the default estate. Used by partial-cue mode tests to set up
/// controlled FingerprintBlock content:
/// - block0 (structure) is driven by provenance sensitivity bitmap bits
/// - block1 (concept)   is driven by the UDC lattice anchor
/// - block2 (temporal)  is driven by random lineageHash + captureWeekBucket
fn seed_cue_memory(
    registry: &EstateRegistry,
    content: &str,
    udc_code: &str,
    sensitivity: locus_kit::provenance::Sensitivity,
) -> String {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;

    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "cue-mode-test",
        LatticeAnchor::udc(udc_code),
        "aria-mcp-tests",
        "default",
    );
    frame.provenance_sensitivity = sensitivity;
    let now = aria_mcp::dispatch::wall_now();
    let coord = registry.coord.lock().unwrap();
    coord
        .capture(&registry.default.handle, frame, now)
        .expect("seed_cue_memory capture must succeed")
        .id
}

#[test]
fn lens_partial_cue_mode_feels_like_ranks_struct_match_first() {
    // AR_FCA_PARTIAL_CUE_MODE_001. feelsLike uses structure block (block0) as
    // the match dimension and concept block (block1) as the differ dimension.
    //
    // anchor: Normal sensitivity, UDC "004"
    // memA:   Normal sensitivity (same structure), UDC "530" (different concept)
    //         → feelsLike score = match_struct(1.0) * differ_concept(>0) → positive
    // memB:   Elevated sensitivity (different structure), UDC "004" (same concept)
    //         → feelsLike score = match_struct(<1) * differ_concept(0) = 0
    //
    // Expected: memA ranked first because its score > 0 while memB's score == 0.
    //
    // Routes through the selected v2 surface (`Dispatcher::handle`).
    use locus_kit::provenance::Sensitivity;

    // TRANSIENT (no charter drawers) so only the seeded memories compete.
    let registry = new_cue_registry();
    // Seed memories before consuming the registry in the dispatcher.
    let anchor_id = seed_cue_memory(&registry, "cue-mode anchor memory", "004", Sensitivity::Normal);
    let mem_a_id  = seed_cue_memory(&registry, "cue-mode feels-like target", "530", Sensitivity::Normal);
    let _mem_b_id = seed_cue_memory(&registry, "cue-mode about-this target", "004", Sensitivity::Elevated);
    let dispatcher = make_cue_dispatcher(registry);

    let result = cue_dispatch_unwrap(
        &dispatcher,
        cue_tools_call("moot_lens_partial_cue", serde_json::json!({
            "anchor_memory_id": anchor_id,
            "mode": "feelsLike",
            "limit": 5
        })),
    );

    assert!(is_success(&result), "feelsLike must succeed; got: {result:?}");
    let top_id = result["structuredContent"]["data"]["results"][0]["id"]
        .as_str()
        .expect("results[0].id must be present");
    assert_eq!(
        top_id, mem_a_id,
        "feelsLike must rank same-structure / different-concept memory first"
    );
}

#[test]
fn lens_partial_cue_mode_about_this_ranks_concept_match_first() {
    // AR_FCA_PARTIAL_CUE_MODE_002. aboutThis uses concept block (block1) as the
    // match dimension and structure block (block0) as the differ dimension.
    //
    // anchor: Normal sensitivity, UDC "004"
    // memA:   Normal sensitivity (same structure), UDC "530" (different concept)
    //         → aboutThis score = match_concept(<1) * differ_struct(0) = 0
    // memB:   Elevated sensitivity (different structure), UDC "004" (same concept)
    //         → aboutThis score = match_concept(1.0) * differ_struct(>0) → positive
    //
    // Expected: memB ranked first because its score > 0 while memA's score == 0.
    //
    // Routes through the v2 surface (Dispatcher::handle) — see
    // lens_partial_cue_mode_feels_like_ranks_struct_match_first for rationale.
    use locus_kit::provenance::Sensitivity;

    // TRANSIENT (no charter drawers) so only the seeded memories compete.
    let registry = new_cue_registry();
    let anchor_id = seed_cue_memory(&registry, "cue-mode anchor memory", "004", Sensitivity::Normal);
    let _mem_a_id = seed_cue_memory(&registry, "cue-mode feels-like target", "530", Sensitivity::Normal);
    let mem_b_id  = seed_cue_memory(&registry, "cue-mode about-this target", "004", Sensitivity::Elevated);
    let dispatcher = make_cue_dispatcher(registry);

    let result = cue_dispatch_unwrap(
        &dispatcher,
        cue_tools_call("moot_lens_partial_cue", serde_json::json!({
            "anchor_memory_id": anchor_id,
            "mode": "aboutThis",
            "limit": 5
        })),
    );

    assert!(is_success(&result), "aboutThis must succeed; got: {result:?}");
    let top_id = result["structuredContent"]["data"]["results"][0]["id"]
        .as_str()
        .expect("results[0].id must be present");
    assert_eq!(
        top_id, mem_b_id,
        "aboutThis must rank same-concept / different-structure memory first"
    );
}

#[test]
fn lens_partial_cue_mode_from_then_score_differs_from_feels_like() {
    // AR_FCA_PARTIAL_CUE_MODE_003. fromThen uses temporal block (block2, which
    // includes a random lineageHash) as the match dimension. Because lineageHashes
    // are drawn independently, match_temporal ≠ match_struct with overwhelming
    // probability, so the top result score changes between modes.
    //
    // Assertion: the score returned for the same top result differs between
    // feelsLike and fromThen runs. Probability of false failure ≈ 2^-64.
    //
    // Routes through the v2 surface (Dispatcher::handle) — see
    // lens_partial_cue_mode_feels_like_ranks_struct_match_first for rationale.
    use locus_kit::provenance::Sensitivity;

    // TRANSIENT (no charter drawers) so only the seeded memories compete.
    let registry = new_cue_registry();
    let anchor_id = seed_cue_memory(&registry, "cue-mode anchor fromThen", "004", Sensitivity::Normal);
    seed_cue_memory(&registry, "cue-mode fromThen peer", "530", Sensitivity::Normal);
    let dispatcher = make_cue_dispatcher(registry);

    let fl_result = cue_dispatch_unwrap(
        &dispatcher,
        cue_tools_call("moot_lens_partial_cue", serde_json::json!({
            "anchor_memory_id": anchor_id,
            "mode": "feelsLike",
            "limit": 5
        })),
    );

    let ft_result = cue_dispatch_unwrap(
        &dispatcher,
        cue_tools_call("moot_lens_partial_cue", serde_json::json!({
            "anchor_memory_id": anchor_id,
            "mode": "fromThen",
            "limit": 5
        })),
    );

    assert!(is_success(&fl_result), "feelsLike must succeed; got: {fl_result:?}");
    assert!(is_success(&ft_result), "fromThen must succeed; got: {ft_result:?}");

    let fl_score = fl_result["structuredContent"]["data"]["results"][0]["score"]
        .as_f64()
        .expect("feelsLike results[0].score must be present");
    let ft_score = ft_result["structuredContent"]["data"]["results"][0]["score"]
        .as_f64()
        .expect("fromThen results[0].score must be present");

    assert_ne!(
        fl_score, ft_score,
        "fromThen top score ({ft_score}) must differ from feelsLike top score ({fl_score})"
    );
}

#[test]
fn lens_partial_cue_unknown_mode_returns_invalid_params() {
    // AR_FCA_PARTIAL_CUE_MODE_004. An unknown mode value must be rejected at
    // decode time as INVALID_PARAMS — not silently coerced to a default and not
    // returned as an isError:true operational refusal.
    //
    // In the v2 surface path, V2RecallLensRequest::decode validates mode at
    // schema decode time (recall_lens.rs) and propagates a V2InvalidArgument
    // → INVALID_PARAMS. The Dispatcher::handle response therefore carries
    // `error.code == INVALID_PARAMS` rather than a `result` with isError:true.
    //
    // A valid anchor is not required — the mode guard fires at decode, before
    // the anchor is resolved.
    //
    // Routes through the v2 surface (Dispatcher::handle) — see
    // lens_partial_cue_mode_feels_like_ranks_struct_match_first for rationale.
    // TRANSIENT (no charter drawers) — the mode guard fires at decode time
    // so the estate contents do not affect the outcome.
    let registry = new_cue_registry();
    let dispatcher = make_cue_dispatcher(registry);

    let response = serde_json::to_value(
        dispatcher.handle(&cue_tools_call(
            "moot_lens_partial_cue",
            serde_json::json!({
                "anchor_memory_id": "00000000-0000-0000-0000-000000000001",
                "mode": "banana"
            }),
        ))
    )
    .expect("response must serialize");

    // Protocol-level error (not isError:true) because decode fails before the
    // tool runner is invoked.
    assert!(
        response.get("error").is_some(),
        "unknown mode must produce a protocol error response; got: {response:?}"
    );
    assert_eq!(
        response["error"]["code"],
        serde_json::json!(JSONRPCErrorCode::INVALID_PARAMS),
        "unknown mode must produce INVALID_PARAMS; got response: {response:?}"
    );
    // Parity gate: both ports must expose a machine-readable allowed list so
    // clients can enumerate valid modes without parsing the message string.
    // Both ports sort alphabetically, so order is part of the contract.
    let allowed = &response["error"]["data"]["allowed"];
    assert!(
        allowed.is_array(),
        "error data.allowed must be an array; got: {response:?}"
    );
    let allowed_values: Vec<String> = allowed
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect();
    assert_eq!(
        allowed_values,
        vec!["aboutThis", "feelsLike", "fromThen"],
        "error data.allowed must be sorted alphabetically and contain exactly the three valid mode values; got: {allowed:?}"
    );
    // Parity gate: both ports must expose a machine-readable correction hint.
    // The hint tells clients which values are valid without parsing the message.
    let correction = &response["error"]["data"]["correction"];
    assert!(
        correction.is_string() && !correction.as_str().unwrap_or("").is_empty(),
        "error data.correction must be a non-empty string; got: {response:?}"
    );
}

/// Seed a partial-cue memory with an explicit subject AND content (both non-empty,
/// deliberately different so the omit-if-equal bestSpan branch does not fire).
fn seed_cue_memory_with_subject(
    registry: &EstateRegistry,
    subject: &str,
    content: &str,
    udc_code: &str,
    sensitivity: locus_kit::provenance::Sensitivity,
) -> String {
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::frames::CaptureFrame;

    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "cue-mode-test",
        LatticeAnchor::udc(udc_code),
        "aria-mcp-tests",
        "default",
    );
    frame.subject = Some(subject.to_owned());
    frame.provenance_sensitivity = sensitivity;
    let now = aria_mcp::dispatch::wall_now();
    let coord = registry.coord.lock().unwrap();
    coord
        .capture(&registry.default.handle, frame, now)
        .expect("seed_cue_memory_with_subject capture must succeed")
        .id
}

#[test]
fn lens_partial_cue_row_carries_best_span() {
    // AR_LENS_PARTIAL_CUE_BEST_SPAN_001
    // A partial-cue result row for an admissible drawer whose subject and content
    // are different must carry bestSpan equal to the normalised content body.
    // Drives the shipped path: Dispatcher::handle → surface.rs execute_recall →
    // lens_lower.rs partial_cue → project_data LensPartialCue arm.
    //
    // Fixture:
    //   anchor: Normal, UDC "004" — probe anchor, not returned in results.
    //   peer:   Normal, UDC "530" — feelsLike score > 0 (same structure block,
    //           different concept block), so the peer appears in results.
    //   peer subject: "partial cue best span subject" (distinct from content).
    //   peer content: "partial cue best span content distinct from subject".
    //   Expected bestSpan: the normalised content string (both conditions for
    //   omission are false — content is non-empty and != subject after normalise).
    //
    // Port parity: the same expected_best_span literal must match both this
    // assertion and the Swift twin in AriaV2LensLowerTests.swift.
    use locus_kit::provenance::Sensitivity;

    // These literal strings are the wire contract. Both ports assert them.
    let expected_best_span = "partial cue best span content distinct from subject";

    let registry = new_cue_registry();
    let anchor_id = seed_cue_memory(
        &registry, "partial-cue-span-anchor", "004", Sensitivity::Normal);
    let peer_id = seed_cue_memory_with_subject(
        &registry,
        "partial cue best span subject",
        expected_best_span,
        "530",
        Sensitivity::Normal,
    );
    let dispatcher = make_cue_dispatcher(registry);

    let result = cue_dispatch_unwrap(
        &dispatcher,
        cue_tools_call("moot_lens_partial_cue", serde_json::json!({
            "anchor_memory_id": anchor_id,
            "mode": "feelsLike",
            "limit": 5
        })),
    );

    assert!(is_success(&result), "partial_cue must succeed; got: {result:?}");
    let results = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("results must be an array");

    // The anchor is not in its own cue results; the peer is the only candidate.
    let peer_row = results
        .iter()
        .find(|row| row["id"].as_str() == Some(peer_id.as_str()))
        .expect("peer must appear in partial_cue results");

    let actual_best_span = peer_row["bestSpan"]
        .as_str()
        .expect("peer row must carry bestSpan — partial_cue must hydrate it");
    assert_eq!(
        actual_best_span, expected_best_span,
        "bestSpan must equal the normalised content body; got: {actual_best_span:?}"
    );
}

#[test]
fn partial_cue_row_keys_and_ssc_facts_match_port_contract() {
    use locus_kit::provenance::Sensitivity;

    let expected_keys = ["bestSpan", "eventTime", "id", "room", "score", "sscFacts", "subject"];
    let expected_ssc_facts = "kind: meeting, entity: row parity";
    let registry = new_cue_registry();
    let anchor_id = seed_cue_memory(
        &registry, "partial-cue-row-contract-anchor", "004", Sensitivity::Normal);
    let peer_id = seed_cue_memory_with_subject(
        &registry,
        "partial cue row contract subject",
        "partial cue row contract content",
        "530",
        Sensitivity::Normal,
    );
    {
        let coord = registry.coord.lock().unwrap();
        let estate = coord.estate_for(&registry.default.handle).expect("estate");
        estate
            .set_ssc_facts(&peer_id, Some(expected_ssc_facts))
            .expect("set peer SSC facts");
    }
    let dispatcher = make_cue_dispatcher(registry);

    let result = cue_dispatch_unwrap(
        &dispatcher,
        cue_tools_call("moot_lens_partial_cue", serde_json::json!({
            "anchor_memory_id": anchor_id,
            "mode": "feelsLike",
            "limit": 5
        })),
    );

    assert!(is_success(&result), "partial_cue must succeed; got: {result:?}");
    let results = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("results must be an array");
    let peer_row = results
        .iter()
        .find(|row| row["id"].as_str() == Some(peer_id.as_str()))
        .expect("peer must appear in partial_cue results");
    let mut actual_keys: Vec<&str> = peer_row
        .as_object()
        .expect("peer row must be an object")
        .keys()
        .map(String::as_str)
        .collect();
    actual_keys.sort_unstable();
    assert_eq!(actual_keys, expected_keys);
    assert_eq!(peer_row["sscFacts"], serde_json::json!(expected_ssc_facts));
}

#[test]
fn partial_cue_row_omits_subject_key_when_drawer_has_none() {
    // AR_LENS_PARTIAL_CUE_ABSENT_SUBJECT_001 (Rust port)
    // A partial-cue result row for an admissible drawer that has no stored
    // subject must carry no "subject" key at all — not "(no subject)", not
    // an empty string, not null. Swift's partialCueOutcome passes
    // drawer.subject through privacy projection to structuredRowObject, which
    // omits the key when nil. Both ports must agree.
    //
    // Drives the shipped path: Dispatcher::handle → surface.rs execute_recall
    // → lens_lower.rs partial_cue → structured_drawers_by_id.
    //
    // Neuter gate: if structured_drawers_by_id substitutes NO_SUBJECT_MARKER
    // ("(no subject)") the assertion fires because the key is present.
    use locus_kit::provenance::Sensitivity;

    let registry = new_cue_registry();
    let anchor_id = seed_cue_memory(
        &registry, "absent-subject-anchor", "004", Sensitivity::Normal);
    // Peer has no subject — seed_cue_memory does not set CaptureFrame.subject.
    let peer_id = seed_cue_memory(
        &registry, "absent subject peer content", "530", Sensitivity::Normal);
    let dispatcher = make_cue_dispatcher(registry);

    let result = cue_dispatch_unwrap(
        &dispatcher,
        cue_tools_call("moot_lens_partial_cue", serde_json::json!({
            "anchor_memory_id": anchor_id,
            "mode": "feelsLike",
            "limit": 5
        })),
    );

    assert!(is_success(&result), "partial_cue must succeed; got: {result:?}");
    let results = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("results must be an array");

    let peer_row = results
        .iter()
        .find(|row| row["id"].as_str() == Some(peer_id.as_str()))
        .expect("peer must appear in partial_cue results");

    assert!(
        peer_row.get("subject").is_none(),
        "row for drawer without subject must not carry subject key; got row: {peer_row:?}"
    );
}

#[test]
fn partial_cue_row_normalises_before_truncating_best_span() {
    // AR_LENS_PARTIAL_CUE_TRUNCATION_ORDER_001 (Rust port)
    // BestSpan is normalized before it is cut at 120 grapheme clusters.
    // The order and unit are visible with collapsible whitespace before the cut
    // point and a multi-scalar emoji exactly at the boundary.
    //
    // Fixture: 50 'A's, five newlines, 100 'B's (155 chars total).
    //   normalize first: "AAAA...AAAA BBBB...BBBB" (151 graphemes)
    //   then cut:        50 A's + space + 69 B's (120 graphemes)
    //
    // Drives the shipped path: Dispatcher::handle → surface.rs execute_recall
    // → lens_lower.rs partial_cue → structured_drawers_by_id.
    //
    // Port parity: both expected literals match the Swift twin in
    // AriaV2LensLowerTests.swift partialCueRowNormalisesBeforeTruncatingBestSpan.
    use locus_kit::provenance::Sensitivity;

    // 50 A's + 5 newlines + 100 B's (155 chars; crosses the 120-char cut).
    let content = format!("{}\n\n\n\n\n{}", "A".repeat(50), "B".repeat(100));
    let expected_best_span = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
    let emoji_content = format!("{}👨‍👩‍👧‍👦TAIL", "C".repeat(119));
    let expected_emoji_best_span = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC👨‍👩‍👧‍👦";

    let registry = new_cue_registry();
    let anchor_id = seed_cue_memory(
        &registry, "truncation-order-anchor", "004", Sensitivity::Normal);
    // Peer: subject is distinct from content so the omit-if-equal branch does
    // not fire and bestSpan reaches the wire.
    let peer_id = seed_cue_memory_with_subject(
        &registry,
        "truncation order subject",
        &content,
        "530",
        Sensitivity::Normal,
    );
    let emoji_peer_id = seed_cue_memory_with_subject(
        &registry,
        "grapheme boundary subject",
        &emoji_content,
        "530",
        Sensitivity::Normal,
    );
    let dispatcher = make_cue_dispatcher(registry);

    let result = cue_dispatch_unwrap(
        &dispatcher,
        cue_tools_call("moot_lens_partial_cue", serde_json::json!({
            "anchor_memory_id": anchor_id,
            "mode": "feelsLike",
            "limit": 5
        })),
    );

    assert!(is_success(&result), "partial_cue must succeed; got: {result:?}");
    let results = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("results must be an array");

    let peer_row = results
        .iter()
        .find(|row| row["id"].as_str() == Some(peer_id.as_str()))
        .expect("peer must appear in partial_cue results");

    let actual_best_span = peer_row["bestSpan"]
        .as_str()
        .expect("peer row must carry bestSpan");
    assert_eq!(
        actual_best_span, expected_best_span,
        "bestSpan must normalize before cutting (50 A's + space + 69 B's); got: {actual_best_span:?}"
    );

    let emoji_row = results
        .iter()
        .find(|row| row["id"].as_str() == Some(emoji_peer_id.as_str()))
        .expect("emoji peer must appear in partial_cue results");
    let actual_emoji_best_span = emoji_row["bestSpan"]
        .as_str()
        .expect("emoji peer row must carry bestSpan");
    assert_eq!(
        actual_emoji_best_span, expected_emoji_best_span,
        "bestSpan must retain the complete grapheme at boundary 120; got: {actual_emoji_best_span:?}"
    );
}

// AR_LENS_PARTIAL_CUE_PROV_RESTRICTED_001
// A partial-cue result row for a provenance-restricted drawer (adjective=Normal)
// must carry the RESTRICTED_MARKER string as its subject and no bestSpan.
// The drawer passes the adjective ceiling (SensitivityAtMost(Elevated)) and
// reaches structured_drawers_by_id, which returns DrawerFill::Restricted.
// The partial_cue arm applies the four-way sensitivity-marker projection
// (matching Swift's AriaV2RecallLensPrivacy.project raw=32 arm) and emits
// the marker rather than the real subject.
//
// seed_cue_memory writes to the PROVENANCE axis (frame.provenance_sensitivity),
// not the adjective axis. Every existing call passes Sensitivity::Normal; this
// test is the first to pass Sensitivity::Restricted, which is the combination
// that opened the hole.
//
// Drives the shipped path: Dispatcher::handle → surface.rs execute_recall →
// lens_lower.rs partial_cue → structured_drawers_by_id.
#[test]
fn lens_partial_cue_provenance_restricted_row_has_restricted_marker() {
    use locus_kit::provenance::Sensitivity;

    let registry = new_cue_registry();
    let anchor_id = seed_cue_memory(&registry, "prov-restricted-cue-anchor", "004", Sensitivity::Normal);
    // Peer: provenance=Restricted, adjective=Normal (default).
    // Same UDC as anchor so feelsLike score > 0 and the peer ranks in results.
    let peer_id = seed_cue_memory(&registry, "prov-restricted peer body", "004", Sensitivity::Restricted);
    let dispatcher = make_cue_dispatcher(registry);

    let result = cue_dispatch_unwrap(
        &dispatcher,
        cue_tools_call("moot_lens_partial_cue", serde_json::json!({
            "anchor_memory_id": anchor_id,
            "mode": "feelsLike",
            "limit": 5
        })),
    );

    assert!(is_success(&result), "partial_cue must succeed; got: {result:?}");
    let results = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("results must be an array");

    let peer_row = results
        .iter()
        .find(|row| row["id"].as_str().map_or(false, |s| s.to_lowercase() == peer_id.to_lowercase()))
        .unwrap_or_else(|| panic!(
            "provenance-restricted peer must appear in results; got: {results:?}"
        ));

    // subject must be the restricted marker — literal string so a constant
    // change breaks this test in both ports simultaneously.
    assert_eq!(
        peer_row["subject"].as_str(),
        Some("[sensitivity: restricted \u{2014} content redacted]"),
        "provenance-restricted row subject must be the restricted marker; got: {peer_row:?}"
    );
    // Real body content must not appear as bestSpan.
    assert!(
        peer_row.get("bestSpan").is_none(),
        "provenance-restricted row must not expose 'bestSpan'; got: {peer_row:?}"
    );
    // id and score must still be present.
    assert!(
        peer_row.get("id").is_some(),
        "provenance-restricted row must carry 'id'; got: {peer_row:?}"
    );
}

// AR_LENS_PARTIAL_CUE_PROV_SECRET_001
// A partial-cue result row for a provenance-secret drawer (adjective=Normal)
// must carry the SECRET_MARKER string as its subject and no bestSpan.
// The drawer passes the adjective ceiling and reaches structured_drawers_by_id,
// which returns DrawerFill::Secret. The partial_cue arm applies the
// four-way sensitivity-marker projection (matching Swift's
// AriaV2RecallLensPrivacy.project raw=48 arm).
//
// Drives the shipped path: Dispatcher::handle → surface.rs execute_recall →
// lens_lower.rs partial_cue → structured_drawers_by_id.
#[test]
fn lens_partial_cue_provenance_secret_row_has_secret_marker() {
    use locus_kit::provenance::Sensitivity;

    let registry = new_cue_registry();
    let anchor_id = seed_cue_memory(&registry, "prov-secret-cue-anchor", "004", Sensitivity::Normal);
    // Peer: provenance=Secret, adjective=Normal (default).
    // Same UDC as anchor so feelsLike score > 0 and the peer ranks in results.
    let peer_id = seed_cue_memory(&registry, "prov-secret peer body", "004", Sensitivity::Secret);
    let dispatcher = make_cue_dispatcher(registry);

    let result = cue_dispatch_unwrap(
        &dispatcher,
        cue_tools_call("moot_lens_partial_cue", serde_json::json!({
            "anchor_memory_id": anchor_id,
            "mode": "feelsLike",
            "limit": 5
        })),
    );

    assert!(is_success(&result), "partial_cue must succeed; got: {result:?}");
    let results = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("results must be an array");

    let peer_row = results
        .iter()
        .find(|row| row["id"].as_str().map_or(false, |s| s.to_lowercase() == peer_id.to_lowercase()))
        .unwrap_or_else(|| panic!(
            "provenance-secret peer must appear in results; got: {results:?}"
        ));

    // subject must be the secret marker — literal string so a constant change
    // breaks this test in both ports simultaneously.
    assert_eq!(
        peer_row["subject"].as_str(),
        Some("[sensitivity: secret \u{2014} content access requires explicit grant]"),
        "provenance-secret row subject must be the secret marker; got: {peer_row:?}"
    );
    // Real body content must not appear as bestSpan.
    assert!(
        peer_row.get("bestSpan").is_none(),
        "provenance-secret row must not expose 'bestSpan'; got: {peer_row:?}"
    );
    // id and score must still be present.
    assert!(
        peer_row.get("id").is_some(),
        "provenance-secret row must carry 'id'; got: {peer_row:?}"
    );
}

// AR_LENS_PARTIAL_CUE_TRIM_ASYMMETRY_001
// Leading whitespace is removed by normalization before the 120-grapheme cut.
//
// Fixture: 10 spaces + 115 A's (125 chars total).
//   normalize first: leading spaces stripped, leaving 115 A's.
//   cut: unchanged because 115 is below the limit.
//
// Both ports assert the same 115-A literal.
//
// Port parity: the expected literal must match the Swift twin in
// AriaV2LensLowerTests.swift partialCueLeadingWhitespaceNormalisesBeforeGraphemeCut.
//
// Drives: Dispatcher::handle → surface.rs execute_recall →
// lens_lower.rs partial_cue → structured_drawers_by_id.
#[test]
fn partial_cue_leading_whitespace_normalises_before_grapheme_cut() {
    use locus_kit::provenance::Sensitivity;

    // 10 leading spaces + 115 A's = 125 chars total.
    let content = format!("{}{}", " ".repeat(10), "A".repeat(115));
    let expected_best_span = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    let registry = new_cue_registry();
    let anchor_id = seed_cue_memory(&registry, "trim-asymmetry-anchor", "004", Sensitivity::Normal);
    // Subject is distinct from content so the omit-if-equal branch does not
    // fire and bestSpan reaches the wire.
    let peer_id = seed_cue_memory_with_subject(
        &registry,
        "trim asymmetry subject",
        &content,
        "530",
        Sensitivity::Normal,
    );
    let dispatcher = make_cue_dispatcher(registry);

    let result = cue_dispatch_unwrap(
        &dispatcher,
        cue_tools_call("moot_lens_partial_cue", serde_json::json!({
            "anchor_memory_id": anchor_id,
            "mode": "feelsLike",
            "limit": 5
        })),
    );

    assert!(is_success(&result), "partial_cue must succeed; got: {result:?}");
    let results = result["structuredContent"]["data"]["results"]
        .as_array()
        .expect("results must be an array");

    let peer_row = results
        .iter()
        .find(|row| row["id"].as_str() == Some(peer_id.as_str()))
        .expect("peer must appear in partial_cue results");

    let actual_best_span = peer_row["bestSpan"]
        .as_str()
        .expect("peer row must carry bestSpan");
    assert_eq!(
        actual_best_span, expected_best_span,
        "bestSpan must be 115 A's after normalize-before-cut; got: {actual_best_span:?}"
    );
}

// R6 parity: apriori mines the estate AUDIT LOG (not drawer bitmaps)
// and renders items in the verbose Swift-matching format "Item(field: F, value: V)".
//
// When rules are produced the format must match Swift's default struct
// interpolation of `AprioriRule.antecedent[n]` ("\(item)" → "Item(field: F, value: V)").
// The old Rust compact format "F:V" must never appear in rules output.

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

/// B-10a internal-origin proof: the dream cycle writes ZERO recall-trace rows.
///
/// After filing a memory and running the dream cycle, the recall-trace table
/// count must be zero — the cycle reads estate data through `all_drawers` and
/// `all_tunnels` (no trace_limit), and writes only through `add_proposal` /
/// `add_diary_entry`. This test is the force-proof mandated by the mission gate.

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

/// With vault_on=true (the default), all vault-gated tools appear in the v2 catalog.
#[test]
fn v2_catalog_with_vault_on_includes_vault_tools() {
    let tools = selected_tools_for_registry(&selected_registry_with_vault(true));
    let arr = tools.as_array().expect("must be array");
    assert_eq!(arr.len(), 80, "vault-on must produce 80 v2 tools");
    let names: std::collections::HashSet<&str> =
        arr.iter().filter_map(|t| t["name"].as_str()).collect();
    for name in &["moot_vault_export", "moot_vault_import", "moot_vault_status",
                   "moot_vault_reconcile", "moot_vault_job"] {
        assert!(names.contains(name), "vault-on: expected {name} in v2 catalog");
    }
}

/// With vault_on=false (MOOTX01_VAULT=0), vault-gated tools are absent from the v2 catalog.
#[test]
fn v2_catalog_with_vault_off_excludes_vault_tools() {
    let tools = selected_tools_for_registry(&selected_registry_with_vault(false));
    let arr = tools.as_array().expect("must be array");
    assert_eq!(arr.len(), 73, "vault-off must produce 73 v2 tools (80 - 7 vault-gated)");
    let names: std::collections::HashSet<&str> =
        arr.iter().filter_map(|t| t["name"].as_str()).collect();
    for name in &["moot_vault_export", "moot_vault_import", "moot_vault_status",
                   "moot_vault_reconcile", "moot_vault_job", "moot_palace_import",
                   "moot_json_import"] {
        assert!(!names.contains(name), "vault-off: {name} must NOT appear in v2 catalog");
    }
    // A sample of non-vault tools must still be present.
    assert!(names.contains("moot_file_memory"), "vault-off: core tools must still be present");
    assert!(names.contains("moot_federated_recall"), "vault-off: federation recall must still be present");
    assert!(names.contains("moot_lens_keystones"), "vault-off: lens tools must still be present");
}

/// When vault is disabled (vault_on=false), calling a vault/import tool returns
/// a clear tool-level refusal (isError=true) rather than a transport fault.
/// The error message directs the user to reinstall with --vault-on.

/// When vault is enabled (vault_on=true, the default), calling a vault tool
/// proceeds to the actual vault backend (not the refusal path).
/// moot_vault_status with a non-existent path returns a tool-level success
/// (the vault has no manifest — that is a valid, non-error state).

// ---------------------------------------------------------------------------
// Wave-C drive-test fixes
// ---------------------------------------------------------------------------

/// Part 1b: file_memory with event_time ISO8601 string persists a back-dated
/// event_time. The selected-v2 decoder parses the event_time argument and
/// passes it as eventTime on the CaptureFrame.
#[test]
fn file_memory_with_event_time_is_accepted() {
    use aria_mcp::dispatch::wall_now;
    use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};

    // _bare: no seeded wing/hint drawers — a controlled single-memory estate so
    // the read-back targets this test's drawer, not a seeded AI_Charter_Hint.
    let registry = EstateRegistry::new_inmemory_bare();
    let session = SelectedV2Session::new(registry);
    // File a memory with a back-dated event_time (2020-01-01T00:00:00Z).
    let result = session.call(
        "moot_file_memory",
        &args![
            "content" => "back-dated event content",
        "subject" => "back-dated event content",
            "location" => "temporal/test",
            "event_time" => "2020-01-01T00:00:00Z"
        ],
    )
    .expect("file_memory with event_time must succeed");
    assert!(
        is_success(&result),
        "file_memory with event_time must return success; got: {result:?}"
    );
    // Confirm the drawer was stored with the provided event_time (epoch ms
    // for 2020-01-01T00:00:00Z = 1577836800000, epoch-millisecond instants).
    let coord = session.coord.lock().unwrap();
    let drawers = coord
        .recall(
            &session.default.handle,
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

#[test]
fn file_memory_with_invalid_event_time_returns_public_refusal_without_write() {
    let registry = EstateRegistry::new_inmemory_bare();
    let session = SelectedV2Session::new(registry);
    let before = session.coord.lock().unwrap()
        .all_drawers(&session.default.handle).expect("baseline drawers").len();

    let result = session.call(
        "moot_file_memory",
        &args![
            "content" => "must not be filed",
            "subject" => "must not be filed",
            "location" => "temporal/test",
            "event_time" => "not-an-instant"
        ],
    ).expect("malformed event_time must render a public refusal");
    assert!(is_tool_error(&result));
    assert_eq!(result["structuredContent"]["error"]["code"], "invalid_argument");
    assert!(result.to_string().contains("ISO-8601"));

    let after = session.coord.lock().unwrap()
        .all_drawers(&session.default.handle).expect("post-refusal drawers").len();
    assert_eq!(after, before, "decoder refusal must occur before any write");
}

/// Part 1b: file_memory with an invalid event_time string returns INVALID_PARAMS.
/// Part 2: estate_status counts only currently-believed (cluster A) drawers.
/// A superseded/withdrawn drawer must NOT be counted as active. The label
/// must be "memories: N active" (not "drawers: N").

/// Part 4: moot_lens_contradiction filed= field must be ISO8601, not an epoch int.

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

/// A memory that is already in the Rejected state cannot be rejected again.
/// This test drives a memory to Rejected via the now-legal Contested → Reject
/// path (contested memories can be judged false and rejected), then attempts a
/// second Reject and asserts the specific "already rejected" actionable message
/// is returned with no internal type names in the error text. Parity with
/// Swift's GateRejectionMessageTests.rejectedRejectEmitsActionableMessage.

/// Tombstoned row + any mutation → "memory has been permanently erased"
/// (We can't directly tombstone via update_memory, so we use moot_erase_memory
/// with confirmation and then try to update the now-tombstoned row.)

/// Verify the describe_gate_rejection parser correctly returns None for a
/// non-gate-rejection error (e.g. DrawerNotFound). The fallback message
/// must be used, not a fabricated gate-rejection phrase.

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

/// `moot_estate_map` must NOT render `_charter` anywhere — the old room name
/// is replaced by `AI_Charter_Hint`. Hint drawers appear as a normal room count.

// MARK: – Change 3: recall wing scoping — moot_memory_search

/// `moot_memory_search` without a `wing` arg must succeed unchanged.
/// Confirms the default path (no wing filter) is unbroken after the change.
#[test]
fn memory_search_without_wing_succeeds_unchanged() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "arctic fox camouflage snow winter survival", "wildlife");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "arctic fox"],
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
    file_one_memory(&registry, "bald eagle nest riverine habitat territory", "wildlife");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "bald eagle", "wing" => "Agentic Memory"],
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
    // Content lands in "Agentic Memory". "Source Corpus" has no captures.
    file_one_memory(&registry, "grey wolf pack hierarchy social structure", "wildlife");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "grey wolf", "wing" => "Source Corpus"],
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
    file_one_memory(&registry, "black bear foraging berry season omnivore", "wildlife");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_recall_precise",
        &args!["query" => "black bear", "filter" => "unconfirmed"],
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
    file_one_memory(&registry, "mountain lion cougar puma altitude range stealth", "wildlife");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_recall_precise",
        &args!["query" => "mountain lion", "filter" => "unconfirmed", "wing" => "Agentic Memory"],
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
    file_one_memory(&registry, "wolverine boreal forest solitary wide range", "wildlife");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_recall_shaped",
        &args!["query" => "wolverine", "filter" => "unconfirmed"],
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
    file_one_memory(&registry, "snowy owl arctic tundra silent flight prey", "wildlife");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_recall_shaped",
        &args!["query" => "snowy owl", "filter" => "unconfirmed", "wing" => "Agentic Memory"],
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
    let session = SelectedV2Session::new(registry);

    let err = session.call(
        "moot_memory_search",
        &args!["query" => "test", "limit" => -1_i64],
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

/// `moot_memory_search` with an over-ceiling limit succeeds (clamped to 500).
/// `moot_recall_precise` with a negative `limit` returns invalidParams.
#[test]
fn precise_recall_negative_limit_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);

    let err = session.call(
        "moot_recall_precise",
        &args!["query" => "test", "limit" => -1_i64],
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

/// `moot_recall_shaped` with a negative `limit` returns invalidParams.
#[test]
fn shaped_recall_negative_limit_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);

    let err = session.call(
        "moot_recall_shaped",
        &args!["query" => "test", "limit" => -1_i64],
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

/// `moot_recall_distilled` with zero `limit` returns invalidParams.
/// ack: "recall_distilled/v2" is required to pass the ACK gate (Wave 1 contract
/// change) so the call reaches the limit-validation guard.
#[test]
fn distilled_recall_zero_limit_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);

    let err = session.call(
        "moot_recall_distilled",
        &args!["query" => "test", "limit" => 0_i64, "ack" => "recall_distilled/v2"],
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

/// `moot_dream` with a far-future `now` (> 24 h ahead) returns invalidParams.

// ---------------------------------------------------------------------------
// clamp_limit boundary guards — Finding 3
//
// Before the fix, moot_lens_associations, moot_lens_concepts,
// moot_grounded_synthesis, and moot_federated_search read the `limit` arg
// without routing through clamp_limit. Negative or over-ceiling values
// could reach the substrate raw, bypassing the [1, 500] safety boundary.
// ---------------------------------------------------------------------------

/// `moot_synthesize` (grounded synthesis) with a negative `limit` must return invalidParams.
#[test]
fn grounded_synthesis_negative_limit_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);

    let err = session.call(
        "moot_synthesize",
        &args!["limit" => -1_i64],
    ).unwrap_err();
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS,
        "negative limit on moot_synthesize must yield invalidParams; message: {}", err.message);
}

#[test]
fn synthesize_with_unknown_estate_returns_public_refusal() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let result = session.call(
        "moot_synthesize",
        &args![
            "query" => "carbon compounds",
            "estate_id" => "ffffffff-ffff-ffff-ffff-ffffffffffff"
        ],
    ).expect("unknown selected estate must render a public refusal");
    assert!(is_tool_error(&result));
    assert_eq!(result["structuredContent"]["error"]["code"], "estate_unavailable");
}

#[test]
fn selected_synthesis_ranks_cue_matches_before_unrelated_rows() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "carbon chemistry of organic compounds", "recipe-tests");
    file_one_memory(&registry, "carbon based biochemistry of life", "recipe-tests");
    file_one_memory(&registry, "quantum mechanics fundamentals", "recipe-tests");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_synthesize",
        &args!["query" => "carbon compounds", "filter" => "unconfirmed"],
    ).expect("selected synthesis dispatch");
    assert!(is_success(&result), "synthesis must succeed: {result:?}");
    let rows = selected_data(&result)["results"].as_array().expect("typed results");
    let first = rows.first().and_then(|row| row["excerpt"].as_str()).unwrap_or("");
    assert!(first.contains("carbon"), "cue-matched row must rank first: {result:?}");
}

/// `query` scopes the recalled pool: only memories whose content matches a
/// distinctive term feed the synthesis, and the response names the cue (a
/// grounded synthesis and an estate digest are different measurements).
/// Twin of Swift `testGroundedSynthesisQueryScopesTheRecalledPool`.
/// Provenance Restricted/Secret is a separate axis from the adjective
/// sensitivity enforced by RecallFrame. Synthesis must gate that axis before
/// verbatim key-insight excerpts are produced.
#[test]
fn grounded_synthesis_does_not_expose_provenance_sensitive_rows() {
    let registry = EstateRegistry::new_inmemory_bare();
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

    let session = SelectedV2Session::new(registry);
    let result = session.call(
        "moot_synthesize",
        &args!["query" => "aardvark synthesis", "filter" => "unconfirmed"],
    )
    .expect("synthesis should succeed after gated rows are removed");
    let text = content_text(&result);
    assert!(is_success(&result));
    assert!(
        !text.contains("classified aardvark synthesis token"),
        "provenance-sensitive content must not reach the candidate section: {text}"
    );
}

/// Mixed-pool case: one normal row and one provenance-restricted row.
/// The gate must silently remove the restricted row from synthesis and
/// pass the normal row through into keyInsights. A gate that blocks
/// everything (including normal rows) must FAIL this test — the gate
/// covers provenance bits 30–35, not the adjective axis.
/// Twin of Swift `testSynthesizeDoesNotExposeProvenanceSensitiveRows`.
/// The bridge scenario recall_connected exists for: an answer memory
/// sharing NO words with the query, reachable only through a
/// moot_link_memories tunnel from the hop-1 memory. Plain similarity
/// cannot surface it; the walk must. Twin of Swift
/// `testConnectedRecallReachesBridgeLinkedAnswer`.
#[test]
fn connected_recall_reaches_bridge_linked_answer() {
    use locus_kit::frames::TunnelCaptureFrame;

    let registry = EstateRegistry::new_inmemory();
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

    let session = SelectedV2Session::new(registry);
    let result = session.call(
        "moot_recall_connected",
        &args!["query" => "Melanie sister Cambridge", "wing" => "recipe-tests",
               "filter" => "unconfirmed", "limit" => 10_i64],
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let ids = selected_result_ids(&result);
    assert!(ids.contains(&answer.as_str()),
        "the tunnel-linked answer must be reachable via the public v2 walk; got IDs: {ids:?}");
}

/// Gate invariant: a withdrawn memory linked by a tunnel to a live anchor must
/// NOT appear in connected-recall results. The walk discovers the edge and
/// attempts hydration; the gated RecallFrame (insert_defaults plus the
/// caller's filter) excludes the withdrawn row via CurrentlyBelieve.
/// Twin of Swift `testConnectedRecallExcludesTombstonedRows`.
#[test]
fn connected_recall_excludes_withdrawn_rows() {
    let registry = EstateRegistry::new_inmemory();

    // Dead memory — shares no words with the query; will be withdrawn.
    let dead = file_one_memory(&registry, "XylophoneZebra secret project archive notes", "recipe-tests");
    // Anchor — matches the query directly.
    let anchor = file_one_memory(&registry, "Quarterly planning moved to Thursday confirmed", "recipe-tests");
    // Distractor.
    file_one_memory(&registry, "bicycle tire pressure maintenance schedule", "recipe-tests");

    // Link dead → anchor directly with a real tunnel.  The public assertion
    // below remains at the selected v2 door; the setup bypasses only the
    // unrelated node-name topology requirement of the in-memory fixture.
    let now = aria_mcp::dispatch::wall_now();
    {
        use locus_kit::frames::TunnelCaptureFrame;
        let coord = registry.coord.lock().unwrap();
        let estate = coord.estate_for(&registry.default.handle).expect("estate must be open");
        let mut tunnel = TunnelCaptureFrame::new(
            "recipe-tests", "recipe-tests", "recipe-tests", "recipe-tests",
            "tombstone gate test link", "test",
        );
        tunnel.source_drawer_id = Some(dead.clone());
        tunnel.target_drawer_id = Some(anchor.clone());
        estate.capture_tunnel(tunnel, now).expect("tunnel capture must succeed");
    }

    let session = SelectedV2Session::new(registry);

    // Withdraw the dead memory — state transition to Withdrawn, excluded by
    // CurrentlyBelieve default filter on walk hydration.
    let withdraw = session.call(
        "moot_withdraw_memory",
        &args!["memory_id" => dead.as_str()],
    ).expect("withdraw must dispatch");
    assert!(is_success(&withdraw), "withdraw should succeed; got: {withdraw:?}");

    let result = session.call(
        "moot_recall_connected",
        &args!["query" => "quarterly planning Thursday",
               "wing" => "recipe-tests",
               "filter" => "unconfirmed", "limit" => 10_i64],
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let rows = selected_data(&result)["results"].as_array().expect("results array");
    assert!(!rows.iter().any(|row| row["id"] == dead
        || row["subject"].as_str().is_some_and(|subject| subject.contains("XylophoneZebra"))),
        "withdrawn graph row must not survive public-v2 caller-filtered hydration: {rows:?}");
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

    let session = SelectedV2Session::new(registry);
    let result = session.call(
        "moot_recall_connected",
        &args!["query" => "annual performance review scheduling",
               "wing" => "recipe-tests",
               "filter" => "unconfirmed", "limit" => 10_i64],
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let rows = selected_data(&result)["results"].as_array().expect("results array");
    assert!(!rows.iter().any(|row| row["id"] == restricted_id
        && (row.get("subject").is_some() || row.get("bestSpan").is_some())),
        "restricted row must never expose body fields after caller-filtered hydration: {rows:?}");
}

/// Shared setup for the Wave-3 G1 walk-filter tests: file an anchor (with
/// optional exportability), file a walk-only target that shares no words
/// with the query, capture a tunnel target→anchor directly (the MCP link
/// tool cannot register wing names on the in-memory estate — see the bridge
/// test above), and PROVE walk reachability with an unrestricted control
/// query before any filtered assertion. A gate test whose walk never reaches
/// the target passes vacuously; the control query removes that failure mode.
fn g1_walk_fixture(
    session: &SelectedV2Session,
    anchor_content: &str,
    anchor_exportability: Option<&str>,
    target_content: &str,
    target_exportability: Option<&str>,
    control_query: &str,
) -> (String, String) {
    use locus_kit::frames::TunnelCaptureFrame;

    let file_with = |content: &str, exportability: Option<&str>| -> String {
        file_one_memory_v2_with_exportability(session, content, "recipe-tests", exportability)
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
        let coord = session.coord.lock().unwrap();
        let locus_estate = coord.estate_for(&session.default.handle)
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
    let control = session.call(
        "moot_recall_connected",
        &args!["query" => control_query, "wing" => "recipe-tests",
               "filter" => "unconfirmed", "limit" => 10_i64],
    ).expect("control connected recall must dispatch");
    assert!(is_success(&control), "control query should succeed; got: {control:?}");
    let control_ids = selected_result_ids(&control);
    assert!(control_ids.contains(&target.as_str()),
        "FIXTURE: the walk must reach the linked target under an \
         unrestricted filter; got IDs: {control_ids:?}");

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
    let session = SelectedV2Session::new(registry);

    let (_anchor, _target) = g1_walk_fixture(
        &session,
        "Roadmap review moved to Friday afternoon confirmed", Some("public"),
        "VelvetOctopus internal pricing draft numbers", None,
        "roadmap review Friday",
    );

    let result = session.call(
        "moot_recall_connected",
        &args!["query" => "roadmap review Friday", "wing" => "recipe-tests",
               "filter" => "exportable", "limit" => 10_i64],
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let rows = selected_data(&result)["results"].as_array().expect("results array");
    // Over-gating check: the exportable anchor's content must be present.
    assert!(rows.iter().any(|row| row["subject"].as_str().is_some_and(|subject| subject.contains("Roadmap review"))),
        "exportable anchor content must be present; got: {rows:?}");
    // The private drawer's content must NOT ride in through the walk.
    assert!(!rows.iter().any(|row| row["subject"].as_str().is_some_and(|subject| subject.contains("VelvetOctopus"))),
        "non-exportable row content must be absent under filter:exportable; got: {rows:?}");
}

/// Wave-3 G1 gate invariant, confirmation axis: an unconfirmed drawer linked
/// to a user-confirmed anchor must NOT surface its content under
/// filter:"userConfirmed".
/// Twin of Swift `testConnectedRecallWalkHonorsUserConfirmedFilter`.
#[test]
fn connected_recall_walk_honors_user_confirmed_filter() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);

    let (anchor, _target) = g1_walk_fixture(
        &session,
        "Sprint retro moved to Tuesday morning confirmed", None,
        "CrimsonNarwhal draft merger term sheet notes", None,
        "sprint retro Tuesday",
    );
    let confirm = session.call(
        "moot_confirm_memory", &args!["memory_id" => anchor.as_str()],
    ).expect("confirm must dispatch");
    assert!(is_success(&confirm), "confirm_memory should succeed; got: {confirm:?}");

    let result = session.call(
        "moot_recall_connected",
        &args!["query" => "sprint retro Tuesday", "wing" => "recipe-tests",
               "filter" => "userConfirmed", "limit" => 10_i64],
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let rows = selected_data(&result)["results"].as_array().expect("results array");
    assert!(rows.iter().any(|row| row["subject"].as_str().is_some_and(|subject| subject.contains("Sprint retro"))),
        "confirmed anchor content must be present; got: {rows:?}");
    assert!(!rows.iter().any(|row| row["subject"].as_str().is_some_and(|subject| subject.contains("CrimsonNarwhal"))),
        "unconfirmed row content must be absent under filter:userConfirmed; got: {rows:?}");
}

/// Wave-3 G1 gate invariant, containment axis: a PUBLIC drawer linked to a
/// contained (born-private) anchor must NOT surface its content under
/// filter:"contained" — the inverse of the exportable test.
/// Twin of Swift `testConnectedRecallWalkHonorsContainedFilter`.
#[test]
fn connected_recall_walk_honors_contained_filter() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);

    let (_anchor, _target) = g1_walk_fixture(
        &session,
        "Standup notes archived for Thursday review", None,
        "AmberFalcon public changelog draft for the release", Some("public"),
        "standup notes Thursday",
    );

    let result = session.call(
        "moot_recall_connected",
        &args!["query" => "standup notes Thursday", "wing" => "recipe-tests",
               "filter" => "contained", "limit" => 10_i64],
    ).expect("connected recall must dispatch");
    assert!(is_success(&result), "connected recall should succeed; got: {result:?}");
    let rows = selected_data(&result)["results"].as_array().expect("results array");
    assert!(rows.iter().any(|row| row["subject"].as_str().is_some_and(|subject| subject.contains("Standup notes"))),
        "contained anchor content must be present; got: {rows:?}");
    assert!(!rows.iter().any(|row| row["subject"].as_str().is_some_and(|subject| subject.contains("AmberFalcon"))),
        "public row content must be absent under filter:contained; got: {rows:?}");
}

/// Rust half of the shared v2 connected-recall vector.  The companion Swift
/// test reads the exact same JSON and calls its public v2 dispatcher.  Keeping
/// the two assertions in one vector makes either regression observable: a wing
/// incorrectly applied to anchors loses the control anchor, while raw drawer
/// projection retains the filtered graph endpoint in the selected result set.
#[test]
fn connected_recall_matches_shared_cross_port_vector() {
    use locus_kit::frames::TunnelCaptureFrame;
    use std::{fs, path::Path};

    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    let path = Path::new(&manifest_dir)
        .parent()
        .expect("rust manifest must sit beneath AriaMcpKit")
        .join("Tests/Conformance/aria_v2_connected_recall_parity_vector.json");
    let vector: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("read shared connected-recall vector at {}: {error}", path.display())),
    )
    .expect("shared connected-recall vector must be valid JSON");
    let vector = &vector["vector"];
    let anchor_spec = &vector["anchor"];
    let target_spec = &vector["target"];
    let string = |object: &serde_json::Value, key: &str| {
        object[key]
            .as_str()
            .unwrap_or_else(|| panic!("shared vector missing string {key}"))
            .to_owned()
    };
    let expected = &vector["expected"];
    let anchor_content = string(anchor_spec, "content");
    let anchor_location = string(anchor_spec, "location");
    let target_content = string(target_spec, "content");
    let target_location = string(target_spec, "location");
    let tunnel_wing = string(vector, "tunnel_wing");
    let query = string(vector, "query");
    let control_filter = string(vector, "control_filter");
    let filtered_filter = string(vector, "filtered_filter");

    let registry = EstateRegistry::new_inmemory_bare();
    let session = SelectedV2Session::new(registry);
    let anchor = file_one_memory_v2_with_exportability(
        &session,
        &anchor_content,
        &anchor_location,
        anchor_spec["exportability"].as_str(),
    );
    let target = file_one_memory_v2_with_exportability(
        &session,
        &target_content,
        &target_location,
        target_spec["exportability"].as_str(),
    );
    {
        let coord = session.coord.lock().unwrap();
        let estate = coord.estate_for(&session.default.handle).expect("estate must be open");
        let mut tunnel = TunnelCaptureFrame::new(
            &tunnel_wing, &tunnel_wing, &tunnel_wing, &tunnel_wing,
            "shared v2 connected-recall parity tunnel", "test",
        );
        tunnel.source_drawer_id = Some(target.clone());
        tunnel.target_drawer_id = Some(anchor.clone());
        estate.capture_tunnel(tunnel, aria_mcp::dispatch::wall_now())
            .expect("shared-vector tunnel capture must succeed");
    }
    let expected_ids = |field: &str| -> std::collections::BTreeSet<String> {
        expected[field]
            .as_array()
            .unwrap_or_else(|| panic!("shared vector missing expected {field} keys"))
            .iter()
            .map(|key| match key.as_str() {
                Some("anchor") => anchor.clone(),
                Some("target") => target.clone(),
                _ => panic!("shared vector has unknown result key {key}"),
            })
            .collect()
    };

    let call = |filter: &str| session.call(
        "moot_recall_connected",
        &args![
            "query" => query.as_str(),
            "wing" => tunnel_wing.as_str(),
            "filter" => filter,
            "limit" => vector["limit"].as_i64().expect("shared vector limit")
        ],
    ).expect("shared-vector connected recall must dispatch");
    let control = call(&control_filter);
    assert!(is_success(&control), "shared-vector control must succeed: {control:?}");
    let control_ids: std::collections::BTreeSet<String> = selected_result_ids(&control)
        .into_iter().map(str::to_owned).collect();
    assert_eq!(control_ids, expected_ids("control_result_keys"),
        "wing must not scope anchor recall and control must prove tunnel reachability");

    let filtered = call(&filtered_filter);
    assert!(is_success(&filtered), "shared-vector filtered recall must succeed: {filtered:?}");
    let filtered_ids: std::collections::BTreeSet<String> = selected_result_ids(&filtered)
        .into_iter().map(str::to_owned).collect();
    assert_eq!(filtered_ids, expected_ids("filtered_result_keys"),
        "caller-filtered full hydration must omit the graph endpoint from selected v2 results");
}

/// Wing scopes the tunnel lookup only, never the anchor search.
/// A tunnel-less anchor outside the request wing must still appear in the control result.
#[test]
fn connected_recall_anchor_outside_request_wing_without_tunnel() {
    use std::{fs, path::Path};

    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    let path = Path::new(&manifest_dir)
        .parent()
        .expect("rust manifest must sit beneath AriaMcpKit")
        .join("Tests/Conformance/aria_v2_connected_recall_parity_vector.json");
    let doc: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("read shared connected-recall vector at {}: {error}", path.display())),
    )
    .expect("shared connected-recall vector must be valid JSON");
    let vec = &doc["anchor_wing_independence_vector"];
    let anchor_spec = &vec["anchor"];
    let string = |object: &serde_json::Value, key: &str| {
        object[key]
            .as_str()
            .unwrap_or_else(|| panic!("anchor-wing vector missing string {key}"))
            .to_owned()
    };
    let anchor_content = string(anchor_spec, "content");
    let anchor_location = string(anchor_spec, "location");
    let request_wing = string(vec, "request_wing");
    let query = string(vec, "query");
    let control_filter = string(vec, "control_filter");
    let limit = vec["limit"].as_i64().expect("anchor-wing vector limit");

    let registry = EstateRegistry::new_inmemory_bare();
    let session = SelectedV2Session::new(registry);
    // File the anchor in its own room; capture no tunnel so nothing bridges it into the request wing.
    let anchor = file_one_memory_v2_with_exportability(
        &session,
        &anchor_content,
        &anchor_location,
        anchor_spec["exportability"].as_str(),
    );

    // Derive the expected set from the fixture so a change to expected.control_result_keys is caught.
    let expected = &vec["expected"];
    let expected_ids = |field: &str| -> std::collections::BTreeSet<String> {
        expected[field]
            .as_array()
            .unwrap_or_else(|| panic!("anchor-wing vector missing expected {field} keys"))
            .iter()
            .map(|key| match key.as_str() {
                Some("anchor") => anchor.clone(),
                _ => panic!("anchor-wing vector has unknown result key {key}"),
            })
            .collect()
    };

    let control = session.call(
        "moot_recall_connected",
        &args![
            "query" => query.as_str(),
            "wing" => request_wing.as_str(),
            "filter" => control_filter.as_str(),
            "limit" => limit
        ],
    ).expect("anchor-wing connected recall must dispatch");
    assert!(is_success(&control), "anchor-wing control must succeed: {control:?}");
    let control_ids: std::collections::BTreeSet<String> = selected_result_ids(&control)
        .into_iter().map(str::to_owned).collect();
    assert_eq!(control_ids, expected_ids("control_result_keys"),
        "folding the request wing into the anchor filter would exclude the tunnel-less anchor; got IDs: {control_ids:?}");
}

/// A query whose every token is a stopword or too short must be rejected
/// (invalidParams), never silently degraded to an unscoped digest.
/// Twin of Swift `testGroundedSynthesisAllStopwordQueryThrowsInvalidParams`.
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
/// `moot_synthesize` with an over-ceiling `limit` must succeed (clamped).
#[test]
fn grounded_synthesis_over_ceiling_limit_is_clamped() {
    let registry = EstateRegistry::new_inmemory();
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_synthesize",
        &args!["limit" => 1_000_000_i64],
    ).expect("over-ceiling limit must not be a transport fault");
    assert!(is_success(&result) || is_tool_error(&result),
        "result must have a well-formed shape; got: {result:?}");
}

/// `moot_federated_search` with a negative `limit` must be refused as a tool error.
/// `run_federated_search` returns `error_result` (isError:true), not a transport fault.

/// `moot_federated_search` with an over-ceiling `limit` must succeed (clamped, no grant error).

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

/// moot_lens_node_motion on a Normal-sensitivity drawer must succeed.
/// Gate: Normal is bulk-exportable, so the motion analysis proceeds.

/// moot_lens_node_motion on a Restricted-sensitivity drawer must return
/// isError:true with "memory not found". The tool must not reveal that
/// the row exists at a higher sensitivity tier.

/// moot_lens_node_motion on a Secret-sensitivity drawer must return
/// isError:true with "memory not found". Secret is above the default ceiling.

/// moot_lens_node_motion on an unknown rowID must return isError:true.
/// Confirms the "not found" path for non-existent rows.

/// moot_estate_map must exclude Restricted and Secret drawers from wing/room counts.
/// Only Normal and Elevated drawers must appear in the estate map.

/// moot_estate_map must include Elevated-sensitivity drawers.
/// Elevated is within the default BitmapEvaluator ceiling.

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// SECFIX (codex: MCP fact tools leak restricted/secret KG data) — the
// contradiction lens must redact source/endpoint drawer IDs that point at
// Restricted/Secret drawers even when the emitted fact/tunnel is exportable.
// (fact_search/fact_timeline source gating already covered elsewhere; this is
// the lens residual the finding flagged.)
// ---------------------------------------------------------------------------

/// A conflicting fact pair whose SOURCE drawer is Secret: the facts themselves
/// are Normal (pass the fact ceiling) but their source id must be redacted.

/// A contradicts tunnel whose target endpoint is Secret: the tunnel is
/// exportable but the secret endpoint id must be redacted.

// ---------------------------------------------------------------------------
// sensitivity unlock — ceiling seam + read-under-grant audit wiring
// ---------------------------------------------------------------------------
//
// Mirrors Swift `SensitivityUnlockIntegrationTests.swift`. Each test uses the
// shipped control-unlock HTTP seam against the same selected-v2 dispatcher
// that serves the read, so the actual dispatcher-owned ledger is exercised.

#[test]
fn restricted_drawer_grant_makes_it_visible_in_search() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    session.call(
        "moot_file_memory",
        &args![
            "content" => "unlock-marker-restricted classified briefing",
            "subject" => "unlock-marker-restricted classified briefing",
            "location" => "vault/plans",
            "wing" => "unlock-search-wing",
            "sensitivity" => "restricted"
        ],
    ).expect("file_memory must succeed");

    // NOTE: this estate is `new_inmemory`, which seeds the seven wing organization
    // default wing-hint drawers — a single-novel-token query like
    // "unlock-marker-restricted" can still return those (degraded/fallback
    // ranking over the non-excluded pool) even though the restricted row
    // itself is correctly excluded. So the assertion checks CONTENT
    // absence, not a literal "found 0" hit count (unlike the isolated,
    // unseeded estate Swift's mirror test uses).
    let before = session.call(
        "moot_memory_search",
        &args!["query" => "unlock-marker-restricted", "wing" => "unlock-search-wing"],
    ).expect("dispatch must not throw");
    assert!(
        !before["structuredContent"]["data"]["results"].as_array()
            .is_some_and(|rows| rows.iter().any(|row| row["subject"] == "unlock-marker-restricted classified briefing")),
        "without a grant the restricted drawer must never appear; got: {before:?}"
    );

    session.unlock("restricted");
    let after = session.call(
        "moot_memory_search",
        &args!["query" => "unlock-marker-restricted", "wing" => "unlock-search-wing"],
    ).expect("dispatch must not throw");
    assert!(
        after["structuredContent"]["data"]["results"].as_array()
            .is_some_and(|rows| rows.iter().any(|row| row["subject"] == "unlock-marker-restricted classified briefing")),
        "with a live restricted grant the drawer must appear; got: {after:?}"
    );
}

#[test]
fn restricted_drawer_grant_makes_it_found_by_id() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    let filed = session.call(
        "moot_file_memory",
        &args![
            "content" => "unlock-get-marker restricted content body",
            "subject" => "unlock-get-marker restricted content body",
            "location" => "vault/plans",
            "sensitivity" => "restricted"
        ],
    ).expect("file_memory must succeed");
    let drawer_id = filed["structuredContent"]["data"]["memory_id"]
        .as_str()
        .expect("v2 file_memory must return memory_id")
        .to_owned();

    let before = session.call(
        "moot_memory_get", &args!["memory_id" => drawer_id.clone()],
    ).expect("an unavailable drawer is a v2 tool response");
    assert_eq!(
        before["structuredContent"]["error"]["code"],
        serde_json::json!("memory_not_found"),
        "without a grant, moot_memory_get must report not-found: {before:?}"
    );

    session.unlock("restricted");
    let after = session.call(
        "moot_memory_get", &args!["memory_id" => drawer_id],
    ).expect("with a live grant, moot_memory_get must find the drawer");
    assert_eq!(
        after["structuredContent"]["data"]["memories"].as_array().map(Vec::len),
        Some(1),
        "with a live grant, moot_memory_get must find the drawer: {after:?}"
    );
}

#[test]
fn restricted_read_under_grant_emits_audit_entry_via_search_and_get() {
    use genius_locus_kit::audit::UnifiedAuditVerb;

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    session.call(
        "moot_file_memory",
        &args![
            "content" => "audit-search-marker restricted content",
            "subject" => "audit-search-marker restricted content",
            "location" => "vault/plans",
            "sensitivity" => "restricted"
        ],
    ).expect("file_memory must succeed");

    session.unlock("restricted");
    session.call(
        "moot_memory_search", &args!["query" => "audit-search-marker"],
    ).expect("dispatch must not throw");

    let coord = session.coord.lock().unwrap();
    let log = coord.audit_log(&session.default.handle).expect("audit log");
    let entries: Vec<_> = log.ordered_entries().into_iter()
        .filter(|e| e.verb == UnifiedAuditVerb::SensitivityReadUnderGrant)
        .collect();
    assert_eq!(entries.len(), 1, "exactly one read-under-grant entry after one qualifying search hit");
    assert_eq!(entries[0].field_path, "restricted");
}

#[test]
fn normal_drawer_read_during_live_grant_does_not_emit_audit_entry() {
    use genius_locus_kit::audit::UnifiedAuditVerb;

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());
    session.call(
        "moot_file_memory",
        &args!["content" => "audit-normal-marker ordinary content", "subject" => "audit-normal-marker ordinary content", "location" => "vault/plans"],
    ).expect("file_memory must succeed");

    session.unlock("restricted");
    session.call(
        "moot_memory_search", &args!["query" => "audit-normal-marker"],
    ).expect("dispatch must not throw");

    let coord = session.coord.lock().unwrap();
    let log = coord.audit_log(&session.default.handle).expect("audit log");
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

/// moot_consolidate no longer dispatches anywhere — not to distill (its
/// former alias target), not to anything else. The name is reserved for the
/// multi-item consolidation feature (SPEC_DISTILLATION_STORAGE §3 Phase 2);
/// The recall_distilled tool schema carries NO "ack" property and its
/// description carries no ceremony vocabulary.
#[test]
fn recall_distilled_schema_has_no_ack_param() {
    let tools = selected_tools_for_registry(&selected_registry_with_vault(vault_enabled()));
    let arr = tools.as_array().expect("tool list must be array");
    let tool = arr.iter()
        .find(|t| t["name"].as_str() == Some("moot_recall_distilled"))
        .expect("moot_recall_distilled must appear in tools list");
    let props = &tool["inputSchema"]["properties"];
    assert!(
        props.as_object().expect("properties must be an object").get("ack").is_none(),
        "moot_recall_distilled schema must NOT have an 'ack' property; schema: {props:?}"
    );
    let desc = tool["description"].as_str().unwrap_or("");
    assert!(!desc.contains("CONTRACT CHANGE"),
        "description must carry no ceremony vocabulary; got: {desc:?}");
}

// ---------------------------------------------------------------------------
// Dream associate step (item 5) — Rust twins of the Swift
// DreamAssociatesDispatchTests. Registry estates are fully wired
// (provisioned hint drawers + vector store), so the default and "all"
// modes REALLY sweep: the report line appears with live counts, and
// "off" suppresses the step entirely.
// ---------------------------------------------------------------------------

/// `associates` with an unknown value is refused at decode time and the shipped
/// refusal is asserted through `Dispatcher::handle` — the live server route.
///
/// Entry point: `Dispatcher::handle`, so the assertion covers the refusal the
/// running server returns.
///
/// Observable: diary-entry count (strongest available).  A completed dream cycle
/// always writes at least one diary entry; a refused call writes none.  Tunnel count
/// alone is weaker because an empty estate writes zero tunnels on both a refused
/// call and a successful call with associates="all" (no proximity pairs to link).
/// Diary-entry count distinguishes "refused before any work" from "completed but
/// wrote no tunnels".  Matches the audit component of Swift's topologyChangeSignature.
///
/// Mutation gate: neutering the guard in `v2/dream.rs` lets "banana" reach the
/// execution branch, a dream cycle completes, and the diary-entry count changes —
/// failing the count assertion.
///
/// Parity: `dreamAssociatesRejectsUnknownValue` in Swift `DreamAssociatesDispatchTests.swift`.
#[test]
fn dream_associates_rejects_unknown_value() {
    let registry = EstateRegistry::new_inmemory();
    // Clone the DrawerStore Arc before moving registry into Dispatcher so we can
    // observe diary-entry count before and after the refused call without needing
    // EstateRegistry to implement Clone.  Arc::clone is a reference-count increment;
    // the store is the same allocation the Dispatcher's coordinator holds.
    let store = std::sync::Arc::clone(&registry.default.store);

    // Diary-entry count before the refused call.
    // Chosen as the observable because a completed dream cycle always writes at
    // least one diary entry, so "refused before any work" is cleanly distinguishable
    // from "completed but wrote no tunnels" (tunnel count stays 0 in both cases on
    // an empty estate).  Matches the audit component of Swift's topologyChangeSignature.
    let diary_before = store.all_diary_entries().expect("all_diary_entries before").len();

    let dispatcher = Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None);

    // "banana" is not a valid associates value.  The response must carry a
    // top-level "error" with code -32602 and data.path == "associates".
    let request = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0", "id": 1,
        "method": "tools/call",
        "params": { "name": "moot_dream", "arguments": { "associates": "banana" } }
    }))
    .expect("tools/call request must decode");
    let response = serde_json::to_value(dispatcher.handle(&request))
        .expect("response must serialize");

    // Diary-entry count after the refused call — must not have moved.
    let diary_after = store.all_diary_entries().expect("all_diary_entries after").len();

    // Assert refusal shape from the shipped path.
    assert_eq!(
        response["error"]["code"],
        serde_json::json!(-32602),
        "associates='banana' must yield -32602 INVALID_PARAMS via Dispatcher::handle; response: {response:?}"
    );
    assert_eq!(
        response["error"]["data"]["path"],
        serde_json::json!("associates"),
        "error data.path must be 'associates'; response: {response:?}"
    );

    // Parity gate: allowed list must be sorted alphabetically and match Swift's emission.
    // Both ports sort, so order is part of the contract.
    assert_eq!(
        response["error"]["data"]["allowed"],
        serde_json::json!(["all", "off", "recent"]),
        "error data.allowed must be [\"all\", \"off\", \"recent\"] (sorted); response: {response:?}"
    );

    // No execution ran — no diary entry was written.
    assert_eq!(
        diary_before,
        diary_after,
        "diary-entry count must not change when associates is refused; before={diary_before} after={diary_after}"
    );
}

/// Uppercase "OFF" is accepted for `associates` and behaves identically to
/// lowercase "off" — the `.to_lowercase()` normalisation in `V2DreamRequest::decode`
/// runs before the enum check, so "OFF" → "off" → accepted.
///
/// Mutation gate: moving `.to_lowercase()` to after the enum check (or removing it)
/// makes "OFF" fail validation with a -32602 error.
///
/// Parity: `dreamAssociatesUppercaseOffIsAccepted` in Swift `DreamAssociatesDispatchTests.swift`.
#[test]
fn dream_associates_uppercase_off_is_accepted() {
    let registry = EstateRegistry::new_inmemory();
    let dispatcher = Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None);

    let request = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0", "id": 1,
        "method": "tools/call",
        "params": {
            "name": "moot_dream",
            "arguments": { "associates": "OFF" }
        }
    }))
    .expect("tools/call request must decode");
    let response = serde_json::to_value(dispatcher.handle(&request))
        .expect("response must serialize");

    // "OFF" must not produce a protocol-level error.
    assert!(
        response.get("error").is_none(),
        "associates='OFF' must not produce a protocol error; response: {response:?}"
    );
    // "off" skips the sweep; isError must be false.
    assert_eq!(
        response["result"]["isError"],
        serde_json::json!(false),
        "associates='OFF' must succeed (isError:false); response: {response:?}"
    );
}

/// Absent `associates` and explicit `associates="recent"` take the same code path
/// (both use `DEFAULT_PROBE_LIMIT = 50`). Gate A proves this by running three dream
/// passes on a SINGLE estate: absent first, then recent, then all.
///
/// **Single-estate strategy** (why three passes on one estate, not three estates):
/// The default ensemble (RandomIndexing) trains a per-registry vocabulary; its
/// document vectors are non-deterministic across independently-constructed
/// registries because Rust's `HashMap` uses a random per-process hasher seed and
/// floating-point accumulation is sensitive to iteration order. Two independent
/// registries seeded with the same 60 items produce association counts that differ
/// by ±20-40, making an equality assertion across registries unreliable.
///
/// A single estate sidesteps this: after Pass 1 (absent, probe_limit=50) settles
/// all cluster-A association pairs, Pass 2 (recent) on the SAME estate visits the
/// same 50 probes and finds every pair already in the settled set — writing 0 new
/// associations. If recent used a different probe limit (e.g. allModeMaxProbe), it
/// would probe cluster B and charter drawers that absent never probed and write
/// new B-B / charter-charter pairs, making `recent_adds > 0` and failing Gate A.
/// Pass 3 (all) confirms the bed is discriminating: the all-mode probe set reaches
/// cluster B and charter drawers and writes new associations that the 50-probe
/// cadence never initiated.
///
/// Bed: 8 cluster B items ("quantum error qubit alignment N correction") seeded
/// first, then 52 cluster A items ("api timeout endpoint N seconds response
/// time") seeded second. `filed_at` is wall-clock capture time recorded at
/// ingest. The bench clock is NOT pinned in this test, so `filed_at` carries no
/// fixed spacing; what places the probe window is seeding ORDER, which gives
/// every cluster A drawer a later capture time than every cluster B drawer.
/// `recent_item_ids` orders by `filed_at DESC, item_id ASC`, and `item_id` is the
/// drawer UUID, so two drawers sharing a `filed_at` break arbitrarily. The bed
/// tolerates that: 52 cluster A items against probe_limit=50 leave cluster B
/// entirely unprobed however the last two cluster A items fall, and cluster B
/// is the only material the wider all-mode pass can reach.
/// Per-item event_times pin each drawer's `event_time` column, which feeds
/// temporal scoring and has no bearing on filed_at or probe selection.
///
/// Mutation gate: wiring `recent` to `DREAM_ASSOCIATE_ALL_MODE_MAX_PROBE` in
/// `v2/dream.rs` makes Pass 2 probe cluster B + charter drawers and write N > 0
/// new associations, failing `assert_eq!(recent_adds, 0)` immediately.
///
/// Parity: `dreamAssociatesAbsentAndRecentAreIdentical` in Swift.
#[test]
fn dream_associates_absent_and_recent_are_identical() {
    // Seed ONE registry with the 60-item discriminating bed.
    //
    // filed_at is wall-clock capture time at ingest and the bench clock is not
    // pinned here, so seeding ORDER is what separates the clusters: cluster B is
    // filed first and cluster A second, putting cluster B below the recency cut.
    // recent_item_ids orders by filed_at DESC, item_id ASC; item_id is the drawer
    // UUID, so a filed_at collision breaks arbitrarily. That does not matter to
    // this bed, because 52 cluster A items exceed probe_limit=50 whichever two
    // fall outside. Per-item event_times pin each drawer's event_time column,
    // which feeds temporal scoring rather than probe selection.
    let registry = EstateRegistry::new_inmemory();
    // Cluster B (older, 8 items): filed first so they fall outside the default
    // 50-probe window once cluster A's 52 items push them below the recency cut.
    for i in 1u32..=8 {
        file_one_memory_at(
            &registry,
            &format!("quantum error qubit alignment {i} correction"),
            "study",
            &format!("2026-01-01T00:00:{:02}Z", i),
        );
    }
    // Cluster A (newer, 52 items): 52 items > 50-probe limit, so the default
    // cadence probes only items from this cluster (the 50 most recent).
    for i in 1u32..=52 {
        file_one_memory_at(
            &registry,
            &format!("api timeout endpoint {i} seconds response time"),
            "api",
            &format!("2026-06-01T00:00:{:02}Z", i),
        );
    }
    let dispatcher = Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None);

    // ── Pass 1: absent associates (None path) ────────────────────────────────
    // Probes the 50 most recent items (cluster A :03Z-:52Z), writes cluster-A
    // association pairs. Non-zero result confirms the probe set is non-trivial.
    let absent_req = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0", "id": 1,
        "method": "tools/call",
        "params": { "name": "moot_dream", "arguments": { "now": "2026-08-01T00:00:00Z" } }
    }))
    .expect("absent tools/call must decode");
    let absent_resp = serde_json::to_value(dispatcher.handle(&absent_req))
        .expect("response must serialize");
    assert!(
        absent_resp.get("error").is_none(),
        "absent associates must not error; response: {absent_resp:?}"
    );
    let absent_written = absent_resp["result"]["structuredContent"]["data"]["associationsWritten"]
        .as_u64()
        .expect("absent-mode must carry associationsWritten in structuredContent.data");
    assert!(
        absent_written > 0,
        "absent-mode must write >0 associations on the seeded bed; got {absent_written}"
    );

    // ── Pass 2: explicit associates="recent" — Gate A ────────────────────────
    // Same estate, same settled set from Pass 1. If recent uses probe_limit=50
    // (same as absent), it visits the same 50 probes and finds every candidate
    // pair already settled — writes 0 new associations.
    //
    // Neuter check: if recent is wired to allModeMaxProbe it probes cluster B +
    // charter drawers (absent never probed those), writes N > 0 new associations,
    // and this assert_eq FAILS — that is the mutation gate firing correctly.
    let recent_req = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0", "id": 1,
        "method": "tools/call",
        "params": { "name": "moot_dream", "arguments": { "now": "2026-08-01T00:00:00Z", "associates": "recent" } }
    }))
    .expect("recent tools/call must decode");
    let recent_resp = serde_json::to_value(dispatcher.handle(&recent_req))
        .expect("response must serialize");
    assert!(
        recent_resp.get("error").is_none(),
        "associates=recent must not error; response: {recent_resp:?}"
    );
    let recent_adds = recent_resp["result"]["structuredContent"]["data"]["associationsWritten"]
        .as_u64()
        .expect("recent-mode must carry associationsWritten in structuredContent.data");
    // Gate A: any structural divergence between the None path and the "recent"
    // path (e.g. a different probe limit) would mean recent reaches cluster B /
    // charter items that absent did not probe and writes new associations,
    // making recent_adds > 0.
    assert_eq!(
        recent_adds, 0,
        "Gate A: recent must add ZERO new associations on an already-settled estate \
         (absent wrote {absent_written}; a non-zero recent_adds means recent probes \
         items absent did not, proving the probe limits differ)"
    );

    // ── Pass 3: associates="all" — discriminator ─────────────────────────────
    // Same estate again; settled set now contains all absent associations.
    // The all-mode probe_limit=10_000 reaches cluster B and charter drawers —
    // items the 50-probe cadence never initiated. B-B and charter-charter
    // pairs are written here, confirming the bed is wide enough that probe
    // limits are observable (all_adds > 0 means something was genuinely missed
    // by the 50-probe window).
    let all_req = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0", "id": 1,
        "method": "tools/call",
        "params": { "name": "moot_dream", "arguments": { "now": "2026-08-01T00:00:00Z", "associates": "all" } }
    }))
    .expect("all tools/call must decode");
    let all_resp = serde_json::to_value(dispatcher.handle(&all_req))
        .expect("response must serialize");
    assert!(
        all_resp.get("error").is_none(),
        "associates=all must not error; response: {all_resp:?}"
    );
    let all_adds = all_resp["result"]["structuredContent"]["data"]["associationsWritten"]
        .as_u64()
        .expect("all-mode must carry associationsWritten in structuredContent.data");
    assert!(
        all_adds > 0,
        "associates=all must write new associations beyond absent's settled set \
         (cluster B + charter items not reached by the 50-probe window); \
         all_adds={all_adds} — if 0 the bed is too small to discriminate probe limits"
    );
}

/// Uppercase "RECENT" must be accepted for `associates` and behave identically
/// to lowercase "recent" — the association sweep runs and `associationsWritten`
/// appears in the result.
///
/// Mutation gate: moving `.to_lowercase()` to after the enum check makes "RECENT"
/// fail validation with -32602.
///
/// Parity: `dreamAssociatesUppercaseRecentIsAccepted` in Swift.
#[test]
fn dream_associates_uppercase_recent_is_accepted() {
    let registry = EstateRegistry::new_inmemory();
    let dispatcher = Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None);

    let request = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0", "id": 1,
        "method": "tools/call",
        "params": {
            "name": "moot_dream",
            "arguments": { "associates": "RECENT" }
        }
    }))
    .expect("tools/call request must decode");
    let response = serde_json::to_value(dispatcher.handle(&request))
        .expect("response must serialize");

    // "RECENT" must not produce a protocol-level error.
    assert!(
        response.get("error").is_none(),
        "associates='RECENT' must not produce a protocol error; response: {response:?}"
    );
    // "recent" runs the default sweep; isError must be false.
    assert_eq!(
        response["result"]["isError"],
        serde_json::json!(false),
        "associates='RECENT' must succeed (isError:false); response: {response:?}"
    );
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

/// With the new args ABSENT the hunt report's legacy portion is exactly
/// today's report — no new vocabulary before the typed section ends —
/// and the tiered synthesis digest is APPENDED after it. The benchmark
/// parser matches the trimmed "PROPOSED "/"CANDIDATE " prefixes and the
/// count lines, so this pin is load-bearing.

/// tier=N runs a read-only purpose search: its own header, only the
/// requested section, no legacy sweep vocabulary, no synthesis-only
/// counts/timing lines, and — the contract — no writes.

/// moot_dream files tier-labeled candidates (step 3.25) and appends the
/// tiered synthesis digest through the same shared renderer.

/// The moot_review_tunnel review ladder: endorse records without
/// activating, a model objection contests or withdraws, and edge
/// activation stays user-only at the public boundary.

// ---------------------------------------------------------------------------
// Front-door family — `door` argument on moot_memory_search
// ---------------------------------------------------------------------------
//
// The `door` argument is an adjective on the recall verb (ARIA grammar).
// Precedence: explicit door arg > explicit scoring arg > A1 DoorManifest
// (provisioned) > MatrixAware.
//
// Tests:
//   A. Unknown door string → INVALID_PARAMS (fail-closed).
//   B. Reserved names "hedge"/"thorough" → INVALID_PARAMS (not yet wired).
//   C. door="guess" with no A1 config → falls back to MatrixAware, succeeds.
//   D. Known door rawValues (rrf, matrixAware, raw) succeed.
//   E. door overrides scoring when both present (no error on valid combination).

// A. Unknown door fails closed.
#[test]
fn memory_search_unknown_door_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "unknown-door-test content", "lab/notes");
    let session = SelectedV2Session::new(registry);

    let err = session.call(
        "moot_memory_search",
        &args!["query" => "unknown-door-test", "door" => "teleporter"],
    )
    .expect_err("unknown door must produce a transport fault");
    assert_eq!(
        err.code,
        JSONRPCErrorCode::INVALID_PARAMS,
        "unknown door must be INVALID_PARAMS; got code {}",
        err.code
    );
}

// B. Reserved name "hedge" is not yet wired — must fail CLOSED.
#[test]
fn memory_search_reserved_door_hedge_returns_invalid_params() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());

    let err = session.call(
        "moot_memory_search",
        &args!["query" => "hedge-test", "door" => "hedge"],
    )
    .expect_err("reserved door 'hedge' must produce a transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// B. Reserved name "thorough" is not yet wired — must fail CLOSED.
#[test]
fn memory_search_reserved_door_thorough_returns_invalid_params() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory());

    let err = session.call(
        "moot_memory_search",
        &args!["query" => "thorough-test", "door" => "thorough"],
    )
    .expect_err("reserved door 'thorough' must produce a transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// B. Null door is explicitly rejected.
#[test]
fn memory_search_null_door_returns_invalid_params() {
    let registry = EstateRegistry::new_inmemory();
    let mut args = args!["query" => "null-door-test"];
    args.insert("door".to_string(), JsonValue::Null);

    let session = SelectedV2Session::new(registry);
    let err = session.call(
        "moot_memory_search",
        &args,
    )
    .expect_err("door:null must produce a transport fault");
    assert_eq!(err.code, JSONRPCErrorCode::INVALID_PARAMS);
}

// C. door="guess" with no A1 config provisioned → falls back to MatrixAware.
#[test]
fn memory_search_door_guess_with_no_config_falls_back_to_matrix_aware() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "door-guess-no-config-test content", "lab/notes");
    let session = SelectedV2Session::new(registry);

    // No DoorManifest has been provisioned — coordinator returns Default
    // (MatrixAware). The call must succeed, not error.
    let result = session.call(
        "moot_memory_search",
        &args!["query" => "door-guess-no-config-test", "door" => "guess"],
    )
    .expect("door=guess with no config must not throw");
    assert!(
        is_success(&result),
        "door=guess with no provisioned config must succeed (fallback to MatrixAware); got: {result:?}"
    );
}

// C2. door="guess" with a provisioned DoorManifest(scoring: .rrf) routes
//     through the manifest-scoring path — the A1 per-corpus static config tier.
#[test]
fn memory_search_door_guess_with_provisioned_config_uses_manifest_scoring() {
    use genius_locus_kit::coordinator::DoorManifest;
    use genius_locus_kit::recall::GLKRecallScoring;

    let registry = EstateRegistry::new_inmemory();
    // Provision DoorManifest { scoring: Rrf } so door="guess" reads it.
    {
        let coord = registry.coord.lock().unwrap();
        let manifest = DoorManifest { scoring: GLKRecallScoring::Rrf };
        coord
            .provision_door_config(&registry.default.handle, &manifest)
            .expect("provision_door_config must succeed on in-memory estate");
    }
    file_one_memory(&registry, "door-guess-provisioned-test content", "lab/notes");
    let session = SelectedV2Session::new(registry);

    // door="guess" reads the provisioned manifest (scoring=rrf) and routes
    // through it. The call must succeed — the provisioned config must reach
    // the recall pipeline.
    let result = session.call(
        "moot_memory_search",
        &args!["query" => "door-guess-provisioned-test", "door" => "guess"],
    )
    .expect("door=guess with DoorManifest{scoring:rrf} must not throw");
    assert!(
        is_success(&result),
        "door=guess with provisioned DoorManifest(scoring:rrf) must succeed; got: {result:?}"
    );
}

// D. Known door rawValues succeed end-to-end.
#[test]
fn memory_search_door_rrf_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "door-rrf-test content", "lab/notes");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "door-rrf-test", "door" => "rrf"],
    )
    .expect("door=rrf must not throw");
    assert!(is_success(&result), "door=rrf must succeed; got: {result:?}");
}

#[test]
fn memory_search_door_matrix_aware_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "door-matrixAware-test content", "lab/notes");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "door-matrixAware-test", "door" => "matrixAware"],
    )
    .expect("door=matrixAware must not throw");
    assert!(is_success(&result), "door=matrixAware must succeed; got: {result:?}");
}

#[test]
fn memory_search_door_raw_succeeds() {
    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "door-raw-test content", "lab/notes");
    let session = SelectedV2Session::new(registry);

    let result = session.call(
        "moot_memory_search",
        &args!["query" => "door-raw-test", "door" => "raw"],
    )
    .expect("door=raw must not throw");
    assert!(is_success(&result), "door=raw must succeed; got: {result:?}");
}

// E. door overrides scoring when both are present — discriminating assertion.
//
// When door=rrf and scoring=matrixAware are both present, the door arg wins.
// rrf on unionBest mode has no distinct equal-weight RRF fusion and records
// "unionBest.rrf" in degraded_stages. matrixAware on unionBest runs the full
// matrix pipeline with no degradation. The response text therefore differs:
//   door wins (rrf)   → the `retrieval: degraded` control line (unionBest.rrf stage)
//   scoring wins (matrixAware) → no degradation line
// This discriminating assertion proves which path ran — not just that the
// call succeeded.
//
// The search is driven through the selected v2 Dispatcher.
#[test]
fn memory_search_door_overrides_scoring_when_both_present() {
    use aria_mcp::dispatcher::Dispatcher;
    use aria_mcp::jsonrpc::JSONRPCRequest;
    use serde_json::json;

    let registry = EstateRegistry::new_inmemory();
    file_one_memory(&registry, "door-overrides-scoring-test content", "lab/notes");

    // Move registry into the v2 Dispatcher after seeding.
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);
    let request = JSONRPCRequest::decode(&json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {
            "name": "moot_memory_search",
            "arguments": {
                "query": "door-overrides-scoring-test",
                "door": "rrf",
                "scoring": "matrixAware"
            }
        }
    })).expect("request decode must succeed");
    let response = serde_json::to_value(dispatcher.handle(&request))
        .expect("response serialize must succeed");

    // Response shape from Dispatcher: {"jsonrpc":"2.0","id":1,"result":{...}}
    assert!(
        response["result"]["isError"] == json!(false),
        "door takes precedence over scoring; must succeed; got: {response:?}"
    );
    // Discriminating assertion: the `retrieval: degraded` control line proves
    // door=rrf won over scoring=matrixAware (unionBest.rrf is the recorded
    // stage). If scoring won instead, the matrixAware full-pipeline path
    // would record no scoring fallback and render no degradation line.
    // Mirrors the Swift DoorDispatchTests.doorOverridesScoringWhenBothPresent twin.
    let text = response["result"]["content"][0]["text"].as_str().unwrap_or("");
    assert!(
        text.contains("retrieval: degraded"),
        "door=rrf must win over scoring=matrixAware — response must show degraded \
         retrieval; text: {text}"
    );
}

/// When both the discrimination line (explain:true) and the degradation line
/// (door=rrf → unionBest.rrf) appear in the same response, "discrimination:"
/// MUST appear before "retrieval: degraded".
///
/// Index comparison on the two substrings, not two independent contains() checks.
/// Two contains() checks cannot detect a swap; comparing the two byte offsets can.
///
/// Emission sites: AriaV2MemoryOperations.swift:738 (discrimination, under
/// explain:true) and :744 (retrieval: degraded), in that order; Rust twin at
/// core_memory.rs:619-628.
///
/// Mirrors Swift: DoorDispatchTests.controlLineOrderDiscriminationBeforeDegraded
#[test]
fn memory_search_control_line_order_discrimination_before_degraded() {
    use aria_mcp::dispatcher::Dispatcher;
    use aria_mcp::jsonrpc::JSONRPCRequest;
    use serde_json::json;

    let registry = EstateRegistry::new_inmemory();
    // Six memories are needed so the locus-rank slope is narrow enough to fire
    // discrimination with door:rrf's raw scoring path.
    //
    // Mechanics: without a registered corpus, only the locus lane fires.
    // Locus rank scores are (K-idx)/K (linearly decreasing). normalize_finals
    // min-max scales them to [0, 1]; with N hits the normalized step is
    // 1/(N-1) and top_gap = 1/(N-1). RecallDiscrimination::classify emits
    // Medium/Low only when top_gap < HIGH_MARGIN (0.25), i.e. N-1 > 4,
    // i.e. N ≥ 6. With N=3 the normalized top_gap is 0.5 → High → silent.
    let seed = "ctrl-order-test seed equal";
    for _ in 0..6 {
        file_one_memory(&registry, seed, "lab/notes");
    }

    // Move registry into the v2 Dispatcher after seeding.
    let dispatcher = Dispatcher::new(registry, "test", "test", "test", None);
    let request = JSONRPCRequest::decode(&json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {
            "name": "moot_memory_search",
            "arguments": {
                "query": "ctrl-order-test",
                "explain": true,
                "door": "rrf"
            }
        }
    }))
    .expect("request decode must succeed");
    let response = serde_json::to_value(dispatcher.handle(&request))
        .expect("response serialize must succeed");

    assert!(
        response["result"]["isError"] == json!(false),
        "explain:true + door=rrf on a seeded estate must succeed; got: {response:?}"
    );
    let text = response["result"]["content"][0]["text"].as_str().unwrap_or("");

    // Both control lines must be present; if either is missing the underlying
    // emission logic regressed independently of ordering.
    let disc_pos = text.find("discrimination:").unwrap_or_else(|| {
        panic!("discrimination: must appear in compact text; got: {text}")
    });
    let degrad_pos = text.find("retrieval: degraded").unwrap_or_else(|| {
        panic!("retrieval: degraded must appear in compact text; got: {text}")
    });

    // Index comparison: discrimination: must precede retrieval: degraded.
    // A swap of the two emission blocks passes both contains() checks but
    // fails this comparison.
    assert!(
        disc_pos < degrad_pos,
        "discrimination: must appear before retrieval: degraded — \
         emission order must match core_memory.rs:619-628; \
         disc_pos={disc_pos}, degrad_pos={degrad_pos}; text: {text}"
    );
}

// ---------------------------------------------------------------------------
// moot_file_memory under a live sensitivity grant: the write side shares the
// read side's ceiling. An omitted `sensitivity` files at the grant's tier, an
// explicit lower tier is refused with the ceiling named, an explicit higher
// tier is kept, and with no grant nothing changes. Mirrors Swift
// `FileMemorySensitivityCeilingTests.swift`. Drives the shipped unlock route
// against the selected dispatcher, as the grant-read tests above do.
// ---------------------------------------------------------------------------

/// Dispatch `moot_file_memory` through the selected dispatcher session.
fn file_memory_with_session(
    session: &SelectedV2Session,
    marker: &str,
    sensitivity: Option<&str>,
) -> Result<serde_json::Value, JSONRPCError> {
    let content = format!("{marker} checkpoint body");
    let subject = format!("{marker} checkpoint");
    let mut a = args![
        "content" => content.as_str(),
        "subject" => subject.as_str(),
        "location" => "session/ceiling-tests/checkpoint-30"
    ];
    if let Some(s) = sensitivity {
        a.insert("sensitivity".to_string(), JsonValue::from(serde_json::json!(s)));
    }
    session.call("moot_file_memory", &a)
}

/// Inspect the durable drawer after the public selected-v2 filing path.
fn drawer_containing(session: &SelectedV2Session, marker: &str) -> locus_kit::drawer::Drawer {
    let coord = session.coord.lock().unwrap();
    coord
        .all_drawers(&session.default.handle)
        .expect("all_drawers must succeed")
        .into_iter()
        .find(|drawer| drawer.content.contains(marker))
        .unwrap_or_else(|| panic!("the filed drawer containing {marker:?} must be durable"))
}

#[test]
fn file_memory_omitted_sensitivity_under_secret_grant_files_secret() {
    use locus_kit::adjectives::AdjectiveSensitivity;

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    session.unlock("secret");

    let result = file_memory_with_session(&session, "ceiling-secret-omitted", None)
        .expect("filing under a grant must dispatch");
    assert!(is_success(&result), "filing under a grant must succeed: {result:?}");
    let filed = drawer_containing(&session, "ceiling-secret-omitted");
    assert_eq!(filed.adjective_sensitivity(), AdjectiveSensitivity::Secret);
}

#[test]
fn file_memory_explicit_lower_sensitivity_under_secret_grant_is_refused_without_write() {
    use locus_kit::{
        adjectives::AdjectiveSensitivity,
        filter::{Filter, HydrationLevel, RecallFrame},
    };

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    session.unlock("secret");

    let result = file_memory_with_session(
        &session,
        "ceiling-secret-lowered",
        Some("restricted"),
    ).expect("a refusal is an isError result, not a transport fault");
    assert!(is_tool_error(&result), "a tier below the ceiling must be refused: {result:?}");

    let mut frame = RecallFrame::new(vec![Filter::SensitivityAtMost(AdjectiveSensitivity::Secret)]);
    frame.hydration_level = HydrationLevel::Full;
    frame.limit = Some(50);
    let coord = session.coord.lock().unwrap();
    let drawers = coord
        .recall(&session.default.handle, frame, aria_mcp::dispatch::wall_now())
        .expect("recall must succeed");
    assert!(
        !drawers.iter().any(|drawer| drawer.content.contains("ceiling-secret-lowered")),
        "a refused public v2 filing must not write a drawer"
    );
}

#[test]
fn file_memory_explicit_normal_under_restricted_grant_is_refused() {
    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    session.unlock("restricted");

    let result = file_memory_with_session(
        &session, "ceiling-restricted-normal", Some("normal"),
    ).expect("a refusal is an isError result, not a transport fault");
    assert!(is_tool_error(&result));
}

#[test]
fn file_memory_explicit_higher_sensitivity_under_grant_is_kept() {
    use locus_kit::adjectives::AdjectiveSensitivity;

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());
    session.unlock("restricted");

    let result = file_memory_with_session(
        &session, "ceiling-restricted-raised", Some("secret"),
    ).expect("filing above the ceiling must dispatch");
    assert!(is_success(&result), "{result:?}");
    let filed = drawer_containing(&session, "ceiling-restricted-raised");
    assert_eq!(filed.adjective_sensitivity(), AdjectiveSensitivity::Secret);
}

#[test]
fn file_memory_without_grant_is_unchanged() {
    use locus_kit::adjectives::AdjectiveSensitivity;

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());

    let result = file_memory_with_session(&session, "ceiling-no-grant", None)
        .expect("filing must dispatch");
    assert!(is_success(&result), "{result:?}");
    let filed = drawer_containing(&session, "ceiling-no-grant");
    assert_eq!(filed.adjective_sensitivity(), AdjectiveSensitivity::Normal);

    // An explicit tier is fine with no grant live.
    let explicit = file_memory_with_session(
        &session, "ceiling-no-grant-explicit", Some("normal"),
    ).expect("filing must dispatch");
    assert!(is_success(&explicit), "{explicit:?}");
}

#[test]
fn file_memory_without_live_grant_does_not_floor() {
    use locus_kit::adjectives::AdjectiveSensitivity;

    let session = SelectedV2Session::new(EstateRegistry::new_inmemory_bare());

    let result = file_memory_with_session(&session, "ceiling-secret-no-live-grant", None)
        .expect("filing must dispatch");
    assert!(is_success(&result), "{result:?}");
    let filed = drawer_containing(&session, "ceiling-secret-no-live-grant");
    assert_eq!(filed.adjective_sensitivity(), AdjectiveSensitivity::Normal);
}

// ── V2 refusal parity tests (Group B) ────────────────────────────────────────
//
// Each test fires one v2 tool — moot_file_memory, moot_update_memory,
// moot_link_memories or moot_review_tunnel — through the full
// Dispatcher::handle path with a bad enum value, and asserts that the v2
// refusal shape rule is met: both data.allowed (non-empty array) and
// data.correction (non-empty string) must be present.  Cross-port equality
// checks pin the allowed list to the same sorted values that Swift emits.

/// Dispatch moot_file_memory with the supplied arguments and return the
/// serialised response value.  Names the tool for the moot_file_memory parity
/// tests below; call_tool_response carries the dispatcher construction.
fn file_memory_refusal_response(args: serde_json::Value) -> serde_json::Value {
    call_tool_response("moot_file_memory", args)
}

/// moot_file_memory with an unknown sensitivity value must return a -32602
/// error whose data carries both `allowed` (non-empty) and `correction`
/// (non-empty).
///
/// Parity: `enumRefusalCarriesBothFields` (case moot_file_memory/sensitivity)
/// in Tests/AriaMCPTests/AriaV2RefusalParityTests.swift.  The Swift side
/// asserts that data.allowed and data.correction are both present and
/// non-empty; it asserts no value list.
#[test]
fn file_memory_bad_sensitivity_carries_both_refusal_fields() {
    let response = file_memory_refusal_response(serde_json::json!({
        "content": "test content",
        "subject": "test subject",
        "location": "test/location",
        "sensitivity": "banana"
    }));

    assert_eq!(
        response["error"]["code"],
        serde_json::json!(-32602),
        "bad sensitivity must yield -32602 INVALID_PARAMS; response: {response:?}"
    );

    let data = &response["error"]["data"];

    let allowed = data["allowed"].as_array()
        .expect("data.allowed must be present and an array");
    assert!(!allowed.is_empty(), "data.allowed must be non-empty; response: {response:?}");

    let correction = data["correction"].as_str()
        .expect("data.correction must be present and a string");
    assert!(!correction.is_empty(), "data.correction must be non-empty; response: {response:?}");

    // Cross-port equality gate: Rust and Swift both sort at emission.
    // The value set is closed and must match exactly across ports.
    assert_eq!(
        data["allowed"],
        serde_json::json!(["elevated", "normal", "restricted", "secret"]),
        "sensitivity allowed must match Swift's sorted emission; response: {response:?}"
    );
}

/// moot_file_memory with an unknown exportability value must return a -32602
/// error whose data carries both `allowed` (non-empty) and `correction`
/// (non-empty).
///
/// Parity: `enumRefusalCarriesBothFields` (case moot_file_memory/exportability)
/// in Tests/AriaMCPTests/AriaV2RefusalParityTests.swift.  The Swift side
/// asserts that data.allowed and data.correction are both present and
/// non-empty; it asserts no value list.
#[test]
fn file_memory_bad_exportability_carries_both_refusal_fields() {
    let response = file_memory_refusal_response(serde_json::json!({
        "content": "test content",
        "subject": "test subject",
        "location": "test/location",
        "exportability": "banana"
    }));

    assert_eq!(
        response["error"]["code"],
        serde_json::json!(-32602),
        "bad exportability must yield -32602 INVALID_PARAMS; response: {response:?}"
    );

    let data = &response["error"]["data"];

    let allowed = data["allowed"].as_array()
        .expect("data.allowed must be present and an array");
    assert!(!allowed.is_empty(), "data.allowed must be non-empty; response: {response:?}");

    let correction = data["correction"].as_str()
        .expect("data.correction must be present and a string");
    assert!(!correction.is_empty(), "data.correction must be non-empty; response: {response:?}");

    // Cross-port equality gate.
    assert_eq!(
        data["allowed"],
        serde_json::json!(["private", "public"]),
        "exportability allowed must match Swift's sorted emission; response: {response:?}"
    );
}

/// Dispatch the named tool through the full Dispatcher::handle path with the
/// supplied arguments and return the serialised response value.  The single
/// dispatcher construction for every parity test in this block.
fn call_tool_response(tool: &str, args: serde_json::Value) -> serde_json::Value {
    let registry = EstateRegistry::new_inmemory();
    let dispatcher = Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None);
    let request = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0", "id": 1,
        "method": "tools/call",
        "params": { "name": tool, "arguments": args }
    }))
    .expect("tools/call request must decode");
    serde_json::to_value(dispatcher.handle(&request))
        .expect("response must serialize")
}

/// moot_update_memory with an unknown mutation value must return a -32602
/// error whose data carries `allowed` equal to the sorted ten-value set and
/// a non-empty `correction`.
///
/// Parity: `enumRefusalCarriesBothFields` (case moot_update_memory/mutation)
/// in Tests/AriaMCPTests/AriaV2RefusalParityTests.swift.
#[test]
fn update_memory_bad_mutation_carries_allowed_and_correction() {
    let response = call_tool_response(
        "moot_update_memory",
        serde_json::json!({
            "memory_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
            "mutation": "bogus_mutation"
        }),
    );

    assert_eq!(
        response["error"]["code"],
        serde_json::json!(-32602),
        "bad mutation must yield -32602 INVALID_PARAMS; response: {response:?}"
    );

    let data = &response["error"]["data"];

    let correction = data["correction"].as_str()
        .expect("data.correction must be present and a string");
    assert!(!correction.is_empty(), "data.correction must be non-empty; response: {response:?}");

    // Cross-port value equality: Rust and Swift sort at emission. The ten-value
    // set is closed and must be byte-identical across ports.
    assert_eq!(
        data["allowed"],
        serde_json::json!(["accept","confirm","contest","correct_exportability","correct_sensitivity","reject","resolve","revive","set_subject","supersede"]),
        "mutation allowed must match Swift's sorted emission; response: {response:?}"
    );
}

/// moot_link_memories with an unknown relationship value must return a -32602
/// error whose data carries `allowed` equal to the sorted fifteen-value set
/// and a non-empty `correction`.
///
/// Parity: `enumRefusalCarriesBothFields` (case moot_link_memories/relationship)
/// in Tests/AriaMCPTests/AriaV2RefusalParityTests.swift.
#[test]
fn link_memories_bad_relationship_carries_allowed_and_correction() {
    let response = call_tool_response(
        "moot_link_memories",
        serde_json::json!({
            "from_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
            "to_id":   "b2c3d4e5-f6a7-8901-bcde-f01234567891",
            "relationship": "bogus_relationship"
        }),
    );

    assert_eq!(
        response["error"]["code"],
        serde_json::json!(-32602),
        "bad relationship must yield -32602 INVALID_PARAMS; response: {response:?}"
    );

    let data = &response["error"]["data"];

    let correction = data["correction"].as_str()
        .expect("data.correction must be present and a string");
    assert!(!correction.is_empty(), "data.correction must be non-empty; response: {response:?}");

    // Cross-port value equality: fifteen-value set, sorted, must be byte-identical
    // across ports.
    assert_eq!(
        data["allowed"],
        serde_json::json!(["blocks","contradicts","covers","derives_from","elaborates","exemplifies","extends","precedes","references","refines","relates","responds_to","supersedes","supports","validates"]),
        "relationship allowed must match Swift's sorted emission; response: {response:?}"
    );
}

/// moot_review_tunnel with decision 'accept' and reviewed_by 'model' must
/// return a -32602 error whose data carries `allowed` equal to ["user"] and
/// a non-empty `correction`.
///
/// Parity: `enumRefusalCarriesBothFields` (case moot_review_tunnel/reviewed_by)
/// in Tests/AriaMCPTests/AriaV2RefusalParityTests.swift.
#[test]
fn review_tunnel_model_accept_carries_allowed_and_correction() {
    let response = call_tool_response(
        "moot_review_tunnel",
        serde_json::json!({
            "tunnel_id":   "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
            "decision":    "accept",
            "reviewed_by": "model"
        }),
    );

    assert_eq!(
        response["error"]["code"],
        serde_json::json!(-32602),
        "model accept must yield -32602 INVALID_PARAMS; response: {response:?}"
    );

    let data = &response["error"]["data"];

    let correction = data["correction"].as_str()
        .expect("data.correction must be present and a string");
    assert!(!correction.is_empty(), "data.correction must be non-empty; response: {response:?}");

    // Cross-port value equality: the only acceptable reviewer for activation is
    // "user".  Sorted list is ["user"].
    assert_eq!(
        data["allowed"],
        serde_json::json!(["user"]),
        "reviewed_by allowed must match Swift's sorted emission; response: {response:?}"
    );
}

/// moot_file_memory with an unknown content-kind value must return a -32602
/// error whose data carries both `allowed` (non-empty) and `correction`
/// (non-empty), and whose `allowed` is exactly the six catalog-declared
/// content-kind values in sorted order.
///
/// Parity: `enumRefusalCarriesBothFields` (case moot_file_memory/kind)
/// in Tests/AriaMCPTests/AriaV2RefusalParityTests.swift, whose
/// expectedAllowed literal is the twin of the list asserted here.  Both
/// catalogs — AriaV2SelectedCatalog.swift and v2/catalog.rs — declare these
/// six values and no others; a value absent from both catalogs is not a v2
/// content kind (ruling, 2026-09-12).
#[test]
fn file_memory_bad_kind_carries_both_refusal_fields() {
    let response = file_memory_refusal_response(serde_json::json!({
        "content": "test content",
        "subject": "test subject",
        "location": "test/location",
        "kind": "banana"
    }));

    assert_eq!(
        response["error"]["code"],
        serde_json::json!(-32602),
        "bad kind must yield -32602 INVALID_PARAMS; response: {response:?}"
    );

    let data = &response["error"]["data"];

    let allowed = data["allowed"].as_array()
        .expect("data.allowed must be present and an array");
    assert!(!allowed.is_empty(), "data.allowed must be non-empty; response: {response:?}");

    let correction = data["correction"].as_str()
        .expect("data.correction must be present and a string");
    assert!(!correction.is_empty(), "data.correction must be non-empty; response: {response:?}");

    // The six catalog-declared values, sorted at emission.  This literal is the
    // twin of the Swift expectedAllowed list, so any addition or removal must
    // update both gates in the same change.
    assert_eq!(
        data["allowed"],
        serde_json::json!(["code", "image_caption", "list", "prose", "structured_json", "transcript"]),
        "kind allowed must contain exactly the six catalog-declared content-kind values (sorted); response: {response:?}"
    );
}
