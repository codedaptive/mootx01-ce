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
//! - `channel` = `CaptureChannel::Actuator` (cookbook §2.4: actuator-driven capture)
//! - `added_by` = `registry.server_identity` (injected at runtime startup — "aria-mcp" or "mootx01")
//! - `lattice_anchor` = `LatticeAnchor::udc("000")` (the unclassified sentinel)
//!   for all capture paths. The GeniusLocusKit seam (`capture_with_mode`)
//!   classifies the sentinel via `Fdc::encode_anchor` on the way in — one
//!   classification door for `moot_file_memory`, vault import, and branch
//!   promotion (one-door principle). UNRESOLVED content keeps the "000" sentinel.
//! - `embedding_model_id` = `"default"` (selects the 1.0 default recall
//!   ensemble — the five honest signals RI/PPMI/LSA/NMF/FDC fused in Lane D,
//!   trained on-corpus and reproducible cross-port; NOT a learned model-weight
//!   embedding)

use std::collections::BTreeMap;

use uuid::Uuid;

use locus_kit::{
    adjectives::{AdjectiveExportability, AdjectiveSensitivity},
    default_wings::{CHARTER_ROOM, DEFAULT_WING_NAME},
    estate_types::LatticeAnchor,
    filter::RecallFrame,
    frames::{CaptureFrame, MutationKind, TunnelCaptureFrame},
    tunnel_operational::TunnelKind,
    drawer_operational::{CaptureChannel, ContentKind},
    provenance::Channel,
};

use genius_locus_kit::{VerbDispatchError, VerbError, WriteMode};

use substrate_types::{RowState, RowStateCluster};

use crate::dispatch::{
    decode_filter_chain, error_result, optional_bool, optional_integer, optional_string,
    require_string, text_result, wall_now,
};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};
use crate::session_protocol::ARIA_SESSION_PROTOCOL;
use crate::surfaced_recall_ledger::SurfacedRecallLedger;

// ---------------------------------------------------------------------------
// Server defaults — mirrors Swift ToolDispatch.swift constants
// ---------------------------------------------------------------------------

// NOTE: SERVER_ADDED_BY has been removed. The host identity is now carried in
// `EstateRegistry::server_identity`, injected at runtime startup so the shared
// dispatcher correctly stamps provenance for whichever binary is hosting it
// ("aria-mcp" or "mootx01"). Mirrors Swift `ToolDispatcher.serverIdentity`.
const DEFAULT_EMBEDDING_MODEL: &str = "default";
/// The canonical unclassified-content sentinel passed to the capture seam.
/// Matches `GeniusLocusKit::UNCLASSIFIED_SENTINEL` and the Swift
/// `GeniusLocusKit.unclassifiedSentinel`. The seam classifies the content
/// when it sees this sentinel (one-door principle). Previously "000.000"
/// (a child node); corrected to "000" (the UDC root, per the LatticeLib
/// Code grammar — the three-digit root is the correct unresolved sentinel).
const DEFAULT_LATTICE_CODE: &str = "000";

// ---------------------------------------------------------------------------
// Tool surface declaration
// ---------------------------------------------------------------------------

/// The 19 interface tool names (Tier 1–5) plus the 1 Maintenance tool, in the
/// order they appear in the tool list. Mirrors Swift `InterfaceTools` enum case
/// order (19 tools) plus `moot_reindex` (Maintenance, 1 tool).
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
    // Maintenance (1)
    "moot_reindex",
];

/// True when `name` is one of the 19 Tier 1–5 interface tools.
pub fn is_interface_tool(name: &str) -> bool {
    INTERFACE_TOOLS.contains(&name)
}

// ---------------------------------------------------------------------------
// Error formatting — verb dispatch errors
// ---------------------------------------------------------------------------

/// Produce a user-facing string for a `VerbDispatchError` at the ARIA boundary.
///
/// For illegal-state-transition gate rejections, returns an actionable message
/// from the per-state/verb message table below (parity with Swift
/// `ToolDispatch.describeGateRejection`). For all other errors, returns the
/// English `{verb} failed: {reason}` form already used by the Swift `describe`
/// overload. No internal Rust type names (BasisViolation, IllegalTransition,
/// UnderlyingEstateFailure) appear in the output.
///
/// Called from every `Err(e) => Ok(error_result(...))` site in this module
/// that handles a `VerbDispatchError`. Sites that return `JSONRPCError` for
/// infrastructure failures (missing estate, bad JSON) are out-of-band and not
/// routed here.
pub(crate) fn describe_verb_dispatch_error(e: &VerbDispatchError) -> String {
    match e {
        VerbDispatchError::EstateNotOpen { estate_uuid } => {
            // estate_uuid is [u8; 16] — format via Uuid::from_bytes to produce a
            // canonical UUID string instead of a raw byte-array debug dump.
            format!("the addressed estate ({}) is not open; open it before issuing verbs",
                Uuid::from_bytes(*estate_uuid))
        }
        VerbDispatchError::Verb(ve) => describe_verb_error(ve),
    }
}

/// Produce a user-facing string for a `VerbError`.
///
/// For `UnderlyingEstateFailure` whose reason encodes an illegal state
/// transition, emits an actionable message from the table.  All other
/// variants fall through to their existing textual descriptions. Parity
/// with Swift `ToolDispatch.describe(_: VerbError)`.
fn describe_verb_error(ve: &VerbError) -> String {
    match ve {
        VerbError::UnderlyingEstateFailure { verb, reason } => {
            // Detect illegal-state-transition gate rejections embedded in the
            // InvalidContent message. The reason looks like:
            //   "InvalidContent: state mutation rejected by gate: illegal state transition: <state> --<verb>-->"
            // Parse out the "<state>" and "<verb>" to look up the clean message.
            if let Some(msg) = describe_gate_rejection(verb, reason) {
                return msg;
            }
            // Strip internal Rust type-name prefixes (e.g. "InvalidContent: room
            // must not be empty") that the substrate error chain can prepend.
            // These are implementation-private names that must not appear in
            // AI-client-facing messages (B-6 describe-helper contract).
            // Parity with Swift ToolDispatcher.stripEnumPrefix(from:).
            let cleaned = strip_enum_prefix(reason);
            format!("{verb} failed: {cleaned}")
        }
        VerbError::NotSupportedByEstate { verb } => {
            format!("verb '{verb}' is not callable on this estate: the estate refused the operation")
        }
        VerbError::RejectedByLexicon { verb, noun } => {
            format!("verb '{verb}' is not accepted on noun '{noun}' by the AriaLexicon acceptance matrix")
        }
        VerbError::EmptyReanchor { row_id } => {
            // row_id is String — use Display ({}) not Debug ({:?}) to omit the Debug quotes.
            format!("reanchor of row {row_id} requires at least one of toRoom or toUDC")
        }
        VerbError::ExpungeNotConfirmed { row_id } => {
            // The caller-facing field is "confirmed" — name it exactly so AI consumers
            // can retry with the correct argument rather than dead-ending on a
            // field name mismatch between this message and the tool schema.
            format!("expunge of row {row_id} requires confirmed=true")
        }
        VerbError::CrossKitVectorDeleteFailed { row_id, reason } => {
            format!(
                "expunge of row {row_id} is incomplete: the LocusKit content was removed but \
                 the vector embedding survived ({reason}). Retry the expunge — do not report \
                 this row as deleted."
            )
        }
    }
}

