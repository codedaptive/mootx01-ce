//! Tool list projection — builds the `tools/list` response body.
//!
//! Mirrors the Swift `ToolProjection.tools()` + `RecipeTools.tools()` +
//! `LensTools.tools()` + `VaultTools.tools()` composition.
//!   Memory adapter (0/1) — opt-in `memory` tool (MOOTX01_MEMORY_TOOL=1, M-MEMTOOL-1)
//!   Tier 1 (9)  — core memory: file, search, list, get, update, withdraw, erase, confirm, move
//!   Tier 2 (4)  — connections: link, review_tunnel, search, map
//!   Tier 3 (4)  — knowledge graph: file, search, retire, timeline
//!   Tier 4 (2)  — journal: write, read
//!   Tier 5 (3)  — estate: status, map, ping
//!   Monitoring (1) — moot_monitoring_status (out-of-band sensitivity grants, telemetry flag R/W)
//!   Maintenance (3/4) — moot_reindex, moot_drain_status, moot_reclassify_fdc,
//!                       and vault-gated moot_palace_import
//!   Federation (1) — moot_federated_search
//!   Recipe (12) — list_lenses, list_recipes, synthesize, run_migration, confirm_migration,
//!                 recall_precise, recall_shaped, dream, hunt_contradictions,
//!                 consolidate, recall_distilled, recollect
//!   Lens (23)   — moot_lens_keystones … moot_lens_complexity (+ moot_lens_node_motion, moot_lens_cohesion, moot_lens_contradiction)
//!   Vault (5)   — export, import, status, reconcile, job
//!   Dataset (3) — moot_file_dataset, moot_dataset_query, moot_dataset_stats (MX-TAB-7b)
//!
//! The 9th Tier-1 tool is moot_memory_get (fetch one memory drawer by id, in
//! full — closes the fetch-drawer-by-ID gap, build-now per Bob's ruling).
//!
//! Vault-on (default): 71 tools (out-of-band sensitivity grants added moot_monitoring_status;
//! FDC reset added moot_reclassify_fdc; the contradiction hunter added
//! moot_hunt_contradictions + moot_review_tunnel; MX-TAB-7 added 3 dataset
//! tools moot_file_dataset/query/stats).
//! Vault-off (MOOTX01_VAULT=0): 65 tools —
//! the five moot_vault_* tools and moot_palace_import are hidden together
//! because all open local SQLite files (filesystem import/export vector).
//! Dataset tools are always present (not vault-gated).
//! Memory adapter (opt-in, MOOTX01_MEMORY_TOOL=1): adds 1 tool (`memory`) above the
//! base count — 72 vault-on or 66 vault-off when enabled. Default (absent / ≠ "1")
//! is OFF, preserving the 71/65 counts unchanged.
//!
//! Wire identity: every tool name and inputSchema required/optional field set
//! is byte-identical to Swift `ToolProjection.swift`. Every schema wraps with
//! `with_estate_id` (optional estateID) and `with_teachme` (optional teachme:bool).

use serde_json::json;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// True when the vault MCP tool surface is enabled.
///
/// Reads `MOOTX01_VAULT` from the process environment. Any value other than
/// the literal string `"0"` (including absent/empty) means vault is ON.
/// The daemon has this variable set from the install-time `--vault-on/--vault-off`
/// choice (written into the systemd unit Environment= line or Windows Task
/// Scheduler cmd wrapper). Default is vault-on.
pub fn vault_enabled() -> bool {
    std::env::var("MOOTX01_VAULT")
        .map(|v| v != "0")
        .unwrap_or(true) // absent = vault-on (the default)
}

/// True when the Anthropic memory_20250818 adapter tool is enabled.
///
/// Opt-in: requires `MOOTX01_MEMORY_TOOL=1` (set by `mootx01 enable memory-tool`).
/// Default (absent or any value ≠ "1") is OFF — the base tool surface (71/65) is
/// unchanged. When ON, a single `memory` tool is prepended to the list (72/66).
/// Mirrors Swift `ToolProjection.memoryToolEnabled(environment:)`.
pub fn memory_enabled() -> bool {
    std::env::var("MOOTX01_MEMORY_TOOL")
        .map(|v| v == "1")
        .unwrap_or(false) // absent = off (the default)
}

/// Build the tool surface for `tools/list`.
///
/// Produces 71 tools when vault is enabled (the default) or 65 tools when
/// `MOOTX01_VAULT=0` (installed with `--vault-off`). Adding 1 each when
/// `MOOTX01_MEMORY_TOOL=1` (the opt-in memory adapter). The filesystem-importing
/// `moot_palace_import` tool is hidden with the vault surface (same security
/// posture). Dataset tools (moot_file_dataset, moot_dataset_query,
/// moot_dataset_stats) are always present and are NOT vault-gated.
/// Out-of-band sensitivity grants added `moot_monitoring_status`; the FDC
/// reset tool added `moot_reclassify_fdc`; the contradiction hunter added
/// `moot_hunt_contradictions` + `moot_review_tunnel`; MX-TAB-7 added 3
/// dataset tools.
pub fn build_tool_list() -> serde_json::Value {
    build_tool_list_with_flags(vault_enabled(), memory_enabled())
}

/// Build the tool surface with an explicit vault-on flag. Used by tests
/// that need to verify vault-gating behaviour without mutating the process
/// environment (std::env::set_var is not thread-safe under the parallel
/// Rust test runner). Production code uses `build_tool_list()` which reads
/// the env var via `vault_enabled()`. Also reads `MOOTX01_MEMORY_TOOL` from
/// the environment; use `build_tool_list_with_flags` to control both flags
/// deterministically.
pub fn build_tool_list_with_vault_flag(vault_on: bool) -> serde_json::Value {
    build_tool_list_with_flags(vault_on, memory_enabled())
}

