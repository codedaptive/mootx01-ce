//! Tool list projection — builds the `tools/list` response body.
//!
//! Mirrors the Swift `ToolProjection.tools()` + `RecipeTools.tools()` +
//! `LensTools.tools()` composition. Produces exactly 44 tools in this order:
//!   Tier 1 (7)  — core memory: file, search, update, withdraw, erase, confirm, move
//!   Tier 2 (3)  — connections: link, search, map
//!   Tier 3 (4)  — knowledge graph: file, search, retire, timeline
//!   Tier 4 (2)  — journal: write, read
//!   Tier 5 (3)  — estate: status, map, ping
//!   Federation (1) — moot_federated_search
//!   Recipe (4)  — list_lenses, synthesize, run_migration, confirm_migration
//!   Lens (16)   — moot_lens_keystones … moot_lens_concepts
//!   Vault (4)   — export, import, status, reconcile
//!
//! Wire identity: every tool name and inputSchema required/optional field set
//! is byte-identical to Swift `ToolProjection.swift`. Every schema wraps with
//! `with_estate_id` (optional estateID) and `with_teachme` (optional teachme:bool).

use serde_json::json;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Build the full 44-tool surface for `tools/list`.
pub fn build_tool_list() -> serde_json::Value {
    let mut tools: Vec<serde_json::Value> = Vec::with_capacity(44);

    // Tier 1 — Core memory (7)
    tools.push(file_memory_tool());
    tools.push(memory_search_tool());
    tools.push(update_memory_tool());
    tools.push(withdraw_memory_tool());
    tools.push(erase_memory_tool());
    tools.push(confirm_memory_tool());
    tools.push(move_memory_tool());

    // Tier 2 — Connections (3)
    tools.push(link_memories_tool());
    tools.push(connection_search_tool());
    tools.push(connection_map_tool());

    // Tier 3 — Knowledge graph (4)
    tools.push(file_fact_tool());
    tools.push(fact_search_tool());
    tools.push(retire_fact_tool());
    tools.push(fact_timeline_tool());

    // Tier 4 — Journal (2)
    tools.push(write_journal_tool());
    tools.push(read_journal_tool());

    // Tier 5 — Estate (3)
    tools.push(estate_status_tool());
    tools.push(estate_map_tool());
    tools.push(estate_ping_tool());

    // Federation (1)
    tools.push(federated_search_tool());

    // Recipe (4)
    tools.push(list_lenses_tool());
    tools.push(synthesize_tool());
    tools.push(run_migration_tool());
    tools.push(confirm_migration_tool());

    // Lens (16)
    for lens_name in crate::lens_tools::LENS_TOOLS {
        tools.push(lens_tool(lens_name));
    }

    // Vault (4) — both Swift and Rust ports are live (ADR-VAULTKIT-002 decision a is
    // superseded; see DECISION_VAULT_BIDIRECTIONAL_IDENTITY_AND_SCOPE_2026-06-05.md).
    // `moot_vault_export` accepts an optional `scope` argument (default "believed").
    tools.push(vault_export_tool());
    tools.push(vault_tool("moot_vault_import", "Import a vault archive into the estate."));
    tools.push(vault_tool("moot_vault_status", "Report the current vault sync state."));
    tools.push(vault_tool("moot_vault_reconcile", "Reconcile diverged vault and estate state."));

    serde_json::Value::Array(tools)
}

// ---------------------------------------------------------------------------
// Tier 1 — Core memory
// ---------------------------------------------------------------------------

fn file_memory_tool() -> serde_json::Value {
    json!({
        "name": "moot_file_memory",
        "description": "File a memory into the estate. Requires content and a location path (wing/room or room).",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "content": string_schema("Verbatim content to file."),
                "location": string_schema("Location path: wing/room or just room. Wing defaults to 'memories'."),
                "sensitivity": string_schema("Sensitivity tier: normal (default), elevated, restricted, secret."),
                "kind": string_schema("Content kind: prose (default), code, transcript, list, structuredJSON, imageCaption, fingerprintOnly."),
                "event_time": string_schema("Optional ISO8601 event timestamp to attach.")
            }),
            json!(["content", "location"])
        )))
    })
}

