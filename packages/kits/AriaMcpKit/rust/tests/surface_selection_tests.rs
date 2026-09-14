//! Selected-surface regressions.
//!
//! These tests prove the v2 catalog, admission, frozen policy, typed
//! MonitoringControl read seam, and independent v2 envelope.

use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc,
};

use std::{fs, path::Path};

use aria_mcp::{
    dispatcher::Dispatcher, estate_registry::EstateRegistry, jsonrpc::JSONRPCRequest,
    v2::catalog::{selected_capability_digest, selected_registry_with_vault},
};

use aria_mcp::{estate_posture::EstatePosture, monitoring_control::MonitoringControl};


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

fn tool_list(dispatcher: &Dispatcher) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/list"
    }))
    .expect("test request must decode");
    serde_json::to_value(dispatcher.handle(&request)).expect("response must serialize")
}

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

fn vector<'a>(fixture: &'a serde_json::Value, name: &str) -> &'a serde_json::Value {
    fixture["vectors"]
        .as_array()
        .expect("shared vectors array")
        .iter()
        .find(|entry| entry["name"] == name)
        .unwrap_or_else(|| panic!("shared vector missing: {name}"))
}

struct MonitoringProbe {
    enabled: AtomicBool,
    reads: AtomicUsize,
    writes: AtomicUsize,
}

impl MonitoringProbe {
    fn enabled() -> Self {
        Self {
            enabled: AtomicBool::new(true),
            reads: AtomicUsize::new(0),
            writes: AtomicUsize::new(0),
        }
    }
}

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

fn v2_dispatcher(probe: Arc<MonitoringProbe>) -> Dispatcher {
    Dispatcher::new(
        EstateRegistry::new_inmemory(),
        "ARIA_MCP_Rust",
        "test",
        "test-serial",
        Some(probe),
    )
}

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