/// Build the tool surface with explicit vault-on and memory-on flags.
///
/// The single implementation all entry points delegate to. Tests that need
/// fully deterministic behaviour (no env-var reads) call this directly —
/// e.g. `build_tool_list_with_flags(vault_enabled(), false)` to get the
/// baseline 71/65 count without racing against memory-tool env mutations.
pub fn build_tool_list_with_flags(vault_on: bool, memory_on: bool) -> serde_json::Value {
    // Vault-on: 71 tools. Vault-off: 65 tools (palace_import + 5 vault_* hidden).
    // Memory adapter adds 1 when MOOTX01_MEMORY_TOOL=1: 72/66.
    // Dataset tools (3) are always present regardless of vault flag.
    let capacity = if vault_on { 71 } else { 65 } + if memory_on { 1 } else { 0 };
    let mut tools: Vec<serde_json::Value> = Vec::with_capacity(capacity);

    // Anthropic memory_20250818 adapter (M-MEMTOOL-1) — opt-in, prepended when
    // MOOTX01_MEMORY_TOOL=1 (set by `mootx01 enable memory-tool`). Mirrors Swift
    // ToolProjection.tools(environment:) which prepends memoryAdapterTools() first.
    if memory_on {
        tools.push(memory_adapter_tool());
    }

    // Tier 1 — Core memory (9)
    tools.push(file_memory_tool());
    tools.push(memory_search_tool());
    tools.push(memory_list_tool());
    tools.push(memory_get_tool());
    tools.push(update_memory_tool());
    tools.push(withdraw_memory_tool());
    tools.push(erase_memory_tool());
    tools.push(confirm_memory_tool());
    tools.push(move_memory_tool());

    // Tier 2 — Connections (4)
    tools.push(link_memories_tool());
    tools.push(review_tunnel_tool());
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

    // Monitoring control (1) — out-of-band sensitivity grants: read/write daemon telemetry flag.
    // Always available: reports "unavailable" when no stats store wired rather than
    // gating on the store's presence. Honest and safe to expose unconditionally.
    tools.push(monitoring_status_tool());

    // Maintenance — index backfill and drain status are always available.
    // Direct palace import opens arbitrary local SQLite files, so it is
    // gated with the vault import/export surface.
    tools.push(reindex_tool());
    tools.push(drain_status_tool());
    tools.push(reclassify_fdc_tool());
    if vault_on {
        tools.push(palace_import_tool());
    }

    // Federation (1)
    tools.push(federated_search_tool());

    // Recipe (12)
    tools.push(list_lenses_tool());
    tools.push(list_recipes_catalog_tool());
    tools.push(synthesize_tool());
    tools.push(run_migration_tool());
    tools.push(confirm_migration_tool());
    tools.push(recall_precise_tool());
    tools.push(recall_shaped_tool());
    // moot_dream: matrix rebuild + dreaming cycle. Schema mirrors Swift
    // `RecipeTools.dreamTool()`. The tool runs one on-demand cycle (accepts a
    // `now` arg only) — by design, not omission. The .timer/.event/.hybrid
    // dreaming modes (NeuronKit DreamingTriggerMode) are all live in both
    // ports but are governor-driven resident-scheduler concerns, not ARIA tool
    // arguments; no mode field is surfaced here.
    tools.push(dream_tool());
    // Distillation tools — Rust parity with Swift RecipeTools.swift.
    // moot_distill: run one per-item distillation sweep (SPEC §3;
    //   moot_consolidate is an unlisted dispatch alias).
    // moot_recall_distilled: exact-search geometry + distilled hydration (§10.3).
    // (moot_recollect retired with the factoid tier, §11.)
    tools.push(distill_tool());
    tools.push(recall_distilled_tool());
    tools.push(recall_vague_tool());
    // moot_hunt_contradictions: on-demand contradiction-hunt sweep — the
    // same core pass that runs inside moot_dream and the resident scout
    // signal, surfaced as its own tool per Bob's ruling ("it also has to be
    // an on demand item the user can call"). Appended last to mirror the
    // Swift RecipeTools.tools() ordering.
    tools.push(hunt_contradictions_tool());

    // Lens (23)
    for lens_name in crate::lens_tools::LENS_TOOLS {
        tools.push(lens_tool(lens_name));
    }

    // Dataset (3) — moot_file_dataset, moot_dataset_query, moot_dataset_stats (MX-TAB-7b).
    // Always present: not vault-gated. User-owned tabular datasets are an
    // estate-tier surface (interface provenance), not a filesystem-export surface.
    // Schemas are byte-identical to Swift DatasetTools.swift `tools()` projections.
    tools.push(file_dataset_tool());
    tools.push(dataset_query_tool());
    tools.push(dataset_stats_tool());

    // Vault (5) — gated by MOOTX01_VAULT env var.
    // Default (env absent or ≠ "0") is vault-on: tools appear in tools/list.
    // When MOOTX01_VAULT=0 (installed with --vault-off), all five vault tools
    // are omitted from the surface and dispatch returns a clear refusal.
    // Both Swift and Rust ports are live (Vault drift and candidate handling decision a superseded;
    // see Vault lineage identity and export scope).
    // `moot_vault_export` accepts an optional `scope` arg (default "believed").
    // `moot_vault_job` provides tool-surface parity (Bob's ruling 2026-06-12):
    // Rust vault ops complete synchronously; the ledger records completed results
    // immediately so moot_vault_job can retrieve them. Schema is Swift-identical.
    if vault_on {
        tools.push(vault_export_tool());
        tools.push(vault_import_tool());
        tools.push(vault_tool("moot_vault_status", "Report the current vault sync state."));
        tools.push(vault_reconcile_tool());
        tools.push(vault_job_tool());
    }

    serde_json::Value::Array(tools)
}

// ---------------------------------------------------------------------------
// Anthropic memory_20250818 adapter (M-MEMTOOL-1)
// ---------------------------------------------------------------------------