fn memory_search_tool() -> serde_json::Value {
    json!({
        "name": "moot_memory_search",
        "description": "Search memories by query. Returns ranked hits with content previews.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "query": string_schema("Natural-language search query."),
                "limit": integer_schema("Max results to return (default 10)."),
                "filter": filter_schema(),
                "explain": boolean_schema("Include scoring explanation (default false)."),
                "scoring": string_schema("Scoring mode: matrixAware (default), hybrid, vector.")
            }),
            json!(["query"])
        )))
    })
}

fn update_memory_tool() -> serde_json::Value {
    json!({
        "name": "moot_update_memory",
        "description": "Apply a named mutation to a memory (confirm, archive, tag, etc.).",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "id": string_schema("UUID of the memory to update."),
                "mutation": string_schema("Mutation kind: confirm, archive, unarchive, promote, demote."),
                "note": string_schema("Optional note to attach to the mutation.")
            }),
            json!(["id", "mutation"])
        )))
    })
}

fn withdraw_memory_tool() -> serde_json::Value {
    json!({
        "name": "moot_withdraw_memory",
        "description": "Withdraw a memory from active circulation (soft delete).",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "id": string_schema("UUID of the memory to withdraw."),
                "reason": string_schema("Optional reason for withdrawal.")
            }),
            json!(["id"])
        )))
    })
}

fn erase_memory_tool() -> serde_json::Value {
    json!({
        "name": "moot_erase_memory",
        "description": "Permanently erase a memory (irreversible). Requires explicit confirmation.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "id": string_schema("UUID of the memory to erase."),
                "reason": string_schema("Justification for the irreversible erasure."),
                "confirmed": boolean_schema("Must be true to proceed.")
            }),
            json!(["id", "reason", "confirmed"])
        )))
    })
}

fn confirm_memory_tool() -> serde_json::Value {
    json!({
        "name": "moot_confirm_memory",
        "description": "Mark a memory as user-confirmed.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "id": string_schema("UUID of the memory to confirm."),
                "note": string_schema("Optional confirmation note.")
            }),
            json!(["id"])
        )))
    })
}

fn move_memory_tool() -> serde_json::Value {
    json!({
        "name": "moot_move_memory",
        "description": "Move a memory to a different location in the estate.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "id": string_schema("UUID of the memory to move."),
                "location": string_schema("New location path: wing/room or just room.")
            }),
            json!(["id", "location"])
        )))
    })
}

// ---------------------------------------------------------------------------
// Tier 2 — Connections
// ---------------------------------------------------------------------------

fn link_memories_tool() -> serde_json::Value {
    json!({
        "name": "moot_link_memories",
        "description": "Create a typed directional tunnel between two memories.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "from_id": string_schema("UUID of the source memory."),
                "to_id": string_schema("UUID of the target memory."),
                "kind": string_schema("Tunnel kind: relates (default), supports, contradicts, refines, extends."),
                "label": string_schema("Optional human-readable label for the connection.")
            }),
            json!(["from_id", "to_id", "kind"])
        )))
    })
}

fn connection_search_tool() -> serde_json::Value {
    json!({
        "name": "moot_connection_search",
        "description": "List outgoing connections (tunnels) from a memory.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "from_id": string_schema("UUID of the source memory.")
            }),
            json!(["from_id"])
        )))
    })
}

fn connection_map_tool() -> serde_json::Value {
    json!({
        "name": "moot_connection_map",
        "description": "List incoming connections (tunnels) pointing to a memory.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "to_id": string_schema("UUID of the target memory.")
            }),
            json!(["to_id"])
        )))
    })
}

// ---------------------------------------------------------------------------
// Tier 3 — Knowledge graph
// ---------------------------------------------------------------------------

fn file_fact_tool() -> serde_json::Value {
    json!({
        "name": "moot_file_fact",
        "description": "Store a structured knowledge-graph fact (subject, predicate, object triple).",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "subject": string_schema("The entity this fact is about."),
                "predicate": string_schema("The relationship or property."),
                "object": string_schema("The value or target entity."),
                "source_id": string_schema("Optional UUID of a memory that grounds this fact.")
            }),
            json!(["subject", "predicate", "object"])
        )))
    })
}