#[test]
fn v2_catalog_and_admission_are_the_same_ready_subset() {
    let probe = Arc::new(MonitoringProbe::enabled());
    let dispatcher = v2_dispatcher(Arc::clone(&probe));
    let list = tool_list(&dispatcher);
    let tools = list["result"]["tools"].as_array().expect("tools list");
    assert_eq!(tools.len(), 80, "selected callable roster count");
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
        "moot_fact_search", "moot_fact_timeline", "moot_federated_recall", "moot_file_dataset", "moot_file_fact", "moot_file_memory", "moot_help", "moot_hunt_contradictions", "moot_json_import", "moot_lens_anticipate", "moot_lens_apriori", "moot_lens_associations", "moot_lens_bias", "moot_lens_cohesion", "moot_lens_complexity", "moot_lens_concepts", "moot_lens_constellation", "moot_lens_contradiction", "moot_lens_divergence", "moot_lens_drift", "moot_lens_free_association", "moot_lens_keystones", "moot_lens_latent_themes", "moot_lens_moment", "moot_lens_node_motion", "moot_lens_overlap", "moot_lens_partial_cue", "moot_lens_precedence", "moot_lens_rhythm", "moot_lens_successors", "moot_lens_theme_weather", "moot_lens_trust_synthesis", "moot_link_memories", "moot_list_lenses", "moot_list_recipes",
        "moot_memory_get", "moot_memory_list", "moot_memory_recall_transcript", "moot_memory_search", "moot_migration_confirm", "moot_migration_run", "moot_monitoring_set",
        "moot_monitoring_status", "moot_move_memory", "moot_palace_import", "moot_propose_contradictions",
        "moot_read_journal", "moot_rebuild_status", "moot_recall_connected", "moot_recall_distilled", "moot_recall_precise", "moot_recall_shaped", "moot_recall_temporal", "moot_recall_vague", "moot_recall_walk", "moot_reclassify_fdc", "moot_reindex", "moot_retire_fact", "moot_review_tunnel", "moot_synthesize", "moot_timing_report", "moot_update_memory", "moot_vault_export", "moot_vault_import", "moot_vault_job", "moot_vault_reconcile", "moot_vault_status", "moot_withdraw_memory", "moot_write_journal",
    ]);
    // Build the registry once to read effect; tools/list does not emit effect.
    // Vault defaults on (absent MOOTX01_VAULT env var = on), so pass true to
    // match the dispatcher's catalog and include vault-gated operations.
    let registry = selected_registry_with_vault(true);
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
        "moot_lens_complexity", "moot_synthesize", "moot_dream",
    ] {
        let expected = mission02_catalog_operation(name);
        let actual = tools.iter().find(|tool| tool["name"] == name)
            .unwrap_or_else(|| panic!("selected catalog missing {name}"));
        assert_eq!(actual["inputSchema"], expected["inputSchema"], "{name} input schema");
        assert_eq!(actual["outputSchema"], expected["outputSchema"], "{name} output schema");
        assert_eq!(actual["description"], expected["description"], "{name} description");
        let descriptor = registry.operation(name)
            .unwrap_or_else(|| panic!("registry missing {name}"));
        assert_eq!(
            serde_json::to_value(descriptor.effect).unwrap(),
            expected["effect"],
            "{name} effect"
        );
    }
    // inputSchema-only loop. Every fixture row now carries a live outputSchema;
    // these five operations remain here as a historical test-partition boundary
    // retained so both loops remain an independent check against the hand-written
    // typed schemas in the side fixtures (aria_v2_output_schemas_*.json). The new
    // fixture_snapshot_gates_all_80_operations test gates all 80 operations verbatim
    // against the fixture without side-fixture patching.
    // moot_file_dataset is also gated in the strict loop above; its inputSchema
    // check here is redundant but kept for explicitness.
    for name in [
        "moot_memory_get", "moot_memory_search", "moot_link_memories",
        "moot_review_tunnel", "moot_file_dataset",
    ] {
        let expected = mission02_catalog_operation(name);
        let actual = tools.iter().find(|tool| tool["name"] == name)
            .unwrap_or_else(|| panic!("selected catalog missing {name}"));
        assert_eq!(actual["inputSchema"], expected["inputSchema"], "{name} input schema");
        assert_eq!(actual["description"], expected["description"], "{name} description");
        let descriptor = registry.operation(name)
            .unwrap_or_else(|| panic!("registry missing {name}"));
        assert_eq!(
            serde_json::to_value(descriptor.effect).unwrap(),
            expected["effect"],
            "{name} effect"
        );
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

#[test]
fn v2_json_import_return_id_map_appends_a_second_text_block() {
    // The catalog advertises return_id_map on moot_json_import. This proves the
    // live v2 path honours it: true appends a second content block carrying the
    // id_map JSON, absent leaves the reply at the single prose receipt.
    //
    // Two distinct seeds, because re-importing one seed into the same estate is
    // not a fresh write and the lower refuses it.
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));
    let write_seed = |record: &str| {
        let path = std::env::temp_dir().join(format!("aria-v2-idmap-{}.json", uuid::Uuid::new_v4()));
        fs::write(&path, format!(
            r#"{{"format_version":1,"name":"idmap","records":[{{"id":"{record}","content":"id map seed {record}","event_time":"2026-09-09T00:00:00Z","room":"handoff/room","exportability":"public"}}]}}"#
        )).expect("write id_map seed");
        path
    };

    // Absent return_id_map: exactly one content block, the prose receipt.
    let plain_seed = write_seed("plain");
    let plain = call(&dispatcher, "moot_json_import", serde_json::json!({
        "path": plain_seed.display().to_string(),
    }));
    let _ = fs::remove_file(&plain_seed);
    assert_eq!(plain["result"]["isError"], false, "{plain}");
    let plain_content = plain["result"]["content"].as_array().expect("content array");
    assert_eq!(
        plain_content.len(), 1,
        "absent return_id_map must leave the reply at one block; got {plain_content:?}",
    );

    // The structured data carries id_map either way — the flag gates the block only.
    let structured_id_map = &plain["result"]["structuredContent"]["data"]["id_map"];
    assert!(
        structured_id_map.is_object(),
        "structured data must carry id_map even when the flag is absent; got {structured_id_map}",
    );

    // return_id_map:true: a second block whose text is the exact id_map JSON.
    let mapped_seed = write_seed("seed/mapped");
    let with_map = call(&dispatcher, "moot_json_import", serde_json::json!({
        "path": mapped_seed.display().to_string(),
        "return_id_map": true,
    }));
    let _ = fs::remove_file(&mapped_seed);
    assert_eq!(with_map["result"]["isError"], false, "{with_map}");
    let content = with_map["result"]["content"].as_array().expect("content array");
    assert_eq!(
        content.len(), 2,
        "return_id_map:true must append a second block; got {content:?}",
    );
    assert_eq!(content[1]["type"], "text");

    // Assert on the block's TEXT, not merely on the array length: a length check
    // passes even when the block carries the wrong payload. The record id carries
    // a slash on purpose: serde_json must leave it unescaped, matching Swift's
    // .withoutEscapingSlashes. An escaped \\/ here would be a port divergence.
    let drawer_id = with_map["result"]["structuredContent"]["data"]["id_map"]["seed/mapped"]
        .as_str().expect("id_map must map the seed record id to its drawer id").to_owned();
    assert_eq!(drawer_id, drawer_id.to_lowercase(), "drawer ids are canonical lowercase");
    let expected = format!("{{\"id_map\":{{\"seed/mapped\":\"{drawer_id}\"}}}}");
    assert_eq!(
        content[1]["text"].as_str().expect("second block must be text"),
        expected,
        "second block text must be the exact id_map JSON",
    );
}

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
        EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", None,
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
    assert_eq!(operations.len(), 80);
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

