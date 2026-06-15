//! Tool list projection — builds the `tools/list` response body.
//!
//! Mirrors the Swift `ToolProjection.tools()` + `RecipeTools.tools()` +
//! `LensTools.tools()` + `VaultTools.tools()` composition. Produces exactly
//! 53 tools in this order:
//!   Tier 1 (7)  — core memory: file, search, update, withdraw, erase, confirm, move
//!   Tier 2 (3)  — connections: link, search, map
//!   Tier 3 (4)  — knowledge graph: file, search, retire, timeline
//!   Tier 4 (2)  — journal: write, read
//!   Tier 5 (3)  — estate: status, map, ping
//!   Federation (1) — moot_federated_search
//!   Recipe (7)  — list_lenses, list_recipes, synthesize, run_migration, confirm_migration, recall_precise, dream
//!   Lens (21)   — moot_lens_keystones … moot_lens_complexity
//!   Vault (5)   — export, import, status, reconcile, job
//!
//! Tool count 53 = 52 (prior surface) + 1 (moot_vault_job, Bob's ruling 2026-06-12).
//! moot_vault_job was present in Swift (53 tools) but absent in Rust (52 tools).
//! Tool-surface parity requires 53/53 even though the Rust backend is synchronous:
//! the tool returns completed-job records from the in-process VaultJobLedger.
//!
//! Wire identity: every tool name and inputSchema required/optional field set
//! is byte-identical to Swift `ToolProjection.swift`. Every schema wraps with
//! `with_estate_id` (optional estateID) and `with_teachme` (optional teachme:bool).

use serde_json::json;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Build the full 53-tool surface for `tools/list`.
pub fn build_tool_list() -> serde_json::Value {
    let mut tools: Vec<serde_json::Value> = Vec::with_capacity(53);

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

    // Recipe (7)
    tools.push(list_lenses_tool());
    tools.push(list_recipes_catalog_tool());
    tools.push(synthesize_tool());
    tools.push(run_migration_tool());
    tools.push(confirm_migration_tool());
    tools.push(recall_precise_tool());
    // moot_dream: matrix rebuild + dreaming cycle. Schema mirrors Swift
    // `RecipeTools.dreamTool()`. The tool runs one on-demand cycle (accepts a
    // `now` arg only) — by design, not omission. The .timer/.event/.hybrid
    // dreaming modes (NeuronKit DreamingTriggerMode) are all live in both
    // ports but are governor-driven resident-scheduler concerns, not ARIA tool
    // arguments; no mode field is surfaced here.
    tools.push(dream_tool());

    // Lens (21)
    for lens_name in crate::lens_tools::LENS_TOOLS {
        tools.push(lens_tool(lens_name));
    }

    // Vault (5) — both Swift and Rust ports are live (ADR-VAULTKIT-002 decision a is
    // superseded; see DECISION_VAULT_BIDIRECTIONAL_IDENTITY_AND_SCOPE_2026-06-05.md).
    // `moot_vault_export` accepts an optional `scope` argument (default "believed").
    // `moot_vault_job` added for tool-surface parity (Bob's ruling 2026-06-12):
    // Rust vault ops complete synchronously; the ledger records completed results
    // immediately so moot_vault_job can retrieve them. Schema is Swift-identical.
    tools.push(vault_export_tool());
    tools.push(vault_tool("moot_vault_import", "Import a vault archive into the estate."));
    tools.push(vault_tool("moot_vault_status", "Report the current vault sync state."));
    tools.push(vault_reconcile_tool());
    tools.push(vault_job_tool());

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
                "event_time": string_schema("Optional ISO8601 event timestamp to attach."),
                "impatient": boolean_schema("Optional. When true, the memory is encoded for semantic search INLINE before the write returns, so it is immediately recallable by BM25/vector search at the cost of a slower write. When false (default), the write returns immediately and encoding happens on the encode drain.")
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
                "scoring": string_schema("Scoring mode: matrixAware (default), hybrid, vector."),
                "ordering": string_schema("Result ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc, byRelevanceDesc. byRelevanceDesc routes to the scored recall pipeline (unionBest) whose results are ranked by relevance score — this is the recommended ordering when relevance matters.")
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
        "description": "Read all knowledge-graph facts in chronological order, including retired ones, to trace how the estate's structured knowledge evolved. Each row is tagged with its lifecycle state (active or retired). Optional entity filter narrows results to facts whose subject or object contains the given string.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "entity": string_schema("Optional entity name to filter by (subject or object substring match, case-insensitive). Omit to return the full history.")
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
                "ordering": string_schema("Ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc."),
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

fn list_recipes_catalog_tool() -> serde_json::Value {
    json!({
        "name": "moot_list_recipes",
        "description": "Browse the full recipe catalog: name, version, description, and required capabilities for every entry.",
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

fn recall_precise_tool() -> serde_json::Value {
    json!({
        "name": "moot_recall_precise",
        "description": "Precise recall: coarse-grab a generous candidate pool then re-rank by a named reduction composition (the ablation selector) to surface the exact answer above near-duplicates. Lifts found@1/MRR without dropping found@10. Returns the same shape as moot_memory_search.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "query": string_schema("The search query text — drives BM25 + vector recall and the precision re-rank."),
                "limit": integer_schema("Max ranked matches to return. Default 20."),
                "pool": integer_schema("Coarse candidate-pool size grabbed before the precision re-rank. Default 30; clamped to be at least limit."),
                "composition": string_schema("Named reduction composition selecting how the coarse pool is re-ranked. E.g. text (default), hamming, matrix, lattice, tokenExact, hamming+tokenExact, hamming+text, text+matrix, lattice+hamming, text+tokenExact, text+mmr, text+temporal, text+assembly, dense-fused, weighted-all. An unknown name is rejected (the boundary validates against the grid)."),
                "filter": filter_schema()
            }),
            json!(["query"])
        )))
    })
}