fn fact_search_tool() -> serde_json::Value {
    json!({
        "name": "moot_fact_search",
        "description": "Search knowledge-graph facts. Optional query filters by subject, predicate, or object.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "query": string_schema("Optional substring filter across subject, predicate, and object."),
                "limit": integer_schema("Max results (default 50).")
            }),
            json!([])
        )))
    })
}

fn retire_fact_tool() -> serde_json::Value {
    json!({
        "name": "moot_retire_fact",
        "description": "Retire (invalidate) a knowledge-graph fact when it becomes false.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "id": string_schema("UUID of the fact to retire.")
            }),
            json!(["id"])
        )))
    })
}

fn fact_timeline_tool() -> serde_json::Value {
    json!({
        "name": "moot_fact_timeline",
        "description": "View the chronological history of facts, optionally filtered by entity.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "entity": string_schema("Optional entity (subject or object) to filter by.")
            }),
            json!([])
        )))
    })
}

// ---------------------------------------------------------------------------
// Tier 4 — Journal
// ---------------------------------------------------------------------------

fn write_journal_tool() -> serde_json::Value {
    json!({
        "name": "moot_write_journal",
        "description": "Write a journal entry recording this session's activities.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "entry": string_schema("Journal text to record."),
                "agent": string_schema("Optional agent name (default: mcp-agent).")
            }),
            json!(["entry"])
        )))
    })
}

fn read_journal_tool() -> serde_json::Value {
    json!({
        "name": "moot_read_journal",
        "description": "Read recent journal entries.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "agent": string_schema("Optional agent name filter (default: mcp-agent)."),
                "last_n": integer_schema("Max entries to return (default 10).")
            }),
            json!([])
        )))
    })
}

// ---------------------------------------------------------------------------
// Tier 5 — Estate
// ---------------------------------------------------------------------------

fn estate_status_tool() -> serde_json::Value {
    json!({
        "name": "moot_estate_status",
        "description": "Get estate metadata, health summary, and session orientation protocol.",
        "inputSchema": with_teachme(with_estate_id(object_schema(json!({}), json!([]))))
    })
}

fn estate_map_tool() -> serde_json::Value {
    json!({
        "name": "moot_estate_map",
        "description": "Return the estate wing/room taxonomy tree grouped by location.",
        "inputSchema": with_teachme(with_estate_id(object_schema(json!({}), json!([]))))
    })
}

fn estate_ping_tool() -> serde_json::Value {
    json!({
        "name": "moot_estate_ping",
        "description": "Verify the estate connection is alive. Returns pong immediately.",
        "inputSchema": with_teachme(with_estate_id(object_schema(json!({}), json!([]))))
    })
}

// ---------------------------------------------------------------------------
// Federation
// ---------------------------------------------------------------------------

fn federated_search_tool() -> serde_json::Value {
    json!({
        "name": "moot_federated_search",
        "description": "Grant-authorized cross-estate federated search: fans across open estates the requester is entitled to read.",
        "inputSchema": with_teachme(object_schema(
            json!({
                "requesterEstateID": string_schema("UUID of the requesting estate. Must name an open estate."),
                "filter": filter_schema(),
                "limit": integer_schema("Max rows per estate."),
                "ordering": string_schema("Ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc, byRelevanceDesc."),
                "hydrationLevel": string_schema("Hydration: structured (default), full, bitmapOnly.")
            }),
            json!(["requesterEstateID"])
        ))
    })
}

// ---------------------------------------------------------------------------
// Recipe tools
// ---------------------------------------------------------------------------

fn list_lenses_tool() -> serde_json::Value {
    json!({
        "name": "moot_list_lenses",
        "description": "List all available cognition lenses and recipes with descriptions and required capabilities.",
        "inputSchema": with_teachme(with_estate_id(object_schema(json!({}), json!([]))))
    })
}

fn synthesize_tool() -> serde_json::Value {
    json!({
        "name": "moot_synthesize",
        "description": "Behaviour recipe: hybrid-recall memories and synthesize them into a grounded context document (summary, patterns, success rate, recommendations, key insights).",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "filter": filter_schema(),
                "limit": integer_schema("Max memories to recall.")
            }),
            json!([])
        )))
    })
}