#[test]
fn v2_memory_search_and_get_exclude_provenance_sensitive_rows() {
    use locus_kit::provenance::Sensitivity;
    let registry = EstateRegistry::new_inmemory();
    let normal = seed_provenance_memory(&registry, "q23 boundary normal common-token", Sensitivity::Normal);
    let elevated = seed_provenance_memory(&registry, "q23 boundary elevated common-token", Sensitivity::Elevated);
    let restricted = seed_provenance_memory(&registry, "q23 boundary restricted common-token", Sensitivity::Restricted);
    let secret = seed_provenance_memory(&registry, "q23 boundary secret common-token", Sensitivity::Secret);
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);

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
    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", None);
    let synthesized = call(&dispatcher, "moot_synthesize", serde_json::json!({
        "query":"orchard radio calibration", "limit":1
    }));
    assert_eq!(synthesized["result"]["isError"], false, "{synthesized}");
    let rows = synthesized["result"]["structuredContent"]["data"]["results"]
        .as_array().expect("typed synthesis results");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["memory_id"], relevant.to_lowercase(), "{synthesized}");
}

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
    // The declared output schema for moot_update_memory is { memory_id, mutation }.
    // The old code emitted `operation` (the tool name) which is not in the schema.
    // After the fix the data carries `mutation` (the wire-format mutation name)
    // matching the schema and the Swift port.
    assert_eq!(updated["result"]["structuredContent"]["data"]["mutation"], "confirm");

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
        registry, "ARIA_MCP_Rust", "test", "test-serial", None,
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
    // The registry stores operations in a BTreeMap keyed by public_name, so
    // moot_list_lenses returns tools in alphabetical order.
    assert_eq!(names, [
        "moot_dream", "moot_hunt_contradictions",
        "moot_lens_anticipate", "moot_lens_apriori", "moot_lens_associations",
        "moot_lens_bias", "moot_lens_cohesion", "moot_lens_complexity",
        "moot_lens_concepts", "moot_lens_constellation", "moot_lens_contradiction",
        "moot_lens_divergence", "moot_lens_drift", "moot_lens_free_association",
        "moot_lens_keystones", "moot_lens_latent_themes", "moot_lens_moment",
        "moot_lens_node_motion", "moot_lens_overlap", "moot_lens_partial_cue",
        "moot_lens_precedence", "moot_lens_rhythm", "moot_lens_successors",
        "moot_lens_theme_weather", "moot_lens_trust_synthesis",
        "moot_list_lenses", "moot_list_recipes",
        "moot_recall_connected", "moot_recall_distilled", "moot_recall_precise",
        "moot_recall_shaped", "moot_recall_temporal", "moot_recall_vague", "moot_recall_walk",
        "moot_synthesize",
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

    // verbose:true to fetch the full row including required_capabilities.
    // The terse default omits it, matching the Swift twin
    // (Tests/AriaMCPTests/AriaSurfaceV2Tests.swift).
    let recipes = call(&dispatcher, "moot_list_recipes", serde_json::json!({"verbose": true}));
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


// ---------------------------------------------------------------------------
// v2-path envelope text for moot_list_lenses — through execute_cognition_catalog
// ---------------------------------------------------------------------------

/// Asserts the v2 envelope text for `moot_list_lenses` in terse and verbose
/// modes through the live v2 dispatch path (`execute_cognition_catalog`),
/// the only dispatch route the crate ships.
///
/// Swift twin: the text assertions in `listLensesTerseDefaultAndVerbose`
/// (UtilityTierTests.swift).
#[test]
fn v2_list_lenses_envelope_text_through_v2_path() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));

    // Terse: "Listed N callable cognition tools." with a hint line appended.
    let terse = call(&dispatcher, "moot_list_lenses", serde_json::json!({}));
    assert_eq!(terse["result"]["isError"], false, "terse lenses must not error");
    let terse_text = terse["result"]["content"][0]["text"]
        .as_str()
        .expect("terse response must carry a text block");
    assert!(
        terse_text.contains("callable cognition tools."),
        "terse text must contain 'callable cognition tools.'; got: {terse_text:?}"
    );
    assert!(
        terse_text.contains("(terse — pass verbose:true"),
        "terse text must carry the schema hint; got: {terse_text:?}"
    );
    // Terse must NOT carry the full schema names list.
    assert!(
        !terse_text.contains("(full schema)"),
        "terse text must not mention 'full schema'; got: {terse_text:?}"
    );

    // Verbose: "Listed N callable cognition tools (full schema). Tools: name1, name2, …"
    let verbose = call(&dispatcher, "moot_list_lenses", serde_json::json!({"verbose": true}));
    assert_eq!(verbose["result"]["isError"], false, "verbose lenses must not error");
    let verbose_text = verbose["result"]["content"][0]["text"]
        .as_str()
        .expect("verbose response must carry a text block");
    assert!(
        verbose_text.contains("callable cognition tools (full schema). Tools:"),
        "verbose text must contain 'callable cognition tools (full schema). Tools:'; got: {verbose_text:?}"
    );
    // Verbose must NOT carry the hint.
    assert!(
        !verbose_text.contains("(terse — pass verbose:true"),
        "verbose text must not carry the terse hint; got: {verbose_text:?}"
    );
}

// ---------------------------------------------------------------------------
// id_map second block key ordering with two records (reverse-sorted seed)
// ---------------------------------------------------------------------------

