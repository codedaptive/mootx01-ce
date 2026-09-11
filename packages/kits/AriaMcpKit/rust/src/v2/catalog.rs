//! The executable subset of the selected ARIA v2 catalog.

use std::collections::BTreeSet;

use serde_json::{json, Value};

use super::{
    operation::{
        V2Availability, V2AvailabilityInputs, V2HelpMetadata, V2OperationDescriptor,
        V2OperationEffect, V2ResultProjection,
    },
    registry::{V2CatalogInput, V2EffectiveRegistry},
};

pub fn selected_registry() -> V2EffectiveRegistry {
    selected_registry_with_vault(crate::tool_list::vault_enabled())
}

pub fn selected_registry_with_vault(vault_on: bool) -> V2EffectiveRegistry {
    let mut inputs = V2AvailabilityInputs::new("aria-v2");
    inputs.enabled_features.insert("core".to_owned());
    if vault_on {
        inputs.enabled_features.insert("vault".to_owned());
    }
    V2EffectiveRegistry::build(
        V2CatalogInput {
            operations: vec![
                descriptor("file_memory", "moot_file_memory", V2OperationEffect::Write,
                    "File a durable memory with explicit subject and placement.",
                    &["file memory", "remember"],
                    json!({"type":"object","properties":{
                        "content":{"type":"string"},"subject":{"type":"string"},"location":{"type":"string"},
                        "wing":{"type":"string"},"sensitivity":{"type":"string","enum":["normal","elevated","restricted","secret"]},
                        "exportability":{"type":"string","enum":["private","public"]},
                        "kind":{"type":"string","enum":["prose","code","transcript","list","structured_json","image_caption"]},
                        "event_time":{"type":"string","format":"date-time"},"impatient":{"type":"boolean"},
                        "estate_id":{"type":"string","format":"uuid"}},
                        "required":["content","subject","location"],"additionalProperties":false})),
                descriptor("update_memory", "moot_update_memory", V2OperationEffect::Write,
                    "Change an explicit mutable field of one memory.",
                    &["change an explicit mutable field of one memory"], memory_mutation_input_schema("moot_update_memory")),
                descriptor("withdraw_memory", "moot_withdraw_memory", V2OperationEffect::Write,
                    "Withdraw one memory from ordinary recall while retaining audit history.",
                    &["withdraw one memory from ordinary recall while retaining audit history"], memory_mutation_input_schema("moot_withdraw_memory")),
                descriptor("erase_memory", "moot_erase_memory", V2OperationEffect::Write,
                    "Permanently erase one memory after explicit confirmation.",
                    &["permanently erase one memory after explicit confirmation"], memory_mutation_input_schema("moot_erase_memory")),
                descriptor("confirm_memory", "moot_confirm_memory", V2OperationEffect::Write,
                    "Mark one memory as user-confirmed.",
                    &["mark one memory as user-confirmed"], memory_mutation_input_schema("moot_confirm_memory")),
                descriptor("move_memory", "moot_move_memory", V2OperationEffect::Write,
                    "Move one memory to an explicit wing and room.",
                    &["move one memory to an explicit wing and room"], memory_mutation_input_schema("moot_move_memory")),
                descriptor("link_memories", "moot_link_memories", V2OperationEffect::Write,
                    "Create a directed typed connection between two memories.",
                    &["create a directed typed connection between two memories"], memory_mutation_input_schema("moot_link_memories")),
                descriptor("review_tunnel", "moot_review_tunnel", V2OperationEffect::Write,
                    "Review a proposed connection and record its settled lifecycle.",
                    &["review a proposed connection and record its settled lifecycle"], memory_mutation_input_schema("moot_review_tunnel")),
                descriptor("connection_search", "moot_connection_search", V2OperationEffect::Read,
                    "Find authorized connections adjacent to one memory.",
                    &["Find authorized connections adjacent to one memory."], knowledge_journal_input_schema("moot_connection_search")),
                descriptor("connection_map", "moot_connection_map", V2OperationEffect::Read,
                    "Traverse the bounded authorized connection graph from one memory.",
                    &["Traverse the bounded authorized connection graph from one memory."], knowledge_journal_input_schema("moot_connection_map")),
                descriptor("file_fact", "moot_file_fact", V2OperationEffect::Write,
                    "Store a typed fact, optionally grounded in a source memory.",
                    &["Store a typed fact, optionally grounded in a source memory."], knowledge_journal_input_schema("moot_file_fact")),
                descriptor("fact_search", "moot_fact_search", V2OperationEffect::Read,
                    "Search authorized facts by text or typed fact fields.",
                    &["Search authorized facts by text or typed fact fields."], knowledge_journal_input_schema("moot_fact_search")),
                descriptor("retire_fact", "moot_retire_fact", V2OperationEffect::Write,
                    "Retire one fact with an explicit reason.",
                    &["Retire one fact with an explicit reason."], knowledge_journal_input_schema("moot_retire_fact")),
                descriptor("fact_timeline", "moot_fact_timeline", V2OperationEffect::Read,
                    "Read the ordered fact history for a subject.",
                    &["Read the ordered fact history for a subject."], knowledge_journal_input_schema("moot_fact_timeline")),
                descriptor("write_journal", "moot_write_journal", V2OperationEffect::Write,
                    "Write one durable journal entry.",
                    &["Write one durable journal entry."], knowledge_journal_input_schema("moot_write_journal")),
                descriptor("read_journal", "moot_read_journal", V2OperationEffect::Read,
                    "Read authorized journal entries in recorded order.",
                    &["Read authorized journal entries in recorded order."], knowledge_journal_input_schema("moot_read_journal")),
                descriptor("hunt_contradictions", "moot_hunt_contradictions", V2OperationEffect::Read,
                    "Analyze authorized memories for contradiction candidates without filing links.",
                    &["Analyze authorized memories for contradiction candidates without filing links."],
                    json!({"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":1000},"estate_id":{"type":"string","format":"uuid"}},"additionalProperties":false})),
                descriptor("propose_contradictions", "moot_propose_contradictions", V2OperationEffect::Write,
                    "Resolve explicitly selected contradiction candidates without rerunning analysis.",
                    &["Resolve explicitly selected contradiction candidates without rerunning analysis."],
                    json!({"type":"object","properties":{"analysis_ref":{"type":"string","minLength":1},"candidate_ids":{"type":"array","minItems":1,"maxItems":1000,"uniqueItems":true,"items":{"type":"string","minLength":1}},"estate_id":{"type":"string","format":"uuid"}},"required":["analysis_ref","candidate_ids"],"additionalProperties":false})),
                descriptor("file_packet", "moot_file_packet", V2OperationEffect::Write,
                    "File a structured work packet and retain its durable drawer identity.",
                    &["file packet", "record work packet"],
                    json!({"type":"object","properties":{
                        "objective":{"type":"string","minLength":1},
                        "sources":{"type":"array","items":{"type":"object","properties":{
                            "description":{"type":"string","minLength":1},"kind":{"type":"string","minLength":1},"uri":{"type":"string"}},
                            "required":["description"],"additionalProperties":false}},
                        "claims":{"type":"array","items":{"type":"object","properties":{
                            "statement":{"type":"string","minLength":1},"confidence":{"type":"number","minimum":0,"maximum":1},
                            "supportingSourceIDs":{"type":"array","items":{"type":"string"}}},
                            "required":["statement"],"additionalProperties":false}},
                        "uncertainties":{"type":"array","items":{"type":"string"}},
                        "next_steps":{"type":"array","items":{"type":"string"}},
                        "model":{"type":"string","minLength":1},"agent":{"type":"string","minLength":1},
                        "sensitivity":{"type":"string","enum":["normal","elevated","restricted","secret"]},
                        "lineage_links":{"type":"array","items":{"type":"object","properties":{
                            "kind":{"type":"string","enum":["derivesFrom","respondsTo"]},
                            "targetPacketID":{"type":"string","format":"uuid"}},
                            "required":["kind","targetPacketID"],"additionalProperties":false}},
                        "wing":{"type":"string","minLength":1},"estate_id":{"type":"string","format":"uuid"}},
                        "required":["objective","model","agent"],"additionalProperties":false})),
                descriptor("help", "moot_help", V2OperationEffect::Read,
                    "Discover the callable operations in this incomplete ARIA v2 build or inspect one exact operation.",
                    &["help", "discover tools"],
                    json!({"type":"object","properties":{"intent":{"type":"string"},"tool":{"type":"string"}},"additionalProperties":false})),
                descriptor("memory_get", "moot_memory_get", V2OperationEffect::Read,
                    "Fetch one or a bounded batch of authorized memories by UUID.",
                    &["get memory", "fetch memory"],
                    json!({"type":"object","properties":{
                        "memory_id":{"type":"string","format":"uuid"},
                        "memory_ids":{"type":"array","items":{"type":"string","format":"uuid"},"minItems":1,"maxItems":50,"uniqueItems":true},
                        "depth":{"type":"string","enum":["subject","distilled","full"]},
                        "estate_id":{"type":"string","format":"uuid"}},
                        "oneOf":[
                            {"required":["memory_id"],"not":{"required":["memory_ids"]}},
                            {"required":["memory_ids"],"not":{"required":["memory_id"]}}
                        ],
                        "additionalProperties":false})),
                descriptor("memory_list", "moot_memory_list", V2OperationEffect::Read,
                    "Enumerate a complete authorized structural memory inventory with revision-bound pagination.",
                    &["list memories", "enumerate memory"],
                    json!({"type":"object","properties":{
                        "wing":{"type":"string","minLength":1},
                        "room":{"type":"string"},
                        "filter":{"type":"string","enum":["missing_subject"]},
                        "limit":{"type":"integer","minimum":1,"maximum":200},
                        "cursor":{"type":"string","minLength":1},
                        "estate_id":{"type":"string","format":"uuid"}},
                        "required":["wing"],"additionalProperties":false})),
                descriptor("memory_search", "moot_memory_search", V2OperationEffect::Read,
                    "Search memories by a query or an anchor, returning compact authorized rows.",
                    &["search memory", "recall"],
                    json!({"type":"object","properties":{
                        "query":{"type":"string"},"near":{"type":"string","format":"uuid"},
                        "limit":{"type":"integer","minimum":1,"maximum":500},
                        // filter: constrains recall by confirmation state (unconfirmed, userConfirmed),
                        // exportability (exportable, contained), or feature flag (pinned). Mirrors Swift.
                        "filter":{"type":"string","enum":["unconfirmed","userConfirmed","exportable","contained","pinned"],"description":"Scope recall by confirmation state or feature flag. 'pinned' constrains to user-pinned memories. Composable with wing and media_type."},
                        "wing":{"type":"string"},
                        // media_type: constrains to drawers with a specific media capture type.
                        // 'voice' → hasVoice (bit 13), 'image' → hasImage (bit 14).
                        "media_type":{"type":"string","enum":["voice","image"]},
                        // door: scoring-strategy adjective. 'guess' reads the A1 per-corpus DoorManifest.
                        "door":{"type":"string","enum":["guess","raw","rrf","matrixAware","discriminative"],"description":"Scoring strategy adjective. 'guess' reads the optimizer-provisioned A1 per-corpus config. Direct values (rrf, matrixAware, raw, discriminative) override it. Absent falls through to scoring, then A1 manifest, then matrixAware."},
                        // scoring: explicit strategy used when door is absent. Fail-closed on unknown values.
                        "scoring":{"type":"string","enum":["raw","rrf","matrixAware","discriminative"]},
                        // ordering: result ordering. 'byRelevanceDesc' routes through the scored recall path.
                        "ordering":{"type":"string","enum":["byCaptureTimeDesc","byCaptureTimeAsc","byRoomAsc","byRelevanceDesc"],"description":"Result ordering. 'byRelevanceDesc' routes through the scored recall pipeline (results are relevance-ordered by score). 'byCaptureTimeDesc' (default), 'byCaptureTimeAsc', 'byRoomAsc' use the LocusKit ordering field."},
                        // frontier_k: candidate-pool depth override. Engine clamps to [64, 256].
                        // Absent uses the engine default formula min(max(limit × 4, 64), 256).
                        "frontier_k":{"type":"integer","minimum":1},
                        "explain":{"type":"boolean","description":"Opt-in flag. When true, appends a discrimination: control line when recall confidence is low or medium, surfacing how clearly the top result separates from the field. Absent or false suppresses the line."},
                        // answer: response-shape adjective. Never (default) → dense rows only.
                        // Always → compose answer block + rows. Auto → confidence gate decides.
                        // Unknown values produce -32602 at decode (Swift parity).
                        "answer":{"type":"string","enum":["never","always","auto"],"description":"Response shape adjective. \"never\" (default) returns dense rows only. \"always\" composes an answer block and rows (requires estate content). \"auto\" lets the server choose the response level by confidence gate (L0 answer-only, L1 answer+rows, or rowsOnly)."},
                        "estate_id":{"type":"string","format":"uuid"}},
                        "oneOf":[
                            {"required":["query"],"not":{"required":["near"]}},
                            {"required":["near"],"not":{"required":["query"]}}
                        ],"additionalProperties":false})),
                descriptor("transcript_recall", "moot_memory_recall_transcript", V2OperationEffect::Read,
                    "Find previous conversations containing the answer to a question, including earlier decisions and troubleshooting.",
                    &["recall transcript", "search conversation"],
                    json!({"type":"object","properties":{
                        "query":{"type":"string","minLength":1},
                        "estate_id":{"type":"string","format":"uuid"}},
                        "required":["query"],"additionalProperties":false})),
                descriptor("monitoring_set", "moot_monitoring_set", V2OperationEffect::Write,
                    "Set daemon telemetry monitoring and return only its confirmed effective state.",
                    &["set monitoring", "enable monitoring", "disable monitoring"],
                    json!({"type":"object","properties":{"enabled":{"type":"boolean"}},
                        "required":["enabled"],"additionalProperties":false})),
                descriptor("monitoring_status", "moot_monitoring_status", V2OperationEffect::Read,
                    "Inspect the current daemon telemetry monitoring state.",
                    &["monitoring status"],
                    json!({"type":"object","properties":{},"additionalProperties":false})),
                descriptor("list_lenses", "moot_list_lenses", V2OperationEffect::Read,
                    "List callable cognition lenses and recipes.",
                    &["list callable cognition lenses and recipes"], cognition_catalog_input_schema()),
                descriptor("list_recipes", "moot_list_recipes", V2OperationEffect::Read,
                    "Browse non-callable recipe records and their callable tools.",
                    &["browse non-callable recipe records and their callable tools"], cognition_catalog_input_schema()),
                descriptor("synthesize", "moot_synthesize", V2OperationEffect::Read,
                    "Produce a grounded synthesis from authorized memories.",
                    &["Produce a grounded synthesis from authorized memories."],
                    json!({"type":"object","properties":{
                        "query":{"type":"string"},
                        // filter: scope synthesis recall. "hasLinks" constrains to drawers with
                        // citations/links — citation-scoped synthesis path (hasLinks feature flag).
                        "filter":{"type":"string","description":"Filter kind: unconfirmed, userConfirmed, exportable, contained, hasLinks. 'hasLinks' scopes synthesis to drawers with links/citations. Composable with query. null is invalid."},
                        "limit":{"type":"integer","minimum":1},
                        "estate_id":{"type":"string","format":"uuid"}},
                        "required":[],"additionalProperties":false})),
                descriptor("dream", "moot_dream", V2OperationEffect::Write,
                    "Run one on-demand maintenance and dreaming cycle.",
                    &["Run one on-demand maintenance and dreaming cycle."],
                    json!({"type":"object","properties":{"estate_id":{"type":"string","format":"uuid"}},"required":[],"additionalProperties":false})),
                descriptor("migration_run", "moot_migration_run", V2OperationEffect::Read,
                    "Evaluate migration plans and return candidates for a separate confirmation.",
                    &["Evaluate migration plans and return candidates for a separate confirmation."],
                    json!({"type":"object","properties":{"corpusName":{"type":"string"},"entries":{"type":"array"},"plans":{"type":"array"},"estate_id":{"type":"string","format":"uuid"}},"required":["corpusName","entries","plans"],"additionalProperties":false})),
                descriptor("migration_confirm", "moot_migration_confirm", V2OperationEffect::Write,
                    "Confirm one previously returned migration candidate.",
                    &["Confirm one previously returned migration candidate."],
                    json!({"type":"object","properties":{"winner_branch_id":{"type":"string","format":"uuid"},"discard_branch_ids":{"type":"array","items":{"type":"string","format":"uuid"}},"estate_id":{"type":"string","format":"uuid"}},"required":["winner_branch_id"],"additionalProperties":false})),
                descriptor("federated_recall", "moot_federated_recall", V2OperationEffect::Read,
                    "Search authorized peer estates from the requesting estate.",
                    &["Search authorized peer estates from the requesting estate."],
                    json!({"type":"object","properties":{"requester_estate_id":{"type":"string","format":"uuid"},"filter":{"type":"string"},"limit":{"type":"integer","minimum":1},"ordering":{"type":"string"},"hydration_level":{"type":"string"}},"required":[],"additionalProperties":false})),
                descriptor("recall_precise", "moot_recall_precise", V2OperationEffect::Read,
                    "Recall known-token answers with a named precision composition.",
                    &["Recall known-token answers with a named precision composition."], recall_input_schema("moot_recall_precise").expect("selected recall schema")),
                descriptor("recall_temporal", "moot_recall_temporal", V2OperationEffect::Read,
                    "Recall memories using an explicit or parsed temporal window.",
                    &["Recall memories using an explicit or parsed temporal window."], recall_input_schema("moot_recall_temporal").expect("selected recall schema")),
                descriptor("recall_connected", "moot_recall_connected", V2OperationEffect::Read,
                    "Recall memories through bounded graph connections.",
                    &["Recall memories through bounded graph connections."], recall_input_schema("moot_recall_connected").expect("selected recall schema")),
                descriptor("recall_shaped", "moot_recall_shaped", V2OperationEffect::Read,
                    "Recall memories with the selected shaped-retrieval composition.",
                    &["Recall memories with the selected shaped-retrieval composition."], recall_input_schema("moot_recall_shaped").expect("selected recall schema")),
                descriptor("recall_distilled", "moot_recall_distilled", V2OperationEffect::Read,
                    "Recall compact distilled memory projections.",
                    &["Recall compact distilled memory projections."], recall_input_schema("moot_recall_distilled").expect("selected recall schema")),
                descriptor("recall_vague", "moot_recall_vague", V2OperationEffect::Read,
                    "Recall memories from a vague cue.",
                    &["Recall memories from a vague cue."], recall_input_schema("moot_recall_vague").expect("selected recall schema")),
                descriptor("recall_walk", "moot_recall_walk", V2OperationEffect::Read,
                    "Recall with the bounded escalation ladder.",
                    &["Recall with the bounded escalation ladder."], recall_input_schema("moot_recall_walk").expect("selected recall schema")),
                descriptor("lens_keystones", "moot_lens_keystones", V2OperationEffect::Read,
                    "Identify hub memories by graph centrality.",
                    &["Identify hub memories by graph centrality."], lens_input_schema("moot_lens_keystones").expect("selected lens schema")),
                descriptor("lens_constellation", "moot_lens_constellation", V2OperationEffect::Read,
                    "Detect community structure in the memory graph.",
                    &["Detect community structure in the memory graph."], lens_input_schema("moot_lens_constellation").expect("selected lens schema")),
                descriptor("lens_free_association", "moot_lens_free_association", V2OperationEffect::Read,
                    "Run bounded spreading activation from one seed memory.",
                    &["Run bounded spreading activation from one seed memory."], lens_input_schema("moot_lens_free_association").expect("selected lens schema")),
                descriptor("lens_bias", "moot_lens_bias", V2OperationEffect::Read,
                    "Compare representation against a reference distribution.",
                    &["Compare representation against a reference distribution."], lens_input_schema("moot_lens_bias").expect("selected lens schema")),
                descriptor("lens_cohesion", "moot_lens_cohesion", V2OperationEffect::Read,
                    "Find low-cohesion memories or dataset anomalies.",
                    &["Find low-cohesion memories or dataset anomalies."], lens_input_schema("moot_lens_cohesion").expect("selected lens schema")),
                descriptor("lens_contradiction", "moot_lens_contradiction", V2OperationEffect::Read,
                    "Surface recorded contradictions and proposed findings.",
                    &["Surface recorded contradictions and proposed findings."], lens_input_schema("moot_lens_contradiction").expect("selected lens schema")),
                descriptor("lens_theme_weather", "moot_lens_theme_weather", V2OperationEffect::Read,
                    "Measure temporal momentum for themes.", &["Measure temporal momentum for themes."], lens_input_schema("moot_lens_theme_weather").expect("selected lens schema")),
                descriptor("lens_latent_themes", "moot_lens_latent_themes", V2OperationEffect::Read,
                    "Extract latent topic clusters.", &["Extract latent topic clusters."], lens_input_schema("moot_lens_latent_themes").expect("selected lens schema")),
                descriptor("lens_drift", "moot_lens_drift", V2OperationEffect::Read,
                    "Measure distribution drift across a temporal split.", &["Measure distribution drift across a temporal split."], lens_input_schema("moot_lens_drift").expect("selected lens schema")),
                descriptor("lens_trust_synthesis", "moot_lens_trust_synthesis", V2OperationEffect::Read,
                    "Recall and rank memories by trust signals.", &["Recall and rank memories by trust signals."], lens_input_schema("moot_lens_trust_synthesis").expect("selected lens schema")),
                descriptor("lens_partial_cue", "moot_lens_partial_cue", V2OperationEffect::Read,
                    "Retrieve memories by partial-cue similarity to an anchor.", &["Retrieve memories by partial-cue similarity to an anchor."], lens_input_schema("moot_lens_partial_cue").expect("selected lens schema")),
                descriptor("lens_anticipate", "moot_lens_anticipate", V2OperationEffect::Read,
                    "Predict next-likely actions from historical patterns.", &["Predict next-likely actions from historical patterns."], lens_input_schema("moot_lens_anticipate").expect("selected lens schema")),
                descriptor("lens_node_motion", "moot_lens_node_motion", V2OperationEffect::Read,
                    "Inspect one memory's movement and churn history.", &["Inspect one memory's movement and churn history."], lens_input_schema("moot_lens_node_motion").expect("selected lens schema")),
                descriptor("lens_successors", "moot_lens_successors", V2OperationEffect::Read,
                    "Suggest probable successor memories by graph traversal.", &["Suggest probable successor memories by graph traversal."], lens_input_schema("moot_lens_successors").expect("selected lens schema")),
                descriptor("lens_overlap", "moot_lens_overlap", V2OperationEffect::Read,
                    "Measure thematic overlap with a comparison estate.", &["Measure thematic overlap with a comparison estate."], lens_input_schema("moot_lens_overlap").expect("selected lens schema")),
                descriptor("lens_divergence", "moot_lens_divergence", V2OperationEffect::Read,
                    "Measure thematic divergence from a comparison estate.", &["Measure thematic divergence from a comparison estate."], lens_input_schema("moot_lens_divergence").expect("selected lens schema")),
                descriptor("lens_associations", "moot_lens_associations", V2OperationEffect::Read,
                    "Mine association rules from memory facets or a dataset.", &["Mine association rules from memory facets or a dataset."], lens_input_schema("moot_lens_associations").expect("selected lens schema")),
                descriptor("lens_concepts", "moot_lens_concepts", V2OperationEffect::Read,
                    "Mine formal concepts from recalled memories or a dataset.", &["Mine formal concepts from recalled memories or a dataset."], lens_input_schema("moot_lens_concepts").expect("selected lens schema")),
                descriptor("lens_apriori", "moot_lens_apriori", V2OperationEffect::Read,
                    "Mine multi-antecedent association rules from the audit log.", &["Mine multi-antecedent association rules from the audit log."], lens_input_schema("moot_lens_apriori").expect("selected lens schema")),
                descriptor("lens_moment", "moot_lens_moment", V2OperationEffect::Read,
                    "Measure memory-fingerprint similarity across time windows.", &["Measure memory-fingerprint similarity across time windows."], lens_input_schema("moot_lens_moment").expect("selected lens schema")),
                descriptor("lens_rhythm", "moot_lens_rhythm", V2OperationEffect::Read,
                    "Detect capture-rhythm patterns from fingerprint bit series.", &["Detect capture-rhythm patterns from fingerprint bit series."], lens_input_schema("moot_lens_rhythm").expect("selected lens schema")),
                descriptor("lens_precedence", "moot_lens_precedence", V2OperationEffect::Read,
                    "Discover temporal precedence from audit-event lags.", &["Discover temporal precedence from audit-event lags."], lens_input_schema("moot_lens_precedence").expect("selected lens schema")),
                descriptor("lens_complexity", "moot_lens_complexity", V2OperationEffect::Read,
                    "Measure entropy and optional mutual information over a field.", &["Measure entropy and optional mutual information over a field."], lens_input_schema("moot_lens_complexity").expect("selected lens schema")),
                descriptor("estate_ping", "moot_estate_ping", V2OperationEffect::Read,
                    "Check whether the selected estate is reachable.",
                    &["estate ping", "check estate"], diagnostic_input_schema()),
                descriptor("estate_status", "moot_estate_status", V2OperationEffect::Read,
                    "Inspect the selected estate status and effective surface metadata.",
                    &["estate status", "inspect estate"], diagnostic_input_schema()),
                descriptor("estate_map", "moot_estate_map", V2OperationEffect::Read,
                    "Inspect the selected estate structural map.",
                    &["estate map", "map estate"], diagnostic_input_schema()),
                descriptor("drain_status", "moot_drain_status", V2OperationEffect::Read,
                    "Inspect background drain progress.",
                    &["drain status", "background progress"], diagnostic_input_schema()),
                descriptor("rebuild_status", "moot_rebuild_status", V2OperationEffect::Read,
                    "Inspect background rebuild progress.",
                    &["rebuild status", "background rebuild"], diagnostic_input_schema()),
                descriptor("timing_report", "moot_timing_report", V2OperationEffect::Read,
                    "Read the current timing report.",
                    &["timing report", "performance timing"], diagnostic_input_schema()),
                descriptor("reindex", "moot_reindex", V2OperationEffect::Write,
                    "Request a bounded index backfill for the selected estate.",
                    &["Request a bounded index backfill for the selected estate."], data_mobility_input_schema("moot_reindex")),
                descriptor("reclassify_fdc", "moot_reclassify_fdc", V2OperationEffect::Write,
                    "Reclassify stored field-density categories.",
                    &["Reclassify stored field-density categories."], data_mobility_input_schema("moot_reclassify_fdc")),
                descriptor_with_features("palace_import", "moot_palace_import", V2OperationEffect::Write,
                    "Import a MemPalace root containing palace/chroma.sqlite3 into the selected estate.",
                    &["Import a MemPalace root containing palace/chroma.sqlite3 into the selected estate."], data_mobility_input_schema("moot_palace_import"), &["vault"]),
                descriptor_with_features("json_import", "moot_json_import", V2OperationEffect::Write,
                    "Import a local JSON source into the selected estate.",
                    &["Import a local JSON source into the selected estate."], data_mobility_input_schema("moot_json_import"), &["vault"]),
                descriptor("file_dataset", "moot_file_dataset", V2OperationEffect::Write,
                    "File a structured dataset into the selected estate.",
                    &["File a structured dataset into the selected estate."], data_mobility_input_schema("moot_file_dataset")),
                descriptor("dataset_query", "moot_dataset_query", V2OperationEffect::Read,
                    "Query a dataset with a strict typed predicate.",
                    &["Query a dataset with a strict typed predicate."], data_mobility_input_schema("moot_dataset_query")),
                descriptor("dataset_stats", "moot_dataset_stats", V2OperationEffect::Read,
                    "Read summary statistics for one dataset.",
                    &["Read summary statistics for one dataset."], data_mobility_input_schema("moot_dataset_stats")),
                descriptor_with_features("vault_export", "moot_vault_export", V2OperationEffect::Read,
                    "Export the authorized selected estate scope to a local vault.",
                    &["Export the authorized selected estate scope to a local vault."], data_mobility_input_schema("moot_vault_export"), &["vault"]),
                descriptor_with_features("vault_import", "moot_vault_import", V2OperationEffect::Write,
                    "Import a local vault into the selected estate.",
                    &["Import a local vault into the selected estate."], data_mobility_input_schema("moot_vault_import"), &["vault"]),
                descriptor_with_features("vault_status", "moot_vault_status", V2OperationEffect::Read,
                    "Inspect local vault synchronization state.",
                    &["Inspect local vault synchronization state."], data_mobility_input_schema("moot_vault_status"), &["vault"]),
                descriptor_with_features("vault_reconcile", "moot_vault_reconcile", V2OperationEffect::Write,
                    "Compare a local vault with the estate and optionally apply reconciliation.",
                    &["Compare a local vault with the estate and optionally apply reconciliation."], data_mobility_input_schema("moot_vault_reconcile"), &["vault"]),
                descriptor_with_features("vault_job", "moot_vault_job", V2OperationEffect::Read,
                    "Fetch the status of one vault job. Returns running, complete, or failed status with progress details.",
                    &["Fetch the status of one vault job."], data_mobility_input_schema("moot_vault_job"), &["vault"]),
                descriptor("packet_get", "moot_packet_get", V2OperationEffect::Read,
                    "Fetch one authorized work packet by its durable drawer UUID.",
                    &["get packet", "fetch work packet"],
                    json!({"type":"object","properties":{
                        "drawer_id":{"type":"string","format":"uuid"},"wing":{"type":"string","minLength":1},
                        "estate_id":{"type":"string","format":"uuid"}},
                        "required":["drawer_id"],"additionalProperties":false})),
                descriptor("packet_lineage", "moot_packet_lineage", V2OperationEffect::Read,
                    "Trace authorized packet antecedents breadth-first from a durable drawer UUID.",
                    &["packet lineage", "trace work packet"],
                    json!({"type":"object","properties":{
                        "drawer_id":{"type":"string","format":"uuid"},"wing":{"type":"string","minLength":1},
                        "max_depth":{"type":"integer","minimum":1,"maximum":50},
                        "estate_id":{"type":"string","format":"uuid"}},
                        "required":["drawer_id"],"additionalProperties":false})),
                descriptor("packet_list", "moot_packet_list", V2OperationEffect::Read,
                    "List authorized work packets in newest-first capture order.",
                    &["list packets", "list work packets"],
                    json!({"type":"object","properties":{
                        "wing":{"type":"string","minLength":1},"limit":{"type":"integer","minimum":1,"maximum":100},
                        "estate_id":{"type":"string","format":"uuid"}},"additionalProperties":false})),
            ],
            directory_records: Vec::new(),
        },
        inputs,
    ).expect("the static selected ARIA v2 registry must be valid")
}