fn run_migration_tool() -> serde_json::Value {
    json!({
        "name": "moot_run_migration",
        "description": "Behaviour recipe: benchmark migration plans against a corpus using the zero-silent-loss gate. Returns ranked survivors with branch ids for a confirm step.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "corpusName": string_schema("Human-readable name for the origin corpus."),
                "entries": {
                    "type": "array",
                    "description": "Origin entries: objects with string id and content.",
                    "items": object_schema(
                        json!({
                            "id": string_schema("Stable source id."),
                            "content": string_schema("Verbatim content.")
                        }),
                        json!(["id", "content"])
                    )
                },
                "plans": {
                    "type": "array",
                    "description": "Candidate plans: objects with string name, room, latticeCode, embeddingModelID.",
                    "items": object_schema(
                        json!({
                            "name": string_schema("Plan name."),
                            "room": string_schema("Room for migrated memories."),
                            "latticeCode": string_schema("UDC lattice code."),
                            "embeddingModelID": string_schema("Embedding model id."),
                            "sensitivity": string_schema("Optional sensitivity tier.")
                        }),
                        json!(["name", "room", "latticeCode", "embeddingModelID"])
                    )
                }
            }),
            json!(["corpusName", "entries", "plans"])
        )))
    })
}

fn confirm_migration_tool() -> serde_json::Value {
    json!({
        "name": "moot_confirm_migration",
        "description": "Behaviour recipe (human-confirmed write): promote the benchmark winner branch and discard losers by branch id. Refuses disqualified branches.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "winnerBranchID": string_schema("UUID of the winning branch to promote."),
                "discardBranchIDs": {
                    "type": "array",
                    "description": "UUIDs of losing branches to discard.",
                    "items": { "type": "string" }
                },
                "disqualifiedBranchIDs": {
                    "type": "array",
                    "description": "UUIDs the run report disqualified.",
                    "items": { "type": "string" }
                }
            }),
            json!(["winnerBranchID"])
        )))
    })
}

// ---------------------------------------------------------------------------
// Lens tools — one schema per lens (16 tools)
// ---------------------------------------------------------------------------

fn lens_tool(name: &str) -> serde_json::Value {
    let description = lens_description(name);
    let schema = lens_schema(name);
    json!({
        "name": name,
        "description": description,
        "inputSchema": schema
    })
}

fn lens_description(name: &str) -> &'static str {
    match name {
        "moot_lens_keystones" => "Reasoning lens: identify hub drawers by eigenvector centrality in the tunnel graph.",
        "moot_lens_constellation" => "Reasoning lens: detect community structure in the tunnel graph.",
        "moot_lens_free_association" => "Reasoning lens: random-walk spreading activation from a seed drawer.",
        "moot_lens_theme_weather" => "Reasoning lens: temporal momentum scores for each theme.",
        "moot_lens_latent_themes" => "Reasoning lens: extract latent topic clusters via matrix factorization.",
        "moot_lens_bias" => "Reasoning lens: detect over/under-representation relative to a reference distribution.",
        "moot_lens_drift" => "Reasoning lens: measure distribution drift across a temporal split point.",
        "moot_lens_contradiction" => "Reasoning lens: surface drawers that are statistical outliers in their category.",
        "moot_lens_trust_synthesis" => "Reasoning lens: hybrid-recall and rank by trust score.",
        "moot_lens_partial_cue" => "Reasoning lens: retrieve memories by partial-cue similarity to an anchor.",
        "moot_lens_anticipate" => "Reasoning lens: predict next-likely actions based on historical patterns.",
        "moot_lens_successors" => "Reasoning lens: suggest probable successor drawers via tunnel traversal.",
        "moot_lens_overlap" => "Reasoning lens: compute thematic overlap between two estates.",
        "moot_lens_divergence" => "Reasoning lens: measure topic divergence between two estates.",
        "moot_lens_associations" => "Analytics lens: mine pairwise association rules from categorical facets.",
        "moot_lens_concepts" => "Analytics lens: mine formal concepts from the categorical feature matrix.",
        _ => "Reasoning lens.",
    }
}