/// Map an illegal-state-transition gate rejection to an actionable English
/// message, or return `None` if the reason does not encode a gate rejection.
///
/// Parses the state and verb names out of the message text produced by
/// `GateViolation::Display` → `RowStateError::Display`. The canonical pattern
/// is "illegal state transition: <state> --<verb>-->".  The function is
/// conservative: if parsing fails for any reason it returns `None` so the
/// caller falls through to the generic "{verb} failed: {reason}" form. No
/// panic, no unwrap.
///
/// **Message table** — parity with Swift `ToolDispatch.describeGateRejection`:
/// ```text
/// active  + reject          → "cannot reject an active memory; contest or withdraw it first"
/// active  + promote/accept  → "only pending memories can be accepted; this memory is already active"
/// accepted + reject/contest → "accepted memories are audit-grade and cannot be rejected or
///                               contested; supersede or withdraw instead"
/// rejected + reject         → "memory is already rejected"
/// rejected + *              → "rejected memories cannot be mutated this way; re-file the content
///                               to start a new memory"
/// pending  + supersede      → "cannot supersede a pending memory; confirm or reject it first"
/// tombstoned + *            → "memory has been permanently erased and cannot be mutated"
/// *        + *              → "the memory's current state (<state>) does not allow this mutation;
///                               check it with moot_memory_search"
/// ```
/// Each message is prefixed with the caller-supplied verb, e.g. "update failed: …", to
/// be consistent with the existing describe format.
fn describe_gate_rejection(verb: &str, reason: &str) -> Option<String> {
    // The sentinel substring produced by GateViolation::Display on a BasisViolation
    // wrapping a RowStateError::IllegalTransition.
    const SENTINEL: &str = "illegal state transition: ";
    let start = reason.find(SENTINEL)?;
    let tail = &reason[start + SENTINEL.len()..];
    // Parse "<state> --<verb>-->" out of tail.
    let dash_pos = tail.find(" --")?;
    let from_str = tail[..dash_pos].trim();
    let after_dash = &tail[dash_pos + 3..];
    let end_pos = after_dash.find("-->")?;
    let gate_verb = after_dash[..end_pos].trim();

    // Map (from_state_name, gate_verb_name) to a clean actionable message.
    // The English state/verb names come from Display impls on RowState / RowVerb.
    let body = match (from_str, gate_verb) {
        ("active", "reject") =>
            "cannot reject an active memory; contest or withdraw it first".to_string(),
        ("active", "promote") | ("active", "accept") =>
            "only pending memories can be accepted; this memory is already active".to_string(),
        ("accepted", "reject") | ("accepted", "contest") =>
            "accepted memories are audit-grade and cannot be rejected or contested; \
             supersede or withdraw instead".to_string(),
        ("rejected", "reject") =>
            "memory is already rejected".to_string(),
        ("rejected", _) =>
            "rejected memories cannot be mutated this way; re-file the content to start \
             a new memory".to_string(),
        ("pending", "supersede") =>
            "cannot supersede a pending memory; confirm or reject it first".to_string(),
        ("tombstoned", _) =>
            "memory has been permanently erased and cannot be mutated".to_string(),
        _ =>
            format!(
                "the memory's current state ({from_str}) does not allow this mutation; \
                 check it with moot_memory_search"
            ),
    };
    Some(format!("{verb} failed: {body}"))
}

/// Strip a leading `EnumCaseName: ` prefix from a substrate error reason
/// string, when present. The substrate error chain can prepend type/variant
/// names like `"InvalidContent: "` that are internal implementation details
/// and must not appear in AI-client-facing messages (B-6 describe-helper
/// contract). Parity with Swift `ToolDispatcher.stripEnumPrefix(from:)`.
///
/// Strips at most one prefix. The pattern is a run of alphanumeric or
/// underscore characters (no spaces) followed by `": "`. A plain English
/// sentence fragment like "state mutation rejected" does NOT match.
fn strip_enum_prefix(reason: &str) -> &str {
    if let Some(sep) = reason.find(": ") {
        let prefix = &reason[..sep];
        let is_enum_like = !prefix.is_empty()
            && prefix.chars().all(|c| c.is_alphanumeric() || c == '_');
        if is_enum_like {
            return &reason[sep + 2..];
        }
    }
    reason
}

/// Dispatch a Tier 1–5 interface tool call. Returns the MCP `tools/call`
/// result payload. Throws `JSONRPCError` for out-of-band failures (bad estate,
/// missing required arg). Substrate refusals surface as `error_result`.
///
/// The `ledger` is the session-scoped `SurfacedRecallLedger` owned by the
/// `Dispatcher`. It is threaded to:
///   - `run_memory_search` — to record surfaced drawer ids.
///   - Dereference verbs — to trigger reward-trace marking when a surfaced
///     drawer id is subsequently acted upon (B-10a trace-reward wiring).
///   - `run_estate_status` — to include the trace row count in the status output.
pub fn dispatch(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    build_serial: &str,
) -> Result<serde_json::Value, JSONRPCError> {
    match name {
        "moot_file_memory" => run_file_memory(args, registry),
        "moot_memory_search" => run_memory_search(args, registry, ledger),
        "moot_update_memory" => run_update_memory(args, registry, ledger),
        "moot_withdraw_memory" => run_withdraw_memory(args, registry, ledger),
        "moot_erase_memory" => run_erase_memory(args, registry),
        "moot_confirm_memory" => run_confirm_memory(args, registry, ledger),
        "moot_move_memory" => run_move_memory(args, registry, ledger),
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
        // Pass build_serial so the pong includes the build segment.
        "moot_estate_ping" => run_estate_ping(args, registry, build_serial),
        // Maintenance
        "moot_reindex" => run_reindex(args, registry),
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
/// `location` maps to `room`; optional `wing` routes the drawer into a named
/// wing (ADR-016 §3). When absent, defaults to DEFAULT_WING_NAME ("Agentic Memory").
/// Server owns infrastructure fields (channel, lattice, added_by, embeddingModelID).
/// The lattice anchor sentinel is passed to the GeniusLocusKit capture seam
/// (`capture_with_mode`), which classifies via `Fdc::encode_anchor` when the
/// sentinel arrives with non-empty content; UNRESOLVED content keeps the "000"
/// sentinel (one-door principle). Mirrors Swift `runFileMemory`.
fn run_file_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let content = require_string(args, "content")?;
    let location = require_string(args, "location")?;
    let exportability = decode_exportability(args)?;

    // Decode caller-supplied adjectives. Absent → keep CaptureFrame defaults.
    // Unknown → reject with INVALID_PARAMS listing accepted values (mirrors Swift).
    let kind = decode_content_kind_arg(args.get("kind"))?;
    let sensitivity = decode_sensitivity_arg(args.get("sensitivity"))?;

    // Pass the unclassified sentinel anchor to the capture seam.
    // The GeniusLocusKit seam (capture_with_mode) classifies the content via
    // Fdc::encode_anchor when it sees the "000" sentinel and the content is
    // non-empty — one classification door for all capture paths (file_memory,
    // vault import, branch promotion). The per-caller Fdc::encode_anchor call
    // that was here before the one-door refactor is removed; the seam owns
    // classification exclusively.
    let mut frame = CaptureFrame::new(
        content,
        // Actuator-driven capture (cookbook §2.4): file_memory is submitted by
        // an MCP AI agent (actuator), not a file import. Raw 5 per DrawerOperational.
        CaptureChannel::Actuator,
        location,
        LatticeAnchor::udc(DEFAULT_LATTICE_CODE),
        // Injected host identity: stamps provenance for the running binary
        // ("aria-mcp" or "mootx01") rather than a hardcoded constant.
        registry.server_identity.as_str(),
        DEFAULT_EMBEDDING_MODEL,
    );
    // Apply exportability at capture time (DEBT-1 write path). Default is
    // Private (privacy-preserving); supply "public" in the args to birth a
    // drawer that is immediately visible to filter:exportable recall.
    frame.exportability = exportability;
    // Apply caller-supplied content kind (defaults to Prose if absent).
    if let Some(k) = kind {
        frame.kind = k;
    }
    // Apply caller-supplied sensitivity tier (defaults to Normal if absent).
    if let Some(s) = sensitivity {
        frame.sensitivity = s;
    }
    // Provenance channel: marks this row as MCP-agent-sourced in the provenance
    // bitmap (§2.5). Mirrors Swift's `provenanceChannel: .mcpAgent`.
    frame.provenance_channel = Channel::McpAgent;
    // ADR-016 §3: optional `wing` argument routes this memory into a specific wing.
    // When supplied, the drawer files into that wing.
    // When absent, defaults to DEFAULT_WING_NAME ("Agentic Memory") — the AI's
    // working memory wing. Mirrors Swift runFileMemory wing routing.
    frame.wing = Some(
        optional_string(args, "wing")?
            .map(|s| s.to_string())
            .unwrap_or_else(|| DEFAULT_WING_NAME.to_string()),
    );
    // Optional back-dated event time. When supplied, the drawer's event_time
    // is set to the caller's ISO8601 instant (epoch seconds) instead of the
    // ingest wall-clock time. Mirrors Swift ToolDispatch.runFileMemory which
    // parses event_time to Date and passes it as eventTime on the CaptureFrame.
    if let Some(raw) = optional_string(args, "event_time")? {
        let secs = parse_iso8601_to_secs(&raw).ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("event_time is not a valid ISO8601 instant: {raw}"),
            )
        })?;
        frame.event_time = Some(secs);
    }

    // D-A: `impatient` is an execution option on the write verb (Dual-Path
    // Intake), mirroring the Swift ARIA_MCP threading. When true the memory is
    // encoded for semantic search inline before the write returns; when false
    // (default) the write returns immediately and the encode drain ingests it.
    let impatient = optional_bool(args, "impatient")?.unwrap_or(false);
    let mode = if impatient { WriteMode::Impatient } else { WriteMode::Regular };

    let now = wall_now();
    // `capture_with_mode` is a write verb that mounts/feeds the encode queue, so
    // it takes `&mut self`; lock the coordinator mutably for the duration.
    let mut coord = estate.coord.lock().unwrap();
    match coord.capture_with_mode(&estate.handle, frame, now, mode) {
        Ok(drawer) => {
            let body = format!(
                "filed memory {}\nroom: {}\nlineage: {}",
                drawer.id, drawer.room, drawer.lineage_id
            );
            Ok(text_result(&body))
        }
        // Route the VerbDispatchError through the describe machinery so no
        // internal Rust type names (UnderlyingEstateFailure, BasisViolation,
        // etc.) leak to the agent. The helper also converts gate-rejection
        // messages to actionable English phrasing.
        Err(e) => Ok(error_result(&describe_verb_dispatch_error(&e))),
    }
}