pub fn selected_tools() -> Value {
    selected_tools_for_registry(&selected_registry())
}

pub fn selected_tools_for_registry(registry: &V2EffectiveRegistry) -> Value {
    Value::Array(
        registry
            .operations()
            .map(|operation| {
                json!({
                    "name": operation.public_name,
                    "description": operation.help.description,
                    "inputSchema": operation.input_schema,
                    "outputSchema": operation.projection.output_schema,
                    "annotations": tool_annotations(operation),
                })
            })
            .collect(),
    )
}

fn tool_annotations(operation: &V2OperationDescriptor) -> Value {
    let additive_write = matches!(
        operation.identity.as_str(),
        "file_memory"
            | "link_memories"
            | "file_fact"
            | "write_journal"
            | "file_dataset"
            | "file_packet"
            | "propose_contradictions"
    );
    let open_world = matches!(
        operation.identity.as_str(),
        "palace_import" | "json_import" | "vault_export" | "vault_import" | "vault_reconcile"
    );
    json!({
        "readOnlyHint": operation.effect == V2OperationEffect::Read,
        "destructiveHint": operation.effect == V2OperationEffect::Write && !additive_write,
        "openWorldHint": open_world,
    })
}

pub fn selected_capability_digest() -> String {
    super::capability_digest::registry_capability_digest(&selected_registry())
}