/// Seeding two records whose IDs are in reverse-sorted order and asserting
/// the emitted id_map second block lists them sorted pins the BTreeMap-collect
/// path in surface.rs that enforces sort order regardless of insert order.
///
/// Swift twin: jsonImportIDMapTwoRecordsAreSorted (MultiBlockHintAndTimingWindowTests.swift).
#[test]
fn v2_json_import_id_map_two_records_sorted() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));

    // Two records with intentionally reverse-sorted IDs.
    // "zeta/b" sorts AFTER "alpha/a"; the emitted block must list "alpha/a" first.
    let path = std::env::temp_dir().join(format!("aria-v2-idmap-two-{}.json", uuid::Uuid::new_v4()));
    fs::write(&path, r#"{"format_version":1,"name":"ordering","records":[
        {"id":"zeta/b","content":"ordering test zeta","event_time":"2026-09-09T00:00:00Z","room":"handoff/room","exportability":"public"},
        {"id":"alpha/a","content":"ordering test alpha","event_time":"2026-09-09T00:00:00Z","room":"handoff/room","exportability":"public"}
    ]}"#).expect("write two-record seed");

    let result = call(&dispatcher, "moot_json_import", serde_json::json!({
        "path": path.display().to_string(),
        "return_id_map": true,
    }));
    let _ = fs::remove_file(&path);

    assert_eq!(result["result"]["isError"], false, "two-record import must succeed; got {result}");

    let content = result["result"]["content"].as_array()
        .expect("content must be an array");
    assert_eq!(
        content.len(), 2,
        "two-record import with return_id_map:true must have two blocks; got {content:?}"
    );

    // Recover the drawer IDs from structured data.
    let id_map = &result["result"]["structuredContent"]["data"]["id_map"];
    let alpha_id = id_map["alpha/a"].as_str()
        .expect("id_map must contain alpha/a");
    let zeta_id = id_map["zeta/b"].as_str()
        .expect("id_map must contain zeta/b");

    // The second block text must have alpha/a before zeta/b (sorted keys).
    let expected = format!("{{\"id_map\":{{\"alpha/a\":\"{alpha_id}\",\"zeta/b\":\"{zeta_id}\"}}}}");
    let actual = content[1]["text"].as_str()
        .expect("second block must be a text value");
    assert_eq!(
        actual, expected,
        "id_map block keys must be in sorted order"
    );
}

// ---------------------------------------------------------------------------
// outputSchema-conformance gate for moot_list_lenses — registry-based
// ---------------------------------------------------------------------------