/// Search memories in the estate using hybrid BM25+vector scored recall.
///
/// Requires `query`. Optional `scoring` (raw/rrf/matrixAware, default
/// "matrixAware"; an unknown non-empty value returns invalidParams),
/// `limit` (default 20), and `ordering` (see below).
/// Decodes the scoring argument and routes through `recall_scored` with
/// mode=unionBest, matching Swift `runMemorySearch` which also uses
/// unionBest+matrixAware defaults.
///
/// # ordering argument
///
/// "byRelevanceDesc" is a compatibility spelling that routes to the scored
/// recall pipeline — the results ARE relevance-ordered because recall_scored
/// with mode=unionBest ranks by score values. The RecallFrame ordering field
/// is set to ByCaptureTimeDesc as a stable tie-break within the scored layer;
/// the final result order is driven by scores. All other orderings are decoded
/// strictly; unknown values return an invalidParams transport fault.
///
/// Mirrors Swift `ToolDispatch.runMemorySearch` and `decodeOrdering`.
fn run_memory_search(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    use genius_locus_kit::recall::{
        GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy,
    };

    let estate = registry.resolve(args, "estateID")?;
    let query = require_string(args, "query")?;

    // Decode optional `scoring` argument. Absent/None keeps the documented
    // default (matrixAware) to match Swift. An unknown NON-EMPTY string is a
    // client error and fails CLOSED with invalidParams — silently coercing it
    // to matrixAware would run a different scoring mode than the caller asked
    // for and hide the typo. This mirrors the `ordering` decode below, which
    // is already strict. Mirrors Swift runMemorySearch.
    let scoring = match optional_string(args, "scoring")? {
        None | Some("matrixAware") => GLKRecallScoring::MatrixAware,
        Some("raw") => GLKRecallScoring::Raw,
        Some("rrf") => GLKRecallScoring::Rrf,
        Some(unknown) => {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("Unknown scoring: {unknown}. Valid: raw, rrf, matrixAware"),
            ));
        }
    };

    // Decode optional `limit` argument. Defaults to 20.
    let limit = optional_integer(args, "limit")?
        .map(|n| n.max(1) as usize)
        .unwrap_or(20_usize);

    // Decode optional `ordering` argument. "byRelevanceDesc" is a compatibility
    // spelling: LocusKit's Ordering enum has no relevance case (it has no scoring
    // signal), but at the ARIA surface we accept the client spelling and route the
    // request through the scored recall path (recall_scored/unionBest), whose
    // results ARE relevance-ordered. The RecallFrame ordering field is set to
    // ByCaptureTimeDesc as a stable tie-break; final order is driven by scores.
    // Unknown spellings return invalidParams. Mirrors Swift decodeOrdering.
    if let Some(ord) = optional_string(args, "ordering")? {
        match ord {
            "byCaptureTimeDesc" | "byCaptureTimeAsc" | "byRoomAsc" | "byRelevanceDesc" => {
                // All accepted spellings proceed to recall_scored. The RecallFrame
                // uses ByCaptureTimeDesc as the internal tie-break regardless of
                // which spelling was sent, because the scored path owns the final order.
            }
            unknown => {
                return Err(JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    format!("Unknown ordering: {unknown}. Valid: byCaptureTimeDesc, byCaptureTimeAsc, byRoomAsc, byRelevanceDesc"),
                ));
            }
        }
    }

    // Decode optional `filter` for the recall frame. Omitted filter uses
    // ordinary recall defaults: state/trust/sensitivity constraints are
    // inserted by LocusKit, but no confirmation constraint is added.
    // Full hydration: the caller is a human-facing AI client; the content
    // preview in the search result requires the content blob. Structured
    // hydration (the RecallFrame default) strips content blobs and would
    // render every result as an empty-content preview.
    let mut filter_chain = decode_filter_chain(args)?;
    // ADR-016 §4: optional `wing` argument scopes recall to a single wing.
    // When absent, recall spans all wings (existing default behavior unchanged).
    // Appended to the filter chain so it composes with any explicit filter arg.
    if let Some(wing_name) = optional_string(args, "wing")? {
        filter_chain.push(locus_kit::filter::Filter::InWing(wing_name.to_string()));
    }
    let mut frame = RecallFrame::new(filter_chain);
    frame.hydration_level = locus_kit::filter::HydrationLevel::Full;

    // B-10a: mark as external so the coordinator writes recall-trace rows for
    // the reward pipeline. The ARIA_MCP boundary is the ONLY place that sets
    // `.external()` — internal callers (dreaming, lenses, recipes) must NOT.
    let request = GLKRecallRequest::new(frame)
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(scoring)
        .with_limit(limit)
        .with_fallback(RecallFallbackPolicy::AllowDegraded)
        .with_query_text(query.to_string())
        .external(); // B-10a: ARIA boundary is external origin

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    let result = coord
        .recall_scored(&estate.handle, request, now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    // Record surfaced drawer ids in the session ledger so dereference verbs can
    // trigger reward-trace marking (DESIGN_TRACE_REWARD_2026-06-12.md §session-ledger).
    let surfaced_ids: Vec<String> = result.hits.iter()
        .filter_map(|h| h.drawer.as_ref().map(|d| d.id.clone()))
        .collect();
    if !surfaced_ids.is_empty() {
        ledger.record_surfaced(&surfaced_ids, now);
    }

    // Compute discrimination over the full ordered hit list before the display
    // prefix so the signal reflects all returned scores.
    let hit_scores: Vec<f64> = result.hits.iter()
        .map(|h| h.score.final_score as f64)
        .collect();
    let discrimination = crate::recall_discrimination::classify(&hit_scores);
    // Dense-lane dark flag: true when Lane D (deterministic vector) did not
    // contribute to this ranking. Used to cap the discrimination signal so
    // "high — clear top result" is never reported on a lexical-only ranking.
    let dense_lane_dark = result.dense_lane_status.is_some();

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
    lines.push(crate::recall_discrimination::result_line_with_dense_dark(discrimination, dense_lane_dark));
    // Recall provenance: surface the dense-lane status and any degraded stages
    // so callers can distinguish retrieval quality (DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12).
    //
    // dense_lane_status non-None means the dense float vector lane (Lane D) did not
    // contribute hits. Lane D uses the deterministic embedding provider (FNV-1a +
    // FloatSimHash projection — the permanent federation-grade vector, not a learned
    // distributional model); callers use this to detect when ranking came from
    // structural/BM25 lanes only rather than the vector lane. The learned semantic
    // vector (MiniLM/MPNet/Gemma) is an additive v1.1 on-device lane, not wired here.
    // This is the honest-labeling requirement from the embedding ADR.
    //
    // degraded_stages lists every pipeline stage that was skipped due to a
    // recoverable error. An empty vec means every attempted stage succeeded.
    //
    // Format: a single "recall_provenance:" status line, always present, never blank.
    // Mirrors Swift ToolDispatch.runMemorySearch provenance block exactly.
    let dense_part = match &result.dense_lane_status {
        Some(reason) => format!("dense_lane:{}", reason),
        None => "dense_lane:active".to_string(),
    };
    let degraded_part = if result.degraded_stages.is_empty() {
        "degraded_stages:none".to_string()
    } else {
        format!("degraded_stages:[{}]", result.degraded_stages.join(","))
    };
    lines.push(format!("recall_provenance: {} {}", dense_part, degraded_part));
    Ok(text_result(&lines.join("\n")))
}