fn descriptor(
    identity: &str,
    name: &str,
    effect: V2OperationEffect,
    description: &str,
    intents: &[&str],
    input_schema: Value,
) -> V2OperationDescriptor {
    V2OperationDescriptor {
        identity: identity.to_owned(),
        public_name: name.to_owned(),
        effect,
        availability: V2Availability {
            required_features: BTreeSet::from(["core".to_owned()]),
            ..V2Availability::default()
        },
        input_schema,
        projection: V2ResultProjection {
            output_schema: output_schema(name, effect),
            compact_text: true,
        },
        help: V2HelpMetadata {
            description: description.to_owned(),
            intents: intents.iter().map(|value| (*value).to_owned()).collect(),
            example: None,
        },
        recipe_bindings: Vec::new(),
    }
}

fn descriptor_with_features(
    identity: &str,
    name: &str,
    effect: V2OperationEffect,
    description: &str,
    intents: &[&str],
    input_schema: Value,
    required_features: &[&str],
) -> V2OperationDescriptor {
    let mut operation = descriptor(identity, name, effect, description, intents, input_schema);
    operation.availability.required_features = required_features
        .iter()
        .map(|feature| (*feature).to_owned())
        .collect();
    operation
}

fn output_schema(name: &str, effect: V2OperationEffect) -> Value {
    let effect = match effect {
        V2OperationEffect::Read => "read",
        V2OperationEffect::Write => "write",
    };
    let data_schema = if name == "moot_memory_list" {
        json!({"type":"object","properties":{
            "memories":{"type":"array","items":{"type":"object","properties":{
                "memory_id":{"type":"string","format":"uuid"},
                "subject":{"type":"string"},
                "score":{"type":"number"},
                "provenance":{"type":"string"},
                "context":{"type":"string"},
                "fetch":{"type":"object","properties":{
                    "tool":{"const":"moot_memory_get"},
                    "arguments":{"type":"object","properties":{"memory_id":{"type":"string","format":"uuid"}},
                        "required":["memory_id"],"additionalProperties":false}},
                    "required":["tool","arguments"],"additionalProperties":false}},
                "required":["memory_id","fetch"],"additionalProperties":false}},
            "has_more":{"type":"boolean"},
            "next_cursor":{"type":"string"},
            "revision":{"type":"string"}},
            "required":["memories","has_more","revision"],"additionalProperties":false})
    } else if let Some(schema) = contradiction_data_schema(name) {
        schema
    } else if let Some(schema) = knowledge_journal_data_schema(name) {
        schema
    } else if let Some(schema) = cognition_catalog_data_schema(name) {
        schema
    } else if let Some(schema) = lens_data_schema(name) {
        schema
    } else if name == "moot_synthesize" {
        synthesis_data_schema()
    } else if let Some(schema) = remaining_data_schema(name) {
        schema
    } else if name == "moot_recall_distilled" {
        distilled_recall_data_schema()
    } else if recall_input_schema(name).is_some() {
        recall_data_schema()
    } else if let Some(schema) = estate_diagnostics_data_schema(name) {
        schema
    } else if let Some(schema) = data_mobility_data_schema(name) {
        schema
    } else {
        json!({"type":"object","additionalProperties":true})
    };
    json!({"type":"object","properties":{
        "surface_version":{"const":"v2"},"tool":{"const":name},
        "data":data_schema,
        "meta":{"type":"object","properties":{"completeness":{"const":"incomplete"},"effect":{"const":effect}},
            "required":["completeness","effect"],"additionalProperties":true}},
        "required":["surface_version","tool","data","meta"],"additionalProperties":false})
}

fn fetch_schema() -> Value {
    json!({"type":"object","properties":{"tool":{"const":"moot_memory_get"},"arguments":{"type":"object","properties":{"memory_id":{"type":"string","format":"uuid"}},"required":["memory_id"],"additionalProperties":false}},"required":["tool","arguments"],"additionalProperties":false})
}
fn placement_schema() -> Value {
    json!({"type":"object","properties":{"wing":{"type":"string"},"room":{"type":"string"}},"required":["wing","room"],"additionalProperties":false})
}
fn compact_memory_schema() -> Value {
    json!({"type":"object","properties":{"memory_id":{"type":"string","format":"uuid"},"subject":{"type":"string"},"score":{"type":"number"},"provenance":{"type":"string"},"context":{"type":"string"},"excerpt":{"type":"string","maxLength":512},"fetch":fetch_schema()},"required":["memory_id","fetch"],"additionalProperties":false})
}
fn recall_data_schema() -> Value {
    json!({"type":"object","properties":{"results":{"type":"array","items":lens_memory_row_schema()},"capabilities":lens_capabilities_schema()},"required":["results"],"additionalProperties":false})
}

// moot_recall_distilled declares its own data schema: the shared memory row plus
// a required capabilities object that always carries the distillation savings
// (ARIA_V2_CONTRACT.md, "Distilled recall savings"). Mirrors the Swift
// distilledRecallDataSchema key for key so both ports digest identically.
fn distilled_recall_data_schema() -> Value {
    json!({"type":"object","properties":{"results":{"type":"array","items":lens_memory_row_schema()},"capabilities":distilled_capabilities_schema()},"required":["results","capabilities"],"additionalProperties":false})
}