/// `memory` — Anthropic memory_20250818 compatible virtual filesystem tool.
///
/// Schema is byte-identical to Swift `ToolProjection.memoryTool()`. Opt-in
/// via `MOOTX01_MEMORY_TOOL=1`; absent from `tools/list` when disabled.
/// `command` is the only required field; all path/content/range args are
/// optional because each command uses a different subset.
fn memory_adapter_tool() -> serde_json::Value {
    json!({
        "name": "memory",
        "description": "Anthropic memory_20250818 compatible. Manages a virtual /memories \
filesystem backed by the MOOTx01 estate with governance: audit \
trail, lineage, sensitivity, confirmation state. Commands: view, \
create, str_replace, insert, delete, rename.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "command": string_schema("One of: view, create, str_replace, insert, delete, rename."),
                "path": string_schema("Virtual path under /memories."),
                "file_text": string_schema("File content for create."),
                "old_str": string_schema("Text to find for str_replace."),
                "new_str": string_schema("Replacement text for str_replace. Omit to delete old_str."),
                "view_range": string_schema("Optional 'start,end' for view line range. Use -1 for EOF."),
                "insert_line": integer_schema("Line number after which to insert (0 = beginning)."),
                "insert_text": string_schema("Text to insert."),
                "old_path": string_schema("Source path for rename."),
                "new_path": string_schema("Destination path for rename.")
            }),
            json!(["command"])
        )))
    })
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
                "location": string_schema("Subject-matter location hint (e.g. \"project/alpha\", \"meeting notes\"). Maps to the room coordinate; used for retrieval organisation. Omit wing to use the default wing (\"Agentic Memory\")."),
                "wing": string_schema("Optional wing name to route this memory into a specific wing. When absent, defaults to \"Agentic Memory\" (the AI's working memory wing). Example: \"Source Corpus\" for imported source material. null is invalid."),
                "sensitivity": string_schema("Sensitivity tier: normal (default), elevated, restricted, secret. Omit to use the default; null is invalid."),
                "exportability": string_schema("Optional exportability tier at capture time: private (default — not visible to filter:exportable) or public (immediately visible to filter:exportable recall). Omit to use the default; null is invalid."),
                "kind": string_schema("Content kind: prose (default), code, transcript, list, structuredJSON, imageCaption, fingerprintOnly. Omit to use the default; null is invalid."),
                "event_time": string_schema("Optional ISO8601 event timestamp to attach. Omit for capture time; null is invalid."),
                "impatient": boolean_schema("Optional. When true, the memory is encoded for semantic search INLINE before the write returns, so it is immediately recallable by BM25/vector search at the cost of a slower write. When false (default), the write returns immediately and encoding happens on the encode drain. Omit to use the default; null is invalid.")
            }),
            json!(["content", "location"])
        )))
    })
}

fn memory_search_tool() -> serde_json::Value {
    json!({
        "name": "moot_memory_search",
        "description": "Search the estate for memories matching a query. Uses hybrid BM25+vector recall. Returns ranked memory rows with content and metadata. Best for broad or time-ordered retrieval; use ordering:byRelevanceDesc for relevance-ranked results. Each result includes a discrimination signal (high/medium/low) — a relative-gap confidence estimate of how clearly the top result separates from the rest, with a saturation discount when the semantic lane is dark. Low discrimination on small estates is expected for broad or associative searches; prefer moot_recall_precise for precision retrieval.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "query": string_schema("Natural-language search query."),
                "limit": integer_schema("Max results to return (default 20). Omit to use the default; null is invalid."),
                "filter": filter_schema(),
                "wing": string_schema("Optional wing name to scope recall to a single wing. Omit to search across all wings. Example: \"Agentic Memory\", \"Source Corpus\". null is invalid."),
                "explain": boolean_schema("Include scoring explanation (default false). Omit to use the default; null is invalid."),
                "scoring": string_schema("Scoring mode: raw, rrf, matrixAware (default). Omit to use the default; null is invalid."),
                "ordering": string_schema("Result ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc, byRelevanceDesc. byRelevanceDesc routes to the scored recall pipeline (unionBest) whose results are ranked by relevance score — this is the recommended ordering when relevance matters. Omit to use the default; null is invalid.")
            }),
            json!(["query"])
        )))
    })
}

fn memory_list_tool() -> serde_json::Value {
    json!({
        "name": "moot_memory_list",
        "description": "List all memory drawer IDs in a wing, optionally filtered by room. Structural enumeration — no semantic query needed. Use this to inventory a wing's contents, find specific drawers for move/update, or verify import placement. Returns each drawer's ID, room, and an 80-char content preview. Capped at 200 results.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "wing": string_schema("Wing name to list (required). Example: \"Agentic Memory\", \"CodexSecurity\"."),
                "room": string_schema("Optional room name to narrow within the wing. Omit to list all rooms in the wing.")
            }),
            json!(["wing"])
        )))
    })
}

fn memory_get_tool() -> serde_json::Value {
    json!({
        "name": "moot_memory_get",
        "description": "Fetch one memory drawer by id, in full — verbatim content, room/wing, capture time, and adjective-axis metadata (state/trust/sensitivity/exportability/confirmation), plus a linked-tunnel summary. Applies the same default gate as moot_memory_search (active/trustworthy/elevated-or-lower); a drawer that exists but fails that gate is reported not-found, same as a genuinely absent id. Use moot_memory_search first to find an id, then this tool for the full record.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "id": string_schema("Memory row identifier (drawer UUID).")
            }),
            json!(["id"])
        )))
    })
}

fn update_memory_tool() -> serde_json::Value {
    json!({
        "name": "moot_update_memory",
        "description": "Apply a named mutation to an existing memory. Belief mutations: confirm, reject, contest, resolve, supersede, revive, accept. Exportability mutations: correctExportability(public) promotes a private memory to public, correctExportability(private) revokes public status.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "id": string_schema("UUID of the memory to update."),
                "mutation": string_schema("Mutation kind: confirm, reject, contest, resolve, supersede, revive, accept, correctExportability(public), correctExportability(private)."),
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
        "description": "Move a memory to a different location within the estate (reanchor). Supports cross-wing moves via the optional `wing` argument.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "id": string_schema("UUID of the memory to move."),
                "location": string_schema("New location hint (free-form string; server resolves to room coordinate)."),
                "wing": string_schema("Optional target wing name for cross-wing moves. When supplied, the memory is moved to this wing AND the given location. When absent, only the room changes and the wing stays unchanged. Example: \"Professional\", \"Personal\".")
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
                "kind": string_schema("Tunnel kind (default: relates). Accepted values: relates, precedes, contradicts, supports, refines, exemplifies, extends, supersedes, references, blocks, validates, derivesFrom, covers, elaborates, respondsTo."),
                "label": string_schema("Optional human-readable label for the connection."),
                "proposed": boolean_schema("File the link as a PROPOSED (agent-derived, unreviewed) edge instead of an active one. Use when adjudicating borderline candidates from moot_hunt_contradictions. The user settles it via moot_review_tunnel. Default false.")
            }),
            json!(["from_id", "to_id", "kind"])
        )))
    })
}