fn lens_schema(name: &str) -> serde_json::Value {
    let filter = filter_schema();
    let estate_id = estate_id_schema();
    let teachme = teachme_schema();

    match name {
        "moot_lens_keystones" => object_schema(
            json!({
                "wing": string_schema("The wing whose tunnel graph to analyse."),
                "topK": integer_schema("How many keystones to return (default 5)."),
                "filter": filter,
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["wing"]),
        ),
        "moot_lens_constellation" => object_schema(
            json!({
                "wing": string_schema("The wing whose tunnel graph to cluster."),
                "filter": filter,
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["wing"]),
        ),
        "moot_lens_free_association" => object_schema(
            json!({
                "wing": string_schema("The wing to walk."),
                "seedDrawerID": string_schema("The seed drawer id for spreading activation."),
                "walkLength": integer_schema("Number of random-walk steps (default 10000)."),
                "k": integer_schema("How many results to return (default 10)."),
                "filter": filter,
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["wing", "seedDrawerID"]),
        ),
        "moot_lens_theme_weather" => object_schema(
            json!({
                "halfLifeSeconds": number_schema("Momentum half-life in seconds (default 604800 = 7 days)."),
                "filter": filter,
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!([]),
        ),
        "moot_lens_latent_themes" => object_schema(
            json!({
                "k": integer_schema("Number of latent themes to extract (default 3)."),
                "filter": filter,
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!([]),
        ),
        "moot_lens_bias" => object_schema(
            json!({
                "reference": {
                    "type": "array",
                    "description": "Reference distribution as objects with label (string) and mass (number).",
                    "items": object_schema(
                        json!({
                            "label": string_schema("Room / category label."),
                            "mass": number_schema("Reference mass for the label.")
                        }),
                        json!(["label", "mass"])
                    )
                },
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!([]),
        ),
        "moot_lens_drift" => object_schema(
            json!({
                "splitAt": string_schema("ISO8601 instant splitting the before/after windows."),
                "filter": filter,
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["splitAt"]),
        ),
        "moot_lens_contradiction" => object_schema(
            json!({
                "threshold": number_schema("Z-score magnitude threshold (default 1.5)."),
                "filter": filter,
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!([]),
        ),
        "moot_lens_trust_synthesis" => object_schema(
            json!({
                "filter": filter,
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!([]),
        ),
        "moot_lens_partial_cue" => object_schema(
            json!({
                "anchorID": string_schema("The anchor drawer id (the cue)."),
                "mode": string_schema("Cue mode: feelsLike (default), aboutThis, fromThen."),
                "k": integer_schema("How many matches to return (default 5)."),
                "filter": filter,
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["anchorID"]),
        ),
        "moot_lens_anticipate" => object_schema(
            json!({
                "targetKind": string_schema("Target outcome as a content kind: prose, code, transcript, list, structuredJSON, imageCaption, fingerprintOnly."),
                "k": integer_schema("How many actions to return (default 5)."),
                "minObservations": integer_schema("Minimum observations per action (default 1)."),
                "filter": filter,
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["targetKind"]),
        ),
        "moot_lens_successors" => object_schema(
            json!({
                "wing": string_schema("The wing whose tunnels to read."),
                "anchorID": string_schema("The anchor drawer id."),
                "k": integer_schema("How many successors to return (default 5)."),
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["wing", "anchorID"]),
        ),
        "moot_lens_overlap" => object_schema(
            json!({
                "estateID": string_schema("Optional UUID of estate A. Omit for the default estate."),
                "estateIDB": string_schema("UUID of estate B (must be a registered open estate)."),
                "filter": filter,
                "teachme": teachme
            }),
            json!(["estateIDB"]),
        ),
        "moot_lens_divergence" => object_schema(
            json!({
                "estateID": string_schema("Optional UUID of estate A. Omit for the default estate."),
                "estateIDB": string_schema("UUID of estate B (must be a registered open estate)."),
                "filter": filter,
                "teachme": teachme
            }),
            json!(["estateIDB"]),
        ),
        "moot_lens_associations" => object_schema(
            json!({
                "filter": filter,
                "limit": integer_schema("Max drawers to recall."),
                "minSupport": number_schema("Minimum rule support (0..1). Default 0."),
                "minConfidence": number_schema("Minimum rule confidence (0..1). Default 0."),
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!([]),
        ),
        "moot_lens_concepts" => object_schema(
            json!({
                "filter": filter,
                "limit": integer_schema("Max drawers to recall."),
                "minSupport": integer_schema("Minimum concept extent size (default 1)."),
                "maxIntentSize": integer_schema("Maximum concept intent size (default 8)."),
                "maxConcepts": integer_schema("Maximum concepts returned (default 20)."),
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!([]),
        ),
        _ => with_teachme(with_estate_id(object_schema(json!({}), json!([]))))
    }
}

// ---------------------------------------------------------------------------
// Vault tools — advertised; return methodNotFound until VaultKit-Rust ships
// ---------------------------------------------------------------------------

/// `moot_vault_export` — has an optional `scope` argument not shared by the
/// other three vault tools.
fn vault_export_tool() -> serde_json::Value {
    json!({
        "name": "moot_vault_export",
        "description": "Export the estate to a portable vault archive.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "vaultPath": string_schema("Filesystem path to the vault directory."),
                "scope": scope_schema()
            }),
            json!(["vaultPath"])
        )))
    })
}

/// Schema for the `scope` argument accepted by `moot_vault_export`.
///
/// Four values are valid. Absent = "believed" (the default). Mirrors Swift
/// `VaultTools.scopeSchema`.
fn scope_schema() -> serde_json::Value {
    json!({
        "type": "string",
        "description": "Which drawers to include. One of: believed (default — currently-believed drawers with any confirmation state), exportable (drawers marked as publicly exportable), confirmed (user-confirmed only), unconfirmed (capture inbox only). Omit to use the default (believed).",
        "enum": ["believed", "exportable", "confirmed", "unconfirmed"]
    })
}

fn vault_tool(name: &str, description: &str) -> serde_json::Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "vaultPath": string_schema("Filesystem path to the vault directory.")
            }),
            json!(["vaultPath"])
        )))
    })
}

// ---------------------------------------------------------------------------
// Schema builder helpers — mirror Swift ToolProjection schema helpers
// ---------------------------------------------------------------------------

/// Wrap a schema with an optional `estateID` field. Mirrors Swift
/// `ToolProjection.withEstateID(_:)`. All interface and recipe tools
/// accept `estateID` to target a specific open estate; omitting it
/// selects the default estate.
pub fn with_estate_id(mut schema: serde_json::Value) -> serde_json::Value {
    if let Some(props) = schema["properties"].as_object_mut() {
        props.insert(
            "estateID".to_owned(),
            estate_id_schema(),
        );
    }
    schema
}

/// Wrap a schema with an optional `teachme` boolean field. Mirrors Swift
/// `ToolProjection.withTeachme(_:)`. When `teachme:true` is set,
/// `dispatch.rs` intercepts the call and returns the tool's usage guide
/// without touching the estate.
pub fn with_teachme(mut schema: serde_json::Value) -> serde_json::Value {
    if let Some(props) = schema["properties"].as_object_mut() {
        props.insert(
            "teachme".to_owned(),
            teachme_schema(),
        );
    }
    schema
}

fn object_schema(properties: serde_json::Value, required: serde_json::Value) -> serde_json::Value {
    let req_arr = required.as_array().unwrap_or(&vec![]).clone();
    if req_arr.is_empty() {
        json!({ "type": "object", "properties": properties })
    } else {
        json!({ "type": "object", "properties": properties, "required": req_arr })
    }
}

fn string_schema(description: &str) -> serde_json::Value {
    json!({ "type": "string", "description": description })
}

fn integer_schema(description: &str) -> serde_json::Value {
    json!({ "type": "integer", "description": description })
}

fn number_schema(description: &str) -> serde_json::Value {
    json!({ "type": "number", "description": description })
}

fn boolean_schema(description: &str) -> serde_json::Value {
    json!({ "type": "boolean", "description": description })
}

fn filter_schema() -> serde_json::Value {
    string_schema("Filter kind: unconfirmed (default), userConfirmed, exportable, contained, currentlyBelieve.")
}

fn estate_id_schema() -> serde_json::Value {
    string_schema("Optional UUID of the open estate to target. Omit for the default estate.")
}

fn teachme_schema() -> serde_json::Value {
    boolean_schema("Set true to receive a usage guide for this tool without touching the estate.")
}