fn distilled_capabilities_schema() -> Value {
    json!({"type":"object","properties":{"discrimination":{"type":"string","enum":["low","medium"]},"distillation":distillation_schema()},"required":["distillation"],"additionalProperties":false})
}

// The skim object is declared now so schema consumers do not change when skim
// is wired; it is absent until then.
fn distillation_schema() -> Value {
    json!({"type":"object","properties":{"returnedTokens":{"type":"integer","minimum":0},"originalTokens":{"type":"integer","minimum":0},"savedTokens":{"type":"integer"},"savedPercent":{"type":"integer"},"estimated":{"type":"boolean"},"estimator":{"type":"string"},"skim":{"type":"object","properties":{"omittedTokens":{"type":"integer","minimum":0}},"required":["omittedTokens"],"additionalProperties":false},"display":{"type":"string"}},"required":["returnedTokens","originalTokens","savedTokens","savedPercent","estimated","estimator","display"],"additionalProperties":false})
}

fn remaining_data_schema(name: &str) -> Option<Value> {
    let uuid = || json!({"type":"string","format":"uuid"});
    let count = || json!({"type":"integer","minimum":0});
    let exact = |properties, required| json!({"type":"object","properties":properties,"required":required,"additionalProperties":false});
    match name {
        "moot_file_memory" => Some(exact(
            json!({"memory_id":uuid(),"placement":placement_schema(),"fetch":fetch_schema()}),
            json!(["memory_id", "placement", "fetch"]),
        )),
        "moot_memory_search" => {
            // `answer` is optional: absent when answer:never or confidence is WEAK.
            // Presence signals a non-empty answer block from GroundedSynthesis + packager.
            let signals = exact(
                json!({"margin":{"type":"number"},"lane_agreement":{"type":"number"},"dense_spread":{"type":"number"},"containment":{"type":"boolean"}}),
                json!(["margin","lane_agreement","dense_spread","containment"]),
            );
            let answer_block = exact(
                json!({"text":{"type":"string"},"confidence":{"type":"string","enum":["confident","intermediate"]},"citations":{"type":"array","items":uuid()},"signals":signals}),
                json!(["text","confidence","citations","signals"]),
            );
            Some(exact(
                json!({"results":{"type":"array","items":compact_memory_schema()},"answer":answer_block}),
                json!(["results"]),
            ))
        }
        "moot_memory_get" => {
            let memory = exact(
                json!({"memory_id":uuid(),"subject":{"type":"string"},"distilled":{"type":"string"},"content":{"type":"string"},"placement":placement_schema(),"filed_at":{"type":"string","format":"date-time"},"event_time":{"type":"string","format":"date-time"},"state":{"type":"string"},"trust":{"type":"string"},"sensitivity":{"type":"string"},"exportability":{"type":"string"},"confirmation":{"type":"string"},"lineage_id":uuid(),"fetch":fetch_schema()}),
                json!(["memory_id", "fetch"]),
            );
            Some(exact(
                json!({"memories":{"type":"array","items":memory}}),
                json!(["memories"]),
            ))
        }
        "moot_memory_recall_transcript" => {
            let fetch = fetch_schema();
            let row = exact(
                json!({"memory_id":uuid(),"room":{"type":"string"},"excerpt":{"type":"string"},"score":{"type":"number"},"fetch":fetch}),
                json!(["memory_id", "room", "excerpt", "score", "fetch"]),
            );
            let evidence = exact(
                json!({"status":{"type":"string","enum":["applied","unavailable"]},"policy_version":{"type":"string"},"fresh_head_candidates":count(),"scored_head_candidates":count(),"freshness_verified":{"type":"boolean"},"reason":{"type":"string"},"encoder_model_id":{"type":"string"},"encoder_model_version":{"type":"string"},"query_dimension":{"type":"integer","minimum":1},"classifier_profile":{"type":"string"},"classifier_model_revision":{"type":"string"},"pool":{"type":"integer","minimum":1},"head":{"type":"integer","minimum":1},"spans":{"type":"integer","minimum":1},"rrf_k":{"type":"integer","minimum":1},"serving_generation":count()}),
                json!([
                    "status",
                    "policy_version",
                    "fresh_head_candidates",
                    "scored_head_candidates",
                    "freshness_verified"
                ]),
            );
            Some(exact(
                json!({"matches":{"type":"array","items":row},"strict_rerank":evidence}),
                json!(["matches", "strict_rerank"]),
            ))
        }
        "moot_update_memory" => Some(exact(
            json!({"memory_id":uuid(),"mutation":{"type":"string"}}),
            json!(["memory_id", "mutation"]),
        )),
        "moot_withdraw_memory" => Some(exact(json!({"memory_id":uuid()}), json!(["memory_id"]))),
        "moot_erase_memory" => Some(exact(
            json!({"memory_id":uuid(),"refused_sibling_memory_ids":{"type":"array","items":uuid()}}),
            json!(["memory_id", "refused_sibling_memory_ids"]),
        )),
        "moot_confirm_memory" => Some(exact(
            json!({"memory_id":uuid(),"mutation":{"const":"confirm"}}),
            json!(["memory_id", "mutation"]),
        )),
        "moot_move_memory" => Some(exact(
            json!({"memory_id":uuid(),"placement":placement_schema()}),
            json!(["memory_id", "placement"]),
        )),
        "moot_link_memories" => Some(exact(
            json!({"tunnel_id":uuid(),"from_id":uuid(),"to_id":uuid(),"kind":{"type":"string"},"lifecycle":{"type":"string","enum":["active","proposed","superseded","withdrawn"]}}),
            json!(["tunnel_id", "kind", "lifecycle"]),
        )),
        "moot_review_tunnel" => Some(
            json!({"oneOf":[exact(json!({"tunnel_id":uuid(),"new_endorser":{"type":"boolean"},"distinct_endorsers":count(),"contested":{"type":"boolean"}}),json!(["tunnel_id","new_endorser","distinct_endorsers","contested"])),exact(json!({"tunnel_id":uuid(),"withdrawn":{"type":"boolean"},"contested":{"type":"boolean"}}),json!(["tunnel_id","withdrawn","contested"]))]}),
        ),
        "moot_dream" => Some(exact(
            json!({"candidatesConsidered":count(),"proposalsEmitted":{"type":"array","items":{"type":"string"}},"suppressedDuplicates":count(),"belowThreshold":count(),"contradictionsProposed":count(),"contradictionCandidatesBorderline":count(),"subjectsBackfilled":count(),"associationsWritten":count(),"associationsNonUniqueProbes":count()}),
            json!([
                "candidatesConsidered",
                "proposalsEmitted",
                "suppressedDuplicates",
                "belowThreshold",
                "contradictionsProposed",
                "contradictionCandidatesBorderline"
            ]),
        )),
        "moot_migration_run" => {
            let report = exact(
                json!({"branch_id":uuid(),"query_count":count(),"recall_overlap":{"type":"number"},"recall_precision":{"type":"number"},"mean_reciprocal_rank":{"type":"number"},"not_found_in_branch":{"type":"array","items":{"type":"string"}},"new_in_branch":{"type":"array","items":{"type":"string"}},"evaluated_at":{"type":"string","format":"date-time"}}),
                json!([
                    "branch_id",
                    "query_count",
                    "recall_overlap",
                    "recall_precision",
                    "mean_reciprocal_rank",
                    "not_found_in_branch",
                    "new_in_branch",
                    "evaluated_at"
                ]),
            );
            let ranking = exact(
                json!({"branch_id":uuid(),"plan_name":{"type":"string"},"combined_score":{"type":"number"},"recall_overlap":{"type":"number"},"mean_reciprocal_rank":{"type":"number"}}),
                json!([
                    "branch_id",
                    "plan_name",
                    "combined_score",
                    "recall_overlap",
                    "mean_reciprocal_rank"
                ]),
            );
            let disqualified = exact(
                json!({"branch_id":uuid(),"plan_name":{"type":"string"},"lost_concepts":{"type":"array","items":{"type":"string"}}}),
                json!(["branch_id", "plan_name", "lost_concepts"]),
            );
            Some(exact(
                json!({"reports":{"type":"array","items":report},"winner_branch_id":uuid(),"winner_plan_name":{"type":"string"},"rankings":{"type":"array","items":ranking},"disqualified":{"type":"array","items":disqualified}}),
                json!(["reports", "rankings", "disqualified"]),
            ))
        }
        "moot_migration_confirm" => {
            let outcome = exact(
                json!({"branch_id":uuid(),"status":{"type":"string","enum":["discarded","already_discarded","winner_skipped","unknown","failed"]}}),
                json!(["branch_id", "status"]),
            );
            Some(exact(
                json!({"status":{"const":"promoted"},"promoted_branch_id":uuid(),"discarded_branch_ids":{"type":"array","items":uuid()},"discard_outcomes":{"type":"array","items":outcome}}),
                json!([
                    "status",
                    "promoted_branch_id",
                    "discarded_branch_ids",
                    "discard_outcomes"
                ]),
            ))
        }
        "moot_federated_recall" => Some(exact(
            json!({"source_estate_id":uuid(),"requester_estate_id":uuid(),"grant_id":uuid(),"results":{"type":"array","items":compact_memory_schema()}}),
            json!([
                "source_estate_id",
                "requester_estate_id",
                "grant_id",
                "results"
            ]),
        )),
        "moot_vault_export" | "moot_vault_import" => Some(exact(
            json!({"job_id":uuid(),"kind":{"type":"string","enum":["export","import"]},"vault_path":{"type":"string"},"status":{"const":"running"},"note_count":count(),"scope":{"type":"string"}}),
            json!(["job_id", "kind", "vault_path", "status"]),
        )),
        "moot_vault_job" => Some(exact(
            json!({"job_id":uuid(),"kind":{"type":"string","enum":["export","import"]},"vault_path":{"type":"string"},"elapsed_ms":count(),"status":{"type":"string","enum":["running","complete","failed"]},"progress":exact(json!({"processed":count(),"total":count()}),json!(["processed","total"])),"drawers_written":count(),"drawers_updated":count(),"items_skipped":count(),"tunnels_created":count(),"fdc_classified":count(),"fdc_unclassified":count(),"drawers_skipped_unchanged":count(),"drawers_skipped_tombstoned":count(),"note_count":count(),"exported_at":{"type":"string","format":"date-time"},"error":{"type":"string"}}),
            json!(["job_id", "kind", "vault_path", "elapsed_ms", "status"]),
        )),
        "moot_monitoring_set" => Some(exact(
            json!({"monitoring":{"type":"string","enum":["enabled","disabled"]}}),
            json!(["monitoring"]),
        )),
        "moot_monitoring_status" => Some(exact(
            json!({"monitoring":{"type":"string","enum":["enabled","disabled","unavailable"]}}),
            json!(["monitoring"]),
        )),
        "moot_file_packet" => Some(exact(
            json!({"drawer_id":uuid(),"packet_id":uuid(),"schema_version":{"type":"integer","minimum":1},"objective":{"type":"string"},"sources":count(),"claims":count(),"uncertainties":count(),"next_steps":count(),"lineage_links":count(),"sensitivity":{"type":"string","enum":["normal","elevated","restricted","secret"]}}),
            json!([
                "drawer_id",
                "packet_id",
                "schema_version",
                "objective",
                "sources",
                "claims",
                "uncertainties",
                "next_steps",
                "lineage_links",
                "sensitivity"
            ]),
        )),
        "moot_packet_get" => Some(exact(json!({"packet":packet_schema()}), json!(["packet"]))),
        "moot_packet_list" => {
            let summary = exact(
                json!({"drawer_id":uuid(),"packet_id":uuid(),"objective":{"type":"string"},"model":{"type":"string"},"agent":{"type":"string"},"lineage_count":count()}),
                json!([
                    "drawer_id",
                    "packet_id",
                    "objective",
                    "model",
                    "agent",
                    "lineage_count"
                ]),
            );
            Some(exact(
                json!({"packets":{"type":"array","items":summary},"total":count()}),
                json!(["packets", "total"]),
            ))
        }
        "moot_packet_lineage" => Some(exact(
            json!({"root":uuid(),"antecedents":{"type":"array","items":uuid()},"count":count()}),
            json!(["root", "antecedents", "count"]),
        )),
        "moot_help" => Some(help_data_schema()),
        _ => None,
    }
}