/// Validates a LIVE `moot_list_lenses` response against the `outputSchema`
/// that the operation itself advertises in the selected registry, in both
/// terse and verbose modes.
///
/// The schema is taken from the registry (not hard-coded) so the test tracks
/// the contract instead of duplicating it.
///
/// What this catches:
/// - Before the fix (commit 6ab748019): terse rows omit `input_schema` but the
///   schema declared it as `required` → fails required-key check. Verbose rows
///   include `output_schema` which wasn't declared → fails additionalProperties.
/// - After the fix: terse rows have `required: ["description","name"]`; all
///   four properties are declared so verbose rows pass additionalProperties.
///
/// Swift twin: listLensesResponseConformsToAdvertisedOutputSchema (UtilityTierTests.swift).
#[test]
fn cognition_catalog_output_schema_conforms_to_registry() {
    use aria_mcp::v2::catalog::selected_registry;
    use std::collections::{BTreeSet, HashSet};

    let registry = selected_registry();
    let op = registry.operation("moot_list_lenses")
        .expect("moot_list_lenses must be in the selected registry");
    let output_schema = &op.projection.output_schema;

    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));

    // Validate a live response against the schema.
    let validate = |data: &serde_json::Value, schema: &serde_json::Value, path: &str| {
        let Some(schema_obj) = schema.as_object() else {
            panic!("{path}: schema is not an object");
        };

        match schema_obj.get("type").and_then(|t| t.as_str()) {
            Some("object") => {
                let Some(data_obj) = data.as_object() else {
                    panic!("{path}: expected object, got {data}");
                };
                // required keys must be present
                if let Some(required) = schema_obj.get("required").and_then(|r| r.as_array()) {
                    for req in required {
                        if let Some(key) = req.as_str() {
                            assert!(
                                data_obj.contains_key(key),
                                "{path}: required key \"{key}\" is missing from {data_obj:?}"
                            );
                        }
                    }
                }
                // additionalProperties: false — no keys outside properties
                if schema_obj.get("additionalProperties") == Some(&serde_json::Value::Bool(false)) {
                    if let Some(props) = schema_obj.get("properties").and_then(|p| p.as_object()) {
                        let declared: HashSet<&str> = props.keys().map(String::as_str).collect();
                        for key in data_obj.keys() {
                            assert!(
                                declared.contains(key.as_str()),
                                "{path}: undeclared key \"{key}\" violates additionalProperties:false; declared: {declared:?}"
                            );
                        }
                    }
                }
                // recurse into properties that are present in data
                if let Some(props) = schema_obj.get("properties").and_then(|p| p.as_object()) {
                    for (key, prop_schema) in props {
                        if let Some(child) = data_obj.get(key) {
                            // inline recurse for one level of nesting (array items)
                            if let (Some("array"), Some(items_schema)) = (
                                prop_schema.get("type").and_then(|t| t.as_str()),
                                prop_schema.get("items"),
                            ) {
                                let Some(arr) = child.as_array() else {
                                    panic!("{path}.{key}: expected array, got {child}");
                                };
                                for (i, item) in arr.iter().enumerate() {
                                    let item_path = format!("{path}.{key}[{i}]");
                                    let Some(item_schema_obj) = items_schema.as_object() else { continue };
                                    let Some(item_obj) = item.as_object() else {
                                        panic!("{item_path}: expected object, got {item}");
                                    };
                                    // required
                                    if let Some(req_arr) = item_schema_obj.get("required").and_then(|r| r.as_array()) {
                                        for req in req_arr {
                                            if let Some(k) = req.as_str() {
                                                assert!(
                                                    item_obj.contains_key(k),
                                                    "{item_path}: required key \"{k}\" missing"
                                                );
                                            }
                                        }
                                    }
                                    // additionalProperties: false
                                    if item_schema_obj.get("additionalProperties") == Some(&serde_json::Value::Bool(false)) {
                                        if let Some(item_props) = item_schema_obj.get("properties").and_then(|p| p.as_object()) {
                                            let decl: BTreeSet<&str> = item_props.keys().map(String::as_str).collect();
                                            for key in item_obj.keys() {
                                                assert!(
                                                    decl.contains(key.as_str()),
                                                    "{item_path}: undeclared key \"{key}\" violates additionalProperties:false; declared: {decl:?}"
                                                );
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Some("array") => {
                assert!(data.is_array(), "{path}: expected array, got {data}");
            }
            _ => {} // other types: no assertions needed for this schema shape
        }
    };

    // The declared outputSchema describes the whole structuredContent envelope
    // (surface_version, tool, data, meta, and the optional hint), not the data
    // payload alone, so the envelope is what gets validated against it. Swift
    // twin: listLensesResponseConformsToAdvertisedOutputSchema.
    let terse = call(&dispatcher, "moot_list_lenses", serde_json::json!({}));
    assert_eq!(terse["result"]["isError"], false, "terse lenses must not error");
    let terse_envelope = &terse["result"]["structuredContent"];
    validate(terse_envelope, output_schema, "terse");

    let verbose = call(&dispatcher, "moot_list_lenses", serde_json::json!({"verbose": true}));
    assert_eq!(verbose["result"]["isError"], false, "verbose lenses must not error");
    let verbose_envelope = &verbose["result"]["structuredContent"];
    validate(verbose_envelope, output_schema, "verbose");
}

/// Wall-clock helper for the dream ceiling tests.
///
/// The dispatcher stamps each call with `bench_clock_now()`, which is the wall
/// clock unless `MOOT_BENCH_EPOCH_NOW` pins it. These tests avoid touching that
/// env seam (it is cached process-wide and other tests share the process) and
/// instead choose offsets that hold under either mode: a value 48 hours ahead of
/// the wall clock is beyond the 24-hour ceiling whether the authority clock is
/// the wall clock or a pinned past instant, and a value in the past is inside
/// the ceiling under both, because the ceiling is an upper bound only.
fn wall_clock_millis() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock after epoch")
        .as_millis() as i64
}

fn iso8601_utc(millis: i64) -> String {
    let seconds = millis / 1_000;
    let days = seconds / 86_400;
    let time_of_day = seconds % 86_400;
    // Civil-date conversion from days since 1970-01-01 (Howard Hinnant's
    // algorithm), so the test needs no date dependency.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y, m, d, time_of_day / 3_600, (time_of_day % 3_600) / 60, time_of_day % 60
    )
}

/// The 24-hour ceiling on `moot_dream`'s `now` is enforced by
/// `SelectedDreamAuthority::admit`, and a breach must surface as -32602 rather
/// than an operational refusal envelope. The distinction matters because the
/// cycle prunes recall traces at the stamped instant minus thirty days, so an
/// out-of-range clock would delete every trace in the estate.
#[test]
fn v2_dream_far_future_now_is_refused_as_invalid_argument() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));
    let far_future = iso8601_utc(wall_clock_millis() + 48 * 3_600 * 1_000);
    let response = call(&dispatcher, "moot_dream", serde_json::json!({ "now": far_future }));

    assert!(
        response.get("error").is_some(),
        "a far-future now must raise a JSON-RPC error, got {response}"
    );
    assert_eq!(
        response["error"]["code"], -32602,
        "the ceiling breach must be invalid-params, not an operational refusal: {response}"
    );
    assert_eq!(
        response["error"]["data"]["path"], "now",
        "the error must name the offending argument: {response}"
    );
    assert!(
        response.as_object().expect("response must be an object").get("result").is_none(),
        "a refused call must not also produce a result envelope: {response}"
    );
}

/// A caller instant inside the ceiling is admitted and the cycle runs. A past
/// instant is always inside the ceiling, which keeps the assertion independent
/// of whichever clock the authority is using.
#[test]
fn v2_dream_past_now_is_admitted_and_the_cycle_runs() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));
    let past = iso8601_utc(wall_clock_millis() - 3_600 * 1_000);
    let response = call(&dispatcher, "moot_dream", serde_json::json!({ "now": past }));

    assert!(
        response.get("error").is_none(),
        "an in-range now must not raise a transport error: {response}"
    );
    assert_eq!(
        response["result"]["isError"], false,
        "an in-range now must complete: {response}"
    );
}