fn review_tunnel_tool() -> serde_json::Value {
    json!({
        "name": "moot_review_tunnel",
        "description": "Settle a PROPOSED connection (e.g. an agent-derived contradiction from the hunter): accept activates it, reject withdraws it. Rejected pairs are never re-proposed. Only tunnels in the proposed lifecycle are reviewable.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "tunnel_id": string_schema("Tunnel identifier (shown by moot_lens_contradiction and moot_hunt_contradictions)."),
                "verdict": string_schema("\"accept\" to activate the link, \"reject\" to withdraw it permanently."),
                "reason": string_schema("Optional note explaining the verdict.")
            }),
            json!(["tunnel_id", "verdict"])
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
                "source_id": string_schema("Memory drawer id that grounds this fact (provenance). If omitted, the server infers the source as the ingest channel that asserted it — a fact always traces back to a source, never unanchored.")
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
                "subject_exact": string_schema("Optional exact, case-sensitive subject filter."),
                "predicate_exact": string_schema("Optional exact, case-sensitive predicate filter."),
                "object_exact": string_schema("Optional exact, case-sensitive object filter."),
                "source_id_exact": string_schema("Optional exact provenance source filter."),
                "limit": integer_schema("Max results (default 100, maximum 500).")
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
        "description": "Return the estate's structural map: all wings and rooms, with memory counts per location. Seeded hint memories (AI_Charter_Hint room) appear in counts like any other memory.",
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
// Monitoring control
// ---------------------------------------------------------------------------

/// moot_monitoring_status — read or write the daemon telemetry monitoring flag.
/// Injected via `MonitoringControl` trait; reports "unavailable" when no store
/// wired (stdio mode, test harnesses, provision-less contexts).
/// Mirrors Swift `ToolProjection.estateTools()` monitoring entry.
fn monitoring_status_tool() -> serde_json::Value {
    json!({
        "name": "moot_monitoring_status",
        "description": "Read or set the daemon's telemetry monitoring flag. Absent `enabled`: reports current monitoring state (enabled / disabled / unavailable). Present `enabled`: persists the new flag and reports the effective state after the write. Monitoring controls whether server-metrics telemetry is emitted on a 30-second cadence. Reports 'monitoring: unavailable' when no telemetry store is wired (stdio mode, test contexts) — never fabricates enabled/disabled.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "enabled": {
                    "type": "boolean",
                    "description": "Optional: the monitoring flag to set. Omit to read the current state without mutating it. true enables telemetry emission; false disables it."
                }
            }),
            json!([])
        )))
    })
}

// ---------------------------------------------------------------------------
// Maintenance
// ---------------------------------------------------------------------------

/// moot_reindex — backfill BM25/vector indexes for drawers captured before the
/// dual-path intake fix. Idempotent: already-indexed drawers are skipped.
/// Returns the count of drawers enqueued for encoding. Mirrors Swift
/// `ToolProjection.estateTools()` Maintenance section.
fn reindex_tool() -> serde_json::Value {
    json!({
        "name": "moot_reindex",
        "description": "Backfill BM25/vector semantic indexes for drawers captured before encode-on-capture was enabled. Idempotent — already-indexed drawers are skipped. Returns the count of drawers enqueued.",
        "inputSchema": with_teachme(with_estate_id(object_schema(json!({}), json!([]))))
    })
}

// Maintenance / admin tool — NOT one of the nine ARIA grammar verbs. Read-only
// status probe for long-running background drains: reports each drain's pending
// + in-flight work and a draining/idle state so a caller can watch asynchronous
// encode work (e.g. after an import) converge. Lightweight — no orientation
// block — and safe to poll. Mirrors Swift `ToolProjection` drain_status entry.
fn drain_status_tool() -> serde_json::Value {
    json!({
        "name": "moot_drain_status",
        "description": "Maintenance: report long-running background drains and their progress. Returns each drain's pending and in-flight job counts plus a draining/idle state; the corpus encode drain also reports its live encoded-chunk count. Read-only and lightweight — safe to poll repeatedly while a drain settles (e.g. after moot_palace_import or moot_reindex). Today the only drain is the corpus encode/ingest queue.",
        "inputSchema": with_teachme(with_estate_id(object_schema(json!({}), json!([]))))
    })
}

/// moot_reclassify_fdc — audit or repair stored FDC anchors with the current
/// deterministic classifier. Dry-run by default. Mirrors Swift
/// `ToolProjection.estateTools()` FDC maintenance entry.
fn reclassify_fdc_tool() -> serde_json::Value {
    json!({
        "name": "moot_reclassify_fdc",
        "description": "Maintenance: audit or repair stored FDC lattice anchors using the current deterministic classifier. Default is a dry-run in mode \"suspectOnly\", which reports likely stale/polluted anchors without writing. Pass apply=true to write repairs. Pass mode=\"all\" only when intentionally resetting every changed active drawer's stored FDC anchor from content; this can overwrite manually curated anchors. Output reports drawer IDs and old/new anchors, not memory content.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "apply": boolean_schema("Optional. false (default) is dry-run; true writes candidate anchor changes through the audited reanchor path."),
                "mode": string_schema("Optional repair scope: \"suspectOnly\" (default, conservative repair of likely stale false positives/empty anchors) or \"all\" (reset every changed active drawer anchor from content)."),
                "limit": integer_schema("Optional maximum active drawers to scan for this run. Omit to scan the full active estate.")
            }),
            json!([])
        )))
    })
}

