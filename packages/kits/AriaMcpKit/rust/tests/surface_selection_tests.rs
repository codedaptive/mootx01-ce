//! Selected-surface regressions.
//!
//! These tests keep the v1 public facade pinned while proving the bounded v2
//! catalog, admission, frozen policy, typed MonitoringControl read seam, and
//! independent v2 envelope. They are intentionally feature-selected: each
//! binary has one active public surface.

#[cfg(feature = "aria-v2")]
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc,
};

#[cfg(feature = "aria-v2")]
use std::{fs, path::Path};

#[cfg(feature = "aria-v2")]
use aria_mcp::{
    dispatcher::Dispatcher, estate_registry::EstateRegistry, jsonrpc::JSONRPCRequest,
    v2::catalog::selected_capability_digest,
};

#[cfg(feature = "aria-v2")]
use aria_mcp::{estate_posture::EstatePosture, monitoring_control::MonitoringControl};

#[cfg(not(feature = "aria-v2"))]
use aria_mcp::tool_list::build_tool_list_with_flags;

#[cfg(feature = "aria-v2")]
fn call(dispatcher: &Dispatcher, name: &str, arguments: serde_json::Value) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": { "name": name, "arguments": arguments }
    }))
    .expect("test request must decode");
    serde_json::to_value(dispatcher.handle(&request)).expect("response must serialize")
}

#[cfg(feature = "aria-v2")]
fn tool_list(dispatcher: &Dispatcher) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/list"
    }))
    .expect("test request must decode");
    serde_json::to_value(dispatcher.handle(&request)).expect("response must serialize")
}

#[cfg(feature = "aria-v2")]
fn shared_vectors() -> serde_json::Value {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    let fixture_path = Path::new(&manifest_dir)
        .parent()
        .expect("rust manifest must sit beneath AriaMcpKit")
        .join("Tests/Conformance/aria_v2_mission01_vectors.json");
    let raw = fs::read_to_string(&fixture_path)
        .unwrap_or_else(|error| panic!("read shared ARIA v2 vectors at {}: {error}", fixture_path.display()));
    serde_json::from_str(&raw).expect("shared ARIA v2 vectors must be valid JSON")
}

#[cfg(feature = "aria-v2")]
fn mission02_catalog_operation(name: &str) -> serde_json::Value {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    let fixture_path = Path::new(&manifest_dir)
        .parent()
        .expect("rust manifest must sit beneath AriaMcpKit")
        .join("Tests/Conformance/aria_v2_mission02_vectors.json");
    let raw = fs::read_to_string(&fixture_path)
        .unwrap_or_else(|error| panic!("read shared ARIA v2 vectors at {}: {error}", fixture_path.display()));
    let fixture: serde_json::Value = serde_json::from_str(&raw)
        .expect("shared ARIA v2 mission02 vectors must be valid JSON");
    let mut operation = fixture["catalog"]["operations"]
        .as_array()
        .expect("mission02 catalog operations")
        .iter()
        .find(|operation| operation["name"] == name)
        .unwrap_or_else(|| panic!("mission02 catalog missing {name}"))
        .clone();
    if name.starts_with("moot_lens_") || name.starts_with("moot_recall_") {
        let schema_path = Path::new(&manifest_dir)
            .parent()
            .expect("rust manifest must sit beneath AriaMcpKit")
            .join("Tests/Conformance/aria_v2_output_schemas_recall_lens.json");
        let schemas: serde_json::Value = serde_json::from_str(
            &fs::read_to_string(&schema_path).unwrap_or_else(|error| {
                panic!("read lens output schemas at {}: {error}", schema_path.display())
            }),
        ).expect("shared lens output schemas must be valid JSON");
        operation["outputSchema"]["properties"]["data"] = resolve_local_schema_refs(
            schemas["operations"][name]["data_schema"].clone(),
            &schemas["$defs"],
        );
    } else if name == "moot_synthesize"
        || matches!(name, "moot_reindex" | "moot_reclassify_fdc" | "moot_palace_import" | "moot_json_import") {
        let schema_path = Path::new(&manifest_dir)
            .parent()
            .expect("rust manifest must sit beneath AriaMcpKit")
            .join("Tests/Conformance/aria_v2_output_schemas_core.json");
        let schemas: serde_json::Value = serde_json::from_str(
            &fs::read_to_string(&schema_path).unwrap_or_else(|error| {
                panic!("read core output schemas at {}: {error}", schema_path.display())
            }),
        ).expect("shared core output schemas must be valid JSON");
        operation["outputSchema"]["properties"]["data"] = resolve_local_schema_refs(
            schemas["operations"][name]["data_schema"].clone(),
            &schemas["definitions"],
        );
    } else if matches!(name,
        "moot_file_dataset" | "moot_dataset_query" | "moot_dataset_stats"
        | "moot_vault_status" | "moot_vault_reconcile"
    ) {
        let schema_path = Path::new(&manifest_dir)
            .parent()
            .expect("rust manifest must sit beneath AriaMcpKit")
            .join("Tests/Conformance/aria_v2_output_schemas_edge.json");
        let schemas: serde_json::Value = serde_json::from_str(
            &fs::read_to_string(&schema_path).unwrap_or_else(|error| {
                panic!("read edge output schemas at {}: {error}", schema_path.display())
            }),
        ).expect("shared edge output schemas must be valid JSON");
        operation["outputSchema"]["properties"]["data"] = resolve_local_schema_refs(
            schemas["operations"][name]["data_schema"].clone(),
            &serde_json::Value::Null,
        );
    }
    operation
}

#[cfg(feature = "aria-v2")]
fn resolve_local_schema_refs(
    value: serde_json::Value,
    definitions: &serde_json::Value,
) -> serde_json::Value {
    match value {
        serde_json::Value::Object(mut object) => {
            if let Some(reference) = object.get("$ref").and_then(serde_json::Value::as_str) {
                if let Some(name) = reference.strip_prefix("#/definitions/")
                    .or_else(|| reference.strip_prefix("#/$defs/"))
                {
                    return resolve_local_schema_refs(definitions[name].clone(), definitions);
                }
            }
            for child in object.values_mut() {
                *child = resolve_local_schema_refs(std::mem::take(child), definitions);
            }
            serde_json::Value::Object(object)
        }
        serde_json::Value::Array(values) => serde_json::Value::Array(
            values.into_iter().map(|value| resolve_local_schema_refs(value, definitions)).collect(),
        ),
        value => value,
    }
}