fn packet_schema() -> Value {
    let uuid = || json!({"type":"string","format":"uuid"});
    let exact = |properties, required| json!({"type":"object","properties":properties,"required":required,"additionalProperties":false});
    let source = exact(
        json!({"id":uuid(),"description":{"type":"string"},"uri":{"type":"string"},"kind":{"type":"string"}}),
        json!(["id", "description", "kind"]),
    );
    let claim = exact(
        json!({"id":uuid(),"statement":{"type":"string"},"confidence":{"type":"number"},"supporting_source_ids":{"type":"array","items":uuid()}}),
        json!(["id", "statement", "confidence", "supporting_source_ids"]),
    );
    let provenance = exact(
        json!({"model":{"type":"string"},"agent":{"type":"string"},"created_at":{"type":"string","format":"date-time"},"updated_at":{"type":"string","format":"date-time"}}),
        json!(["model", "agent", "created_at", "updated_at"]),
    );
    let link = exact(
        json!({"kind":{"type":"string","enum":["derivesFrom","respondsTo"]},"target_packet_id":uuid()}),
        json!(["kind", "target_packet_id"]),
    );
    exact(
        json!({"drawer_id":uuid(),"packet_id":uuid(),"schema_version":{"type":"integer","minimum":1},"future_schema":{"type":"boolean"},"objective":{"type":"string"},"sources":{"type":"array","items":source},"claims":{"type":"array","items":claim},"uncertainties":{"type":"array","items":{"type":"string"}},"next_steps":{"type":"array","items":{"type":"string"}},"provenance":provenance,"lineage_links":{"type":"array","items":link}}),
        json!([
            "drawer_id",
            "packet_id",
            "schema_version",
            "future_schema",
            "objective",
            "sources",
            "claims",
            "uncertainties",
            "next_steps",
            "provenance",
            "lineage_links"
        ]),
    )
}

fn help_data_schema() -> Value {
    let operation = json!({"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"description":{"type":"string"},"effect":{"type":"string","enum":["read","write"]},"input_schema":{"type":"object"},"output_schema":{"type":"object"},"intents":{"type":"array","items":{"type":"string"}}},"required":["id","name","description","effect","input_schema","output_schema","intents"],"additionalProperties":false});
    let operations = json!({"type":"array","items":operation.clone()});
    let record = json!({"type":"object","properties":{"recipe_id":{"type":"string"},"description":{"type":"string"},"callable":{"const":false},"callable_tools":{"type":"array","items":{"type":"string"}}},"required":["recipe_id","description","callable","callable_tools"],"additionalProperties":false});
    json!({"oneOf":[{"type":"object","properties":{"operation":operation},"required":["operation"],"additionalProperties":false},{"type":"object","properties":{"intent":{"type":"string"},"operations":operations.clone()},"required":["intent","operations"],"additionalProperties":false},{"type":"object","properties":{"operations":operations,"directory_records":{"type":"array","items":record}},"required":["operations","directory_records"],"additionalProperties":false}]})
}

fn synthesis_data_schema() -> Value {
    json!({"type":"object","properties":{
        "summary":{"type":"string"},
        "cues":{"type":"array","items":{"type":"string"}},
        "results":{"type":"array","items":{"type":"object","properties":{
            "memory_id":{"type":"string","format":"uuid"},
            "subject":{"type":"string"},"score":{"type":"number"},
            "provenance":{"type":"string"},"context":{"type":"string"},
            "excerpt":{"type":"string","maxLength":512},
            "fetch":{"type":"object","properties":{
                "tool":{"const":"moot_memory_get"},
                "arguments":{"type":"object","properties":{"memory_id":{"type":"string","format":"uuid"}},
                    "required":["memory_id"],"additionalProperties":false}},
                "required":["tool","arguments"],"additionalProperties":false}},
            "required":["memory_id","fetch"],"additionalProperties":false}}},
        "required":["summary","results"],"additionalProperties":false})
}

fn recall_input_schema(name: &str) -> Option<Value> {
    let basic = || json!({"query":{"type":"string"},"limit":{"type":"integer","minimum":1},"filter":{"type":"string"},"wing":{"type":"string"},"estate_id":{"type":"string","format":"uuid"}});
    match name {
        "moot_recall_precise" => Some(
            json!({"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1},"pool":{"type":"integer","minimum":1,"maximum":500},"composition":{"type":"string"},"filter":{"type":"string"},"wing":{"type":"string"},"estate_id":{"type":"string","format":"uuid"}},"required":["query"],"additionalProperties":false}),
        ),
        "moot_recall_temporal" => Some(
            json!({"type":"object","properties":{"query":{"type":"string"},"window":{"type":"string","enum":["loose","tight"]},"from":{"type":"string"},"to":{"type":"string"},"limit":{"type":"integer","minimum":1},"pool":{"type":"integer","minimum":1,"maximum":500},"grab":{"type":"string","enum":["pool","dated"]},"filter":{"type":"string"},"wing":{"type":"string"},"estate_id":{"type":"string","format":"uuid"}},"required":["query"],"additionalProperties":false}),
        ),
        "moot_recall_connected" => Some(
            json!({"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1},"depth":{"type":"integer","minimum":1},"filter":{"type":"string"},"wing":{"type":"string"},"estate_id":{"type":"string","format":"uuid"}},"required":["query"],"additionalProperties":false}),
        ),
        "moot_recall_shaped" => Some(
            // frontier_k: candidate-pool depth override, same semantics as moot_memory_search.
            // The shaped-recall engine clamps the value to [64, 256].
            json!({"type":"object","properties":{"query":{"type":"string"},"preset":{"type":"string"},"limit":{"type":"integer","minimum":1},"filter":{"type":"string"},"wing":{"type":"string"},"frontier_k":{"type":"integer","minimum":1},"estate_id":{"type":"string","format":"uuid"}},"required":["query"],"additionalProperties":false}),
        ),
        "moot_recall_distilled" | "moot_recall_vague" | "moot_recall_walk" => {
            let mut props = basic();
            props["echo_query"] = json!({"type":"boolean"});
            Some(json!({"type":"object","properties":props,"required":["query"],"additionalProperties":false}))
        }
        _ => None,
    }
}

fn lens_input_schema(name: &str) -> Option<Value> {
    let uuid = || json!({"type":"string","format":"uuid"});
    let string = || json!({"type":"string"});
    match name {
        "moot_lens_keystones" => Some(
            json!({"type":"object","properties":{"wing":string(),"topK":string(),"keystoneOnly":string(),"estate_id":uuid()},"required":["wing"],"additionalProperties":false}),
        ),
        "moot_lens_constellation" => Some(
            json!({"type":"object","properties":{"wing":string(),"estate_id":uuid()},"required":["wing"],"additionalProperties":false}),
        ),
        "moot_lens_free_association" => Some(
            json!({"type":"object","properties":{"wing":string(),"seed_memory_id":uuid(),"walkLength":string(),"k":string(),"estate_id":uuid()},"required":["wing","seed_memory_id"],"additionalProperties":false}),
        ),
        "moot_lens_bias" => Some(
            json!({"type":"object","properties":{"reference":{"type":"array"},"estate_id":uuid()},"required":[],"additionalProperties":false}),
        ),
        "moot_lens_cohesion" => Some(
            json!({"type":"object","properties":{"dataset_id":uuid(),"estate_id":uuid()},"required":[],"additionalProperties":false}),
        ),
        "moot_lens_contradiction" => Some(
            json!({"type":"object","properties":{"estate_id":uuid()},"required":[],"additionalProperties":false}),
        ),
        "moot_lens_theme_weather" | "moot_lens_latent_themes" => Some(
            json!({"type":"object","properties":{"estate_id":uuid()},"required":[],"additionalProperties":false}),
        ),
        "moot_lens_drift" => Some(
            json!({"type":"object","properties":{"splitAt":string(),"estate_id":uuid()},"required":["splitAt"],"additionalProperties":false}),
        ),
        "moot_lens_trust_synthesis" => Some(
            json!({"type":"object","properties":{"limit":{"type":"integer","minimum":1},"estate_id":uuid()},"required":[],"additionalProperties":false}),
        ),
        "moot_lens_partial_cue" => Some(
            json!({"type":"object","properties":{"anchor_memory_id":uuid(),"limit":{"type":"integer","minimum":1},"estate_id":uuid()},"required":["anchor_memory_id"],"additionalProperties":false}),
        ),
        "moot_lens_anticipate" => Some(
            json!({"type":"object","properties":{"targetKind":string(),"limit":{"type":"integer","minimum":1},"estate_id":uuid()},"required":["targetKind"],"additionalProperties":false}),
        ),
        "moot_lens_node_motion" => Some(
            json!({"type":"object","properties":{"memory_id":uuid(),"estate_id":uuid()},"required":["memory_id"],"additionalProperties":false}),
        ),
        "moot_lens_successors" => Some(
            json!({"type":"object","properties":{"wing":string(),"anchor_memory_id":uuid(),"limit":{"type":"integer","minimum":1},"estate_id":uuid()},"required":["wing","anchor_memory_id"],"additionalProperties":false}),
        ),
        "moot_lens_overlap" | "moot_lens_divergence" => Some(
            json!({"type":"object","properties":{"comparison_estate_id":uuid(),"estate_id":uuid()},"required":["comparison_estate_id"],"additionalProperties":false}),
        ),
        "moot_lens_associations" => Some(
            json!({"type":"object","properties":{"dataset_id":uuid(),"limit":{"type":"integer","minimum":1},"estate_id":uuid()},"required":[],"additionalProperties":false}),
        ),
        "moot_lens_concepts" => Some(
            json!({"type":"object","properties":{"recall_limit":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1},"estate_id":uuid()},"required":[],"additionalProperties":false}),
        ),
        "moot_lens_apriori" => Some(
            json!({"type":"object","properties":{"limit":{"type":"integer","minimum":1},"estate_id":uuid()},"required":[],"additionalProperties":false}),
        ),
        "moot_lens_moment" => Some(
            json!({"type":"object","properties":{"windowStart":string(),"windowEnd":string(),"comparison_windows":string(),"estate_id":uuid()},"required":["windowStart","windowEnd"],"additionalProperties":false}),
        ),
        "moot_lens_rhythm" => Some(
            json!({"type":"object","properties":{"bit":string(),"bucketSeconds":string(),"bucketCount":string(),"endingAt":string(),"estate_id":uuid()},"required":["bit","bucketSeconds","bucketCount","endingAt"],"additionalProperties":false}),
        ),
        "moot_lens_precedence" => Some(
            json!({"type":"object","properties":{"windowStart":string(),"windowEnd":string(),"targetField":string(),"targetValue":string(),"estate_id":uuid()},"required":["windowStart","windowEnd","targetField","targetValue"],"additionalProperties":false}),
        ),
        "moot_lens_complexity" => Some(
            json!({"type":"object","properties":{"fieldA":string(),"fieldB":string(),"dataset_id":uuid(),"estate_id":uuid()},"required":["fieldA"],"additionalProperties":false}),
        ),
        _ => None,
    }
}

fn lens_data_schema(name: &str) -> Option<Value> {
    match name {
        "moot_lens_keystones" => Some(
            json!({"type":"object","properties":{"keystones":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"centrality":{"type":"number"}},"required":["id","centrality"],"additionalProperties":false}}},"required":["keystones"],"additionalProperties":false}),
        ),
        "moot_lens_constellation" => Some(
            json!({"type":"object","properties":{"communities":{"type":"array","items":{"type":"array","items":{"type":"string"}}}},"required":["communities"],"additionalProperties":false}),
        ),
        "moot_lens_free_association" => Some(
            json!({"type":"object","properties":{"associations":{"type":"array","items":{"type":"object","properties":{"drawerID":{"type":"string"},"activation":{"type":"number"}},"required":["drawerID","activation"],"additionalProperties":false}}},"required":["associations"],"additionalProperties":false}),
        ),
        "moot_lens_bias" => Some(
            json!({"type":"object","properties":{"biasedFor":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"bias":{"type":"number"}},"required":["label","bias"],"additionalProperties":false}},"biasedAgainst":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"bias":{"type":"number"}},"required":["label","bias"],"additionalProperties":false}},"dismissal":{"type":"array","items":{"type":"object","properties":{"nodeId":{"type":"string"},"rate":{"type":"number"}},"required":["nodeId","rate"],"additionalProperties":false}},"learned":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"strength":{"type":"number"},"endorsements":{"type":"integer"},"dismissals":{"type":"integer"}},"required":["label","strength","endorsements","dismissals"],"additionalProperties":false}}},"required":["biasedFor","biasedAgainst","dismissal","learned"],"additionalProperties":false}),
        ),
        "moot_lens_cohesion" => Some(
            json!({"oneOf":[{"type":"object","properties":{"considered":{"type":"integer"},"outliers":{"type":"array","items":{"type":"string"}}},"required":["considered","outliers"],"additionalProperties":false},{"type":"object","properties":{"rowsScored":{"type":"integer"},"topAnomalies":{"type":"array","items":{"type":"object","properties":{"rowIndex":{"type":"integer"},"score":{"type":"number"}},"required":["rowIndex","score"],"additionalProperties":false}}},"required":["rowsScored","topAnomalies"],"additionalProperties":false}]}),
        ),
        "moot_lens_contradiction" => Some(
            json!({"type":"object","properties":{"contradictsTunnels":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"sourceDrawerId":{"type":"string"},"targetDrawerId":{"type":"string"},"lifecycle":{"type":"string","enum":["active","proposed"]}},"required":["id","lifecycle"],"additionalProperties":false}},"conflictingFacts":{"type":"array","items":{"type":"object","properties":{"subject":{"type":"string"},"predicate":{"type":"string"},"objects":{"type":"array","items":{"type":"string"}}},"required":["subject","predicate","objects"],"additionalProperties":false}}},"required":["contradictsTunnels","conflictingFacts"],"additionalProperties":false}),
        ),
        "moot_lens_theme_weather" => Some(
            json!({"type":"object","properties":{"weather":{"type":"array","items":{"type":"object","properties":{"category":{"type":"string"},"momentum":{"type":"number"}},"required":["category","momentum"],"additionalProperties":false}}},"required":["weather"],"additionalProperties":false}),
        ),
        "moot_lens_latent_themes" => Some(
            json!({"type":"object","properties":{"k":{"type":"integer"},"loadings":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"dominantTheme":{"type":"integer"}},"required":["label","dominantTheme"],"additionalProperties":false}}},"required":["k","loadings"],"additionalProperties":false}),
        ),
        "moot_lens_drift" => Some(
            json!({"type":"object","properties":{"beforeCount":{"type":"integer"},"afterCount":{"type":"integer"},"drift":{"type":"object","properties":{"jensenShannon":{"type":"number"},"klDivergence":{"type":"number"}},"required":["jensenShannon","klDivergence"],"additionalProperties":false}},"required":["beforeCount","afterCount","drift"],"additionalProperties":false}),
        ),
        "moot_lens_trust_synthesis" => Some(
            json!({"type":"object","properties":{"context":{"type":"object","properties":{"summary":{"type":"string"},"patterns":{"type":"array","items":{"type":"string"}},"successRate":{"type":"number"},"averageReward":{"type":"number"},"recommendations":{"type":"array","items":{"type":"string"}},"keyInsights":{"type":"array","items":{"type":"string"}}},"required":["summary","patterns","successRate","averageReward","recommendations","keyInsights"],"additionalProperties":false},"rankedIDs":{"type":"array","items":{"type":"string"}},"highTrustCount":{"type":"integer"},"calibratedConfidences":{"type":"array","items":{"type":"object","properties":{"claimed":{"type":"number"},"calibrated":{"type":"number"},"isCalibrated":{"type":"boolean"}},"required":["claimed","calibrated","isCalibrated"],"additionalProperties":false}}},"required":["context","rankedIDs","highTrustCount"],"additionalProperties":false}),
        ),
        "moot_lens_partial_cue" => Some(
            json!({"type":"object","properties":{"results":{"type":"array","items":lens_memory_row_schema()},"capabilities":lens_capabilities_schema()},"required":["results"],"additionalProperties":false}),
        ),
        "moot_lens_anticipate" => Some(
            json!({"type":"object","properties":{"actions":{"type":"array","items":{"type":"object","properties":{"action":{"type":"integer"},"successRate":{"type":"number"},"count":{"type":"integer"}},"required":["action","successRate","count"],"additionalProperties":false}}},"required":["actions"],"additionalProperties":false}),
        ),
        "moot_lens_node_motion" => Some(
            json!({"type":"object","properties":{"rowID":{"type":"string"},"volatility":{"type":"number"},"eventCount":{"type":"integer"},"lastEventPhysicalMs":{"type":"integer"},"anchorTrajectory":{"type":"array","items":{"type":"integer"}},"reanchored":{"type":"boolean"},"currentAnchor":{"type":"integer"},"anomaly":{"type":"string","enum":["churning","reanchored","stable"]}},"required":["rowID","volatility","eventCount","anchorTrajectory","reanchored","anomaly"],"additionalProperties":false}),
        ),
        "moot_lens_successors" => Some(
            json!({"type":"object","properties":{"successors":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"weight":{"type":"number"}},"required":["id","weight"],"additionalProperties":false}}},"required":["successors"],"additionalProperties":false}),
        ),
        "moot_lens_overlap" => Some(
            json!({"type":"object","properties":{"overlap":{"type":"number"},"aSufficient":{"type":"boolean"},"bSufficient":{"type":"boolean"}},"required":["overlap","aSufficient","bSufficient"],"additionalProperties":false}),
        ),
        "moot_lens_divergence" => Some(
            json!({"type":"object","properties":{"aCount":{"type":"integer"},"bCount":{"type":"integer"},"divergence":lens_metric_schema()},"required":["aCount","bCount","divergence"],"additionalProperties":false}),
        ),
        "moot_lens_associations" => Some(
            json!({"type":"object","properties":{"rules":{"type":"array","items":lens_association_rule_schema()},"drawerCount":{"type":"integer"},"rowCount":{"type":"integer"},"labelOverflow":{"type":"boolean"}},"required":["rules","labelOverflow"],"additionalProperties":false}),
        ),
        "moot_lens_concepts" => Some(
            json!({"type":"object","properties":{"concepts":{"type":"array","items":{"type":"object","properties":{"intent":{"type":"array","items":{"type":"string"}},"extentDrawerIDs":{"type":"array","items":{"type":"string"}},"support":{"type":"integer"},"stability":{"type":"number"}},"required":["intent","extentDrawerIDs","support"],"additionalProperties":false}},"drawerCount":{"type":"integer"},"coverDeltas":{"type":"array","items":{"type":"object","properties":{"lowerIntent":{"type":"array","items":{"type":"string"}},"addedAttributes":{"type":"array","items":{"type":"string"}}},"required":["lowerIntent","addedAttributes"],"additionalProperties":false}},"implications":{"type":"array","items":{"type":"object","properties":{"premise":{"type":"array","items":{"type":"string"}},"conclusion":{"type":"array","items":{"type":"string"}}},"required":["premise","conclusion"],"additionalProperties":false}},"implicationsTruncated":{"type":"boolean"}},"required":["concepts","drawerCount","coverDeltas","implications","implicationsTruncated"],"additionalProperties":false}),
        ),
        "moot_lens_apriori" => Some(
            json!({"type":"object","properties":{"rules":{"type":"array","items":{"type":"object","properties":{"antecedent":{"type":"array","items":{"type":"string"}},"consequent":{"type":"string"},"support":{"type":"number"},"confidence":{"type":"number"},"lift":{"type":"number"},"evidenceCount":{"type":"integer"}},"required":["antecedent","consequent","support","confidence","lift","evidenceCount"],"additionalProperties":false}}},"required":["rules"],"additionalProperties":false}),
        ),
        "moot_lens_moment" => Some(
            json!({"type":"object","properties":{"windowCount":{"type":"integer"},"ranking":{"type":"array","items":{"type":"object","properties":{"hammingDistance":{"type":"integer"}},"required":["hammingDistance"],"additionalProperties":false}}},"required":["windowCount","ranking"],"additionalProperties":false}),
        ),
        "moot_lens_rhythm" => Some(
            json!({"type":"object","properties":{"bucketCount":{"type":"integer"},"periods":{"type":"array","items":{"type":"object","properties":{"periodSeconds":{"type":"integer"},"relativeMagnitude":{"type":"number"}},"required":["periodSeconds","relativeMagnitude"],"additionalProperties":false}}},"required":["bucketCount","periods"],"additionalProperties":false}),
        ),
        "moot_lens_precedence" => Some(
            json!({"type":"object","properties":{"entryCount":{"type":"integer"},"antecedents":{"type":"array","items":{"type":"object","properties":{"source":{"type":"object","properties":{"fieldPath":{"type":"string"},"valueRepr":{"type":"string"}},"required":["fieldPath","valueRepr"],"additionalProperties":false},"lagBucket":{"type":"integer"},"count":{"type":"integer"}},"required":["source","lagBucket","count"],"additionalProperties":false}}},"required":["entryCount","antecedents"],"additionalProperties":false}),
        ),
        "moot_lens_complexity" => Some(
            json!({"type":"object","properties":{"totalCount":{"type":"integer"},"nonNullCount":{"type":"integer"},"nullCount":{"type":"integer"},"result":{"type":"object","properties":{"entropyA":{"type":"number"},"entropyB":{"type":"number"},"mutualInformation":{"type":"number"}},"required":["entropyA"],"additionalProperties":false}},"required":["result"],"additionalProperties":false}),
        ),
        _ => None,
    }
}