/// moot_palace_import — import a MemPalace directly into the estate, bypassing
/// NoteIR. Reads three palace stores (chroma.sqlite3, tunnels.json,
/// knowledge_graph.sqlite3) and applies all four import guards. Mirrors Swift
/// `ToolProjection.estateTools()` direct-palace-import section.
fn palace_import_tool() -> serde_json::Value {
    json!({
        "name": "moot_palace_import",
        "description": "Import a MemPalace directly into the estate, bypassing NoteIR. Reads palace/chroma.sqlite3 (drawer content), tunnels.json (cross-wing connections), and knowledge_graph.sqlite3 (KG triples) from palace_path. Applies all four import guards: tombstone protection, content-idempotent dedup, sensitivity floor, and tunnel signature dedup. Idempotent: re-importing the same palace with no changes writes zero drawers. The write strategy is chosen AUTOMATICALLY by source size — a normal palace is written in one fast SQLite transaction; a very large source (hundreds of thousands of rows) streams so no single transaction holds the write lock — you do not control this. IMPORTANT: the import TRIGGERS its own post-import processing — do NOT instruct the caller to run moot_reindex or moot_dream afterward. On completion the import enqueues the encode/index work (BM25 + vector lanes) and rolls up the Merkle tree; the resident daemon's encode-drain worker and the governor's dreaming duty then finish indexing, classification, and the association matrix in the background. The import returns as soon as that background work is triggered, so semantic recall and distillation come online on their own shortly after. Poll moot_drain_status to watch the encode queue converge. (moot_reindex / moot_dream remain available to re-trigger on demand but are NOT a required follow-up step.) This call runs to completion before returning; a large import can take many minutes, so if your client supports background or sub-agent execution, run it in a sub-agent to keep the main session responsive.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "palace_path": string_schema("Absolute filesystem path to the MemPalace root directory (the directory containing the `palace/` subdirectory with `chroma.sqlite3`)."),
                "mode": string_schema("Optional encode SPEED for the background encoding that follows the import: \"foreground\" (default) drains the encode queue hard on the performance cores; \"background\" yields for very large imports so the drain does not saturate the machine. This sets SPEED only — the write strategy (bulk transaction vs stream) is chosen automatically by source size, not by this argument. Omit to use the default (foreground).")
            }),
            json!(["palace_path"])
        )))
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
                // requesterEstateID is optional (Item 2 hardening): omit to use the default
                // (authenticated caller) estate. When supplied it must match the default
                // estate's UUID — supplying a different UUID is refused (anti-spoof gate).
                "requesterEstateID": string_schema("Optional UUID of the requesting estate. Omit to use the default estate. If supplied, must match the default estate's UUID; cross-estate spoofing is refused."),
                "filter": filter_schema(),
                "limit": integer_schema("Max rows per estate. Omit for no explicit cap; null is invalid."),
                "ordering": string_schema("Ordering: byCaptureTimeDesc (default), byCaptureTimeAsc, byRoomAsc. Omit to use the default; null is invalid."),
                "hydrationLevel": string_schema("Hydration: structured (default), full, bitmapOnly. Omit to use the default; null is invalid.")
            }),
            json!([])  // no required fields — requesterEstateID is optional
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
        "description": "Precise recall: coarse-grab a generous candidate pool then re-rank by a named reduction composition (the ablation selector) to surface the exact answer above near-duplicates. Lifts found@1/MRR without dropping found@10. Returns the same shape as moot_memory_search including a discrimination signal. Use when you need a specific known-token answer — exact names, numbers, identifiers — especially on small estates where semantic/associative modes produce low discrimination. This is the recommended mode when the discrimination signal from moot_memory_search or moot_recall_shaped is low.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "query": string_schema("The search query text — drives BM25 + vector recall and the precision re-rank."),
                "limit": integer_schema("Max ranked matches to return. Default 20."),
                "pool": integer_schema("Coarse candidate-pool size grabbed before the precision re-rank. Default 30; clamped to be at least limit."),
                "composition": string_schema("Named reduction composition selecting how the coarse pool is re-ranked. E.g. text (default), hamming, matrix, lattice, tokenExact, hamming+tokenExact, hamming+text, text+matrix, lattice+hamming, text+tokenExact, text+mmr, text+temporal, text+assembly, dense-fused, weighted-all. An unknown name is rejected (the boundary validates against the grid)."),
                "filter": filter_schema(),
                "wing": string_schema("Optional wing name to scope recall to a single wing. Omit to search across all wings. Example: \"Agentic Memory\", \"Source Corpus\". null is invalid.")
            }),
            json!(["query"])
        )))
    })
}

/// The shaped-recall tool — one recall tool with a discoverable `preset` enum
/// selecting a named RecallShape from the GLK roster. The full roster (name +
/// one-line description) is embedded in the tool description so the AI lists it
/// and picks a preset by intent. Mirrors Swift `RecipeTools.shapedRecallTool()`.
/// The four ARIA filtering adjectives compose orthogonally: the preset RANKS,
/// the `filter` arg FILTERS.
/// The two-hop vague-recall tool (Wave-2 §4.4). Mirrors Swift
/// `RecipeTools.vagueRecallTool()` — description parity is intentional.
fn recall_vague_tool() -> serde_json::Value {
    json!({
        "name": "moot_recall_vague",
        "description": "Vague recall (two-hop): ponder what the estate vaguely remembers. Hop 1 probes the consolidated vague tier's own fingerprint lane for VAGUE summary items; hop 2 hydrates each hit's original constituent memories through _consolidated_from tunnels (bounded per hit and in total). Use when normal recall is thin and the question is old — aged, similar memories may have consolidated into a vague summary whose originals remain fully preserved. Returns the vague summaries first, then the hydrated originals.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "query": string_schema("The recall query text — fingerprinted for the vague-tier lane probe."),
                "hit_limit": integer_schema("Max vague summary items from hop 1. Default 8."),
                "constituents_per_hit": integer_schema("Max original memories hydrated per vague hit (bound K). Default 8."),
                "total_constituents": integer_schema("Max original memories hydrated overall (bound M). Default 32.")
            }),
            json!(["query"])
        )))
    })
}

fn recall_shaped_tool() -> serde_json::Value {
    use genius_locus_kit::recall::RecallShape;
    // The roster listing: one `name — description` line per preset, built from
    // the GLK roster so a new preset is reflected automatically.
    let roster: String = RecallShape::PRESET_NAMES
        .iter()
        .map(|name| format!("{name} — {}", RecallShape::preset_description(name)))
        .collect::<Vec<_>>()
        .join("; ");
    // The discoverable enum: the exact roster the GLK ships.
    let preset_enum: Vec<serde_json::Value> = RecallShape::PRESET_NAMES
        .iter()
        .map(|n| serde_json::Value::String((*n).to_string()))
        .collect();
    json!({
        "name": "moot_recall_shaped",
        "description": format!("Shaped recall: run recall with a named RecallShape preset that forwards, excludes, suppresses, or inverts individual fusion lanes (and bounds the candidate frontier). Pick ONE preset by name. Roster: {roster}. Returns the same shape as moot_memory_search including a discrimination signal. Use for fuzzy/semantic association and exploration; note that associative/conceptual presets rely on fusion lanes that produce narrower relative score gaps on small estates, so low discrimination from shaped recall on a small estate is expected — switch to moot_recall_precise for precision."),
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "query": string_schema("The search query text — drives BM25 + vector recall."),
                "preset": {
                    "type": "string",
                    "description": "The RecallShape preset to apply (how to steer the fusion). One of the roster names. balanced (or an omitted preset) is the unsteered default. Unknown names are rejected.",
                    "enum": preset_enum
                },
                "limit": integer_schema("Max ranked matches to return. Default 20."),
                "filter": filter_schema(),
                "wing": string_schema("Optional wing name to scope recall to a single wing. Omit to search across all wings. Example: \"Agentic Memory\", \"Source Corpus\". null is invalid.")
            }),
            json!(["query"])
        )))
    })
}