/// Note that a drawer id was "used" (acted upon) by a dereference verb.
///
/// If the id is present in the session ledger (i.e., it was surfaced by a
/// prior `moot_memory_search` in this session), call `mark_recall_used` on
/// the coordinator so the dreaming daemon's reward sweep assigns reward 1.0
/// for that drawer's trace rows (DESIGN_TRACE_REWARD_2026-06-12.md).
///
/// Failures are silenced — a reward-marking failure must never break the
/// dereference verb's primary result.
fn note_usage(
    id: &str,
    estate: &crate::estate_registry::OpenEstate,
    ledger: &SurfacedRecallLedger,
) {
    if let Some(entry) = ledger.get(id) {
        let now = wall_now();
        // Retention window: 30 days in seconds (mirrors Swift traceRetentionSeconds).
        let since_secs = entry.surfaced_at_secs - 30 * 24 * 60 * 60;
        let since = unix_epoch_secs_to_iso8601(since_secs);
        let now_str = unix_epoch_secs_to_iso8601(now);
        if let Ok(coord) = estate.coord.lock() {
            // Silently ignore errors — reward marking is best-effort.
            let _ = coord.mark_recall_used(&estate.handle, id, &since, &now_str);
        }
    }
}

/// Convert Unix epoch seconds to an ISO 8601 string (UTC, no sub-second
/// precision). Used for the `since` and `now` parameters of
/// `mark_recall_used` which expects TEXT ISO8601 dates (fleet date rule).
fn unix_epoch_secs_to_iso8601(secs: i64) -> String {
    // Manual conversion — no external crate (zero-dep rule).
    // Gregorian calendar arithmetic for the range 1970–2106.
    let s = secs.max(0) as u64;
    let days_since_epoch = s / 86400;
    let time_of_day = s % 86400;
    let hh = time_of_day / 3600;
    let mm = (time_of_day % 3600) / 60;
    let ss = time_of_day % 60;

    // Days since 1970-01-01. Gregorian calendar.
    let (y, mo, d) = days_to_ymd(days_since_epoch);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, mo, d, hh, mm, ss)
}