fn lens_metric_schema() -> Value {
    json!({"type":"object","properties":{"jensenShannon":{"type":"number"},"klDivergence":{"type":"number"}},"required":["jensenShannon","klDivergence"],"additionalProperties":false})
}

fn lens_association_rule_schema() -> Value {
    json!({"type":"object","properties":{"antecedent":{"type":"string"},"consequent":{"type":"string"},"support":{"type":"number"},"confidence":{"type":"number"},"lift":{"type":"number"},"conviction":{"type":"number"},"leverage":{"type":"number"},"exemplarDrawerIDs":{"type":"array","items":{"type":"string"}}},"required":["antecedent","consequent","support","confidence","lift","conviction","leverage","exemplarDrawerIDs"],"additionalProperties":false})
}

fn lens_memory_row_schema() -> Value {
    json!({"type":"object","properties":{"id":{"type":"string"},"subject":{"type":"string"},"bestSpan":{"type":"string"},"sscFacts":{"type":"string"},"eventTime":{"type":"string"},"score":{"type":"number"},"room":{"type":"string"},"retrievalSource":{"type":"string","enum":["anchor","walk","both"]},"distilled":{"type":"string"},"representation":{"const":"distilled"},"tier":{"type":"string","enum":["summary","original"]}},"required":["id","eventTime"],"additionalProperties":false})
}

fn lens_capabilities_schema() -> Value {
    json!({"type":"object","properties":{"discrimination":{"type":"string","enum":["low","medium"]},"temporal":{"type":"object","properties":{"mode":{"type":"string","enum":["loose","tight"]},"source":{"type":"string"},"grab":{"type":"string","enum":["pool","dated"]},"from":{"type":"string"},"to":{"type":"string"},"widenedDays":{"type":"integer"}},"required":["mode","source","grab","from","to"],"additionalProperties":false},"walk":{"type":"object","properties":{"stage":{"type":"string","enum":["stage1_session_hybrid","stage2_precise_hamming"]},"stoppedEarly":{"type":"boolean"}},"required":["stage","stoppedEarly"],"additionalProperties":false}},"required":[],"additionalProperties":false})
}

fn contradiction_data_schema(name: &str) -> Option<Value> {
    let proposal = || json!({"type":"object","properties":{"candidate_id":{"type":"string","minLength":1},"status":{"type":"string","enum":["created","existing","settled"]},"tunnel_id":{"type":"string","format":"uuid"},"lifecycle":{"type":"string"}},"required":["candidate_id","status"],"additionalProperties":false});
    let endpoint = || json!({"type":"object","properties":{"memory_id":{"type":"string","format":"uuid"},"excerpt":{"type":"string"},"fetch":fetch_schema()},"required":["memory_id","excerpt","fetch"],"additionalProperties":false});
    let candidate = || json!({"type":"object","properties":{"candidate_id":{"type":"string","minLength":1},"reason":{"type":"string","minLength":1},"source":endpoint(),"target":endpoint()},"required":["candidate_id","reason","source","target"],"additionalProperties":false});
    match name {
        "moot_hunt_contradictions" => Some(
            json!({"type":"object","properties":{"analysis_ref":{"type":"string","minLength":1},"expires_at":{"type":"string","format":"date-time"},"candidates":{"type":"array","items":candidate()}},"required":["analysis_ref","expires_at","candidates"],"additionalProperties":false}),
        ),
        "moot_propose_contradictions" => Some(
            json!({"type":"object","properties":{"analysis_ref":{"type":"string","minLength":1},"expires_at":{"type":"string","format":"date-time"},"candidates":{"type":"array","items":proposal()}},"required":["analysis_ref","expires_at","candidates"],"additionalProperties":false}),
        ),
        _ => None,
    }
}