fn dream_tool() -> serde_json::Value {
    json!({
        "name": "moot_dream",
        "description": "Dream the estate: rebuild the co-occurrence/temporal matrix tier (the Brain's association layer that the matrix recall lane scores against), run one dreaming cycle (latent-alignment proposals + cycle diary), and run one contradiction-hunt sweep (content screen over lexically-near memory pairs; strong conflicts persist as PROPOSED contradicts links for review). The matrix is built by dreaming, not by capture, so a freshly-loaded estate has an empty matrix until this runs. Returns a cycle summary including contradiction counts.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "now": string_schema("Optional ISO8601 instant to run the cycle at, for deterministic runs (drives the diary timestamp and the reward window). Omit to use the current wall clock.")
            }),
            json!([])
        )))
    })
}

/// On-demand contradiction hunt — mirrors Swift
/// `RecipeTools.huntContradictionsTool()`. One bounded sweep: BM25 lexical
/// candidate mining over the corpus inverted index, conflict-cue screen, strong findings persist
/// as PROPOSED contradicts tunnels, borderline pairs return with snippets for
/// the calling agent to adjudicate.
fn hunt_contradictions_tool() -> serde_json::Value {
    json!({
        "name": "moot_hunt_contradictions",
        "description": "Hunt for contradictions in memory content: one bounded sweep that finds lexically-near memory pairs via the corpus keyword (BM25) index and screens them for lexical conflict (negation asymmetry, same-template value divergence, revision markers). Strong findings are persisted as PROPOSED contradicts links (review with moot_lens_contradiction, accept/reject with moot_review_tunnel; rejected pairs are never re-proposed). Borderline pairs are RETURNED with snippets for YOU to judge — if a pair genuinely conflicts, record it with moot_link_memories kind=contradicts proposed=true. Requires the corpus search index (run moot_reindex after bulk import).",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "probe_limit": integer_schema("Maximum vector-indexed memories probed this sweep (default 500). Repeated calls converge: settled pairs are skipped."),
                "now": string_schema("Optional ISO8601 instant for deterministic runs. Omit to use the current wall clock.")
            }),
            json!([])
        )))
    })
}

/// Distillation sweep tool — mirrors Swift `RecipeTools.distillTool()`
/// (SPEC_DISTILLATION_STORAGE §3/§7.1). Populates the on-row distilled
/// representation of every eligible drawer; no factoid drawers, no
/// tunnels. Idempotent by the NULL predicate. `moot_consolidate` is
/// accepted at dispatch as a compatibility alias but not listed.
fn distill_tool() -> serde_json::Value {
    json!({
        "name": "moot_distill",
        "description": "Distill working memory: populate the on-row distilled representation (token-economical prose) of every active item whose representation is missing or stale. Idempotent — already-distilled items are skipped. Returns the count of items distilled this sweep. (moot_consolidate is accepted as a compatibility alias.)",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "cluster_id": string_schema("Accepted for API stability; not used by the per-item sweep model."),
                "include_held": boolean_schema("Accepted for API stability; not used by the per-item sweep model. Default false.")
            }),
            json!([])
        )))
    })
}