#[cfg(feature = "aria-v2")]
fn vector<'a>(fixture: &'a serde_json::Value, name: &str) -> &'a serde_json::Value {
    fixture["vectors"]
        .as_array()
        .expect("shared vectors array")
        .iter()
        .find(|entry| entry["name"] == name)
        .unwrap_or_else(|| panic!("shared vector missing: {name}"))
}

#[cfg(feature = "aria-v2")]
struct MonitoringProbe {
    enabled: AtomicBool,
    reads: AtomicUsize,
    writes: AtomicUsize,
}

#[cfg(feature = "aria-v2")]
impl MonitoringProbe {
    fn enabled() -> Self {
        Self {
            enabled: AtomicBool::new(true),
            reads: AtomicUsize::new(0),
            writes: AtomicUsize::new(0),
        }
    }
}

#[cfg(feature = "aria-v2")]
impl MonitoringControl for MonitoringProbe {
    fn read(&self) -> Option<bool> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        Some(self.enabled.load(Ordering::SeqCst))
    }

    fn set(&self, enabled: bool) {
        self.writes.fetch_add(1, Ordering::SeqCst);
        self.enabled.store(enabled, Ordering::SeqCst);
    }
}

#[cfg(feature = "aria-v2")]
fn v2_dispatcher(probe: Arc<MonitoringProbe>) -> Dispatcher {
    Dispatcher::new(
        EstateRegistry::new_inmemory(),
        "ARIA_MCP_Rust",
        "test",
        "test-serial",
        "",
        Some(probe),
    )
}