fn dream_tool() -> serde_json::Value {
    json!({
        "name": "moot_dream",
        "description": "Dream the estate: rebuild the co-occurrence/temporal matrix tier (the Brain's association layer that the matrix recall lane scores against) and run one dreaming cycle (latent-alignment proposals + cycle diary). The matrix is built by dreaming, not by capture, so a freshly-loaded estate has an empty matrix until this runs. Returns a cycle summary.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "now": string_schema("Optional ISO8601 instant to run the cycle at, for deterministic runs (drives the diary timestamp and the reward window). Omit to use the current wall clock.")
            }),
            json!([])
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
        "moot_lens_apriori" => "Analytics lens: mine multi-antecedent Apriori association rules from bitmap fingerprints.",
        "moot_lens_moment" => "Temporal lens: measure fingerprint-set similarity across a primary window and optional comparison windows.",
        "moot_lens_rhythm" => "Temporal lens: detect capture-rhythm patterns from fingerprint bit-series data.",
        "moot_lens_precedence" => "Temporal lens: discover temporal precedence (causal ordering) between drawers via audit event lag analysis.",
        "moot_lens_complexity" => "Information-theoretic lens: compute per-drawer content complexity scores.",
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
        "moot_lens_apriori" => object_schema(
            json!({
                "minSupport": number_schema("Minimum rule support (0..1). Default 0."),
                "minConfidence": number_schema("Minimum rule confidence (0..1). Default 0."),
                "minLift": number_schema("Minimum rule lift (default 1.0)."),
                "maxK": integer_schema("Maximum antecedent size (default 3)."),
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!([]),
        ),
        "moot_lens_moment" => object_schema(
            json!({
                "windowStart": string_schema("ISO8601 start of the primary window (inclusive)."),
                "windowEnd": string_schema("ISO8601 end of the primary window (inclusive)."),
                "comparisonWindows": {
                    "type": "array",
                    "description": "Optional comparison windows: objects with windowStart and windowEnd (ISO8601).",
                    "items": object_schema(
                        json!({
                            "windowStart": string_schema("ISO8601 start of the comparison window."),
                            "windowEnd": string_schema("ISO8601 end of the comparison window.")
                        }),
                        json!(["windowStart", "windowEnd"])
                    )
                },
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["windowStart", "windowEnd"]),
        ),
        "moot_lens_rhythm" => object_schema(
            json!({
                "bit": integer_schema("Fingerprint bit index to analyse (0–255)."),
                "bucketSeconds": integer_schema("Duration of each time bucket in seconds."),
                "bucketCount": integer_schema("Number of buckets back from endingAt."),
                "endingAt": string_schema("ISO8601 instant marking the end of the series."),
                "topK": integer_schema("How many dominant periods to return (default 3)."),
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["bit", "bucketSeconds", "bucketCount", "endingAt"]),
        ),
        "moot_lens_precedence" => object_schema(
            json!({
                "windowStart": string_schema("ISO8601 start of the audit window."),
                "windowEnd": string_schema("ISO8601 end of the audit window."),
                "targetField": string_schema("Field path of the target coordinate (e.g. \"room\")."),
                "targetValue": string_schema("Value repr of the target coordinate (e.g. \"string:study\")."),
                "k": integer_schema("How many antecedents to return (default 5)."),
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["windowStart", "windowEnd", "targetField", "targetValue"]),
        ),
        "moot_lens_complexity" => object_schema(
            json!({
                "fieldA": string_schema("Label field for entropy: room, wing, addedBy, embeddingModelID."),
                "fieldB": string_schema("Optional second label field for mutual information."),
                "filter": filter,
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["fieldA"]),
        ),
        _ => with_teachme(with_estate_id(object_schema(json!({}), json!([]))))
    }
}

// ---------------------------------------------------------------------------
// Vault tools — all five live over VaultKit-Rust: export/import (synchronous,
// recording a completed VaultJobRecord and returning its job_id), status,
// reconcile (dry-run default; apply=true actions candidates), and vault_job
// (completed-job lookup; tool-surface-parity ruling 2026-06-12)
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

/// `moot_vault_reconcile` — has an optional `apply` argument not shared by the
/// other vault tools.
///
/// Dry-run (default): re-hashes the vault, diffs against the export manifest,
/// and returns the candidate list. Writes nothing.
/// Apply mode (`apply=true`): imports the added/modified candidates into the
/// estate synchronously. Idempotent per note's `stable_source_key`.
/// Mirrors Swift `VaultTools.tools()` reconcile entry.
fn vault_reconcile_tool() -> serde_json::Value {
    json!({
        "name": "moot_vault_reconcile",
        "description": "Re-hash a vault's notes and report drift (added / modified / deleted) vs the export manifest. Dry-run by default: returns candidates and writes nothing. Pass apply=true to action the added and modified candidates by importing them into the estate synchronously. Deleted files are always reported only; no drawer is expunged.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "vaultPath": string_schema("Filesystem path to the vault directory."),
                "apply": boolean_schema("When true, import added/modified vault notes into the estate. Omit or set false for a dry-run that reports candidates without writing.")
            }),
            json!(["vaultPath"])
        )))
    })
}

/// `moot_vault_job` — poll the status and result of a vault job.
///
/// Schema is byte-identical to Swift `VaultTools.tools()` job entry:
///   required: ["job_id"]
///   job_id: string — "Job ID returned by moot_vault_import or moot_vault_export."
///
/// The Rust backend is synchronous: vault ops complete before returning, so
/// jobs recorded in the VaultJobLedger are always in the "complete" state.
/// moot_vault_job returns the completed record or the Swift-identical not-found
/// shape ("unknown job_id: <id>") for unrecognised IDs.
///
/// Parity ruling: Bob 2026-06-12 — "even if it returns synchronous-complete/
/// no-active-job. Tool surface parity matters."
fn vault_job_tool() -> serde_json::Value {
    json!({
        "name": "moot_vault_job",
        "description": "Poll the status and result of a vault import or export job started by moot_vault_import or moot_vault_export. Returns status (running / complete / failed), elapsed_s, and on completion the result counts or error description.",
        "inputSchema": with_teachme(object_schema(
            json!({
                "job_id": string_schema("Job ID returned by moot_vault_import or moot_vault_export.")
            }),
            json!(["job_id"])
        ))
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