/// Convert days since 1970-01-01 to (year, month, day). Gregorian.
fn days_to_ymd(mut days: u64) -> (u64, u64, u64) {
    let mut y = 1970u64;
    loop {
        let leap = is_leap(y);
        let diy = if leap { 366 } else { 365 };
        if days < diy { break; }
        days -= diy;
        y += 1;
    }
    let months = if is_leap(y) {
        [31u64, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31u64, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut mo = 1u64;
    for &dim in &months {
        if days < dim { break; }
        days -= dim;
        mo += 1;
    }
    (y, mo, days + 1)
}

fn is_leap(y: u64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

/// Apply a named mutation to a memory. Requires `id` and `mutation`.
///
/// Mutation strings: confirm, reject, contest, resolve, supersede, revive,
/// accept. Mirrors Swift `runUpdateMemory`.
fn run_update_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let id = require_string(args, "id")?;
    let mutation_str = require_string(args, "mutation")?;

    let kind = decode_mutation_kind(mutation_str)?;
    // Note usage before acquiring the coord lock so note_usage can also lock.
    note_usage(id, &estate, ledger);
    let coord = estate.coord.lock().unwrap();
    match coord.mutate(&estate.handle, id, kind, None) {
        Ok(()) => Ok(text_result(&format!("updated memory {id} ({mutation_str})"))),
        Err(e) => Ok(error_result(&describe_verb_dispatch_error(&e))),
    }
}

/// Withdraw a memory (soft-delete). Requires `id`. Optional `reason`.
///
/// Mirrors Swift `runWithdrawMemory`.
fn run_withdraw_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let id = require_string(args, "id")?;
    let reason = optional_string(args, "reason")?;

    // Note usage: if this drawer was surfaced by moot_memory_search, mark its
    // recall-trace rows used so the reward sweep assigns reward 1.0.
    note_usage(id, &estate, ledger);
    let now = wall_now();
    let coord = estate.coord.lock().unwrap();
    match coord.withdraw(&estate.handle, id, reason, now) {
        Ok(()) => Ok(text_result(&format!("withdrew memory {id}"))),
        Err(e) => Ok(error_result(&describe_verb_dispatch_error(&e))),
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
    let confirmed = optional_bool(args, "confirmed")?.unwrap_or(false);

    if !confirmed {
        return Ok(error_result(
            "erase_memory requires confirmed: true — this action is irreversible",
        ));
    }

    let coord = estate.coord.lock().unwrap();
    // Wall-clock `now` enters at the ARIA boundary; the deferred-seal expunge
    // (§B-2a) threads it so the success-audit timestamp is deterministic downstream.
    let now = wall_now();
    match coord.expunge(&estate.handle, id, reason, confirmed, now) {
        Ok(()) => Ok(text_result(&format!("erased memory {id}"))),
        Err(e) => Ok(error_result(&describe_verb_dispatch_error(&e))),
    }
}

/// Confirm a memory (promote to UserConfirmed). Requires `id`.
///
/// Mirrors Swift `runConfirmMemory`.
fn run_confirm_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let id = require_string(args, "id")?;

    // Note usage: confirming a surfaced drawer means the user acted on it.
    note_usage(id, &estate, ledger);
    let coord = estate.coord.lock().unwrap();
    match coord.mutate(&estate.handle, id, MutationKind::Confirm, None) {
        Ok(()) => Ok(text_result(&format!("confirmed memory {id}"))),
        Err(e) => Ok(error_result(&describe_verb_dispatch_error(&e))),
    }
}

/// Move a memory to a different room. Requires `id` and `location`.
///
/// `location` maps to the new `room`. Mirrors Swift `runMoveMemory`.
fn run_move_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let id = require_string(args, "id")?;
    let location = require_string(args, "location")?;

    // Note usage: moving a surfaced drawer means the user acted on it.
    note_usage(id, &estate, ledger);
    let coord = estate.coord.lock().unwrap();
    match coord.reanchor(&estate.handle, id, Some(location), None) {
        Ok(()) => Ok(text_result(&format!("moved memory {id} to {location}"))),
        Err(e) => Ok(error_result(&describe_verb_dispatch_error(&e))),
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

    // Reject unknown kind strings — silent fallback to References would accept
    // garbage input and produce a misleadingly-typed tunnel.
    if !VALID_KIND_STRINGS.contains(&kind_str) {
        let valid_list = {
            let mut v: Vec<&str> = VALID_KIND_STRINGS.to_vec();
            v.sort();
            v.join(", ")
        };
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown kind: {kind_str}. Valid kinds: {valid_list}"),
        ));
    }

    // Reject self-loops — a tunnel from a drawer to itself is semantically
    // meaningless and breaks graph traversal algorithms.
    if from_id == to_id {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Self-loop not allowed: from_id and to_id are the same ({from_id})."),
        ));
    }

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    // Recall all drawers to resolve wing+room for source and target.
    let all = coord
        .recall(&estate.handle, RecallFrame::new(vec![]), now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

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
        // Injected host identity: stamps provenance for the running binary.
        registry.server_identity.as_str(),
    );
    frame.source_drawer_id = Some(from_id.to_string());
    frame.target_drawer_id = Some(to_id.to_string());
    frame.kind = tunnel_kind;

    // Access the estate directly for tunnel capture (not via coordinator, which
    // has no capture_tunnel wrapper — the estate_verbs surface exposes it).
    // coord.estate_for returns GeniusLocusKitError (not VerbDispatchError), so
    // route through describe_glk_error to surface a clean English reason.
    let locus_estate = coord.estate_for(&estate.handle).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, crate::dispatch::describe_glk_error(&e))
    })?;

    match locus_estate.capture_tunnel(frame, now) {
        Ok(tunnel) => {
            let body = format!(
                "linked {from_id} → {to_id} via {kind_str} ({})",
                tunnel.id
            );
            Ok(text_result(&body))
        }
        // LocusKitError has Display — surface the English reason without
        // leaking internal Rust enum variant names to the agent.
        Err(e) => Ok(error_result(&format!("link_memories failed: {e}"))),
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
        .recall(&estate.handle, RecallFrame::new(vec![]), now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    let source = all.iter().find(|d| d.id == from_id).ok_or_else(|| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("from_id not found: {from_id}"),
        )
    })?;
    let wing = source.wing.clone();

    let tunnels = coord
        .recall_tunnels(&estate.handle, &wing)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

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
        .recall(&estate.handle, RecallFrame::new(vec![]), now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    let wings: std::collections::HashSet<&str> =
        all.iter().map(|d| d.wing.as_str()).collect();

    // Scan every wing's tunnels for incoming edges to to_id.
    let mut incoming = Vec::new();
    for wing in &wings {
        let tunnels = coord
            .recall_tunnels(&estate.handle, wing)
            .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;
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
/// `source_id` grounds the fact; when the caller omits it, it defaults to the
/// ingest channel that asserted it (never unanchored). Calls
/// `coordinator.add_kg_fact`. Mirrors Swift `runFileFact`.
fn run_file_fact(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let subject = require_string(args, "subject")?;
    let predicate = require_string(args, "predicate")?;
    let object = require_string(args, "object")?;
    // source_id grounds the fact (provenance — KGFact: every fact traces back to a
    // source). When the caller omits it, infer the source as the injected host
    // identity so a fact is never stored unanchored and provenance reflects the
    // actual binary filing it ("aria-mcp" or "mootx01").
    let provided = optional_string(args, "source_id")?.unwrap_or("");
    let source_id = if provided.is_empty() { registry.server_identity.as_str() } else { provided };

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();
    match coord.add_kg_fact(&estate.handle, subject, predicate, object, source_id, now) {
        Ok(fact) => Ok(text_result(&format!(
            "filed fact {}: [{subject}] {predicate} [{object}]",
            fact.id
        ))),
        Err(e) => Ok(error_result(&describe_verb_dispatch_error(&e))),
    }
}

/// Search knowledge-graph facts. Optional `query` for substring filtering.
///
/// Reads all facts via `coordinator.recall_kg_facts` and filters in-memory.
/// Fact retrieval is a KGFact row scan — the dense vector lane (Lane D) does
/// not participate. When a query is present and no corpus is registered (dense
/// lane dark), a `recall_provenance:` hint is appended so the AI caller can
/// distinguish "no lexical match" from "semantic search was not consulted".
/// This mirrors the honest-lane-state reporting that `moot_memory_search`
/// emits (DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12).
///
/// Mirrors Swift `runFactSearch`.
fn run_fact_search(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let query = optional_string(args, "query")?;

    let coord = estate.coord.lock().unwrap();
    // Capture dense-lane availability before consuming the lock via recall_kg_facts.
    // `has_corpus` is a cheap registry lookup — no I/O — so it is safe to call
    // under the same lock acquisition before the recall call.
    let dense_lane_dark = !coord.has_corpus(&estate.handle);
    let facts = coord
        .recall_kg_facts(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

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

    // Include evaluation fields (filed_at as ISO8601, source_drawer_id) so
    // callers can reason about provenance without a separate timeline call.
    // Mirrors Swift runFactSearch field additions.
    let mut lines = vec![header];
    for f in &matches {
        let filed_iso = epoch_to_iso8601(f.filed_at);
        lines.push(format!(
            "  {} — [{}] {} [{}]  filed={}  source={}",
            f.id, f.subject, f.predicate, f.object, filed_iso, f.source_drawer_id
        ));
    }
    // Dark-lane hint: when a query was supplied and the dense lane is dark (no
    // corpus registered), append a recall_provenance line using the same format
    // as moot_memory_search so AI callers receive a consistent signal. "0 results"
    // then means "no lexical match", not "this fact does not exist semantically".
    if query.is_some() && dense_lane_dark {
        lines.push("recall_provenance: dense_lane:dark:noCorpus degraded_stages:none".to_owned());
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
        Err(e) => Ok(error_result(&describe_verb_dispatch_error(&e))),
    }
}

/// Format an epoch-seconds timestamp as an ISO8601 / RFC3339 UTC string.
///
/// Convert epoch seconds to ISO8601 UTC string.
///
/// `pub(crate)` so that `lens_tools` can call it directly for the
/// contradiction lens `filed=` field (Part 4 — filed_at ISO8601 fix).
/// Delegates to the canonical helper in NeuronKit's topology_analysis module;
/// the duplication in recipe_tools stays private (its own use only).
pub(crate) fn epoch_to_iso8601(epoch_secs: i64) -> String {
    neuron_kit::topology_analysis::epoch_to_iso8601(epoch_secs)
}

/// Minimal ISO8601 UTC parser — handles the subset the ARIA MCP server accepts.
///
/// Accepts "YYYY-MM-DDTHH:MM:SSZ", "YYYY-MM-DDTHH:MM:SS.mmmZ", and
/// "YYYY-MM-DDTHH:MM:SS+00:00". Returns epoch seconds (not milliseconds).
/// Used to decode the optional `event_time` argument in `run_file_memory`,
/// mirroring Swift's `ISO8601DateFormatter().date(from:)` in `runFileMemory`.
fn parse_iso8601_to_secs(s: &str) -> Option<i64> {
    // Strip timezone suffix and milliseconds fraction before splitting on T.
    let s = s
        .trim_end_matches('Z')
        .trim_end_matches("+00:00")
        .trim_end_matches("+0000");
    // Drop optional fractional seconds (.mmm) — we only need whole-second precision.
    let s = if let Some(dot_pos) = s.rfind('.') {
        &s[..dot_pos]
    } else {
        s
    };
    let parts: Vec<&str> = s.split('T').collect();
    if parts.len() != 2 {
        return None;
    }
    let date_parts: Vec<i64> = parts[0].split('-').filter_map(|p| p.parse().ok()).collect();
    let time_parts: Vec<i64> = parts[1].split(':').filter_map(|p| p.parse().ok()).collect();
    if date_parts.len() < 3 || time_parts.len() < 3 {
        return None;
    }
    let (y, m, d) = (date_parts[0], date_parts[1], date_parts[2]);
    let (h, min, sec) = (time_parts[0], time_parts[1], time_parts[2]);
    // Days since Unix epoch via Howard Hinnant's algorithm (same as lens_tools).
    let days = days_from_ymd_interface(y, m, d)?;
    Some(days * 86400 + h * 3600 + min * 60 + sec)
}

fn days_from_ymd_interface(y: i64, m: i64, d: i64) -> Option<i64> {
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    let y = if m <= 2 { y - 1 } else { y };
    let m = if m <= 2 { m + 9 } else { m - 3 };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * m + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some(era * 146097 + doe - 719468)
}

/// Render a retired lifecycle cluster as its single-letter label for the
/// fact-timeline tag (`retired(B)` / `retired(C)`). Kept identical to the
/// Swift port's `clusterLabel` so both ports emit byte-identical tags.
fn cluster_label(cluster: RowStateCluster) -> &'static str {
    match cluster {
        RowStateCluster::A => "A",
        RowStateCluster::B => "B",
        RowStateCluster::C => "C",
    }
}

/// Derive the fact-timeline lifecycle tag from an `adjective_bitmap` value.
///
/// The tag comes from the canonical `RowStateAutomaton` cluster — the SAME
/// partition (`cluster(s) = (s>>4)&0x3`) the rest of the substrate uses —
/// never a hand-rolled raw boundary. The state raw lives in bits 0–5 of
/// `adjective_bitmap`. Cluster A is the believed/active partition; B
/// (historical) and C (terminal) are retired. The tag carries the retired
/// cluster letter, not the raw state, so any future state added inside a
/// defined cluster classifies correctly. An undefined raw (not one of the ten
/// cookbook §2.3 states) is reported verbatim as `unknown(raw)`. Mirrors the
/// Swift `ToolDispatcher.lifecycleTag(forAdjectiveBitmap:)`.
pub(crate) fn lifecycle_tag_for_adjective_bitmap(adjective_bitmap: i64) -> String {
    let state_raw = (adjective_bitmap & 0x3F) as u8;
    match RowState::cluster_of_raw_state(state_raw) {
        Some(RowStateCluster::A) => "active".to_string(),
        Some(c @ RowStateCluster::B) | Some(c @ RowStateCluster::C) => {
            format!("retired({})", cluster_label(c))
        }
        None => format!("unknown({state_raw})"),
    }
}

/// Read all KG facts — active AND retired — in chronological order, including
/// lifecycle state tags, to trace how the estate's structured knowledge evolved.
///
/// Delegates to `EstateCoordinator::recall_kg_fact_timeline`, which reads every
/// row ever filed regardless of state.  Each row is tagged with its lifecycle
/// state derived from the canonical `RowStateAutomaton` cluster: the state raw
/// in `adjective_bitmap & 0x3F` is classified by `RowState::cluster_of_raw_state`
/// (`cluster(s) = (s>>4)&0x3`). Cluster A is active/believed; clusters B and C
/// are retired. The tag carries the retired cluster letter, not the raw state.
///
/// Optional `entity` arg: when present, only facts whose subject or object
/// contains the value (case-insensitive substring) are returned.
///
/// Distinct from `moot_fact_search`, which returns active facts only (no
/// regression: `recall_kg_facts` backing `run_fact_search` is unchanged).
///
/// Mirrors Swift `runFactTimeline`.
fn run_fact_timeline(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    // The case-insensitive match is done in recall_kg_fact_timeline, which
    // lowercases both the entity and each fact's subject/object. Pass the raw
    // entity through.
    let entity_raw = optional_string(args, "entity")?;
    let entity_ref: Option<&str> = entity_raw.as_deref();

    let coord = estate.coord.lock().unwrap();
    let mut facts = coord
        .recall_kg_fact_timeline(&estate.handle, entity_ref)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    // Results are ordered by filed_at ascending from the storage layer.
    // Sort here to be defensive in case backends return unordered rows.
    facts.sort_by_key(|f| f.filed_at);

    let header = if let Some(e) = entity_raw {
        format!("fact timeline for \"{e}\": {}", facts.len())
    } else {
        format!("fact timeline: {}", facts.len())
    };

    let mut lines = vec![header];
    // Cap at 200 rows matching the Swift port.
    // Include source_drawer_id for provenance tracing (mirrors Swift runFactTimeline
    // which adds sourceDrawerID in the same Part 6 change).
    for f in facts.iter().take(200) {
        let lifecycle_tag = lifecycle_tag_for_adjective_bitmap(f.adjective_bitmap);
        // Emit ISO8601 timestamps to match the Swift port's output format.
        // filed_at is epoch seconds; format as UTC RFC3339 / ISO8601.
        let filed_iso = epoch_to_iso8601(f.filed_at);
        lines.push(format!(
            "{}  {}  {}  [{}] {} [{}]  source={}",
            filed_iso, lifecycle_tag, f.id, f.subject, f.predicate, f.object, f.source_drawer_id
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
    let agent = optional_string(args, "agent")?.unwrap_or("mcp-agent");

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
        Err(e) => Ok(error_result(&describe_verb_dispatch_error(&e))),
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
    let agent = optional_string(args, "agent")?.unwrap_or("mcp-agent");
    let last_n = optional_integer(args, "last_n")?
        .map(|n| n as usize)
        .unwrap_or(10);

    let coord = estate.coord.lock().unwrap();
    let mut entries = coord
        .recall_diary_entries(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

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
///
/// `sync:` reports the real ConvergenceKit backend state via
/// `EstateCoordinator::sync_state_token`. When no sync engine is registered
/// the field reads `"sync: local-only"`. The fabricated constant that
/// previously appeared here has been removed (OP-1 honesty fix).
fn run_estate_status(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    let drawers = coord
        .recall(&estate.handle, RecallFrame::new(vec![]), now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    let kg_facts = coord
        .recall_kg_facts(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    let wings: std::collections::BTreeSet<&str> =
        drawers.iter().map(|d| d.wing.as_str()).collect();

    let estate_info = coord.estate_for(&estate.handle).ok();
    let (estate_name, estate_uuid) = estate_info
        .and_then(|e| e.manifest().ok())
        .map(|m| (m.estate_name, m.estate_uuid))
        .unwrap_or_else(|| ("unknown".to_string(), "unknown".to_string()));

    let wings_list = wings.iter().cloned().collect::<Vec<_>>().join(", ");

    // Trace row count — the reward pipeline's read log size. A read failure
    // must not break the whole status response, but it must NOT be reported as
    // `0`: a fabricated zero is indistinguishable from a genuinely empty trace
    // table and would lie about reward-pipeline depth. On failure the field
    // reads `unavailable` so the consumer can tell "no traces" from "could not
    // read". Mirrors Swift runEstateStatus.
    let trace_rows = match coord.count_recall_traces(&estate.handle) {
        Ok(n) => n.to_string(),
        Err(_) => "unavailable".to_string(),
    };

    // Sync state — read the real ConvergenceKit backend state via GLK.
    // Best-effort: a sync_state_token failure must not break the status
    // response; fall back to "local-only" so the field is always present
    // and honest. "local-only" means no sync engine is wired for this estate.
    let sync_token = coord
        .sync_state_token(&estate.handle)
        .unwrap_or_else(|_| "local-only".to_string());

    // "active" = cluster-A believed drawers only. `recall()` with an empty
    // filter chain returns only currently-believed rows (RowState cluster A,
    // where (state_raw >> 4) & 0x3 == 0). This matches the Swift fix that
    // applies `RowState.cluster(ofRawState:) == .a` to filter out rejected/
    // withdrawn drawers that were previously mis-counted as "active".
    //
    // "total" = all non-erased rows (tombstone = permanently erased).
    // We call `all_drawers()` which includes tombstoned rows, then subtract.
    // Best-effort: on error, report "unavailable" rather than fabricating 0
    // or failing the status response.
    let total_count: String = match coord.all_drawers(&estate.handle) {
        Ok(all) => {
            let non_erased = all.iter().filter(|d| d.tombstoned_at.is_none()).count();
            non_erased.to_string()
        }
        Err(_) => "unavailable".to_string(),
    };

    let body = format!(
        "estate: {estate_name} [{estate_uuid}]\nmemories: {} active ({} total)\nkg_facts: {}\nwings: {}\ntrace_rows: {}\nsync: {}\n{}",
        drawers.len(),
        total_count,
        kg_facts.len(),
        wings_list,
        trace_rows,
        sync_token,
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

    // Resolve estate name for the header — mirrors Swift `handle.estateName`.
    let estate_info = coord.estate_for(&estate.handle).ok();
    let estate_name = estate_info
        .and_then(|e| e.manifest().ok())
        .map(|m| m.estate_name)
        .unwrap_or_else(|| "unknown".to_string());

    // Full hydration required so charter drawer content bodies are available.
    // The default Structured hydration uses a no-blob projection that zeroes the
    // content field — charter text would be empty. Full forces the blob load.
    // Mirrors Swift runEstateMap which uses estate.allDrawers() (always full).
    let mut map_frame = RecallFrame::new(vec![]);
    map_frame.hydration_level = locus_kit::filter::HydrationLevel::Full;
    let drawers = coord
        .recall(&estate.handle, map_frame, now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    // Build a per-wing charter map: wing → charter text (from CHARTER_ROOM drawers).
    // ADR-016 §3: each wing's charter is surfaced inline so callers can orient to each
    // wing's role without a separate lookup. The first charter drawer per wing wins;
    // user-defined wings without a charter drawer show no inline text.
    let mut charters: std::collections::BTreeMap<&str, &str> = std::collections::BTreeMap::new();
    for d in &drawers {
        if d.room == CHARTER_ROOM && !charters.contains_key(d.wing.as_str()) {
            charters.insert(d.wing.as_str(), d.content.as_str());
        }
    }

    // Group by wing then room, counting NON-charter drawers per location.
    // Charter drawers are excluded from counts — they are structural metadata,
    // not user-filed memories, mirroring Swift runEstateMap (ADR-016 §3).
    let mut tree: std::collections::BTreeMap<&str, std::collections::BTreeMap<&str, usize>> =
        std::collections::BTreeMap::new();
    for d in &drawers {
        if d.room != CHARTER_ROOM {
            *tree
                .entry(d.wing.as_str())
                .or_default()
                .entry(d.room.as_str())
                .or_insert(0) += 1;
        }
    }

    // Header mirrors Swift runEstateMap: "estate map: estateName" (not a raw count).
    // Per-room counts enumerate non-charter drawers; charter text shown inline per wing.
    let mut lines = vec![format!("estate map: {estate_name}")];
    for (wing, rooms) in &tree {
        lines.push(format!("  {wing}/"));
        // Surface the wing's charter inline per ADR-016 §3.
        if let Some(charter) = charters.get(wing) {
            lines.push(format!("    charter: {charter}"));
        }
        for (room, count) in rooms {
            lines.push(format!("    {room}: {count}"));
        }
    }
    // Also surface wings that have a charter but no non-charter drawers yet —
    // newly seeded wings with no user content. Mirrors Swift runEstateMap.
    for (wing, charter) in &charters {
        if !tree.contains_key(wing) {
            lines.push(format!("  {wing}/"));
            lines.push(format!("    charter: {charter}"));
        }
    }
    Ok(text_result(&lines.join("\n")))
}

/// Verify the estate is reachable. Returns a pong with estate name, UUID,
/// and the build serial of this running binary.
///
/// Mirrors Swift `runEstatePing`. The build serial is forwarded from
/// `build_serial::derive()`, computed once at server startup and threaded
/// through the dispatch chain — no filesystem access per call.
///
/// Response format: `pong: estate <name> [<uuid>] is live — build <serial>`
///
/// The serial changes on every relink so a driver can confirm it is
/// talking to the most recently compiled binary. Override via
/// `MOOTX01_BUILD_SERIAL` to inject a known value (CI, tests, debugging).
fn run_estate_ping(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    build_serial: &str,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let coord = estate.coord.lock().unwrap();

    // coord.estate_for returns GeniusLocusKitError (not VerbDispatchError), so
    // route through describe_glk_error to surface a clean English reason.
    let locus_estate = coord.estate_for(&estate.handle).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, crate::dispatch::describe_glk_error(&e))
    })?;

    let manifest = locus_estate.manifest().map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("estate_ping: manifest read failed: {e}"))
    })?;

    Ok(text_result(&format!(
        "pong: estate {} [{}] is live — build {}",
        manifest.estate_name, manifest.estate_uuid, build_serial
    )))
}

// ===========================================================================
// Maintenance
// ===========================================================================

/// Enqueue encode jobs for every active drawer that is not yet BM25/vector-
/// indexed in the estate. Returns the count enqueued. Idempotent. Mirrors
/// Swift `ToolDispatch.runReindex`. Requires `&mut` coord because
/// `reindex_missing` calls `enqueue_encode_job` → `mount_encode_queue`.
fn run_reindex(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    // mut: reindex_missing calls enqueue_encode_job which calls mount_encode_queue
    // (&mut self). The standard pattern for write-path tools in this module.
    let mut coord = estate.coord.lock().unwrap();
    let now = wall_now();
    match coord.reindex_missing(&estate.handle, now) {
        Ok(enqueued) => Ok(text_result(&format!("reindex: enqueued {enqueued} drawers for encoding"))),
        Err(e) => Ok(error_result(&describe_verb_dispatch_error(&e))),
    }
}

// ===========================================================================
// Argument decoders
// ===========================================================================

/// Map a mutation string to `MutationKind`. Returns `Err(invalidParams)` for
/// unknown strings. Mirrors Swift `ToolDispatch.decodeMutation(_:)`.
///
/// Exportability mutations (DEBT-1 write path):
///   "correctExportability(public)"  → `MutationKind::CorrectExportability(Public)`
///   "correctExportability(private)" → `MutationKind::CorrectExportability(Private)`
fn decode_mutation_kind(s: &str) -> Result<MutationKind, JSONRPCError> {
    match s {
        "confirm" => Ok(MutationKind::Confirm),
        "reject" => Ok(MutationKind::Reject),
        "contest" => Ok(MutationKind::Contest),
        "resolve" => Ok(MutationKind::Resolve),
        "supersede" => Ok(MutationKind::Supersede),
        "revive" => Ok(MutationKind::Revive),
        "accept" => Ok(MutationKind::Accept),
        // Exportability axis — DEBT-1 write path. String spellings mirror
        // decode_exportability: "private" and "public" are the human-readable
        // forms accepted at the ARIA surface.
        "correctExportability(public)" => {
            Ok(MutationKind::CorrectExportability(AdjectiveExportability::Public))
        }
        "correctExportability(private)" => {
            Ok(MutationKind::CorrectExportability(AdjectiveExportability::Private))
        }
        _ => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!(
                "Unknown mutation: {s}. Valid: confirm, reject, contest, resolve, \
                 supersede, revive, accept, correctExportability(public), correctExportability(private)"
            ),
        )),
    }
}

/// Decode the optional `exportability` arg for a capture call.
///
/// Absent → `Private` (privacy-preserving default; all existing callers
/// continue to produce private drawers — DEBT-1 write-side fix).
/// Accepted string values: `"private"` → `Private`, `"public"` → `Public`.
/// Mirrors Swift `ToolDispatch.decodeExportability(_:)`.
fn decode_exportability(args: &BTreeMap<String, JsonValue>) -> Result<AdjectiveExportability, JSONRPCError> {
    match optional_string(args, "exportability")? {
        None | Some("private") => Ok(AdjectiveExportability::Private),
        Some("public") => Ok(AdjectiveExportability::Public),
        Some(other) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown exportability: {other}. Accepted values: private, public"),
        )),
    }
}

/// Decode the optional `kind` arg for a file_memory capture call.
///
/// Absent → `None` (caller keeps the `CaptureFrame` default of `Prose`).
/// Unknown → `INVALID_PARAMS` listing accepted values.
/// Mirrors Swift `ToolDispatch.decodeContentKind(_:)`.
fn decode_content_kind_arg(value: Option<&JsonValue>) -> Result<Option<ContentKind>, JSONRPCError> {
    let name = match value {
        None => return Ok(None),
        Some(JsonValue::String(s)) => s.as_str(),
        Some(_) => {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "kind must be a string".to_string(),
            ))
        }
    };
    match name {
        "prose"          => Ok(Some(ContentKind::Prose)),
        "code"           => Ok(Some(ContentKind::Code)),
        "transcript"     => Ok(Some(ContentKind::Transcript)),
        "list"           => Ok(Some(ContentKind::List)),
        "structuredJSON" => Ok(Some(ContentKind::StructuredJson)),
        "imageCaption"   => Ok(Some(ContentKind::ImageCaption)),
        "fingerprintOnly"=> Ok(Some(ContentKind::FingerprintOnly)),
        other => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!(
                "Unknown kind: {other}. Accepted values: prose, code, transcript, list, structuredJSON, imageCaption, fingerprintOnly"
            ),
        )),
    }
}