/// `associates: "off"` skips the association sweep entirely, so the receipt
/// carries neither association field. The default cadence runs the sweep, so it
/// carries both. Asserting on the presence of the fields proves the mode
/// reached the lower, which a no-error assertion would not.
#[test]
fn v2_dream_associates_off_skips_the_sweep_and_default_runs_it() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));

    let off = call(&dispatcher, "moot_dream", serde_json::json!({ "associates": "off" }));
    assert_eq!(off["result"]["isError"], false, "associates:off must complete: {off}");
    let off_data = &off["result"]["structuredContent"]["data"];
    assert!(
        off_data.get("associationsWritten").is_none(),
        "associates:off must skip the sweep, so associationsWritten is absent: {off_data}"
    );
    assert!(
        off_data.get("associationsNonUniqueProbes").is_none(),
        "associates:off must skip the sweep, so associationsNonUniqueProbes is absent: {off_data}"
    );

    let default = call(&dispatcher, "moot_dream", serde_json::json!({}));
    assert_eq!(default["result"]["isError"], false, "default must complete: {default}");
    let default_data = &default["result"]["structuredContent"]["data"];
    assert!(
        default_data.get("associationsWritten").is_some(),
        "the default cadence must run the sweep: {default_data}"
    );
}

/// `associates: "all"` runs the sweep with the full-estate probe bound rather
/// than the default cadence. The receipt does not expose the limit, and the
/// limit reaches `associate_sweep` through a concrete coordinator with no seam
/// to intercept it, so the exact value passed is NOT asserted here. What is
/// asserted is that the mode reached the lower and ran the sweep. On an empty
/// estate a 50-probe and a 10_000-probe sweep produce identical receipts, so no
/// receipt assertion could distinguish them; the two constants the branch
/// selects between are crate-private and are pinned by
/// `associates_mode_selects_the_documented_probe_bounds` in `v2::dream`.
#[test]
fn v2_dream_associates_all_runs_the_sweep_against_the_full_estate_bound() {
    let dispatcher = v2_dispatcher(Arc::new(MonitoringProbe::enabled()));
    let all = call(&dispatcher, "moot_dream", serde_json::json!({ "associates": "all" }));
    assert_eq!(all["result"]["isError"], false, "associates:all must complete: {all}");
    assert!(
        all["result"]["structuredContent"]["data"].get("associationsWritten").is_some(),
        "associates:all must run the sweep: {all}"
    );

}

/// `associates: "all"` probes all items in the estate; the default cadence
/// probes only the 50 most recent.  With a two-cluster estate — cluster B
/// (older, 8 items) and cluster A (newer, 52 items) — default mode cannot
/// reach cluster B because the 50-probe recency window is exhausted by cluster
/// A alone.  All-mode probes all 60 and writes additional associations across
/// the cluster boundary, so `allWritten > defaultWritten`.
///
/// Mutation gate: if all-mode is changed to use the default 50-probe limit,
/// both runs probe only cluster A and write the same count, failing
/// `allWritten > defaultWritten` ✗.
#[test]
fn v2_dream_all_mode_reaches_older_items_that_default_mode_skips() {
    // --- Estate 1: default mode (50-probe cadence) ---
    let registry_default = EstateRegistry::new_inmemory();
    let coord_default = Arc::clone(&registry_default.coord);
    let handle_default = registry_default.default.handle.clone();
    let dispatcher_default = Dispatcher::new(
        registry_default,
        "ARIA_MCP_Rust", "test", "test-serial", Some(Arc::new(MonitoringProbe::enabled())),
    );

    // Plant cluster B first (older — planted before cluster A so filed_at is
    // strictly earlier and falls outside the 50-probe recency window).
    for i in 1..=8_i32 {
        let r = call(
            &dispatcher_default,
            "moot_file_memory",
            serde_json::json!({
                "content": format!("quantum error qubit alignment {i} correction"),
                "subject": format!("quantum error qubit alignment {i} correction"),
                "location": "test/cluster-b",
                "impatient": true
            }),
        );
        assert!(r.get("error").is_none(), "cluster-B plant {i} must not error: {r}");
    }

    // Plant cluster A (newer — 52 items, fills and exceeds the 50-probe window).
    for i in 1..=52_i32 {
        let r = call(
            &dispatcher_default,
            "moot_file_memory",
            serde_json::json!({
                "content": format!("api timeout endpoint {i} seconds response time"),
                "subject": format!("api timeout endpoint {i} seconds response time"),
                "location": "test/cluster-a",
                "impatient": true
            }),
        );
        assert!(r.get("error").is_none(), "cluster-A plant {i} must not error: {r}");
    }

    let default_result = call(&dispatcher_default, "moot_dream", serde_json::json!({}));
    assert_eq!(
        default_result["result"]["isError"], false,
        "default dream must complete: {default_result}"
    );
    let default_written = coord_default
        .lock()
        .unwrap()
        .recall_associations(&handle_default)
        .expect("recall default associations")
        .len();

    // --- Estate 2: all mode (10,000-probe ceiling) ---
    let registry_all = EstateRegistry::new_inmemory();
    let coord_all = Arc::clone(&registry_all.coord);
    let handle_all = registry_all.default.handle.clone();
    let dispatcher_all = Dispatcher::new(
        registry_all,
        "ARIA_MCP_Rust", "test", "test-serial", Some(Arc::new(MonitoringProbe::enabled())),
    );

    // Same two clusters planted in the same order.
    for i in 1..=8_i32 {
        let r = call(
            &dispatcher_all,
            "moot_file_memory",
            serde_json::json!({
                "content": format!("quantum error qubit alignment {i} correction"),
                "subject": format!("quantum error qubit alignment {i} correction"),
                "location": "test/cluster-b",
                "impatient": true
            }),
        );
        assert!(r.get("error").is_none(), "cluster-B(all) plant {i} must not error: {r}");
    }
    for i in 1..=52_i32 {
        let r = call(
            &dispatcher_all,
            "moot_file_memory",
            serde_json::json!({
                "content": format!("api timeout endpoint {i} seconds response time"),
                "subject": format!("api timeout endpoint {i} seconds response time"),
                "location": "test/cluster-a",
                "impatient": true
            }),
        );
        assert!(r.get("error").is_none(), "cluster-A(all) plant {i} must not error: {r}");
    }

    let all_result = call(
        &dispatcher_all,
        "moot_dream",
        serde_json::json!({ "associates": "all" }),
    );
    assert_eq!(
        all_result["result"]["isError"], false,
        "all-mode dream must complete: {all_result}"
    );
    let all_written = coord_all
        .lock()
        .unwrap()
        .recall_associations(&handle_all)
        .expect("recall all-mode associations")
        .len();

    assert!(
        all_written > default_written,
        "all-mode must write more associations than default ({all_written} > {default_written}): \
         all-mode probes all 60 items including the older cluster-B items that the \
         50-probe default window cannot reach"
    );
}