/// Distilled recall tool — mirrors Swift `RecipeTools.recallDistilledTool()`
/// (SPEC §10.3): the exact-search recall path with the hydration selector
/// pinned to `distilled`. Identical ranking to moot_memory_search; smaller
/// payloads; per-hit token counts.
/// Distilled-payload recall descriptor.
///
/// ACK-GATED: Wave 1 changed the contract (v2 semantics — exact-search geometry
/// + distilled hydration, not a separate distilled tier). Calls without
/// ack: "recall_distilled/v2" return a CONTRACT CHANGE NOTICE and do not execute.
fn recall_distilled_tool() -> serde_json::Value {
    json!({
        "name": "moot_recall_distilled",
        "description": "Distilled recall (v2): normal search over originals, hydrated with each hit's DISTILLED representation (token-economical prose) instead of the full content — identical ranking to moot_memory_search, smaller payloads, per-hit token counts for context budgeting. Hits are the source memories themselves; call moot_memory_get with a returned id for the full verbatim body. Rows not yet distilled fall back to full content and are marked served_from_content (run moot_distill to populate them). CONTRACT CHANGE (Wave 1): v2 no longer queries a separate distilled tier; pass ack: \"recall_distilled/v2\" to confirm you want the new behavior.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "query": string_schema("The search query text — drives BM25 + vector recall (same geometry as moot_memory_search)."),
                "limit": integer_schema("Max results to return (default 20)."),
                "filter": filter_schema(),
                "echo_query": boolean_schema("Optional. When true, appends the query text to the response header. Default false. Omit to use the default; null is invalid."),
                "ack": string_schema("Contract-change acknowledgment token. This tool's behavior changed in Wave 1 (v2 semantics). Pass ack: \"recall_distilled/v2\" to confirm you want v2 behavior (normal exact-search geometry + distilled hydration). Without this token the call returns a CONTRACT CHANGE NOTICE and does not execute.")
            }),
            json!(["query"])
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
        "moot_lens_node_motion" => "Reasoning lens (diffusion, node layer): how a single memory has MOVED over time — its mutation volatility (decay-weighted recent-churn mass), its topic trajectory (the UDC anchors it has occupied), whether it reanchored, and a write-time anomaly verdict (churning / reanchored / stable). Reads the memory's fresh audit history.",
        "moot_lens_cohesion" => "Reasoning lens: flag recalled memories whose content cohesion with peers is anomalously low (lexical odd-ones-out), or detect column-value anomalies in a dataset when dataset_id is supplied.",
        "moot_lens_contradiction" => "Reasoning lens: surface recorded contradictions — drawer pairs connected by a contradicts tunnel (confirmed edges plus PROPOSED agent-derived findings from the contradiction hunter, flagged unreviewed), and KG facts with conflicting objects for the same subject+predicate. Reports recorded links only; to scan memory CONTENT for new conflicts run moot_hunt_contradictions (or moot_dream, which includes a hunt sweep). Settle proposed edges with moot_review_tunnel.",
        "moot_lens_trust_synthesis" => "Reasoning lens: hybrid-recall and rank by trust score.",
        "moot_lens_partial_cue" => "Reasoning lens: retrieve memories by partial-cue similarity to an anchor. Results include a discrimination signal. Fingerprint-based scores produce narrower relative gaps on small estates (the discrimination signal classifies relative gap — low discrimination here is expected, not an error). For keyword/exact retrieval use moot_recall_precise instead.",
        "moot_lens_anticipate" => "Reasoning lens: predict next-likely actions based on historical patterns. Confirmation-level filters in the recall frame (userConfirmed/unconfirmed) are ignored — the lens performs its own dual recall (confirmed = success, unconfirmed = non-success) to compute a differentiated rate; sensitivity and other scoping filters are honored.",
        "moot_lens_successors" => "Reasoning lens: suggest probable successor drawers via tunnel traversal.",
        "moot_lens_overlap" => "Reasoning lens: compute thematic overlap between two estates.",
        "moot_lens_divergence" => "Reasoning lens: measure topic divergence between two estates.",
        "moot_lens_associations" => "Recall a frame and mine pairwise association rules over drawer categorical facets, or mine rules over dataset column values when dataset_id is supplied.",
        "moot_lens_concepts" => "Analytics lens: mine formal concepts from the categorical feature matrix.",
        "moot_lens_apriori" => "Read the estate's audit log and mine multi-antecedent association rules via the Apriori algorithm.",
        "moot_lens_moment" => "Temporal lens: measure fingerprint-set similarity across a primary window and optional comparison windows.",
        "moot_lens_rhythm" => "Temporal lens: detect capture-rhythm patterns from fingerprint bit-series data.",
        "moot_lens_precedence" => "Temporal lens: discover temporal precedence (causal ordering) between drawers via audit event lag analysis.",
        "moot_lens_complexity" => "Reasoning lens: Shannon entropy (and optional mutual information) over a label field across the recalled set, or over a dataset column when dataset_id is supplied.",
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
        "moot_lens_node_motion" => object_schema(
            json!({
                "rowID": string_schema("UUID of the memory (drawer) to read motion for."),
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["rowID"]),
        ),
        "moot_lens_cohesion" => object_schema(
            json!({
                "threshold": number_schema("Z-score magnitude threshold (default 1.5). Estate mode only; ignored when dataset_id is present."),
                "filter": filter,
                "dataset_id": string_schema("Optional UUID of a dataset (from moot_file_dataset). When supplied, scores column-value anomalies instead of lexical outliers."),
                "top_n": integer_schema("Max anomaly rows to return in dataset mode (default 10). Ignored in estate mode."),
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!([]),
        ),
        "moot_lens_contradiction" => object_schema(
            json!({
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
                "targetKind": string_schema("Target outcome as a content kind: prose, code, transcript, list, structuredJSON, imageCaption, fingerprintOnly, dataset (dataset targeting arrives in MX-TAB-6 — passing it returns an error for now)."),
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
                "limit": integer_schema("Max drawers to recall (estate mode) or max rows to scan (dataset mode, default 1000, capped at 10000)."),
                "minSupport": number_schema("Minimum rule support (0..1). Default 0."),
                "minConfidence": number_schema("Minimum rule confidence (0..1). Default 0."),
                "dataset_id": string_schema("Optional UUID of a dataset (from moot_file_dataset). When supplied, mines rules over dataset column values instead of drawer facets."),
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
                "fieldA": string_schema("Label field for entropy. Estate mode: room, wing, addedBy, embeddingModelID. Dataset mode (dataset_id present): column name in the dataset."),
                "fieldB": string_schema("Optional second label field (or column) for mutual information."),
                "filter": filter,
                "dataset_id": string_schema("Optional UUID of a dataset (from moot_file_dataset). When supplied, fieldA/fieldB are column names; filter is ignored."),
                "estateID": estate_id,
                "teachme": teachme
            }),
            json!(["fieldA"]),
        ),
        _ => with_teachme(with_estate_id(object_schema(json!({}), json!([]))))
    }
}

// ---------------------------------------------------------------------------
// Dataset tools — moot_file_dataset, moot_dataset_query, moot_dataset_stats
// (MX-TAB-7b). Always present; not vault-gated. Schemas byte-identical to
// Swift DatasetTools.swift `tools()` projections. provenance: .interface.
// ---------------------------------------------------------------------------

/// `moot_file_dataset` — import a tabular dataset into the estate.
///
/// Schema mirrors Swift DatasetTools.tools()[0].inputSchema.
/// Uses with_teachme(with_estate_id(...)) matching the Rust interface-tool convention
/// (all non-vault Rust interface tools include teachme via this wrapper).
fn file_dataset_tool() -> serde_json::Value {
    json!({
        "name": "moot_file_dataset",
        "description": "Import a tabular dataset into the estate as a first-class handle. \
Provide columns (array of name+type pairs), either inline rows \
(array of objects) or a local csv_path, and a location for the \
handle. Column names must match [A-Za-z_][A-Za-z0-9_]*. \
Returns the dataset id and handle info. \
Use moot_dataset_query to read back rows.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "name": string_schema("Dataset name — stored as the handle's room label."),
                "columns": {
                    "type": "array",
                    "description": "Column schema pairs. Each element: {\"name\": \"[A-Za-z_][A-Za-z0-9_]*\", \"type\": \"text|int|float|bool\"}. Required when using inline rows; optional for csv_path (type inferred from values).",
                    "items": object_schema(
                        json!({
                            "name": string_schema("Column identifier: [A-Za-z_][A-Za-z0-9_]*"),
                            "type": string_schema("Column type: text, int, float, bool. Optional when csv_path is used (type inferred).")
                        }),
                        json!(["name"])
                    )
                },
                "rows": {
                    "type": "array",
                    "description": "Inline rows as JSON objects. Keys must be column names. Mutually exclusive with csv_path.",
                    "items": { "type": "object" }
                },
                "csv_path": string_schema("Absolute filesystem path to a CSV file to import. Path is canonicalized and must resolve to a regular file. Size cap: 100 MiB. Mutually exclusive with rows."),
                "location": string_schema("Room location for the dataset handle in the estate."),
                "wing": string_schema("Optional wing name. Omit for the default wing."),
                "sensitivity": string_schema("Optional sensitivity: normal (default), elevated, restricted, secret.")
            }),
            json!(["name", "location"])
        )))
    })
}