/// Decode the optional `sensitivity` arg for a file_memory capture call.
///
/// Absent → `None` (caller keeps the `CaptureFrame` default of `Normal`).
/// Unknown → `INVALID_PARAMS` listing accepted values.
/// Mirrors Swift `ToolDispatch.decodeSensitivity(_:)`.
fn decode_sensitivity_arg(value: Option<&JsonValue>) -> Result<Option<AdjectiveSensitivity>, JSONRPCError> {
    let name = match value {
        None => return Ok(None),
        Some(JsonValue::String(s)) => s.as_str(),
        Some(_) => {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "sensitivity must be a string".to_string(),
            ))
        }
    };
    match name {
        "normal"     => Ok(Some(AdjectiveSensitivity::Normal)),
        "elevated"   => Ok(Some(AdjectiveSensitivity::Elevated)),
        "restricted" => Ok(Some(AdjectiveSensitivity::Restricted)),
        "secret"     => Ok(Some(AdjectiveSensitivity::Secret)),
        other => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!(
                "Unknown sensitivity: {other}. Accepted values: normal, elevated, restricted, secret"
            ),
        )),
    }
}

/// Valid kind strings for `moot_link_memories`. Mirrors Swift `ToolDispatcher.validKindStrings`.
/// Any string not in this list is rejected with INVALID_PARAMS before decode_tunnel_kind runs.
const VALID_KIND_STRINGS: &[&str] = &[
    // Caller-friendly vocabulary
    "relates", "precedes", "contradicts", "supports", "refines",
    "exemplifies", "extends",
    // Pass-through substrate names (for advanced callers)
    "supersedes", "references", "blocks", "validates", "derivesFrom",
    "covers", "elaborates", "respondsTo",
];