/// A past `now` within the admission ceiling must be accepted AND used to stamp
/// associations written during the dream cycle.  This verifies that
/// `SelectedDreamAuthority::admit` forwards the proposed instant to the
/// estate's association sweep rather than substituting the wall clock.
///
/// Setup: a wired in-memory estate with three similar items planted via
/// `moot_file_memory impatient:true` (so the VectorStore is populated
/// synchronously).  The dream runs with `now = "2021-01-01T00:00:00Z"`
/// (epoch ms 1_609_459_200_000 — five years before wall clock 2026), so
/// associations are stamped with that date.
///
/// Mutation gate: if `SelectedDreamAuthority::admit` ignores the proposed
/// `now` and uses `self.now_millis` (wall clock) instead, every
/// `association.filed_at` will be approximately 2026, not 2021, and the
/// `(filed_at - 1_609_459_200_000).abs() < 60_000` assertion fails ✗.
#[test]
fn v2_dream_past_now_stamps_associations_with_admitted_instant() {
    // Known past instant: 2021-01-01T00:00:00Z = 1_609_459_200_000 ms epoch.
    // Five years from wall-clock 2026, so the difference is unambiguous.
    let known_past_ms: i64 = 1_609_459_200_000;
    let known_past_str = iso8601_utc(known_past_ms);

    // Pre-clone coord + handle before Dispatcher::new consumes the registry.
    let registry = EstateRegistry::new_inmemory();
    let coord = Arc::clone(&registry.coord);
    let handle = registry.default.handle.clone();
    let dispatcher = Dispatcher::new(
        registry,
        "ARIA_MCP_Rust", "test", "test-serial", Some(Arc::new(MonitoringProbe::enabled())),
    );

    // Plant three similar rows so the association sweep finds proximity pairs.
    for phrase in [
        "the api timeout is thirty seconds on all endpoints",
        "the api timeout is sixty seconds on all endpoints",
        "the api timeout is ninety seconds on all endpoints",
    ] {
        let r = call(
            &dispatcher,
            "moot_file_memory",
            serde_json::json!({
                "content": phrase,
                "subject": phrase,
                "location": "test/notes",
                "impatient": true
            }),
        );
        assert!(r.get("error").is_none(), "plant must not error: {r}");
    }

    // Run the dream with the known past timestamp and all-mode to maximise the
    // chance of associations being written.
    let result = call(
        &dispatcher,
        "moot_dream",
        serde_json::json!({
            "now": known_past_str,
            "associates": "all"
        }),
    );
    assert!(
        result.get("error").is_none(),
        "an in-range past now must not raise a transport error: {result}"
    );
    assert_eq!(
        result["result"]["isError"], false,
        "dream with admitted past now must complete: {result}"
    );

    // Verify the admitted instant was forwarded to the sweep.
    let associations = coord
        .lock()
        .unwrap()
        .recall_associations(&handle)
        .expect("recall associations after past-now dream");

    // If no associations were written, the proximity threshold wasn't met (very
    // low probability with three near-identical rows, but guard explicitly so
    // any failure is visible rather than silent).
    assert!(
        !associations.is_empty(),
        "expected at least one association from three similar planted rows; got zero — \
         the mutation gate cannot be verified"
    );

    // Every association must be stamped within 60 seconds (60,000 ms) of the
    // admitted past instant.  A wall-clock stamp (~2026) would be ~5 years away
    // and fail this assertion.
    let margin_ms: i64 = 60_000;
    for assoc in &associations {
        let diff = (assoc.filed_at - known_past_ms).abs();
        assert!(
            diff < margin_ms,
            "association.filed_at must be close to admitted past ({known_past_str} = {known_past_ms} ms); \
             got {} ms — diff {} ms > {margin_ms} ms",
            assoc.filed_at,
            diff
        );
    }
}

