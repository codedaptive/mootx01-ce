//! Interface tool surface — Tier 1–5 of the 5-tier AI-client interface.
//!
//! Mirrors Swift `ToolDispatch.swift` for the 19 Tier 1–5 tools:
//!   Tier 1 — Core memory (7): moot_file_memory, moot_memory_search,
//!             moot_update_memory, moot_withdraw_memory, moot_erase_memory,
//!             moot_confirm_memory, moot_move_memory
//!   Tier 2 — Connections (3): moot_link_memories, moot_connection_search,
//!             moot_connection_map
//!   Tier 3 — Knowledge graph (4): moot_file_fact, moot_fact_search,
//!             moot_retire_fact, moot_fact_timeline
//!   Tier 4 — Journal (2): moot_write_journal, moot_read_journal
//!   Tier 5 — Estate (3): moot_estate_status, moot_estate_map, moot_estate_ping
//!
//! # GLK write-path runners
//!
//! `moot_file_fact`, `moot_retire_fact`, and `moot_write_journal` call
//! `coordinator.add_kg_fact`, `coordinator.withdraw_kg_fact`, and
//! `coordinator.add_diary_entry` respectively. These methods landed via the
//! GLK Rust write-path mission, so the runners now perform real writes.
//!
//! # Server defaults (mirrors Swift `ToolDispatch.swift` constants)
//!
//! - `channel` = `CaptureChannel::ImportedFile`
//! - `added_by` = `"aria-mcp-server"`
//! - `lattice_anchor` = `LatticeAnchor::udc("000.000")`
//! - `embedding_model_id` = `"default"`

use std::collections::BTreeMap;

use locus_kit::{
    estate_types::LatticeAnchor,
    filter::{Filter, RecallFrame},
    frames::{CaptureFrame, MutationKind, TunnelCaptureFrame},
    tunnel_operational::TunnelKind,
    drawer_operational::CaptureChannel,
};

use crate::dispatch::{error_result, require_string, text_result, wall_now};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};
use crate::session_protocol::ARIA_SESSION_PROTOCOL;

// ---------------------------------------------------------------------------
// Server defaults — mirrors Swift ToolDispatch.swift constants
// ---------------------------------------------------------------------------

const SERVER_ADDED_BY: &str = "aria-mcp-server";
const DEFAULT_EMBEDDING_MODEL: &str = "default";
const DEFAULT_LATTICE_CODE: &str = "000.000";

// ---------------------------------------------------------------------------
// Tool surface declaration
// ---------------------------------------------------------------------------

/// The 19 interface tool names (Tier 1–5), in the order they appear in the
/// tool list. Mirrors Swift `InterfaceTools` enum case order.
pub const INTERFACE_TOOLS: &[&str] = &[
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
];

/// True when `name` is one of the 19 Tier 1–5 interface tools.
pub fn is_interface_tool(name: &str) -> bool {
    INTERFACE_TOOLS.contains(&name)
}

/// Dispatch a Tier 1–5 interface tool call. Returns the MCP `tools/call`
/// result payload. Throws `JSONRPCError` for out-of-band failures (bad estate,
/// missing required arg). Substrate refusals surface as `error_result`.
pub fn dispatch(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    match name {
        "moot_file_memory" => run_file_memory(args, registry),
        "moot_memory_search" => run_memory_search(args, registry),
        "moot_update_memory" => run_update_memory(args, registry),
        "moot_withdraw_memory" => run_withdraw_memory(args, registry),
        "moot_erase_memory" => run_erase_memory(args, registry),
        "moot_confirm_memory" => run_confirm_memory(args, registry),
        "moot_move_memory" => run_move_memory(args, registry),
        "moot_link_memories" => run_link_memories(args, registry),
        "moot_connection_search" => run_connection_search(args, registry),
        "moot_connection_map" => run_connection_map(args, registry),
        "moot_file_fact" => run_file_fact(args, registry),
        "moot_fact_search" => run_fact_search(args, registry),
        "moot_retire_fact" => run_retire_fact(args, registry),
        "moot_fact_timeline" => run_fact_timeline(args, registry),
        "moot_write_journal" => run_write_journal(args, registry),
        "moot_read_journal" => run_read_journal(args, registry),
        "moot_estate_status" => run_estate_status(args, registry),
        "moot_estate_map" => run_estate_map(args, registry),
        "moot_estate_ping" => run_estate_ping(args, registry),
        _ => Err(JSONRPCError::new(
            JSONRPCErrorCode::METHOD_NOT_FOUND,
            format!("Unknown interface tool: {name}"),
        )),
    }
}