#[cfg(feature = "aria-v2")]
fn seed_provenance_memory(
    registry: &EstateRegistry,
    content: &str,
    sensitivity: locus_kit::provenance::Sensitivity,
) -> String {
    use locus_kit::{
        drawer_operational::CaptureChannel, estate_types::LatticeAnchor,
        frames::CaptureFrame,
    };
    let mut frame = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "q23-provenance",
        LatticeAnchor::udc("004"),
        "aria-v2-tests",
        "test-model-v1",
    );
    frame.subject = Some(content.to_owned());
    frame.provenance_sensitivity = sensitivity;
    registry.coord.lock().unwrap()
        .capture(&registry.default.handle, frame, 1_700_000_000_123)
        .expect("provenance fixture capture").id
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_catalog_and_admission_are_the_same_ready_subset() {
    let probe = Arc::new(MonitoringProbe::enabled());
    let dispatcher = v2_dispatcher(Arc::clone(&probe));
    let list = tool_list(&dispatcher);
    let tools = list["result"]["tools"].as_array().expect("tools list");
    assert_eq!(tools.len(), 84, "selected callable roster count");
    assert!(tools.iter().all(|tool| tool.get("annotations").is_some()));
    let annotations = |name: &str| {
        tools.iter().find(|tool| tool["name"] == name)
            .unwrap_or_else(|| panic!("missing selected tool {name}"))["annotations"].clone()
    };
    assert_eq!(annotations("moot_memory_get"), serde_json::json!({
        "readOnlyHint":true,"destructiveHint":false,"openWorldHint":false
    }));
    assert_eq!(annotations("moot_file_memory"), serde_json::json!({
        "readOnlyHint":false,"destructiveHint":false,"openWorldHint":false
    }));
    assert_eq!(annotations("moot_erase_memory"), serde_json::json!({
        "readOnlyHint":false,"destructiveHint":true,"openWorldHint":false
    }));
    assert_eq!(annotations("moot_vault_export"), serde_json::json!({
        "readOnlyHint":true,"destructiveHint":false,"openWorldHint":true
    }));
    assert_eq!(tools.iter().map(|tool| tool["name"].as_str().unwrap()).collect::<Vec<_>>(), vec![
        "moot_confirm_memory", "moot_connection_map", "moot_connection_search", "moot_dataset_query", "moot_dataset_stats", "moot_drain_status", "moot_dream", "moot_erase_memory", "moot_estate_map", "moot_estate_ping", "moot_estate_status",
        "moot_fact_search", "moot_fact_timeline", "moot_federated_recall", "moot_file_dataset", "moot_file_fact", "moot_file_memory", "moot_file_packet", "moot_help", "moot_hunt_contradictions", "moot_json_import", "moot_lens_anticipate", "moot_lens_apriori", "moot_lens_associations", "moot_lens_bias", "moot_lens_cohesion", "moot_lens_complexity", "moot_lens_concepts", "moot_lens_constellation", "moot_lens_contradiction", "moot_lens_divergence", "moot_lens_drift", "moot_lens_free_association", "moot_lens_keystones", "moot_lens_latent_themes", "moot_lens_moment", "moot_lens_node_motion", "moot_lens_overlap", "moot_lens_partial_cue", "moot_lens_precedence", "moot_lens_rhythm", "moot_lens_successors", "moot_lens_theme_weather", "moot_lens_trust_synthesis", "moot_link_memories", "moot_list_lenses", "moot_list_recipes",
        "moot_memory_get", "moot_memory_list", "moot_memory_recall_transcript", "moot_memory_search", "moot_migration_confirm", "moot_migration_run", "moot_monitoring_set",
        "moot_monitoring_status", "moot_move_memory", "moot_packet_get", "moot_packet_lineage", "moot_packet_list", "moot_palace_import", "moot_propose_contradictions",
        "moot_read_journal", "moot_rebuild_status", "moot_recall_connected", "moot_recall_distilled", "moot_recall_precise", "moot_recall_shaped", "moot_recall_temporal", "moot_recall_vague", "moot_recall_walk", "moot_reclassify_fdc", "moot_reindex", "moot_retire_fact", "moot_review_tunnel", "moot_synthesize", "moot_timing_report", "moot_update_memory", "moot_vault_export", "moot_vault_import", "moot_vault_job", "moot_vault_reconcile", "moot_vault_status", "moot_withdraw_memory", "moot_write_journal",
    ]);
    for name in [
        "moot_reindex", "moot_reclassify_fdc", "moot_palace_import", "moot_json_import",
        "moot_file_dataset", "moot_dataset_query", "moot_dataset_stats", "moot_vault_export", "moot_vault_import",
        "moot_vault_status", "moot_vault_reconcile", "moot_vault_job",
        "moot_recall_precise", "moot_recall_temporal", "moot_recall_connected",
        "moot_recall_shaped", "moot_recall_distilled", "moot_recall_vague", "moot_recall_walk",
        "moot_lens_keystones", "moot_lens_constellation", "moot_lens_free_association",
        "moot_lens_bias", "moot_lens_cohesion", "moot_lens_contradiction", "moot_lens_theme_weather",
        "moot_lens_latent_themes", "moot_lens_drift", "moot_lens_trust_synthesis",
        "moot_lens_partial_cue", "moot_lens_anticipate", "moot_lens_node_motion",
        "moot_lens_successors", "moot_lens_overlap", "moot_lens_divergence",
        "moot_lens_associations", "moot_lens_concepts", "moot_lens_apriori",
        "moot_lens_moment", "moot_lens_rhythm", "moot_lens_precedence",
        "moot_lens_complexity", "moot_synthesize",
    ] {
        let expected = mission02_catalog_operation(name);
        let actual = tools.iter().find(|tool| tool["name"] == name)
            .unwrap_or_else(|| panic!("selected catalog missing {name}"));
        assert_eq!(actual["inputSchema"], expected["inputSchema"], "{name} input schema");
        assert_eq!(actual["outputSchema"], expected["outputSchema"], "{name} output schema");
    }
    for name in [
        "moot_memory_get", "moot_memory_search", "moot_link_memories",
        "moot_review_tunnel", "moot_file_dataset",
    ] {
        let expected = mission02_catalog_operation(name);
        let actual = tools.iter().find(|tool| tool["name"] == name)
            .unwrap_or_else(|| panic!("selected catalog missing {name}"));
        assert_eq!(actual["inputSchema"], expected["inputSchema"], "{name} input schema");
    }

    let response = call(&dispatcher, "moot_monitoring_status", serde_json::json!({}));
    assert_eq!(response["result"]["isError"], false);
    assert_eq!(
        response["result"]["structuredContent"],
        serde_json::json!({
            "surface_version": "v2",
            "tool": "moot_monitoring_status",
            "data": { "monitoring": "enabled" },
            "meta": {
                "build_id": "test-serial",
                "capability_digest": selected_capability_digest(),
                "completeness": "incomplete",
                "effect": "read"
            }
        })
    );
    assert_eq!(probe.reads.load(Ordering::SeqCst), 1);
    assert_eq!(probe.writes.load(Ordering::SeqCst), 0);

    let concepts = call(&dispatcher, "moot_lens_concepts", serde_json::json!({}));
    assert_eq!(concepts["result"]["isError"], false, "{concepts}");
    assert!(concepts["result"]["structuredContent"]["data"]["concepts"].is_array());
    assert!(concepts["result"]["structuredContent"]["data"]["coverDeltas"].is_array());
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_recall_recipe_family_is_selected_and_strict_before_legacy_dispatch() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));
    let names = [
        "moot_recall_precise", "moot_recall_temporal", "moot_recall_connected",
        "moot_recall_shaped", "moot_recall_distilled", "moot_recall_vague", "moot_recall_walk",
    ];
    for name in names {
        let rejected = call(&dispatcher, name, serde_json::json!({"query": "typed recall", "legacy": true}));
        assert_eq!(rejected["error"]["code"], -32602, "{name}: {rejected}");
        assert_eq!(rejected["error"]["data"]["code"], "invalid_argument");
    }

    let temporal = call(&dispatcher, "moot_recall_temporal", serde_json::json!({"query": "typed recall", "window": "loose"}));
    assert_eq!(temporal["result"]["structuredContent"]["tool"], "moot_recall_temporal");
    assert_eq!(temporal["result"]["structuredContent"]["meta"]["effect"], "read");
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_vault_lifecycle_uses_the_selected_estate_and_dispatcher_job_ledger() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));
    let vault = std::env::temp_dir().join(format!("aria-v2-vault-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&vault).expect("create isolated vault fixture");
    let vault_path = vault.to_string_lossy().into_owned();

    let exported = call(&dispatcher, "moot_vault_export", serde_json::json!({
        "vaultPath": vault_path,
        "scope": "exportable",
    }));
    assert_eq!(exported["result"]["isError"], false, "{exported}");
    assert_eq!(exported["result"]["structuredContent"]["tool"], "moot_vault_export");
    assert_eq!(exported["result"]["structuredContent"]["meta"]["effect"], "read");
    let export_job_id = exported["result"]["structuredContent"]["data"]["job_id"]
        .as_str().expect("selected export returns a minted job id").to_owned();

    let export_job = call(&dispatcher, "moot_vault_job", serde_json::json!({
        "job_id": export_job_id,
    }));
    assert_eq!(export_job["result"]["isError"], false, "{export_job}");
    assert_eq!(export_job["result"]["structuredContent"]["data"]["kind"], "export");
    assert_eq!(export_job["result"]["structuredContent"]["data"]["status"], "complete");
    assert!(export_job["result"]["structuredContent"]["data"]["export"]["note_count"].is_u64());

    let imported = call(&dispatcher, "moot_vault_import", serde_json::json!({
        "vaultPath": vault.to_string_lossy(),
        "mode": "foreground",
    }));
    assert_eq!(imported["result"]["isError"], false, "{imported}");
    assert_eq!(imported["result"]["structuredContent"]["tool"], "moot_vault_import");
    assert_eq!(imported["result"]["structuredContent"]["meta"]["effect"], "write");

    let rejected_estate = call(&dispatcher, "moot_vault_export", serde_json::json!({
        "vaultPath": vault.to_string_lossy(),
        "estate_id": uuid::Uuid::new_v4().to_string(),
    }));
    assert_eq!(rejected_estate["result"]["isError"], true);
    assert_eq!(rejected_estate["result"]["structuredContent"]["error"]["code"], "mobility_unavailable");

    let frozen = v2_dispatcher(Arc::new(MonitoringProbe::enabled()))
        .with_posture(EstatePosture::Frozen);
    let frozen_import = call(&frozen, "moot_vault_import", serde_json::json!({
        "vaultPath": vault.to_string_lossy(),
    }));
    assert_eq!(frozen_import["result"]["structuredContent"]["error"]["code"], "estate_frozen");

    let invalid = call(&dispatcher, "moot_vault_job", serde_json::json!({
        "job_id": export_job["result"]["structuredContent"]["data"]["job_id"],
        "unexpected": true,
    }));
    assert_eq!(invalid["error"]["code"], -32602);
    assert_eq!(invalid["error"]["data"]["code"], "invalid_argument");

    fs::remove_dir_all(vault).expect("remove isolated vault fixture");
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_contradiction_hunt_is_selected_and_proposal_is_a_frozen_write() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));
    let hunt = call(&dispatcher, "moot_hunt_contradictions", serde_json::json!({"limit": 1}));
    assert_eq!(hunt["result"]["isError"], false, "{hunt}");
    let data = &hunt["result"]["structuredContent"]["data"];
    assert!(data["analysis_ref"].is_string());
    assert!(data["expires_at"].is_string());
    assert!(data["candidates"].as_array().is_some());
    assert!(data["candidates"].as_array().unwrap().iter().all(|candidate| {
        candidate.as_object().is_some_and(|object| {
            object.len() == 4
                && candidate["candidate_id"].is_string()
                && candidate["reason"].is_string()
                && candidate["source"].is_object()
                && candidate["target"].is_object()
        })
    }));

    let frozen = v2_dispatcher(Arc::new(MonitoringProbe::enabled()))
        .with_posture(EstatePosture::Frozen);
    let proposal = call(&frozen, "moot_propose_contradictions", serde_json::json!({
        "analysis_ref": "analysis_opaque", "candidate_ids": ["candidate_opaque"]
    }));
    assert_eq!(proposal["result"]["structuredContent"]["error"]["code"], "estate_frozen");
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_knowledge_journal_is_selected_and_projects_optional_fact_source() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));
    let filed = call(&dispatcher, "moot_file_fact", serde_json::json!({
        "subject": "selected knowledge subject", "predicate": "status", "object": "ready"
    }));
    assert_eq!(filed["result"]["isError"], false, "{filed}");
    assert_eq!(filed["result"]["structuredContent"]["meta"]["effect"], "write");
    assert!(filed["result"]["structuredContent"]["data"].get("source_memory_id").is_none());

    let searched = call(&dispatcher, "moot_fact_search", serde_json::json!({
        "subject": "selected knowledge subject"
    }));
    assert_eq!(searched["result"]["isError"], false, "{searched}");
    assert_eq!(searched["result"]["structuredContent"]["data"]["facts"].as_array().unwrap().len(), 1);

    let written = call(&dispatcher, "moot_write_journal", serde_json::json!({
        "content": "selected journal entry", "tags": "selected-v2"
    }));
    assert_eq!(written["result"]["isError"], false, "{written}");
    let read = call(&dispatcher, "moot_read_journal", serde_json::json!({}));
    assert_eq!(read["result"]["isError"], false, "{read}");
    assert!(read["result"]["structuredContent"]["data"]["entries"].as_array().unwrap()
        .iter().any(|entry| entry["entry"] == "selected journal entry"));
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_preserves_mission01_monitoring_semantics_with_v2_effect_vocabulary() {
    let fixture = shared_vectors();
    let probe = Arc::new(MonitoringProbe::enabled());
    let dispatcher = v2_dispatcher(Arc::clone(&probe));

    let enabled = vector(&fixture, "enabled_monitoring_inspection");
    let enabled_result = call(
        &dispatcher,
        enabled["request"]["name"].as_str().expect("enabled tool name"),
        enabled["request"]["arguments"].clone(),
    );
    assert_eq!(enabled_result["result"]["structuredContent"]["data"]["monitoring"], "enabled");
    assert_eq!(enabled_result["result"]["structuredContent"]["meta"]["effect"], "read");
    assert_eq!(probe.reads.load(Ordering::SeqCst), 1);
    assert_eq!(probe.writes.load(Ordering::SeqCst), 0);

    let unavailable = vector(&fixture, "unavailable_monitoring_inspection");
    let unavailable_dispatcher = Dispatcher::new(
        EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", "", None,
    );
    let unavailable_result = call(
        &unavailable_dispatcher,
        unavailable["request"]["name"].as_str().expect("unavailable tool name"),
        unavailable["request"]["arguments"].clone(),
    );
    assert_eq!(unavailable_result["result"]["structuredContent"]["data"]["monitoring"], "unavailable");
    assert_eq!(unavailable_result["result"]["structuredContent"]["meta"]["effect"], "read");

    for name in ["non_object_arguments_are_invalid", "enabled_argument_is_invalid_for_inspection"] {
        let entry = vector(&fixture, name);
        let response = call(
            &dispatcher,
            entry["request"]["name"].as_str().expect("vector tool name"),
            entry["request"]["arguments"].clone(),
        );
        assert_eq!(response["error"], entry["expected_jsonrpc_error"], "vector mismatch: {name}");
    }
    assert_eq!(probe.reads.load(Ordering::SeqCst), 1);
    assert_eq!(probe.writes.load(Ordering::SeqCst), 0);
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_rejects_inactive_names_and_arguments_before_any_control_call() {
    let probe = Arc::new(MonitoringProbe::enabled());
    let dispatcher = v2_dispatcher(Arc::clone(&probe));

    for args in [serde_json::json!({}), serde_json::json!({"teachme": true})] {
        let inactive = call(&dispatcher, "moot_federated_search", args);
        assert_eq!(
            inactive["error"]["code"], -32601,
            "inactive v1 tool must reject: {inactive}"
        );
    }

    for args in [
        serde_json::json!({"enabled": false}),
        serde_json::json!({"unknown": true}),
    ] {
        let rejected = call(&dispatcher, "moot_monitoring_status", args);
        assert_eq!(
            rejected["error"]["code"], -32602,
            "v2 argument must reject: {rejected}"
        );
        assert_eq!(rejected["error"]["data"]["code"], "invalid_argument");
    }

    assert_eq!(probe.reads.load(Ordering::SeqCst), 0);
    assert_eq!(probe.writes.load(Ordering::SeqCst), 0);
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_files_searches_gets_and_explains_through_typed_handlers() {
    let probe = Arc::new(MonitoringProbe::enabled());
    let dispatcher = v2_dispatcher(probe);
    let filed_content = format!("ARIA v2 direct typed memory. {}", "🦀".repeat(513));
    let filed = call(&dispatcher, "moot_file_memory", serde_json::json!({
        "content":filed_content.clone(),
        "subject":"ARIA v2 direct typed memory.",
        "location":"typed-memory-tests"
    }));
    assert_eq!(filed["result"]["isError"], false, "{filed}");
    let memory_id = filed["result"]["structuredContent"]["data"]["memory_id"]
        .as_str().expect("file receipt memory UUID").to_owned();

    let fetched = call(&dispatcher, "moot_memory_get", serde_json::json!({
        "memory_id":memory_id, "depth":"full"
    }));
    assert_eq!(fetched["result"]["isError"], false, "{fetched}");
    assert_eq!(fetched["result"]["structuredContent"]["data"]["memories"][0]["content"], filed_content);

    let searched = call(&dispatcher, "moot_memory_search", serde_json::json!({"query":"direct typed memory","limit":5}));
    assert_eq!(searched["result"]["isError"], false, "{searched}");
    assert_eq!(searched["result"]["structuredContent"]["meta"]["effect"], "read");
    let excerpt = searched["result"]["structuredContent"]["data"]["results"][0]["excerpt"]
        .as_str().expect("authorized search excerpt");
    assert_eq!(excerpt.chars().count(), 512);
    assert!(excerpt.starts_with("ARIA v2 direct typed memory."));
    assert_eq!(searched["result"]["structuredContent"]["data"]["results"][0]["fetch"]["arguments"]["memory_id"], memory_id);
    let list = tool_list(&dispatcher);
    let search_descriptor = list["result"]["tools"].as_array().expect("tools list").iter()
        .find(|tool| tool["name"] == "moot_memory_search")
        .expect("selected memory search descriptor");
    assert_eq!(
        search_descriptor["outputSchema"]["properties"]["data"]["properties"]["results"]
            ["items"]["properties"]["excerpt"],
        serde_json::json!({"type":"string","maxLength":512}),
    );

    let dataset = call(&dispatcher, "moot_file_dataset", serde_json::json!({
        "name":"typed-dataset", "location":"typed-dataset-tests",
        "columns":[{"name":"score","type":"int"}],
        "rows":[{"score":7}]
    }));
    assert_eq!(dataset["result"]["isError"], false, "{dataset}");
    let dataset_id = dataset["result"]["structuredContent"]["data"]["dataset_id"]
        .as_str().expect("typed dataset UUID");
    let queried = call(&dispatcher, "moot_dataset_query", serde_json::json!({
        "dataset_id":dataset_id, "where":{"col":"score","op":"eq","val":7}
    }));
    assert_eq!(queried["result"]["isError"], false, "{queried}");
    assert_eq!(queried["result"]["structuredContent"]["tool"], "moot_dataset_query");
    assert_eq!(queried["result"]["structuredContent"]["data"]["rows"][0]["score"], 7);

    let help = call(&dispatcher, "moot_help", serde_json::json!({}));
    assert_eq!(help["result"]["isError"], false, "{help}");
    let data=&help["result"]["structuredContent"]["data"];
    let operations=data["operations"].as_array().unwrap();
    assert_eq!(operations.len(), 84);
    assert!(data["directory_records"].is_array());
    let keys=operations[0].as_object().unwrap().keys().cloned().collect::<std::collections::BTreeSet<_>>();
    assert_eq!(keys,["description","effect","id","input_schema","intents","name","output_schema"].into_iter().map(str::to_owned).collect());
    let one=call(&dispatcher,"moot_help",serde_json::json!({"tool":"moot_memory_get"}));
    assert_eq!(one["result"]["structuredContent"]["data"]["operation"]["name"],"moot_memory_get");
    assert!(one["result"]["structuredContent"]["data"]["operation"]["output_schema"].is_object());
    let unknown=call(&dispatcher,"moot_help",serde_json::json!({"tool":"not_a_real_operation"}));
    assert_eq!(unknown["result"]["isError"],true);
    assert_eq!(unknown["result"]["structuredContent"]["error"]["code"],"unknown_operation");
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_memory_search_and_get_exclude_provenance_sensitive_rows() {
    use locus_kit::provenance::Sensitivity;
    let registry = EstateRegistry::new_inmemory();
    let normal = seed_provenance_memory(&registry, "q23 boundary normal common-token", Sensitivity::Normal);
    let elevated = seed_provenance_memory(&registry, "q23 boundary elevated common-token", Sensitivity::Elevated);
    let restricted = seed_provenance_memory(&registry, "q23 boundary restricted common-token", Sensitivity::Restricted);
    let secret = seed_provenance_memory(&registry, "q23 boundary secret common-token", Sensitivity::Secret);
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", "", None);

    let searched = call(&dispatcher, "moot_memory_search", serde_json::json!({
        "query":"q23 boundary common-token", "limit":10
    }));
    let ids = searched["result"]["structuredContent"]["data"]["results"].as_array().unwrap()
        .iter().filter_map(|row| row["memory_id"].as_str()).collect::<std::collections::BTreeSet<_>>();
    assert!(ids.contains(normal.as_str()));
    assert!(ids.contains(elevated.as_str()));
    assert!(!ids.contains(restricted.as_str()));
    assert!(!ids.contains(secret.as_str()));

    for id in [&restricted, &secret] {
        let fetched = call(&dispatcher, "moot_memory_get", serde_json::json!({"memory_id":id}));
        assert_eq!(fetched["result"]["isError"], true, "{fetched}");
        assert_eq!(fetched["result"]["structuredContent"]["error"]["code"], "memory_not_found");
    }

    let synthesized = call(&dispatcher, "moot_synthesize", serde_json::json!({
        "query":"q23 boundary common-token", "limit":10
    }));
    let data = &synthesized["result"]["structuredContent"]["data"];
    let rows = data["results"].as_array().expect("typed synthesis results");
    let ids = rows.iter().filter_map(|row| row["memory_id"].as_str())
        .collect::<std::collections::BTreeSet<_>>();
    assert!(ids.contains(normal.as_str()));
    assert!(ids.contains(elevated.as_str()));
    assert!(!ids.contains(restricted.as_str()));
    assert!(!ids.contains(secret.as_str()));
    assert!(rows.iter().all(|row| row.get("context").is_none()));
    assert!(rows.iter().all(|row| row["excerpt"].as_str()
        .is_some_and(|excerpt| excerpt.chars().count() <= 512)));
    let summary = data["summary"].as_str().expect("typed synthesis summary");
    assert!(!summary.contains("restricted"));
    assert!(!summary.contains("secret"));
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_synthesis_ranks_an_older_query_match_above_recent_distractors() {
    use locus_kit::provenance::Sensitivity;
    let registry = EstateRegistry::new_inmemory();
    // The semantic intake rider is mounted by mode-aware capture; legacy
    // `capture` intentionally bypasses that queue. Use a regular capture here
    // so the subsequent drain establishes actual BM25 evidence.
    let seed_regular = |content: &str| {
        use genius_locus_kit::WriteMode;
        use locus_kit::{drawer_operational::CaptureChannel, estate_types::LatticeAnchor, frames::CaptureFrame};
        let mut frame = CaptureFrame::new(
            content, CaptureChannel::Typed, "q31-synthesis",
            LatticeAnchor::udc("004"), "aria-v2-tests", "test-model-v1",
        );
        frame.subject = Some(content.to_owned());
        frame.provenance_sensitivity = Sensitivity::Normal;
        registry.coord.lock().unwrap()
            .capture_with_mode(&registry.default.handle, frame, 1_700_000_000_123, WriteMode::Regular)
            .expect("q31 regular capture")
            .id
    };
    let relevant = seed_regular("Orchard radio calibration uses channel 17 and the amber coupler.");
    for index in 0..3 {
        seed_regular(&format!("Recent unrelated distractor {index}."));
    }
    registry.coord.lock().unwrap()
        .await_encode_drain(&registry.default.handle)
        .expect("synthesis fixture encode drain");
    {
        use genius_locus_kit::recall::{
            GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallEvidencePath,
            RecallFallbackPolicy, RecallOrigin,
        };
        use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};
        let mut lexical_frame = RecallFrame::new(vec![Filter::Any(vec![
            Filter::ContentMatches("orchard".to_owned()),
            Filter::ContentMatches("radio".to_owned()),
            Filter::ContentMatches("calibration".to_owned()),
        ])]);
        lexical_frame.hydration_level = HydrationLevel::Full;
        lexical_frame.limit = Some(200);
        let coordinator = registry.coord.lock().unwrap();
        let lexical = coordinator.recall(
            &registry.default.handle, lexical_frame, 1_700_000_000_124,
        ).expect("direct synthesis lexical lane");
        assert!(lexical.iter().any(|row| row.id.eq_ignore_ascii_case(&relevant)),
            "direct lexical lane must retain the older query match: {lexical:?}");

        let mut scored_frame = RecallFrame::new(vec![]);
        scored_frame.hydration_level = HydrationLevel::Full;
        scored_frame.limit = Some(200);
        let scored = coordinator.recall_scored(
            &registry.default.handle,
            GLKRecallRequest::new(
                scored_frame, GLKRecallMode::UnionBest, GLKRecallScoring::MatrixAware,
                200, RecallFallbackPolicy::AllowDegraded, RecallOrigin::Internal,
            ).with_query_text("orchard radio calibration".to_owned()),
            1_700_000_000_124,
        ).expect("direct synthesis scored lane");
        let relevant_hit = scored.hits.iter().find(|hit| {
            hit.drawer.as_ref().is_some_and(|row| row.id.eq_ignore_ascii_case(&relevant))
        }).expect("direct scored lane must retain the older query match");
        assert!(relevant_hit.sources.contains(&RecallEvidencePath::CorpusBm25),
            "direct scored lane must carry BM25 evidence: {:?}", relevant_hit.sources);
    }
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", "", None);
    let synthesized = call(&dispatcher, "moot_synthesize", serde_json::json!({
        "query":"orchard radio calibration", "limit":1
    }));
    assert_eq!(synthesized["result"]["isError"], false, "{synthesized}");
    let rows = synthesized["result"]["structuredContent"]["data"]["results"]
        .as_array().expect("typed synthesis results");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["memory_id"], relevant.to_lowercase(), "{synthesized}");
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_memory_mutations_are_selected_writes_before_legacy_dispatch() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));
    let filed = call(&dispatcher, "moot_file_memory", serde_json::json!({
        "content":"typed mutation target", "subject":"typed mutation target", "location":"v2 mutation"
    }));
    let memory_id = filed["result"]["structuredContent"]["data"]["memory_id"]
        .as_str().expect("typed memory id");
    let updated = call(&dispatcher, "moot_update_memory", serde_json::json!({
        "memory_id": memory_id, "mutation": "confirm"
    }));
    assert_eq!(updated["result"]["isError"], false, "{updated}");
    assert_eq!(updated["result"]["structuredContent"]["tool"], "moot_update_memory");
    assert_eq!(updated["result"]["structuredContent"]["meta"]["effect"], "write");
    assert_eq!(updated["result"]["structuredContent"]["data"]["operation"], "moot_update_memory");

    let tools = tool_list(&dispatcher);
    let listed: std::collections::BTreeSet<&str> = tools["result"]["tools"]
        .as_array().expect("tools/list entries")
        .iter().map(|tool| tool["name"].as_str().expect("tool name")).collect();
    for name in [
        "moot_update_memory", "moot_withdraw_memory", "moot_erase_memory", "moot_confirm_memory",
        "moot_move_memory", "moot_link_memories", "moot_review_tunnel",
    ] {
        assert!(listed.contains(name), "selected catalog omitted {name}");
    }

    let erase = tools["result"]["tools"].as_array().expect("tools/list entries").iter()
        .find(|tool| tool["name"] == "moot_erase_memory").expect("erase-memory descriptor");
    assert_eq!(erase["inputSchema"]["properties"]["confirmation"]["type"], "boolean");
    assert_eq!(erase["inputSchema"]["properties"]["confirmation"]["const"], true);
    assert_eq!(erase["inputSchema"]["properties"]["reason"]["type"], "string");
    assert_eq!(erase["inputSchema"]["required"], serde_json::json!(["memory_id", "confirmation"]));

    let frozen = v2_dispatcher(Arc::new(MonitoringProbe::enabled())).with_posture(EstatePosture::Frozen);
    let refused = call(&frozen, "moot_confirm_memory", serde_json::json!({
        "memory_id": memory_id
    }));
    assert_eq!(refused["result"]["structuredContent"]["error"]["code"], "estate_frozen");
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_review_tunnel_endorse_uses_the_selected_coordinator_ladder() {
    use locus_kit::{
        frames::TunnelCaptureFrame,
        tunnel_operational::TunnelLifecycle,
    };

    let registry = EstateRegistry::new_inmemory();
    let mut frame = TunnelCaptureFrame::new(
        "Lab", "source", "Lab", "target", "tier3:value-divergence@test", "fixture",
    );
    frame.lifecycle = TunnelLifecycle::Proposed;
    let tunnel = registry.coord.lock().unwrap()
        .estate_for(&registry.default.handle).expect("selected estate")
        .capture_tunnel(frame, 1_700_000_000_123).expect("proposed tunnel");
    let tunnel_id = tunnel.id.to_lowercase();
    let dispatcher = Dispatcher::new(
        registry, "ARIA_MCP_Rust", "test", "test-serial", "", None,
    );

    let endorsed = call(&dispatcher, "moot_review_tunnel", serde_json::json!({
        "tunnel_id": tunnel_id, "decision": "endorse"
    }));
    assert_eq!(endorsed["result"]["isError"], false, "{endorsed}");
    assert_eq!(endorsed["result"]["structuredContent"]["data"], serde_json::json!({
        "tunnel_id": tunnel_id,
        "new_endorser": true,
        "distinct_endorsers": 1,
        "contested": false,
    }));
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_cognition_directories_advertise_only_selected_handlers_and_typed_recipes() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));

    let lenses = call(&dispatcher, "moot_list_lenses", serde_json::json!({"verbose": true}));
    assert_eq!(lenses["result"]["isError"], false, "{lenses}");
    assert_eq!(lenses["result"]["structuredContent"]["meta"]["effect"], "read");
    let names: Vec<&str> = lenses["result"]["structuredContent"]["data"]["tools"]
        .as_array().expect("typed cognition tools")
        .iter()
        .map(|tool| tool["name"].as_str().expect("tool name"))
        .collect();
    assert_eq!(names, [
        "moot_list_lenses", "moot_list_recipes", "moot_synthesize", "moot_recall_precise",
        "moot_recall_temporal", "moot_recall_connected", "moot_recall_shaped", "moot_dream",
        "moot_recall_distilled", "moot_recall_vague", "moot_hunt_contradictions",
        "moot_recall_walk", "moot_lens_keystones", "moot_lens_constellation",
        "moot_lens_free_association", "moot_lens_theme_weather", "moot_lens_latent_themes",
        "moot_lens_bias", "moot_lens_drift", "moot_lens_node_motion", "moot_lens_cohesion", "moot_lens_contradiction",
        "moot_lens_trust_synthesis", "moot_lens_partial_cue", "moot_lens_anticipate",
        "moot_lens_successors", "moot_lens_overlap", "moot_lens_divergence",
        "moot_lens_associations", "moot_lens_concepts", "moot_lens_apriori",
        "moot_lens_moment", "moot_lens_rhythm", "moot_lens_precedence", "moot_lens_complexity",
    ]);
    assert!(lenses["result"]["structuredContent"]["data"]["tools"]
        .as_array().expect("typed cognition tools")
        .iter().all(|tool| tool["input_schema"].is_object()));

    let keystones = call(&dispatcher, "moot_lens_keystones", serde_json::json!({"wing":"work"}));
    assert_eq!(keystones["result"]["isError"], false, "{keystones}");
    assert!(keystones["result"]["structuredContent"]["data"]["keystones"].is_array());

    let weather = call(&dispatcher, "moot_lens_theme_weather", serde_json::json!({}));
    assert_eq!(weather["result"]["isError"], false, "{weather}");
    assert!(weather["result"]["structuredContent"]["data"]["weather"].is_array());

    let synthesis = call(&dispatcher, "moot_synthesize", serde_json::json!({"query":"typed synthesis"}));
    assert_eq!(synthesis["result"]["isError"], false, "{synthesis}");
    assert!(synthesis["result"]["structuredContent"]["data"]["summary"].is_string());
    assert!(synthesis["result"]["structuredContent"]["data"]["results"].is_array());

    let recipes = call(&dispatcher, "moot_list_recipes", serde_json::json!({}));
    assert_eq!(recipes["result"]["isError"], false, "{recipes}");
    let recipe = recipes["result"]["structuredContent"]["data"]["recipes"]
        .as_array().expect("typed recipe records")
        .iter()
        .find(|recipe| recipe["name"] == "grounded_synthesis")
        .expect("CognitionKit recipe catalog entry");
    assert!(recipe["version"].is_string());
    assert!(recipe["description"].is_string());
    assert!(recipe["required_capabilities"].is_array());

    let invalid = call(&dispatcher, "moot_list_lenses", serde_json::json!({"verbose": "full"}));
    assert_eq!(invalid["error"]["code"], -32602);
    assert_eq!(invalid["error"]["data"]["code"], "invalid_argument");

    let unavailable = call(&dispatcher, "moot_list_recipes", serde_json::json!({
        "estate_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    }));
    assert_eq!(unavailable["result"]["structuredContent"]["error"]["code"], "estate_unavailable");
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_estate_diagnostics_are_direct_read_only_selected_operations() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));
    let ping = call(&dispatcher, "moot_estate_ping", serde_json::json!({}));
    assert_eq!(ping["result"]["isError"], false, "{ping}");
    assert_eq!(ping["result"]["structuredContent"]["data"]["state"], "mounted");
    assert_eq!(ping["result"]["structuredContent"]["meta"]["effect"], "read");

    let drain = call(&dispatcher, "moot_drain_status", serde_json::json!({}));
    assert_eq!(drain["result"]["isError"], false, "{drain}");
    assert!(drain["result"]["structuredContent"]["data"]["drains"].is_array());

    let rebuild = call(&dispatcher, "moot_rebuild_status", serde_json::json!({}));
    assert_eq!(rebuild["result"]["isError"], false, "{rebuild}");
    assert!(matches!(rebuild["result"]["structuredContent"]["data"]["state"].as_str(), Some("idle") | Some("running")));

    for name in ["moot_estate_status", "moot_estate_map", "moot_timing_report"] {
        let response = call(&dispatcher, name, serde_json::json!({}));
        assert_eq!(response["result"]["isError"], false, "{name}: {response}");
    }

    let invalid = call(&dispatcher, "moot_estate_ping", serde_json::json!({"estate_id":7}));
    assert_eq!(invalid["error"]["code"], -32602);
    assert_eq!(invalid["error"]["data"]["code"], "invalid_argument");
    assert_eq!(invalid["error"]["data"]["correction"], "correct the argument and retry this estate diagnostic");

    let unavailable = call(&dispatcher, "moot_estate_ping", serde_json::json!({
        "estate_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    }));
    assert_eq!(unavailable["result"]["structuredContent"]["error"]["code"], "estate_unavailable");

    let frozen = v2_dispatcher(Arc::new(MonitoringProbe::enabled())).with_posture(EstatePosture::Frozen);
    let frozen_ping = call(&frozen, "moot_estate_ping", serde_json::json!({}));
    assert_eq!(frozen_ping["result"]["isError"], false, "frozen inspection must proceed: {frozen_ping}");
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_memory_list_is_selected_typed_and_keeps_its_cursor_between_calls() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));
    for subject in ["selected memory list first", "selected memory list second"] {
        let filed = call(&dispatcher, "moot_file_memory", serde_json::json!({
            "content": subject,
            "subject": subject,
            "location": "selected-memory-list",
            "wing": "Agentic Memory",
            "exportability": "public"
        }));
        assert_eq!(filed["result"]["isError"], false, "{filed}");
    }

    let first = call(&dispatcher, "moot_memory_list", serde_json::json!({
        "wing": "Agentic Memory", "limit": 1
    }));
    assert_eq!(first["result"]["isError"], false, "{first}");
    assert_eq!(first["result"]["structuredContent"]["meta"]["effect"], "read");
    assert_eq!(first["result"]["structuredContent"]["data"]["memories"].as_array().unwrap().len(), 1);
    assert_eq!(first["result"]["structuredContent"]["data"]["memories"][0]["fetch"]["tool"], "moot_memory_get");
    let cursor = first["result"]["structuredContent"]["data"]["next_cursor"].as_str()
        .expect("selected surface must retain an opaque cursor").to_owned();

    let second = call(&dispatcher, "moot_memory_list", serde_json::json!({
        "wing": "Agentic Memory", "limit": 1, "cursor": cursor
    }));
    assert_eq!(second["result"]["isError"], false, "{second}");
    assert_eq!(second["result"]["structuredContent"]["data"]["memories"].as_array().unwrap().len(), 1);
    assert_eq!(second["result"]["structuredContent"]["data"]["revision"], first["result"]["structuredContent"]["data"]["revision"]);

    let rejected_estate = call(&dispatcher, "moot_memory_list", serde_json::json!({
        "wing": "Agentic Memory", "estate_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    }));
    assert_eq!(rejected_estate["result"]["structuredContent"]["error"]["code"], "estate_unavailable");

    let invalid_filter = call(&dispatcher, "moot_memory_list", serde_json::json!({
        "wing": "Agentic Memory", "filter": "all"
    }));
    assert_eq!(invalid_filter["error"]["code"], -32602);
    assert_eq!(invalid_filter["error"]["data"]["code"], "invalid_argument");
    assert_eq!(invalid_filter["error"]["data"]["correction"], "correct the argument and retry moot_memory_list");
}

#[cfg(feature = "aria-v2")]
#[test]
fn frozen_v2_file_refuses_before_writing() {
    let probe = Arc::new(MonitoringProbe::enabled());
    let dispatcher = v2_dispatcher(probe).with_posture(EstatePosture::Frozen);
    let refused = call(&dispatcher, "moot_file_memory", serde_json::json!({
        "content":"must not land", "subject":"must not land", "location":"frozen"
    }));
    assert_eq!(refused["result"]["isError"], true, "{refused}");
    assert_eq!(refused["result"]["structuredContent"]["error"]["code"], "estate_frozen");
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_monitoring_inspection_is_read_only_when_frozen() {
    let probe = Arc::new(MonitoringProbe::enabled());
    let dispatcher = v2_dispatcher(Arc::clone(&probe)).with_posture(EstatePosture::Frozen);
    let response = call(&dispatcher, "moot_monitoring_status", serde_json::json!({}));

    assert_eq!(
        response["result"]["isError"], false,
        "frozen inspection must proceed: {response}"
    );
    assert_eq!(
        response["result"]["structuredContent"]["data"]["monitoring"],
        "enabled"
    );
    assert_eq!(probe.reads.load(Ordering::SeqCst), 1);
    assert_eq!(probe.writes.load(Ordering::SeqCst), 0);
}

#[cfg(feature = "aria-v2")]
#[test]
fn v2_monitoring_set_writes_only_when_live_and_returns_confirmed_state() {
    let live_probe = Arc::new(MonitoringProbe::enabled());
    let live = v2_dispatcher(Arc::clone(&live_probe));
    let written = call(&live, "moot_monitoring_set", serde_json::json!({"enabled":false}));
    assert_eq!(written["result"]["structuredContent"]["data"]["monitoring"], "disabled");
    assert_eq!(written["result"]["structuredContent"]["meta"]["effect"], "write");
    assert_eq!(live_probe.reads.load(Ordering::SeqCst), 1);
    assert_eq!(live_probe.writes.load(Ordering::SeqCst), 1);

    let frozen_probe = Arc::new(MonitoringProbe::enabled());
    let frozen = v2_dispatcher(Arc::clone(&frozen_probe)).with_posture(EstatePosture::Frozen);
    let refused = call(&frozen, "moot_monitoring_set", serde_json::json!({"enabled":false}));
    assert_eq!(refused["result"]["structuredContent"]["error"]["code"], "estate_frozen");
    assert_eq!(frozen_probe.reads.load(Ordering::SeqCst), 0);
    assert_eq!(frozen_probe.writes.load(Ordering::SeqCst), 0);
}

#[cfg(not(feature = "aria-v2"))]
#[test]
fn v1_public_catalog_facade_remains_full_and_monitoring_keeps_legacy_schema() {
    let tools = build_tool_list_with_flags(true, false);
    let tools = tools.as_array().expect("v1 catalog must be an array");
    assert_eq!(tools.len(), 76, "v1 catalog count changed");
    let monitoring = tools
        .iter()
        .find(|tool| tool["name"] == "moot_monitoring_status")
        .expect("v1 monitoring tool");
    assert!(monitoring["inputSchema"]["properties"]
        .get("enabled")
        .is_some());
    assert!(tools.iter().any(|tool| tool["name"] == "moot_file_memory"));
    assert!(!tools.iter().any(|tool| tool["name"] == "moot_help"));
    assert!(tools.iter().all(|tool| tool.get("annotations").is_none()),
        "selected-v2 annotations must not change the v1 wire catalog");
}