fn diagnostic_input_schema() -> Value {
    json!({"type":"object","properties":{"estate_id":{"type":"string","format":"uuid"}},"additionalProperties":false})
}

fn cognition_catalog_input_schema() -> Value {
    json!({"type":"object","properties":{
        "verbose":{"type":"boolean"},
        "estate_id":{"type":"string","format":"uuid"}
    },"additionalProperties":false})
}

fn data_mobility_input_schema(name: &str) -> Value {
    let uuid = || json!({"type":"string","format":"uuid"});
    let string = || json!({"type":"string"});
    let (properties, required) = match name {
        "moot_reindex" => (json!({"estate_id":uuid()}), json!([])),
        "moot_reclassify_fdc" => (
            json!({
                "estate_id": uuid(),
                "apply": {"type":"boolean"},
                "mode": {"type":"string","enum":["suspectOnly","all"]},
                "limit": {"type":"integer","minimum":1,"maximum":50000},
            }),
            json!([]),
        ),
        "moot_palace_import" => (
            json!({"palace_path":string(),"mode":{"type":"string","enum":["foreground","background"]},"estate_id":uuid()}),
            json!(["palace_path"]),
        ),
        "moot_json_import" => (json!({"path":string(),"return_id_map":{"type":"boolean"},"estate_id":uuid()}), json!(["path"])),
        "moot_file_dataset" => return json!({
            "type":"object",
            "properties":{"name":string(),"location":string(),"columns":{"type":"array"},"rows":{"type":"array"},"csv_path":string(),"wing":string(),"sensitivity":{"type":"string","enum":["normal","elevated","restricted","secret"]},"estate_id":uuid()},
            "required":["name","location"],
            "oneOf":[
                {"required":["rows"],"not":{"required":["csv_path"]}},
                {"required":["csv_path"],"not":{"required":["rows"]}}
            ],
            "additionalProperties":false
        }),
        "moot_dataset_query" => {
            let scalar = json!({"type":["string","integer","number"]});
            let column = json!({"type":"string","minLength":1});
            let leaf = json!({"type":"object","properties":{"col":column.clone(),"op":{"type":"string","enum":["eq","neq","lt","lte","gt","gte"]},"val":scalar},"required":["col","op","val"],"additionalProperties":false});
            let bool_leaf = json!({"type":"object","properties":{"col":column.clone(),"op":{"type":"string","enum":["eq","neq"]},"val":{"type":"boolean"}},"required":["col","op","val"],"additionalProperties":false});
            let null_leaf = json!({"type":"object","properties":{"col":column.clone(),"op":{"type":"string","enum":["is_null","is_not_null"]}},"required":["col","op"],"additionalProperties":false});
            let mut definitions = serde_json::Map::new();
            for depth in (1..=8).rev() {
                let mut variants = vec![leaf.clone(), bool_leaf.clone(), null_leaf.clone()];
                if depth < 8 {
                    let child_name = if depth == 1 {
                        "datasetPredicate2".to_owned()
                    } else {
                        format!("datasetPredicate{}", depth + 1)
                    };
                    let child = json!({"$ref": format!("#/$defs/{child_name}")});
                    variants.push(json!({"type":"object","properties":{"and":{"type":"array","items":child.clone(),"minItems":1,"maxItems":128}},"required":["and"],"additionalProperties":false}));
                    variants.push(json!({"type":"object","properties":{"or":{"type":"array","items":child,"minItems":1,"maxItems":128}},"required":["or"],"additionalProperties":false}));
                }
                let name = if depth == 1 {
                    "datasetPredicate".to_owned()
                } else {
                    format!("datasetPredicate{depth}")
                };
                definitions.insert(name, json!({"oneOf": variants}));
            }
            return json!({"type":"object","properties":{"dataset_id":uuid(),"where":{"$ref":"#/$defs/datasetPredicate"},"order_by":{"type":"array","items":{"type":"object","properties":{"col":column.clone(),"dir":{"type":"string","enum":["asc","desc"]}},"required":["col"],"additionalProperties":false}},"limit":{"type":"integer","minimum":1,"maximum":1000},"columns":{"type":"array","items":column},"estate_id":uuid()},"required":["dataset_id"],"additionalProperties":false,"$defs":definitions});
        }
        "moot_dataset_stats" => (
            json!({"dataset_id":uuid(),"column":string(),"estate_id":uuid()}),
            json!(["dataset_id"]),
        ),
        "moot_vault_export" => (
            json!({"vaultPath":string(),"scope":string(),"estate_id":uuid()}),
            json!(["vaultPath"]),
        ),
        "moot_vault_import" => (
            json!({"vaultPath":string(),"mode":string(),"estate_id":uuid()}),
            json!(["vaultPath"]),
        ),
        "moot_vault_status" => (json!({"vaultPath":string()}), json!(["vaultPath"])),
        "moot_vault_reconcile" => (
            json!({"vaultPath":string(),"apply":{"type":"boolean"},"estate_id":uuid()}),
            json!(["vaultPath"]),
        ),
        "moot_vault_job" => (json!({"job_id":{"type":"string","format":"uuid","description":"Job ID returned by moot_vault_import or moot_vault_export."}}), json!(["job_id"])),
        _ => unreachable!("only selected data-mobility names use this schema"),
    };
    json!({"type":"object","properties":properties,"required":required,"additionalProperties":false})
}

fn memory_mutation_input_schema(name: &str) -> Value {
    let uuid = || json!({"type":"string","format":"uuid"});
    let string = || json!({"type":"string"});
    let (properties, required) = match name {
        "moot_update_memory" => {
            return json!({
                "type":"object",
                "properties":{
                    "memory_id":uuid(),
                    "mutation":{"type":"string","enum":["confirm","reject","contest","resolve","supersede","revive","accept","set_subject","correct_sensitivity","correct_exportability"]},
                    "subject":{"type":"string","minLength":1,"maxLength":120},
                    "sensitivity":{"type":"string","enum":["normal","elevated","restricted","secret"]},
                    "exportability":{"type":"string","enum":["private","public"]},
                    "note":string(),
                    "estate_id":uuid()
                },
                "required":["memory_id","mutation"],
                "allOf":[
                    {"if":{"properties":{"mutation":{"const":"set_subject"}},"required":["mutation"]},"then":{"required":["subject"]},"else":{"not":{"required":["subject"]}}},
                    {"if":{"properties":{"mutation":{"const":"correct_sensitivity"}},"required":["mutation"]},"then":{"required":["sensitivity"]},"else":{"not":{"required":["sensitivity"]}}},
                    {"if":{"properties":{"mutation":{"const":"correct_exportability"}},"required":["mutation"]},"then":{"required":["exportability"]},"else":{"not":{"required":["exportability"]}}},
                    {"if":{"properties":{"mutation":{"const":"confirm"}},"required":["mutation"]},"then":{"not":{"required":["note"]}}}
                ],
                "additionalProperties":false
            })
        }
        "moot_withdraw_memory" => (
            json!({"memory_id":uuid(),"reason":string(),"estate_id":uuid()}),
            json!(["memory_id"]),
        ),
        "moot_erase_memory" => (
            json!({"memory_id":uuid(),"confirmation":{"type":"boolean","const":true},"reason":string(),"estate_id":uuid()}),
            json!(["memory_id", "confirmation"]),
        ),
        "moot_confirm_memory" => (
            json!({"memory_id":uuid(),"estate_id":uuid()}),
            json!(["memory_id"]),
        ),
        "moot_move_memory" => (
            json!({"memory_id":uuid(),"wing":string(),"room":string(),"estate_id":uuid()}),
            json!(["memory_id", "wing", "room"]),
        ),
        "moot_link_memories" => (
            json!({"from_id":uuid(),"to_id":uuid(),"relationship":{"type":"string","enum":["blocks","contradicts","covers","derives_from","elaborates","exemplifies","extends","precedes","references","refines","relates","responds_to","supersedes","supports","validates"]},"confidence":string(),"evidence":string(),"proposed":{"type":"boolean"},"estate_id":uuid()}),
            json!(["from_id", "to_id", "relationship"]),
        ),
        "moot_review_tunnel" => (
            json!({"tunnel_id":uuid(),"decision":{"type":"string","enum":["accept","endorse","reject"]},"note":string(),"reviewed_by":string(),"estate_id":uuid()}),
            json!(["tunnel_id", "decision"]),
        ),
        _ => unreachable!("only selected memory mutation names use this schema"),
    };
    json!({"type":"object","properties":properties,"required":required,"additionalProperties":false})
}

fn knowledge_journal_input_schema(name: &str) -> Value {
    let uuid = || json!({"type":"string","format":"uuid"});
    let string = || json!({"type":"string"});
    let (properties, required) = match name {
        "moot_connection_search" => (
            json!({"memory_id":uuid(),"relationship":string(),"direction":string(),"limit":{"type":"integer","minimum":1},"estate_id":uuid()}),
            json!(["memory_id"]),
        ),
        "moot_connection_map" => (
            json!({"memory_id":uuid(),"depth":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1},"estate_id":uuid()}),
            json!(["memory_id"]),
        ),
        "moot_file_fact" => (
            json!({"subject":string(),"predicate":string(),"object":string(),"source_memory_id":uuid(),"event_time":{"type":"string","format":"date-time"},"estate_id":uuid()}),
            json!(["subject", "predicate", "object"]),
        ),
        "moot_fact_search" => (
            json!({"query":string(),"subject":string(),"predicate":string(),"object":string(),"limit":{"type":"integer","minimum":1},"estate_id":uuid()}),
            json!([]),
        ),
        "moot_retire_fact" => (
            json!({"fact_id":uuid(),"reason":string(),"estate_id":uuid()}),
            json!(["fact_id"]),
        ),
        "moot_fact_timeline" => (
            json!({"subject":string(),"predicate":string(),"limit":{"type":"integer","minimum":1},"estate_id":uuid()}),
            json!(["subject"]),
        ),
        "moot_write_journal" => (
            json!({"content":string(),"entry_time":string(),"tags":string(),"estate_id":uuid()}),
            json!(["content"]),
        ),
        "moot_read_journal" => (
            json!({"limit":{"type":"integer","minimum":1},"before":string(),"after":string(),"estate_id":uuid()}),
            json!([]),
        ),
        _ => unreachable!("only selected knowledge/journal names use this schema"),
    };
    let mut schema = json!({"type":"object","properties":properties,"additionalProperties":false});
    if required.as_array().is_some_and(|values| !values.is_empty()) {
        schema
            .as_object_mut()
            .expect("schema is an object")
            .insert("required".to_owned(), required);
    }
    schema
}

fn knowledge_journal_data_schema(name: &str) -> Option<Value> {
    let uuid = || json!({"type":"string","format":"uuid"});
    // Room-level tunnel endpoints and unanchored facts are valid lower rows.
    // Their ID fields are optional rather than replaced with fabricated UUIDs.
    // `lifecycle` is always present: a caller that cannot see it has no way to
    // tell a confirmed link from an unreviewed machine proposal.
    let tunnel = || json!({"type":"object","properties":{"tunnel_id":uuid(),"from_id":uuid(),"to_id":uuid(),"kind":{"type":"string"},"lifecycle":{"type":"string","enum":["active","proposed","superseded","withdrawn"]}},"required":["tunnel_id","kind","lifecycle"],"additionalProperties":false});
    let fact = || json!({"type":"object","properties":{"fact_id":uuid(),"subject":{"type":"string"},"predicate":{"type":"string"},"object":{"type":"string"},"source_memory_id":uuid(),"event_time":{"type":"string","format":"date-time"},"state":{"type":"string"}},"required":["fact_id","subject","predicate","object"],"additionalProperties":false});
    let journal = || json!({"type":"object","properties":{"agent_name":{"type":"string"},"entry":{"type":"string"},"written_at":{"type":"string","format":"date-time"}},"required":["agent_name","entry","written_at"],"additionalProperties":false});
    match name {
        "moot_connection_search" | "moot_connection_map" => Some(
            json!({"type":"object","properties":{"edges":{"type":"array","items":tunnel()}},"required":["edges"],"additionalProperties":false}),
        ),
        "moot_file_fact" => Some(fact()),
        "moot_fact_search" | "moot_fact_timeline" => Some(
            json!({"type":"object","properties":{"facts":{"type":"array","items":fact()}},"required":["facts"],"additionalProperties":false}),
        ),
        "moot_retire_fact" => Some(
            json!({"type":"object","properties":{"fact_id":uuid()},"required":["fact_id"],"additionalProperties":false}),
        ),
        "moot_write_journal" => Some(journal()),
        "moot_read_journal" => Some(
            json!({"type":"object","properties":{"entries":{"type":"array","items":journal()}},"required":["entries"],"additionalProperties":false}),
        ),
        _ => None,
    }
}