/// Map a validated kind string to `TunnelKind`. Only called after
/// `VALID_KIND_STRINGS` membership is confirmed — caller-friendly vocabulary
/// maps to the matching substrate enum case; unknown strings are rejected
/// before this function is reached. Mirrors Swift `ToolDispatcher.tunnelKind(for:)`.
fn decode_tunnel_kind(s: &str) -> TunnelKind {
    match s {
        // Caller-friendly vocabulary
        "relates"     => TunnelKind::References,
        "precedes"    => TunnelKind::Blocks,
        "contradicts" => TunnelKind::Contradicts,
        "supports"    => TunnelKind::Validates,
        "refines"     => TunnelKind::Elaborates,
        "exemplifies" => TunnelKind::Covers,
        "extends"     => TunnelKind::DerivesFrom,
        // Pass-through substrate names
        "supersedes"  => TunnelKind::Supersedes,
        "references"  => TunnelKind::References,
        "blocks"      => TunnelKind::Blocks,
        "validates"   => TunnelKind::Validates,
        "derivesFrom" => TunnelKind::DerivesFrom,
        "covers"      => TunnelKind::Covers,
        "elaborates"  => TunnelKind::Elaborates,
        "respondsTo"  => TunnelKind::RespondsTo,
        // Unreachable — VALID_KIND_STRINGS gate ensures only the above reach here.
        _ => TunnelKind::References,
    }
}