#[test]
fn fixture_snapshot_gates_all_80_operations() {
    // Snapshot gate for the full 80-operation fixture. Loads the mission02
    // fixture, derives the name list from the fixture itself (sorted — so a
    // future catalog addition enters the loop with no hand edit), and compares
    // every row against the live Rust catalog on four fields: inputSchema,
    // outputSchema, description, and effect.
    //
    // The outputSchema field is compared verbatim from the fixture with no
    // patching from the side fixtures (aria_v2_output_schemas_*.json). The
    // existing loop in v2_catalog_and_admission_are_the_same_ready_subset
    // patches outputSchema.properties.data from those side fixtures for the
    // 48 operations it covers, providing an independent check against a
    // hand-written typed schema; both loops are kept.
    //
    // What this test proves by port:
    //   Swift side (snapshotGatesCatalogAgainstMission02Fixture): the fixture
    //     was generated from the live Swift catalog, so comparing live Swift to
    //     the fixture is a snapshot gate — it catches unintended catalog changes
    //     between regenerations but does not independently verify the schema,
    //     because both sides derive from the same source.
    //   Rust side (this test): the fixture carries Swift's values, so comparing
    //     live Rust to it is a genuine port-parity gate. Any divergence on any
    //     of the 32 operations not covered by the existing loop means a real
    //     Swift/Rust discrepancy in that field.
    //
    // Count gate: if the live catalog gains an 81st operation, the assertion
    // that live count equals 80 will fail. Both name directions are checked:
    // every fixture row must have a live tool, and every live tool must have
    // a fixture row. A one-directional check would let a catalog addition pass.
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR must be set during cargo test");
    let fixture_path = Path::new(&manifest_dir)
        .parent()
        .expect("rust manifest must sit beneath AriaMcpKit")
        .join("Tests/Conformance/aria_v2_mission02_vectors.json");
    let raw = fs::read_to_string(&fixture_path)
        .unwrap_or_else(|e| panic!("read mission02 fixture at {}: {e}", fixture_path.display()));
    let fixture: serde_json::Value = serde_json::from_str(&raw)
        .expect("mission02 fixture must be valid JSON");

    let fixture_ops = fixture["catalog"]["operations"]
        .as_array()
        .expect("fixture must contain catalog.operations array");

    // Derive name list from the fixture itself — sorted so a future catalog
    // addition enters the loop with no hand edit.
    let mut fixture_names: Vec<String> = fixture_ops
        .iter()
        .map(|op| op["name"].as_str().expect("operation must have name field").to_owned())
        .collect();
    fixture_names.sort();

    let fixture_by_name: std::collections::HashMap<&str, &serde_json::Value> = fixture_ops
        .iter()
        .map(|op| (op["name"].as_str().unwrap(), op))
        .collect();

    // Build the live tool list (vault enabled by default — absent env var = vault on).
    let probe = Arc::new(MonitoringProbe::enabled());
    let dispatcher = v2_dispatcher(Arc::clone(&probe));
    let tools_response = tool_list(&dispatcher);
    let live_tools = tools_response["result"]["tools"]
        .as_array()
        .expect("tools/list must return a tools array");
    // Build the registry to read effect; tools/list does not emit effect.
    let registry = selected_registry_with_vault(true);

    // Count gates.
    assert_eq!(
        fixture_ops.len(), 80,
        "fixture must contain exactly 80 operations; got {}",
        fixture_ops.len()
    );
    assert_eq!(
        live_tools.len(), 80,
        "live catalog must contain exactly 80 tools; got {}",
        live_tools.len()
    );

    // Bidirectional name coverage.
    let live_name_set: std::collections::HashSet<&str> = live_tools
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    for name in &fixture_names {
        assert!(
            live_name_set.contains(name.as_str()),
            "fixture row {name} has no live tool"
        );
    }
    let fixture_name_set: std::collections::HashSet<&str> = fixture_by_name.keys().copied().collect();
    for name in &live_name_set {
        assert!(
            fixture_name_set.contains(*name),
            "live tool {name} has no fixture row"
        );
    }

    // Four-field comparison for every fixture row against live.
    for name in &fixture_names {
        let expected = fixture_by_name.get(name.as_str())
            .unwrap_or_else(|| panic!("fixture missing {name}"));
        let actual = live_tools.iter().find(|t| t["name"] == name.as_str())
            .unwrap_or_else(|| panic!("{name}: live tool missing from tools/list"));
        assert_eq!(actual["inputSchema"], expected["inputSchema"], "{name} inputSchema");
        assert_eq!(actual["outputSchema"], expected["outputSchema"], "{name} outputSchema");
        assert_eq!(actual["description"], expected["description"], "{name} description");
        let descriptor = registry.operation(name)
            .unwrap_or_else(|| panic!("{name}: missing from registry"));
        assert_eq!(
            serde_json::to_value(descriptor.effect).unwrap(),
            expected["effect"],
            "{name} effect"
        );
    }
}