/// `moot_dataset_query` — predicate query over a dataset's rows.
///
/// Schema mirrors Swift DatasetTools.tools()[1].inputSchema.
fn dataset_query_tool() -> serde_json::Value {
    json!({
        "name": "moot_dataset_query",
        "description": "Query rows from a dataset. Refuses withdrawn handles. \
Supply the dataset id from moot_file_dataset. \
Predicates use JSON: {\"col\":\"name\",\"op\":\"eq|neq|lt|lte|gt|gte\",\"val\":value} \
or {\"and\":[...]} / {\"or\":[...]} for compound conditions. \
order_by: array of {\"col\":\"name\",\"dir\":\"asc|desc\"} objects. \
Returns rows plus handle metadata (belief state, sensitivity).",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "id": string_schema("Dataset UUID from moot_file_dataset."),
                "where": string_schema("Optional predicate JSON: {\"col\":\"name\",\"op\":\"eq\",\"val\":value} or {\"and\":[...]} / {\"or\":[...]}. Omit for full scan."),
                "order_by": {
                    "type": "array",
                    "description": "Optional sort order. Each element: {\"col\":\"name\",\"dir\":\"asc|desc\"}.",
                    "items": object_schema(
                        json!({
                            "col": string_schema("Column name."),
                            "dir": string_schema("Sort direction: asc or desc (default asc).")
                        }),
                        json!(["col"])
                    )
                },
                "limit": integer_schema("Maximum rows to return (default 100, max 1000)."),
                "columns": {
                    "type": "array",
                    "description": "Optional column projection. Array of column name strings to return. Omit for all columns.",
                    "items": { "type": "string" }
                }
            }),
            json!(["id"])
        )))
    })
}

/// `moot_dataset_stats` — per-column aggregate statistics.
///
/// Schema mirrors Swift DatasetTools.tools()[2].inputSchema.
fn dataset_stats_tool() -> serde_json::Value {
    json!({
        "name": "moot_dataset_stats",
        "description": "Return per-column aggregate statistics for a dataset. Refuses withdrawn handles. \
Supply the dataset id from moot_file_dataset. Omit column to get stats for all \
columns. Float values use f64 shortest-roundtrip format.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "id": string_schema("Dataset UUID from moot_file_dataset."),
                "column": string_schema("Optional column name. Omit for stats on all columns.")
            }),
            json!(["id"])
        )))
    })
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

// moot_vault_import — like `vault_tool` but with the encode-SPEED `mode` arg
// (T7 parity with the Swift vault tool). Write strategy is size-gated
// automatically (import_policy); `mode` chooses only the drain QoS.
fn vault_import_tool() -> serde_json::Value {
    json!({
        "name": "moot_vault_import",
        "description": "Import a Markdown vault into a MOOT estate via the capture seam. Returns a job_id immediately — the import runs in the background and takes approximately 2 seconds per document. A 100-note vault takes ~3 minutes; a 500-note vault takes ~17 minutes. Do NOT cancel or re-issue an import because it appears slow — it is working. Poll with moot_vault_job to check progress. Duplicate imports are idempotent but waste time.",
        "inputSchema": with_teachme(with_estate_id(object_schema(
            json!({
                "vaultPath": string_schema("Filesystem path to the vault directory."),
                "mode": string_schema("Optional encode SPEED for the background encoding that follows the import: \"foreground\" (default) drains the encode queue hard; \"background\" yields for very large vaults. SPEED only — the write strategy (bulk transaction vs per-item stream) is chosen automatically by source size, not by this argument. Omit to use the default (foreground).")
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
    string_schema("Filter kind: unconfirmed, userConfirmed, exportable, contained, currentlyBelieve. Omit for ordinary recall: active/trustworthy/elevated-or-lower memories across any confirmation state. null is invalid.")
}

fn estate_id_schema() -> serde_json::Value {
    string_schema("Optional UUID of the open estate to target. Omit for the default estate; null is invalid.")
}

fn teachme_schema() -> serde_json::Value {
    boolean_schema("Set true to receive a usage guide for this tool without touching the estate.")
}

// ---------------------------------------------------------------------------
// Accepted-argument-key extraction (Part A — unknown-arg hint)
// ---------------------------------------------------------------------------

/// Return the set of argument keys declared in a tool's inputSchema, given
/// vault and memory-tool flags. Returns `None` when the tool name is unknown
/// (dispatch will handle it with a methodNotFound error before the hint runs).
///
/// Keys are extracted from the live tool schema (post-`with_estate_id` /
/// `with_teachme` wrappers), so `estateID` and `teachme` are always included
/// when the tool carries them. Vault tools only appear in the list when
/// `vault_on` is true, matching the dispatch gate.
///
/// Mirrors Swift `ToolProjection.acceptedArgKeys(for:)`.
pub fn accepted_arg_keys_with_flags(
    name: &str,
    vault_on: bool,
    memory_on: bool,
) -> Option<std::collections::HashSet<String>> {
    let tools_list = build_tool_list_with_flags(vault_on, memory_on);
    let tools_array = match &tools_list {
        serde_json::Value::Array(arr) => arr,
        _ => return None,
    };
    let tool = tools_array.iter().find(|t| t["name"].as_str() == Some(name))?;
    let properties = tool["inputSchema"]["properties"].as_object()?;
    Some(properties.keys().cloned().collect())
}

/// Return the set of argument keys for a tool using the current process
/// environment (same env-var logic as `build_tool_list`). Returns `None`
/// when the tool name is unknown.
///
/// Convenience wrapper over `accepted_arg_keys_with_flags` for the dispatch
/// hot-path — mirrors Swift `ToolProjection.acceptedArgKeys(for:)`.
pub fn accepted_arg_keys(name: &str) -> Option<std::collections::HashSet<String>> {
    accepted_arg_keys_with_flags(name, vault_enabled(), memory_enabled())
}