// ===========================================================================
// Tier 1 — Core memory
// ===========================================================================

/// File a memory into the estate. Requires `content` and `location`.
///
/// `location` maps to `room`; wing is derived by the estate from its manifest
/// owner identifier. Server owns infrastructure fields (channel, lattice,
/// added_by, embeddingModelID). Mirrors Swift `runFileMemory`.
fn run_file_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let content = require_string(args, "content")?;
    let location = require_string(args, "location")?;

    let frame = CaptureFrame::new(
        content,
        CaptureChannel::ImportedFile,
        location,
        LatticeAnchor::udc(DEFAULT_LATTICE_CODE),
        SERVER_ADDED_BY,
        DEFAULT_EMBEDDING_MODEL,
    );

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();
    match coord.capture(&estate.handle, frame, now) {
        Ok(drawer) => {
            let body = format!(
                "filed memory {}\nroom: {}\nlineage: {}",
                drawer.id, drawer.room, drawer.lineage_id
            );
            Ok(text_result(&body))
        }
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Search memories in the estate using hybrid BM25+vector scored recall.
///
/// Requires `query`. Optional `scoring` (raw/rrf/matrixAware, default
/// "matrixAware") and `limit` (default 20). Decodes the scoring argument
/// and routes through `recall_scored` with mode=unionBest, matching
/// Swift `runMemorySearch` which also uses unionBest+matrixAware defaults.
///
/// Previously used plain `recall` + substring filter. Now uses `recall_scored`
/// with a `GLKRecallRequest`, so ranked and BM25/vector-scored results are
/// returned when CorpusKit/VectorKit stores are registered for the estate.
fn run_memory_search(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    use genius_locus_kit::recall::{
        GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy,
    };

    let estate = registry.resolve(args, "estateID")?;
    let query = require_string(args, "query")?;

    // Decode optional `scoring` argument. Defaults to matrixAware to match Swift.
    let scoring_str = args
        .get("scoring")
        .and_then(|v| v.as_str())
        .unwrap_or("matrixAware");
    let scoring = match scoring_str {
        "raw"         => GLKRecallScoring::Raw,
        "rrf"         => GLKRecallScoring::Rrf,
        "matrixAware" => GLKRecallScoring::MatrixAware,
        _             => GLKRecallScoring::MatrixAware, // safe fallback
    };

    // Decode optional `limit` argument. Defaults to 20.
    let limit = args
        .get("limit")
        .and_then(|v| v.as_i64())
        .map(|n| n.max(1) as usize)
        .unwrap_or(20_usize);

    // Decode optional `filter` for the recall frame; default to Unconfirmed.
    let frame = RecallFrame::new(vec![Filter::Unconfirmed]);

    let request = GLKRecallRequest::new(frame)
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(scoring)
        .with_limit(limit)
        .with_fallback(RecallFallbackPolicy::AllowDegraded)
        .with_query_text(query.to_string());

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    let result = coord
        .recall_scored(&estate.handle, request, now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;

    let mut lines = vec![format!("found {} memory(s)", result.hits.len())];
    for hit in result.hits.iter().take(50) {
        let preview: String = hit
            .drawer
            .as_ref()
            .map(|d| d.content.chars().take(120).collect())
            .unwrap_or_else(|| "(not hydrated)".to_string());
        let room = hit.drawer.as_ref().map(|d| d.room.as_str()).unwrap_or("");
        lines.push(format!(
            "{}  [{}]  {}  (score: {:.4})",
            hit.id, room, preview, hit.score.final_score
        ));
    }
    Ok(text_result(&lines.join("\n")))
}

/// Apply a named mutation to a memory. Requires `id` and `mutation`.
///
/// Mutation strings: confirm, reject, contest, resolve, supersede, revive,
/// accept. Mirrors Swift `runUpdateMemory`.
fn run_update_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let id = require_string(args, "id")?;
    let mutation_str = require_string(args, "mutation")?;

    let kind = decode_mutation_kind(mutation_str)?;
    let coord = estate.coord.lock().unwrap();
    match coord.mutate(&estate.handle, id, kind, None) {
        Ok(()) => Ok(text_result(&format!("updated memory {id} ({mutation_str})"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Withdraw a memory (soft-delete). Requires `id`. Optional `reason`.
///
/// Mirrors Swift `runWithdrawMemory`.
fn run_withdraw_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let id = require_string(args, "id")?;
    let reason = args.get("reason").and_then(|v| v.as_str());

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();
    match coord.withdraw(&estate.handle, id, reason, now) {
        Ok(()) => Ok(text_result(&format!("withdrew memory {id}"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Permanently erase a memory. Requires `id`, `reason`, and `confirmed: true`.
///
/// Mirrors Swift `runEraseMemory`.
fn run_erase_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let id = require_string(args, "id")?;
    let reason = require_string(args, "reason")?;
    let confirmed = args
        .get("confirmed")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    if !confirmed {
        return Ok(error_result(
            "erase_memory requires confirmed: true — this action is irreversible",
        ));
    }

    let coord = estate.coord.lock().unwrap();
    match coord.expunge(&estate.handle, id, reason, confirmed) {
        Ok(()) => Ok(text_result(&format!("erased memory {id}"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Confirm a memory (promote to UserConfirmed). Requires `id`.
///
/// Mirrors Swift `runConfirmMemory`.
fn run_confirm_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let id = require_string(args, "id")?;

    let coord = estate.coord.lock().unwrap();
    match coord.mutate(&estate.handle, id, MutationKind::Confirm, None) {
        Ok(()) => Ok(text_result(&format!("confirmed memory {id}"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Move a memory to a different room. Requires `id` and `location`.
///
/// `location` maps to the new `room`. Mirrors Swift `runMoveMemory`.
fn run_move_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let id = require_string(args, "id")?;
    let location = require_string(args, "location")?;

    let coord = estate.coord.lock().unwrap();
    match coord.reanchor(&estate.handle, id, Some(location), None) {
        Ok(()) => Ok(text_result(&format!("moved memory {id} to {location}"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

// ===========================================================================
// Tier 2 — Connections
// ===========================================================================

/// Link two memories with a typed tunnel. Requires `from_id`, `to_id`, `kind`.
///
/// Looks up both drawers by ID to resolve their wing/room coordinates, then
/// calls `estate.capture_tunnel`. Mirrors Swift `runLinkMemories`.
fn run_link_memories(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let from_id = require_string(args, "from_id")?;
    let to_id = require_string(args, "to_id")?;
    let kind_str = require_string(args, "kind")?;

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    // Recall all drawers to resolve wing+room for source and target.
    let all = coord
        .recall(&estate.handle, RecallFrame::new(vec![Filter::Unconfirmed]), now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;

    let source = all.iter().find(|d| d.id == from_id).ok_or_else(|| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("from_id not found: {from_id}"),
        )
    })?;
    let target = all.iter().find(|d| d.id == to_id).ok_or_else(|| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("to_id not found: {to_id}"),
        )
    })?;

    let tunnel_kind = decode_tunnel_kind(kind_str);
    let mut frame = TunnelCaptureFrame::new(
        source.wing.clone(),
        source.room.clone(),
        target.wing.clone(),
        target.room.clone(),
        kind_str,
        SERVER_ADDED_BY,
    );
    frame.source_drawer_id = Some(from_id.to_string());
    frame.target_drawer_id = Some(to_id.to_string());
    frame.kind = tunnel_kind;

    // Access the estate directly for tunnel capture (not via coordinator, which
    // has no capture_tunnel wrapper — the estate_verbs surface exposes it).
    let locus_estate = coord.estate_for(&estate.handle).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}"))
    })?;

    match locus_estate.capture_tunnel(frame, now) {
        Ok(tunnel) => {
            let body = format!(
                "linked {from_id} → {to_id} via {kind_str} ({})",
                tunnel.id
            );
            Ok(text_result(&body))
        }
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// List outgoing connections from a memory. Requires `from_id`.
///
/// Recalls the source drawer to resolve its wing, then reads tunnels from
/// that wing filtered by `source_drawer_id`. Mirrors Swift `runConnectionSearch`.
fn run_connection_search(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let from_id = require_string(args, "from_id")?;

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    // Recall all drawers to find the source drawer's wing.
    let all = coord
        .recall(&estate.handle, RecallFrame::new(vec![Filter::Unconfirmed]), now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;

    let source = all.iter().find(|d| d.id == from_id).ok_or_else(|| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("from_id not found: {from_id}"),
        )
    })?;
    let wing = source.wing.clone();

    let tunnels = coord
        .recall_tunnels(&estate.handle, &wing)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;

    let outgoing: Vec<_> = tunnels
        .iter()
        .filter(|t| t.source_drawer_id.as_deref() == Some(from_id))
        .collect();

    let mut lines = vec![format!("connections from {from_id}: {}", outgoing.len())];
    for t in &outgoing {
        let target = t.target_drawer_id.as_deref().unwrap_or(&t.target_room);
        lines.push(format!("  {} [{}] → {}", t.id, t.label, target));
    }
    Ok(text_result(&lines.join("\n")))
}

/// List incoming connections to a memory. Requires `to_id`.
///
/// Scans tunnels across all wings (derived from recalling all drawers) and
/// filters by `target_drawer_id`. Mirrors Swift `runConnectionMap`.
fn run_connection_map(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let to_id = require_string(args, "to_id")?;

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    // Recall all drawers to discover all wings in the estate.
    let all = coord
        .recall(&estate.handle, RecallFrame::new(vec![Filter::Unconfirmed]), now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;

    let wings: std::collections::HashSet<&str> =
        all.iter().map(|d| d.wing.as_str()).collect();

    // Scan every wing's tunnels for incoming edges to to_id.
    let mut incoming = Vec::new();
    for wing in &wings {
        let tunnels = coord
            .recall_tunnels(&estate.handle, wing)
            .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;
        for t in tunnels {
            if t.target_drawer_id.as_deref() == Some(to_id) {
                incoming.push(t);
            }
        }
    }

    let mut lines = vec![format!("connections to {to_id}: {}", incoming.len())];
    for t in &incoming {
        let src = t.source_drawer_id.as_deref().unwrap_or(&t.source_room);
        lines.push(format!("  {} [{}] ← {}", t.id, t.label, src));
    }
    Ok(text_result(&lines.join("\n")))
}

// ===========================================================================
// Tier 3 — Knowledge graph
// ===========================================================================

/// File a knowledge-graph fact. Requires `subject`, `predicate`, `object`.
///
/// Optional `source_id` (default `""`) records the originating drawer. Calls
/// `coordinator.add_kg_fact`. Mirrors Swift `runFileFact`.
fn run_file_fact(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let subject = require_string(args, "subject")?;
    let predicate = require_string(args, "predicate")?;
    let object = require_string(args, "object")?;
    let source_id = args.get("source_id").and_then(|v| v.as_str()).unwrap_or("");

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();
    match coord.add_kg_fact(&estate.handle, subject, predicate, object, source_id, now) {
        Ok(fact) => Ok(text_result(&format!(
            "filed fact {}: [{subject}] {predicate} [{object}]",
            fact.id
        ))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Search knowledge-graph facts. Optional `query` for substring filtering.
///
/// Reads all facts via `coordinator.recall_kg_facts` and filters in-memory.
/// Mirrors Swift `runFactSearch`.
fn run_fact_search(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let query = args.get("query").and_then(|v| v.as_str());

    let coord = estate.coord.lock().unwrap();
    let facts = coord
        .recall_kg_facts(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;

    let matches: Vec<_> = facts
        .iter()
        .filter(|f| {
            if let Some(q) = query {
                f.subject.contains(q) || f.predicate.contains(q) || f.object.contains(q)
            } else {
                true
            }
        })
        .collect();

    let header = if let Some(q) = query {
        format!("facts matching \"{q}\": {}", matches.len())
    } else {
        format!("facts: {}", matches.len())
    };

    let mut lines = vec![header];
    for f in &matches {
        lines.push(format!("  {} — [{}] {} [{}]", f.id, f.subject, f.predicate, f.object));
    }
    Ok(text_result(&lines.join("\n")))
}

/// Retire a knowledge-graph fact. Requires `id`.
///
/// Transitions the fact to `Withdrawn` via `coordinator.withdraw_kg_fact`.
/// Mirrors Swift `runRetireFact`.
fn run_retire_fact(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let id = require_string(args, "id")?;

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();
    match coord.withdraw_kg_fact(&estate.handle, id, now) {
        Ok(()) => Ok(text_result(&format!("retired fact {id}"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Read KG facts in chronological order. Optional `entity` filter.
///
/// Mirrors Swift `runFactTimeline`.
fn run_fact_timeline(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let entity = args.get("entity").and_then(|v| v.as_str());

    let coord = estate.coord.lock().unwrap();
    let mut facts = coord
        .recall_kg_facts(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;

    if let Some(e) = entity {
        facts.retain(|f| f.subject.contains(e) || f.object.contains(e));
    }

    // Sort ascending by filed_at (epoch seconds).
    facts.sort_by_key(|f| f.filed_at);

    let header = if let Some(e) = entity {
        format!("fact timeline for \"{e}\": {}", facts.len())
    } else {
        format!("fact timeline: {}", facts.len())
    };

    let mut lines = vec![header];
    for f in &facts {
        lines.push(format!(
            "  {} | [{}] {} [{}]",
            f.filed_at, f.subject, f.predicate, f.object
        ));
    }
    Ok(text_result(&lines.join("\n")))
}

// ===========================================================================
// Tier 4 — Journal
// ===========================================================================

/// Write a journal entry. Requires `entry`. Optional `agent` (default "mcp-agent").
///
/// Calls `coordinator.add_diary_entry`. Mirrors Swift `runWriteJournal`.
fn run_write_journal(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let entry = require_string(args, "entry")?;
    let agent = args
        .get("agent")
        .and_then(|v| v.as_str())
        .unwrap_or("mcp-agent");

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();
    match coord.add_diary_entry(
        &estate.handle,
        agent,
        entry,
        "mcp-session",
        DEFAULT_EMBEDDING_MODEL,
        now,
    ) {
        Ok(_) => Ok(text_result(&format!("wrote journal entry for {agent}"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Read journal entries. Optional `agent` (default "mcp-agent") and `last_n` (default 10).
///
/// Reads all diary entries via `coordinator.recall_diary_entries`, filters by
/// agent_name if specified, returns the most-recent `last_n`. Mirrors Swift
/// `runReadJournal`.
fn run_read_journal(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let agent = args
        .get("agent")
        .and_then(|v| v.as_str())
        .unwrap_or("mcp-agent");
    let last_n = args
        .get("last_n")
        .and_then(|v| v.as_i64())
        .map(|n| n as usize)
        .unwrap_or(10);

    let coord = estate.coord.lock().unwrap();
    let mut entries = coord
        .recall_diary_entries(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;

    entries.retain(|e| e.agent_name == agent);
    // Sort by filed_at descending so most-recent entries come first.
    entries.sort_by(|a, b| b.filed_at.cmp(&a.filed_at));
    entries.truncate(last_n);

    let mut lines = vec![format!("journal for {agent}: {} entry(s)", entries.len())];
    for e in &entries {
        let preview: String = e.entry.chars().take(80).collect();
        lines.push(format!("  {} | {}", e.filed_at, preview));
    }
    Ok(text_result(&lines.join("\n")))
}

// ===========================================================================
// Tier 5 — Estate
// ===========================================================================

/// Return estate statistics. Appends the ARIA session protocol block.
///
/// Counts active drawers, KG facts, and wings. Mirrors Swift `runEstateStatus`.
fn run_estate_status(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    let drawers = coord
        .recall(&estate.handle, RecallFrame::new(vec![Filter::Unconfirmed]), now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;

    let kg_facts = coord
        .recall_kg_facts(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;

    let wings: std::collections::BTreeSet<&str> =
        drawers.iter().map(|d| d.wing.as_str()).collect();

    let estate_info = coord.estate_for(&estate.handle).ok();
    let (estate_name, estate_uuid) = estate_info
        .and_then(|e| e.manifest().ok())
        .map(|m| (m.estate_name, m.estate_uuid))
        .unwrap_or_else(|| ("unknown".to_string(), "unknown".to_string()));

    let wings_list = wings.iter().cloned().collect::<Vec<_>>().join(", ");
    let body = format!(
        "estate: {estate_name} [{estate_uuid}]\ndrawers: {}\nkg_facts: {}\nwings: {}\n{}",
        drawers.len(),
        kg_facts.len(),
        wings_list,
        ARIA_SESSION_PROTOCOL
    );
    Ok(text_result(&body))
}

/// Return the estate's memory taxonomy as a tree grouped by wing and room.
///
/// Mirrors Swift `runEstateMap`.
fn run_estate_map(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    let drawers = coord
        .recall(&estate.handle, RecallFrame::new(vec![Filter::Unconfirmed]), now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}")))?;

    // Group by wing then room.
    let mut tree: std::collections::BTreeMap<&str, std::collections::BTreeMap<&str, usize>> =
        std::collections::BTreeMap::new();
    for d in &drawers {
        *tree
            .entry(d.wing.as_str())
            .or_default()
            .entry(d.room.as_str())
            .or_insert(0) += 1;
    }

    let mut lines = vec![format!("estate map: {} drawer(s)", drawers.len())];
    for (wing, rooms) in &tree {
        lines.push(format!("  {wing}/"));
        for (room, count) in rooms {
            lines.push(format!("    {room}: {count}"));
        }
    }
    Ok(text_result(&lines.join("\n")))
}

/// Verify the estate is reachable. Returns a pong with estate name and UUID.
///
/// Mirrors Swift `runEstatePing`.
fn run_estate_ping(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let coord = estate.coord.lock().unwrap();

    let locus_estate = coord.estate_for(&estate.handle).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}"))
    })?;

    let manifest = locus_estate.manifest().map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}"))
    })?;

    Ok(text_result(&format!(
        "pong: estate {} [{}] is live",
        manifest.estate_name, manifest.estate_uuid
    )))
}

// ===========================================================================
// Argument decoders
// ===========================================================================

/// Map a mutation string to `MutationKind`. Returns `Err(invalidParams)` for
/// unknown strings. Mirrors Swift `ToolDispatch.decodeMutation(_:)`.
fn decode_mutation_kind(s: &str) -> Result<MutationKind, JSONRPCError> {
    match s {
        "confirm" => Ok(MutationKind::Confirm),
        "reject" => Ok(MutationKind::Reject),
        "contest" => Ok(MutationKind::Contest),
        "resolve" => Ok(MutationKind::Resolve),
        "supersede" => Ok(MutationKind::Supersede),
        "revive" => Ok(MutationKind::Revive),
        "accept" => Ok(MutationKind::Accept),
        _ => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown mutation: {s}. Valid: confirm, reject, contest, resolve, supersede, revive, accept"),
        )),
    }
}

/// Map a kind string to `TunnelKind`, defaulting to `References`.
/// Mirrors Swift `ToolDispatch.decodeTunnelKind(_:)`.
fn decode_tunnel_kind(s: &str) -> TunnelKind {
    match s {
        "supersedes" => TunnelKind::Supersedes,
        "references" => TunnelKind::References,
        "blocks" => TunnelKind::Blocks,
        "validates" => TunnelKind::Validates,
        "contradicts" => TunnelKind::Contradicts,
        "derivesFrom" => TunnelKind::DerivesFrom,
        "covers" => TunnelKind::Covers,
        "elaborates" => TunnelKind::Elaborates,
        "respondsTo" => TunnelKind::RespondsTo,
        _ => TunnelKind::References,
    }
}