fn cognition_catalog_data_schema(name: &str) -> Option<Value> {
    match name {
        "moot_list_lenses" => Some(json!({"type":"object","properties":{
            "tools":{"type":"array","items":{"type":"object","properties":{
                "name":{"type":"string"},
                "description":{"type":"string"},
                "input_schema":{"type":"object","additionalProperties":true}
            },"required":["description","input_schema","name"],"additionalProperties":false}}
        },"required":["tools"],"additionalProperties":false})),
        "moot_list_recipes" => Some(json!({"type":"object","properties":{
            "recipes":{"type":"array","items":{"$ref":"#/definitions/recipe"}}
        },"required":["recipes"],"additionalProperties":false})),
        _ => None,
    }
}

fn exact_object(properties: serde_json::Map<String, Value>) -> Value {
    let mut keys: Vec<_> = properties.keys().cloned().collect();
    keys.sort();
    let required: Vec<Value> = keys.into_iter().map(Value::String).collect();
    json!({"type":"object","properties":properties,"required":required,"additionalProperties":false})
}

fn drain_entry_schema() -> Value {
    // Swift's drain entry is the one non-`exactObjectSchema` diagnostic
    // shape; retain its declared required-array order for the capability hash.
    json!({"type":"object","properties":{
        "name":{"type":"string"},
        "state":{"type":"string","enum":["draining","idle"]},
        "pending":{"type":"integer","minimum":0}
    },"required":["name","state","pending"],"additionalProperties":false})
}

fn estate_diagnostics_data_schema(name: &str) -> Option<Value> {
    let count = || json!({"type":"integer","minimum":0});
    let uuid = || json!({"type":"string","format":"uuid"});
    let string = || json!({"type":"string"});
    match name {
        "moot_estate_ping" => Some(exact_object(serde_json::Map::from_iter([
            ("estate_id".to_owned(), uuid()),
            ("estate_name".to_owned(), string()),
            ("state".to_owned(), json!({"const":"mounted"})),
            ("build_serial".to_owned(), string()),
        ]))),
        // `recall_trace_count` and `shared_content_migration` are the two
        // optional members: the first is omitted when the count could not be
        // read, because a fabricated zero cannot be told from an empty trace
        // table; the second appears only once a migration record exists, so
        // an estate that never ran detection keeps the shape it always had.
        "moot_estate_status" => Some(json!({
            "type": "object",
            "properties": {
                "estate_id": uuid(),
                "estate_name": string(),
                "memory_count": count(),
                "fact_count": count(),
                "fdc_recalculation": {"type":"string","enum":["current","missing","stale"]},
                "drains": {"type":"array","items":drain_entry_schema()},
                "recall_trace_count": count(),
                "sync_state": string(),
                "subjects_bearing": count(),
                "subjects_eligible": count(),
                "shared_content_migration": {
                    "type": "object",
                    "properties": {
                        "state": string(),
                        "estimated_reclaimable_bytes": count(),
                        "reclaimed_bytes": count(),
                    },
                    "required": ["state"],
                    "additionalProperties": false,
                },
            },
            // Sorted, matching exact_object and the Swift port. The required
            // array is ordered, so a different order is a different catalog.
            "required": [
                "drains", "estate_id", "estate_name", "fact_count", "fdc_recalculation", "memory_count", "subjects_bearing", "subjects_eligible", "sync_state",
            ],
            "additionalProperties": false,
        })),
        "moot_estate_map" => {
            let room = exact_object(serde_json::Map::from_iter([
                ("name".to_owned(), string()),
                ("memory_count".to_owned(), count()),
            ]));
            let wing = exact_object(serde_json::Map::from_iter([
                ("name".to_owned(), string()),
                ("rooms".to_owned(), json!({"type":"array","items":room})),
            ]));
            Some(exact_object(serde_json::Map::from_iter([
                ("estate_id".to_owned(), uuid()),
                ("wings".to_owned(), json!({"type":"array","items":wing})),
            ])))
        }
        "moot_drain_status" => Some(exact_object(serde_json::Map::from_iter([(
            "drains".to_owned(),
            json!({"type":"array","items":drain_entry_schema()}),
        )]))),
        "moot_rebuild_status" => Some(exact_object(serde_json::Map::from_iter([(
            "state".to_owned(),
            json!({"type":"string","enum":["running","idle"]}),
        )]))),
        "moot_timing_report" => Some(exact_object(serde_json::Map::from_iter([
            ("since_ms".to_owned(), json!({"const":0})),
            ("watermark_ms".to_owned(), json!({"type":"integer"})),
            ("truncated".to_owned(), json!({"type":"boolean"})),
        ]))),
        _ => None,
    }
}

fn data_mobility_data_schema(name: &str) -> Option<Value> {
    let count = || json!({"type":"integer","minimum":0});
    let string = || json!({"type":"string"});
    let uuid = || json!({"type":"string","format":"uuid"});
    let exact = |properties, required| {
        json!({
            "type":"object", "properties":properties, "required":required, "additionalProperties":false,
        })
    };
    match name {
        "moot_reindex" => Some(exact(
            json!({
                "state":{"type":"string","enum":["running","already_running"]},
            }),
            json!(["state"]),
        )),
        "moot_reclassify_fdc" => {
            // The four optional fields (estate_recalced_data_version_before,
            // estate_recalced_data_version_after) are declared in properties
            // but omitted from required. The `changes` items carry three
            // required fields and two optional QID fields. Per data contract §3.
            let change_item = json!({
                "type":"object",
                "properties": {
                    "id": {"type":"string","minLength":1},
                    "old_code": {"type":"string","minLength":1},
                    "new_code": {"type":"string","minLength":1},
                    "old_qid": {"type":"string"},
                    "new_qid": {"type":"string"},
                },
                "required": ["id","old_code","new_code"],
                "additionalProperties": false,
            });
            Some(exact(
                json!({
                    "applied": {"type":"boolean"},
                    // Wire-value enum matches the FdcReclassifyMode Swift enum: suspectOnly or all.
                    // minLength on version strings: non-empty string enforced at schema level.
                    "mode": {"type":"string","enum":["suspectOnly","all"]},
                    "estate_id": {"type":"string","format":"uuid"},
                    "fdc_data_version": {"type":"string","minLength":1},
                    "fdc_recalculation_version": {"type":"string","minLength":1},
                    "scanned": count(),
                    "unchanged": count(),
                    "empty_content": count(),
                    "candidates": count(),
                    "updated": count(),
                    "would_update": count(),
                    "unclassified_after": count(),
                    "skipped_non_candidate_changes": count(),
                    "floor_stamp": string(),
                    "estate_recalced_data_version_before": string(),
                    "estate_recalced_data_version_after": string(),
                    "changes": {"type":"array","items":change_item},
                    "changes_omitted": count(),
                }),
                json!([
                    "applied", "mode", "estate_id",
                    "fdc_data_version", "fdc_recalculation_version",
                    "scanned", "unchanged", "empty_content",
                    "candidates", "updated", "would_update",
                    "unclassified_after", "skipped_non_candidate_changes",
                    "floor_stamp", "changes", "changes_omitted",
                ]),
            ))
        },
        "moot_palace_import" => Some(exact(
            json!({
                "drawers_written":count(), "drawers_updated":count(),
                "drawers_skipped_unchanged":count(), "drawers_skipped_tombstoned":count(),
                "drawers_skipped_partial_write":count(), "tunnels_created":count(),
                "items_skipped":count(), "fdc_classified":count(), "fdc_unclassified":count(),
                "fields_dropped":{"type":"object","additionalProperties":count()},
                "enqueued_for_encode":count(),
            }),
            json!([
                "drawers_written",
                "drawers_updated",
                "drawers_skipped_unchanged",
                "drawers_skipped_tombstoned",
                "drawers_skipped_partial_write",
                "tunnels_created",
                "items_skipped",
                "fdc_classified",
                "fdc_unclassified",
                "fields_dropped",
                "enqueued_for_encode",
            ]),
        )),
        "moot_json_import" => Some(exact(
            json!({
                "seed_name":string(), "drawers_written":count(), "facts_written":count(),
                "tunnels_created":count(), "enqueued_for_encode":count(),
                "subjects_provided":count(), "subjects_debt":count(),
                "seed_sha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},
                "id_map":{"type":"object","additionalProperties":uuid()},
            }),
            json!([
                "seed_name",
                "drawers_written",
                "facts_written",
                "tunnels_created",
                "enqueued_for_encode",
                "subjects_provided",
                "subjects_debt",
                "seed_sha256",
            ]),
        )),
        "moot_file_dataset" => Some(exact(
            json!({
                "dataset_id":uuid(), "handle_memory_id":uuid(), "name":string(), "location":string(),
                "wing":string(), "columns":count(), "rows":count(), "source":string(),
                "sensitivity":{"type":"string","enum":["normal","elevated","restricted","secret"]},
                "signatures":string(),
            }),
            json!([
                "dataset_id",
                "handle_memory_id",
                "name",
                "location",
                "columns",
                "rows",
                "source",
                "sensitivity",
                "signatures",
            ]),
        )),
        "moot_dataset_query" => Some(exact(
            json!({
                "dataset_id":uuid(), "handle_memory_id":uuid(), "state":string(),
                "sensitivity":{"type":"string","enum":["normal","elevated","restricted","secret"]},
                "rows_returned":count(), "limit":{"type":"integer","minimum":1,"maximum":1000},
                "rows":{"type":"array","items":{"type":"object","properties":{},"required":[],"additionalProperties":{"type":["string","integer","number","boolean","null"]}}},
                "columns":{"type":"array","items":string()}, "handle_row_count":count(),
            }),
            json!([
                "dataset_id",
                "handle_memory_id",
                "state",
                "sensitivity",
                "rows_returned",
                "limit",
                "rows",
            ]),
        )),
        "moot_dataset_stats" => {
            let scalar = json!({"type":["string","integer","number","boolean","null"]});
            let stat = exact(
                json!({
                    "count":count(), "distinct_count":count(), "null_count":count(),
                    "min":scalar.clone(), "max":scalar,
                }),
                json!(["count", "distinct_count", "null_count", "min", "max"]),
            );
            Some(exact(
                json!({
                    "dataset_id":uuid(), "handle_memory_id":uuid(),
                    "stats":{"type":"object","properties":{},"required":[],"additionalProperties":stat},
                }),
                json!(["dataset_id", "handle_memory_id", "stats"]),
            ))
        }
        "moot_vault_status" => Some(exact(
            json!({
                "manifest_present":{"type":"boolean"}, "path":string(),
                "last_export":{"type":"string","format":"date-time"}, "note_count":count(),
            }),
            json!(["manifest_present", "path"]),
        )),
        "moot_vault_reconcile" => {
            let candidate = exact(
                json!({
                    "stable_source_key":string(), "vault_path":string(), "sha256":string(),
                }),
                json!(["stable_source_key", "vault_path", "sha256"]),
            );
            let import_report = exact(
                json!({
                    "drawers_written":count(), "drawers_updated":count(), "items_skipped":count(),
                    "tunnels_created":count(), "fdc_classified":count(), "fdc_unclassified":count(),
                    "drawers_skipped_unchanged":count(), "drawers_skipped_tombstoned":count(),
                }),
                json!([
                    "drawers_written",
                    "drawers_updated",
                    "items_skipped",
                    "tunnels_created",
                    "fdc_classified",
                    "fdc_unclassified",
                    "drawers_skipped_unchanged",
                    "drawers_skipped_tombstoned",
                ]),
            );
            Some(exact(
                json!({
                    "added":{"type":"array","items":string()}, "modified":{"type":"array","items":string()},
                    "deleted":{"type":"array","items":string()}, "missing":{"type":"array","items":string()},
                    "import_set_count":count(), "candidate_count":count(), "missing_count":count(),
                    "applied":{"type":"boolean"}, "candidates":{"type":"array","items":candidate},
                    "import_report":import_report,
                }),
                json!([
                    "added",
                    "modified",
                    "deleted",
                    "missing",
                    "import_set_count",
                    "candidate_count",
                    "missing_count",
                    "applied",
                ]),
            ))
        }
        _ => None,
    }
}