#[cfg(test)]
mod lifecycle_tag_tests {
    use super::*;

    /// Pack a RowState raw into the bits 0–5 state field of an adjective
    /// bitmap, the way persisted rows carry it.
    fn adjective_with_state(state: RowState) -> i64 {
        (state as u8 as i64) & 0x3F
    }

    /// CONFORMANCE: the fact_timeline lifecycle tag must agree with the
    /// canonical `RowState::cluster` for EVERY defined state — not just the
    /// ten current ones in aggregate, but each one individually. Cluster A
    /// renders `active`; clusters B and C render `retired(<cluster>)`. If a
    /// future state is added inside a defined cluster, this derivation
    /// classifies it correctly; the old `< 7` boundary could not.
    #[test]
    fn lifecycle_tag_matches_automaton_cluster_for_every_state() {
        let all = [
            RowState::Active,
            RowState::Pending,
            RowState::Contested,
            RowState::Accepted,
            RowState::Superseded,
            RowState::Decayed,
            RowState::Withdrawn,
            RowState::Expired,
            RowState::Rejected,
            RowState::Tombstoned,
        ];
        for s in all {
            let tag = lifecycle_tag_for_adjective_bitmap(adjective_with_state(s));
            let expected = match s.cluster() {
                RowStateCluster::A => "active".to_string(),
                RowStateCluster::B => "retired(B)".to_string(),
                RowStateCluster::C => "retired(C)".to_string(),
            };
            assert_eq!(tag, expected, "{s:?} lifecycle tag must match its automaton cluster");
        }
    }

    /// Every defined raw across the full 6-bit state field classifies via the
    /// automaton; undefined gap raws (4–15, 20–31, 34–63) render `unknown(raw)`
    /// rather than being silently mis-tagged as `active` (the bug the old
    /// `< 7` boundary would hit for any state added in 4–15).
    #[test]
    fn gap_state_raws_render_unknown_not_active() {
        for raw in 0u8..=63 {
            let tag = lifecycle_tag_for_adjective_bitmap((raw as i64) & 0x3F);
            match RowState::from_raw(raw) {
                Some(s) => {
                    let expected = match s.cluster() {
                        RowStateCluster::A => "active".to_string(),
                        RowStateCluster::B => "retired(B)".to_string(),
                        RowStateCluster::C => "retired(C)".to_string(),
                    };
                    assert_eq!(tag, expected);
                }
                None => assert_eq!(tag, format!("unknown({raw})"),
                    "gap raw {raw} must render unknown, never active"),
            }
        }
    }

    /// Higher bits of the adjective bitmap (trust/sensitivity/exportability)
    /// must not leak into the lifecycle tag — only bits 0–5 select the state.
    #[test]
    fn lifecycle_tag_ignores_non_state_bits() {
        // Active state (raw 0) with trust/sensitivity/exportability all set.
        let adj = adjective_with_state(RowState::Active)
            | (3 << 18) | (16 << 6) | (32 << 12);
        assert_eq!(lifecycle_tag_for_adjective_bitmap(adj), "active");
        // Superseded (raw 16, cluster B) with high bits set stays retired(B).
        let adj_b = adjective_with_state(RowState::Superseded) | (3 << 18);
        assert_eq!(lifecycle_tag_for_adjective_bitmap(adj_b), "retired(B)");
    }
}
