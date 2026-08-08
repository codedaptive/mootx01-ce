//! Interface tool surface — Tier 1–5 of the 5-tier AI-client interface.
//!
//! Mirrors Swift `ToolDispatch.swift` for the 20 Tier 1–5 tools:
//!   Tier 1 — Core memory (8): moot_file_memory, moot_memory_search,
//!             moot_memory_get, moot_update_memory, moot_withdraw_memory,
//!             moot_erase_memory, moot_confirm_memory, moot_move_memory
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
    default_wings::DEFAULT_WING_NAME,
    drawer_store::SUBJECT_LENGTH_CONTRACT,
    estate_types::LatticeAnchor,
    filter::RecallFrame,
    frames::{CaptureFrame, MutationKind, TunnelCaptureFrame},
    tunnel_operational::TunnelKind,
    drawer_operational::{CaptureChannel, ContentKind},
    provenance::Channel,
};

use genius_locus_kit::{EncodeSpeed, VerbDispatchError, VerbError, WriteMode};
use genius_locus_kit_migrations::SharedContentMigrationExt;

use substrate_types::{RowState, RowStateCluster};

use vault_kit::palace_bridge::PalaceBridge;

use crate::dispatch::{
    clamp_limit, decode_filter_chain, error_result, optional_bool, optional_integer, optional_string,
    require_string, text_result, wall_now,
};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};
use crate::sensitivity_grant_ledger::SensitivityGrantLedger;
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
/// Estate-wide floor: after a successful full FDC reclassification apply,
/// this key records the composite classifier/artifact version against which
/// every active stored anchor has been checked.
const FDC_RECALCED_DATA_VERSION_META_KEY: &str = "aria.fdc.recalced_data_version";

// ---------------------------------------------------------------------------
// Tool surface declaration
// ---------------------------------------------------------------------------

/// The interface tool names (Tier 1–5) plus maintenance tools, in the order
/// they appear in the tool list. Mirrors Swift `InterfaceTools`.
pub const INTERFACE_TOOLS: &[&str] = &[
    // Anthropic memory_20250818 adapter (M-MEMTOOL-1)
    "memory",
    // Tier 1 — Core memory (8)
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
    // Monitoring control (1) — out-of-band sensitivity grants: read/write daemon telemetry flag.
    // Injected via MonitoringControl trait; reports "unavailable" when no store wired.
    "moot_monitoring_status",
    // Maintenance (4)
    "moot_reindex",
    "moot_drain_status",
    "moot_reclassify_fdc",
    "moot_palace_import",
];

/// True when `name` is one of the 20 Tier 1–5 interface tools or the 4
/// Maintenance tools. Mirrors Swift `InterfaceTools.isInterfaceTool`.
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
        VerbDispatchError::EstateQuiesced { estate_uuid } => {
            // Quiesced estates reject all verb calls. The admin plane (moot_quiesce_estate)
            // must not be followed by additional verb calls on the same estate; the caller
            // should drain and close before issuing any further operations.
            format!("the addressed estate ({}) is quiesced and not accepting new work; drain and close it before reuse",
                Uuid::from_bytes(*estate_uuid))
        }
        VerbDispatchError::RecallLaneUnavailable { reason } => {
            // CorpusOnly + FailClosed: the corpus/vector lane is not wired for this
            // estate. Surface as a clear user-facing error so callers can open the
            // estate with a corpus backend or switch to AllowDegraded.
            format!("recall lane unavailable: {reason}")
        }
        VerbDispatchError::SourceDrawerNotFound { drawer_id } => {
            // source_id must name a drawer that exists in this estate, because
            // the filed fact inherits that drawer's sensitivity. Naming a
            // missing drawer is rejected rather than filed at the Normal
            // default, which would over-disclose.
            format!(
                "source_id '{drawer_id}' names no drawer in this estate; \
                 omit source_id to file an unanchored fact"
            )
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
            // Parity with Swift ToolDispatch: LocusKit Rust formats DrawerNotFound
            // as "DrawerNotFound: id='{id}'" while Swift formats it as
            // "drawer not found: {id}". Detect the Rust prefix and reformat to
            // match the Swift message so AI consumers see one shape.
            if let Some(rest) = reason.strip_prefix("DrawerNotFound: id='") {
                let drawer_id = rest.trim_end_matches('\'');
                return format!("drawer not found: {drawer_id}");
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
            // Parity with Swift ToolDispatch: no "row" prefix, trailing period.
            // The caller-facing field is "confirmed" — name it exactly so AI consumers
            // can retry with the correct argument rather than dead-ending on a
            // field name mismatch between this message and the tool schema.
            format!("expunge of {row_id} requires confirmed=true.")
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
///
/// `sensitivity_ledger` is the process-scoped out-of-band sensitivity grants grant ledger, also
/// owned by the `Dispatcher` (mirrors Swift `ToolDispatcher.runMemorySearch`/
/// `runMemoryGet`'s `sensitivityUnlockLedger` threading). Passed to
/// `run_memory_search` and `run_memory_get` so a live restricted/secret
/// grant lifts the substrate's default sensitivity ceiling for those two
/// read paths.
pub fn dispatch(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    sensitivity_ledger: &SensitivityGrantLedger,
    build_serial: &str,
    version_skew: &str,
    // Upstream-release advisory provider — consumed by ping/status only.
    // None when the host wired none (stdio one-shots, tests, aria-mcp dev).
    update_advisory: Option<&crate::dispatcher::UpdateAdvisoryProvider>,
    // monitoring seam injected from the serve host.
    // None when no stats store wired — moot_monitoring_status reports "unavailable".
    monitoring_control: Option<&dyn crate::monitoring_control::MonitoringControl>,
) -> Result<serde_json::Value, JSONRPCError> {
    match name {
        // Anthropic memory_20250818 adapter (M-MEMTOOL-1)
        "memory" => crate::memory_adapter::dispatch_memory(args, registry),
        "moot_file_memory" => run_file_memory(args, registry),
        "moot_memory_search" => run_memory_search(args, registry, ledger, sensitivity_ledger),
        "moot_memory_list" => run_memory_list(args, registry),
        "moot_memory_get" => run_memory_get(args, registry, sensitivity_ledger),
        "moot_update_memory" => run_update_memory(args, registry, ledger),
        "moot_withdraw_memory" => run_withdraw_memory(args, registry, ledger),
        "moot_erase_memory" => run_erase_memory(args, registry),
        "moot_confirm_memory" => run_confirm_memory(args, registry, ledger),
        "moot_move_memory" => run_move_memory(args, registry, ledger),
        "moot_link_memories" => run_link_memories(args, registry),
        "moot_review_tunnel" => run_review_tunnel(args, registry),
        "moot_connection_search" => run_connection_search(args, registry),
        "moot_connection_map" => run_connection_map(args, registry),
        "moot_file_fact" => run_file_fact(args, registry),
        "moot_fact_search" => run_fact_search(args, registry),
        "moot_retire_fact" => run_retire_fact(args, registry),
        "moot_fact_timeline" => run_fact_timeline(args, registry),
        "moot_write_journal" => run_write_journal(args, registry),
        "moot_read_journal" => run_read_journal(args, registry),
        // Pass version_skew so the report includes the plugin-owned MCP connections advisory
        // when present (empty string ⇒ no line appended).
        "moot_estate_status" => run_estate_status(args, registry, version_skew, update_advisory),
        "moot_estate_map" => run_estate_map(args, registry),
        // Pass build_serial so the pong includes the build segment.
        "moot_estate_ping" => run_estate_ping(args, registry, build_serial, version_skew, update_advisory),
        // Monitoring control — pass the injected seam.
        "moot_monitoring_status" => run_monitoring_status(args, monitoring_control),
        // Maintenance
        "moot_reindex" => run_reindex(args, registry),
        "moot_drain_status" => run_drain_status(args, registry),
        "moot_reclassify_fdc" => run_reclassify_fdc(args, registry),
        "moot_palace_import" => run_palace_import(args, registry),
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
/// wing. When absent, defaults to DEFAULT_WING_NAME ("Agentic Memory").
/// Server owns infrastructure fields (channel, lattice, added_by, embeddingModelID).
/// The lattice anchor sentinel is passed to the GeniusLocusKit capture seam
/// (`capture_with_mode`), which classifies via `Fdc::encode_anchor` when the
/// sentinel arrives with non-empty content; UNRESOLVED content keeps the "000"
/// sentinel (one-door principle). Mirrors Swift `runFileMemory`.
fn run_file_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let content = require_string(args, "content")?;
    let location = require_string(args, "location")?;
    // Subject is REQUIRED at this boundary (PR-02): the calling AI is the
    // only party that knows what the content asserts, and a subject written
    // at capture is the cheapest one the estate will ever get. The error is
    // instructive rather than the generic missing-argument text because the
    // fix is a register, not just a field. Mirrors Swift runFileMemory.
    let subject = match args.get("subject").and_then(|v| v.as_str()) {
        Some(s) => s.trim().to_string(),
        None => {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!(
                    "Missing required argument: subject. Provide one sentence \
                     (≤{SUBJECT_LENGTH_CONTRACT} chars) stating what this memory asserts, \
                     written for the NEXT AI that will scan it — telegraphic, entities and \
                     claims front-loaded, no narrative framing. Example: \"Quarterly \
                     planning moved to Thursday; Sarah sends invites Monday.\""
                ),
            ));
        }
    };
    {
        let n = subject.chars().count();
        if n == 0 || n > SUBJECT_LENGTH_CONTRACT {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!(
                    "subject must be 1–{SUBJECT_LENGTH_CONTRACT} characters (got {n}). \
                     One telegraphic sentence in the AI-facing register — compress, \
                     don't truncate."
                ),
            ));
        }
    }
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
    // Subject trio threading (PR-02): boundary-validated above; the LocusKit
    // capture verb stamps pipeline ai-v1 + subject_at from this slot.
    frame.subject = Some(subject);
    // optional `wing` argument routes this memory into a specific wing.
    // When supplied, the drawer files into that wing.
    // When absent, defaults to DEFAULT_WING_NAME ("Agentic Memory") — the AI's
    // working memory wing. Mirrors Swift runFileMemory wing routing.
    frame.wing = Some(
        optional_string(args, "wing")?
            .map(|s| s.to_string())
            .unwrap_or_else(|| DEFAULT_WING_NAME.to_string()),
    );
    // Optional back-dated event time. When supplied, the drawer's event_time
    // is set to the caller's ISO8601 instant (epoch milliseconds, epoch-millisecond instants)
    // instead of the ingest wall-clock time. Mirrors Swift ToolDispatch.runFileMemory
    // which parses event_time to Date and passes it as eventTime on the CaptureFrame.
    if let Some(raw) = optional_string(args, "event_time")? {
        let ms = parse_iso8601_to_ms(&raw).ok_or_else(|| {
            JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("event_time is not a valid ISO8601 instant: {raw}"),
            )
        })?;
        // Bounds check (#16): reject event_time more than 10 years in the
        // past or more than 1 day in the future. An extreme back-date forces
        // the matrix temporal buckets to span a huge range, triggering a full
        // rebuild on every subsequent capture.
        let now_ms = crate::dispatch::wall_now();
        let ten_years_ms: i64 = 10 * 365 * 86_400 * 1_000;
        let one_day_ms: i64 = 86_400 * 1_000;
        if ms < now_ms - ten_years_ms || ms > now_ms + one_day_ms {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "event_time is outside the acceptable range (10 years past to 1 day future)".to_string(),
            ));
        }
        frame.event_time = Some(ms);
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
            // Resolve room display name from the node tree via parent_node_id.
            let node_names = coord.resolve_drawer_node_names(
                &estate.handle,
                &[drawer.parent_node_id.clone()],
            );
            let room = node_names
                .get(&drawer.parent_node_id)
                .map(|(_, r)| r.as_str())
                .unwrap_or("");
            let body = format!(
                "filed memory {}\nroom: {}\nlineage: {}",
                drawer.id, room, drawer.lineage_id
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

/// `true` if `f` constrains sensitivity anywhere in its structure (directly,
/// nested under `All`/`Any`, or negated). Used to suppress the out-of-band sensitivity grants
/// grant-ceiling injection when the caller's own `filter` argument already
/// specifies a sensitivity constraint — an explicit caller constraint
/// always wins over the grant-lifted default. Mirrors Swift
/// `ToolDispatcher.isSensitivityFilter` exactly.
fn is_sensitivity_filter(f: &locus_kit::filter::Filter) -> bool {
    use locus_kit::filter::Filter;
    match f {
        Filter::Sensitivity(_) | Filter::SensitivityAtMost(_) => true,
        Filter::All(fs) | Filter::Any(fs) => fs.iter().any(is_sensitivity_filter),
        Filter::Not(inner) => is_sensitivity_filter(inner),
        _ => false,
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
// ---------------------------------------------------------------------------
// Structured recall results (MXE-SS) — shared by the recall family here and
// in recipe_tools.rs (moot_recall_shaped / moot_recall_precise).
// ---------------------------------------------------------------------------

/// One structured recall row — the typed twin of a rendered row, per the
/// recall family's `outputSchema` (`tool_list::recall_results_output_schema`).
/// Optional fields are OMITTED (never null) when the text analog is absent:
/// room/content on opaque rows, content at memory_get depth:subject, subject
/// at memory_get depth:full when the drawer carries none. Mirrors Swift
/// `ToolDispatcher.StructuredRecallRow`.
pub struct StructuredRow {
    pub id: String,
    pub room: Option<String>,
    pub content: Option<String>,
    pub subject: Option<String>,
}

impl StructuredRow {
    fn as_json(&self) -> serde_json::Value {
        let mut object = serde_json::Map::new();
        object.insert("id".to_string(), serde_json::Value::String(self.id.clone()));
        if let Some(ref room) = self.room {
            object.insert("room".to_string(), serde_json::Value::String(room.clone()));
        }
        if let Some(ref content) = self.content {
            object.insert("content".to_string(), serde_json::Value::String(content.clone()));
        }
        if let Some(ref subject) = self.subject {
            object.insert("subject".to_string(), serde_json::Value::String(subject.clone()));
        }
        serde_json::Value::Object(object)
    }
}

/// MCP `tools/call` success result carrying BOTH the text block —
/// byte-identical to `text_result` — and its typed twin under
/// `structuredContent`, the MCP-sanctioned structured-result mechanism the
/// recall family's `outputSchema` declares. Every redaction the text path
/// applied must already be applied to `results` by the caller; this helper
/// only shapes the envelope. Wire-identical to Swift
/// `ToolDispatcher.structuredTextResult`.
pub fn structured_text_result(
    text: &str,
    results: &[StructuredRow],
) -> serde_json::Value {
    serde_json::json!({
        "content": [{ "type": "text", "text": text }],
        "structuredContent": {
            "results": results.iter().map(|r| r.as_json()).collect::<Vec<_>>()
        },
        "isError": false
    })
}

/// Build the structured row for a drawer the text path renders as a dense
/// row. The subject slot mirrors `dense_row::render`'s priority exactly
/// (redaction marker → stored subject → absence marker), and the SAME
/// provenance redaction extends to the content field: a restricted/secret
/// row's body never enters the structured block — both fields carry the
/// marker the text shows. Content values in hand at the recipe call sites
/// (`PreciseMatch.content`) are PRE-redaction, so they must pass through
/// this switch, never straight into a row. Mirrors Swift
/// `ToolDispatcher.structuredRecallRow`.
pub fn structured_recall_row(
    id: &str,
    room: Option<String>,
    content: Option<String>,
    drawer: &locus_kit::drawer::Drawer,
) -> StructuredRow {
    use locus_kit::provenance::Sensitivity;
    match drawer.sensitivity() {
        Sensitivity::Restricted => StructuredRow {
            id: id.to_string(),
            room,
            content: content.map(|_| crate::dense_row::RESTRICTED_MARKER.to_string()),
            subject: Some(crate::dense_row::RESTRICTED_MARKER.to_string()),
        },
        Sensitivity::Secret => StructuredRow {
            id: id.to_string(),
            room,
            content: content.map(|_| crate::dense_row::SECRET_MARKER.to_string()),
            subject: Some(crate::dense_row::SECRET_MARKER.to_string()),
        },
        _ => StructuredRow {
            id: id.to_string(),
            room,
            content,
            subject: Some(
                drawer
                    .subject
                    .clone()
                    .unwrap_or_else(|| crate::dense_row::NO_SUBJECT_MARKER.to_string()),
            ),
        },
    }
}

/// The structured twin of `dense_row::render_unhydrated` — id plus the
/// absence marker only. Room and content stay absent even when values are in
/// hand at the call site: an id the text renders opaquely (gated or
/// unhydrated) must be exactly as opaque in the structured block. Mirrors
/// Swift `ToolDispatcher.opaqueStructuredRow`.
pub fn opaque_structured_row(id: &str) -> StructuredRow {
    StructuredRow {
        id: id.to_string(),
        room: None,
        content: None,
        subject: Some(crate::dense_row::NO_SUBJECT_MARKER.to_string()),
    }
}

/// Mirrors Swift `ToolDispatch.runMemorySearch` and `decodeOrdering`.
fn run_memory_search(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    ledger: &SurfacedRecallLedger,
    sensitivity_ledger: &SensitivityGrantLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    use genius_locus_kit::recall::{
        GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy,
    };

    let estate = registry.resolve_direct(args)?;
    // Anchor pivot (PR-03): `near:<uuid>` is accepted as an ALTERNATIVE to
    // `query:` — "find memories similar to this one". Exactly one of the two
    // must be present. The anchor's verbatim content becomes the query text
    // through the SAME scored pipeline (full fusion stack), so the fan-out
    // inherits every shape/filter/limit unchanged; the anchor row itself is
    // excluded from the reply. The anchor is fetched under the DEFAULT
    // containment gate (no grant lift, deliberately) AND is then checked
    // against the provenance sensitivity axis: the frame gate covers
    // adjective sensitivity (bits 6–11) only, while `Drawer::sensitivity()`
    // decodes provenance sensitivity (bits 30–35). Both checks are needed —
    // a provenance-Secret row with the default adjective-Normal passes the
    // frame. Pivoting through a restricted/secret anchor's content would leak
    // content-derived neighbors past the redaction boundary, so a gated
    // anchor reads as not-found, byte-identical to an absent id — the same
    // oracle-free shape memory_get uses. Mirrors Swift runMemorySearch.
    let query_arg = optional_string(args, "query")?.map(|s| s.to_string());
    let near_arg = optional_string(args, "near")?.map(|s| s.to_string());
    let (query, anchor_id): (String, Option<String>) = match (query_arg, near_arg) {
        (None, None) => {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "Provide either query (text search) or near (UUID of an anchor memory — \
                 returns the memories most similar to it)."
                    .to_string(),
            ));
        }
        (Some(_), Some(_)) => {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                "query and near are mutually exclusive — pass exactly one.".to_string(),
            ));
        }
        (Some(q), None) => (q, None),
        (None, Some(anchor)) => {
            let coord = estate.coord.lock().unwrap();
            let locus_estate = coord.estate_for(&estate.handle).map_err(|e| {
                JSONRPCError::new(
                    JSONRPCErrorCode::TOOL_DISPATCH_FAILURE,
                    format!("{e:?}"),
                )
            })?;
            let mut frame = RecallFrame::new(vec![]);
            frame.hydration_level = locus_kit::filter::HydrationLevel::Full;
            let fetched = locus_estate
                .get_drawers_matching_frame(&[anchor.clone()], &frame)
                .map_err(|e| JSONRPCError::new(
                    JSONRPCErrorCode::TOOL_DISPATCH_FAILURE,
                    format!("{e}"),
                ))?;
            drop(coord);
            // The provenance reject runs BEFORE the empty-content check, so a
            // gated row and an empty row collapse into the one not-found
            // shape. Ordering discipline and defence in depth: this fetch
            // requests a single id, so `admissible` holds at most one drawer
            // and either order yields the same error today. Should this ever
            // resolve a set, provenance-first is the order that cannot leak.
            let anchor_drawer = fetched
                .admissible
                .into_iter()
                .find(|d| !matches!(
                    d.sensitivity(),
                    locus_kit::provenance::Sensitivity::Restricted
                        | locus_kit::provenance::Sensitivity::Secret
                ))
                .filter(|d| !d.content.is_empty())
                .ok_or_else(|| JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    format!("near: anchor memory not found: {anchor}"),
                ))?;
            (anchor_drawer.content, Some(anchor))
        }
    };
    let query = query.as_str();

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

    // Clamp to [1, 500]: reject negative/zero (crash downstream range ops) and
    // cap absurdly-large values (DoS via unbounded substrate recall scan).
    // Parity: Swift runMemorySearch uses Self.clampLimit with the same ceiling.
    let limit = crate::dispatch::clamp_limit(
        optional_integer(args, "limit")?, "limit", 20, crate::dispatch::LIMIT_HARD_CEILING
    )?;

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
    // Wall-clock time for this request, hoisted here (rather than the later
    // call site this replaces) so the SAME instant gates both the out-of-band sensitivity grants
    // grant check below and `recall_scored` further down — one request, one
    // `now`. Mirrors Swift `runMemorySearch`'s identical hoist.
    let now = wall_now();
    // sensitivity unlock: when a restricted/secret grant is live,
    // inject the grant-lifted ceiling explicitly. This is the seam
    // `BitmapEvaluator::insert_defaults` documents: conditional on absence
    // so an explicit caller sensitivity constraint suppresses this default
    // — by appending our own `SensitivityAtMost` here, the substrate's own
    // narrower default (`Elevated`) never gets inserted. Only applies when
    // the caller's `filter` argument did not already specify a sensitivity
    // constraint of its own. Mirrors Swift `runMemorySearch` exactly.
    let mut sensitivity_ceiling_lifted = false;
    if !filter_chain.iter().any(is_sensitivity_filter) {
        if let Some(ceiling) = sensitivity_ledger.ceiling_sensitivity(now) {
            filter_chain.push(locus_kit::filter::Filter::SensitivityAtMost(ceiling));
            sensitivity_ceiling_lifted = true;
        }
    }
    // optional `wing` argument scopes recall to a single wing.
    // When absent, recall spans all wings (existing default behavior unchanged).
    // Appended to the filter chain so it composes with any explicit filter arg.
    if let Some(wing_name) = optional_string(args, "wing")? {
        filter_chain.push(locus_kit::filter::Filter::InWing(wing_name.to_string()));
    }
    // optional `media_type` argument: constrains recall to drawers that
    // carry a specific media capture type. "voice" → HasVoice (bit 13),
    // "image" → HasImage (bit 14). Composable with `filter` and `wing`.
    // Re-homed from moot_recollect (retired Wave 1).
    // Feature-flag adoption §4. Mirrors Swift runMemorySearch.
    if let Some(media_type) = optional_string(args, "media_type")? {
        use locus_kit::drawer_operational::DrawerFeatureFlags;
        match media_type {
            "voice" => filter_chain.push(locus_kit::filter::Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_VOICE)),
            "image" => filter_chain.push(locus_kit::filter::Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_IMAGE)),
            unknown => return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("Unknown media_type: {unknown}. Valid: voice, image"),
            )),
        }
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

    // `mut`: out-of-band sensitivity grants read-under-grant audit recording below needs a
    // mutable coordinator borrow (audit append is a coordinator-owned
    // HashMap mutation), in addition to the existing immutable
    // `recall_scored`/`resolve_drawer_node_names` reads later in this
    // function (both still work through the same `&mut` binding — a `mut`
    // binding can call `&self` methods too).
    let mut coord = estate.coord.lock().unwrap();

    let mut result = coord
        .recall_scored(&estate.handle, request, now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;
    // Anchor exclusion (PR-03): a near: pivot must not hand the anchor back
    // as its own top neighbor. Every consumer below (ledger, discrimination
    // scores, rendering, count) works from the filtered list.
    if let Some(ref anchor) = anchor_id {
        result.hits.retain(|h| h.id != *anchor);
    }

    // Record surfaced drawer ids in the session ledger so dereference verbs can
    // trigger reward-trace marking (DESIGN_TRACE_REWARD_2026-06-12.md §session-ledger).
    let surfaced_ids: Vec<String> = result.hits.iter()
        .filter_map(|h| h.drawer.as_ref().map(|d| d.id.clone()))
        .collect();
    if !surfaced_ids.is_empty() {
        ledger.record_surfaced(&surfaced_ids, now);
    }

    // record a sensitivity_read_under_grant audit entry for each
    // hit admitted PAST the substrate's default ceiling specifically
    // because a grant is live. Only rows whose OWN adjective sensitivity is
    // restricted/secret qualify — an elevated-or-below row would have been
    // admitted regardless of any grant, so recording it here would
    // misrepresent "read under grant" as having happened when it did not.
    // Gated on `sensitivity_ceiling_lifted` so a query with no live grant
    // never emits. Mirrors Swift `runMemorySearch`'s identical guard.
    if sensitivity_ceiling_lifted {
        for hit in &result.hits {
            let Some(drawer) = hit.drawer.as_ref() else { continue };
            match drawer.adjective_sensitivity() {
                locus_kit::adjectives::AdjectiveSensitivity::Restricted
                | locus_kit::adjectives::AdjectiveSensitivity::Secret => {
                    let _ = coord.record_sensitivity_read_under_grant(
                        &estate.handle,
                        drawer.adjective_sensitivity(),
                        &drawer.id,
                        now,
                    );
                }
                locus_kit::adjectives::AdjectiveSensitivity::Normal
                | locus_kit::adjectives::AdjectiveSensitivity::Elevated => {}
            }
        }
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

    // Dense-row reply (PR-03): UUID · subject · fdc · qid · event_time per
    // hit — the address plus the assertion, no content hauling. Redaction
    // (provenance sensitivity restricted/secret) replaces the subject field
    // inside dense_row::render — the body's access control must not be
    // bypassable through its content-derived summary. The full text is one
    // hop away via moot_memory_get depth:full. Mirrors Swift runMemorySearch.
    let mut lines = vec![format!("found {} memory(s)", result.hits.len())];
    // Structured twin (MXE-SS): room is resolved in ONE batched node-name
    // read over the shown rows (the same resolution
    // `memory_get_full_record_lines` uses per drawer) — disclosed in the BRR
    // §Part 0 (2). Rows are built in the SAME loop as the text lines so the
    // two blocks can never cover different sets. Mirrors Swift
    // runMemorySearch.
    let shown_parent_ids: Vec<String> = {
        let mut seen = std::collections::HashSet::new();
        result.hits.iter().take(50)
            .filter_map(|h| h.drawer.as_ref().map(|d| d.parent_node_id.clone()))
            .filter(|p| seen.insert(p.clone()))
            .collect()
    };
    let search_node_names =
        coord.resolve_drawer_node_names(&estate.handle, &shown_parent_ids);
    let mut results: Vec<StructuredRow> = Vec::new();
    for hit in result.hits.iter().take(50) {
        match hit.drawer.as_ref() {
            Some(d) => {
                lines.push(crate::dense_row::render(d));
                results.push(structured_recall_row(
                    &d.id,
                    search_node_names.get(&d.parent_node_id).map(|(_, room)| room.clone()),
                    Some(d.content.clone()),
                    d,
                ));
            }
            None => {
                lines.push(crate::dense_row::render_unhydrated(&hit.id));
                results.push(opaque_structured_row(&hit.id));
            }
        }
    }
    // Deviation-only narration (PR-03): the discrimination line appears ONLY
    // when the EFFECTIVE signal is low or medium (the dense-lane-dark cap is
    // applied first so a dark-capped high still surfaces as medium+caveat).
    // A clear top result and the single/zero case stay silent — the advisory
    // paragraph lives in the tool description now.
    let effective = if dense_lane_dark
        && discrimination == crate::recall_discrimination::DiscriminationLevel::High
    {
        crate::recall_discrimination::DiscriminationLevel::Medium
    } else {
        discrimination
    };
    if matches!(
        effective,
        crate::recall_discrimination::DiscriminationLevel::Low
            | crate::recall_discrimination::DiscriminationLevel::Medium
    ) {
        lines.push(crate::recall_discrimination::result_line_with_dense_dark(discrimination, dense_lane_dark));
    }
    // Recall provenance — DEVIATION-ONLY (PR-03): the line appears only when
    // something is off-nominal (dense lane dark, or degraded stages). Its
    // absence now MEANS nominal. The response labels embedding provenance
    // accurately whenever it deviates. Mirrors Swift runMemorySearch.
    if result.dense_lane_status.is_some() || !result.degraded_stages.is_empty() {
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
    }
    // Sensitivity-gate advisory — conditioned on GRANT STATE ALONE.
    // When no grant is live the gate is in effect, so the client is told
    // the gate exists and which commands lift it. The message asserts
    // NOTHING about what this estate holds: any condition that consulted
    // estate contents would make advisory presence a disclosure channel
    // for exactly the restricted/secret rows the gate protects, to a
    // caller with no grant. Emitting on grant state alone discloses
    // nothing — the caller is the party that did not unlock, so they
    // already know it. Gated on `!sensitivity_ceiling_lifted`: under a live
    // grant those rows are already included and no advisory applies.
    // Mirrors Swift `runMemorySearch`.
    if !sensitivity_ceiling_lifted {
        lines.push(
            "sensitivity_advisory: a sensitivity tier gate is in effect — \
             run `mootx01 unlock private` to include restricted memories, \
             `mootx01 unlock secret` for secret memories.".to_string()
        );
    }
    Ok(structured_text_result(&lines.join("\n"), &results))
}

/// `moot_memory_get` — fetch one memory drawer by id, in full.
///
/// Closes the "fetch-drawer-by-ID" MCP API gap — build-now per Bob's
/// ruling, not deferred to v1.1.
///
/// Reifies the ARIA `recall` verb (docs/concepts/ARIA_LEXICON.md) applied to
/// the Drawer noun, constrained by an exact identifier rather than free-text
/// criteria — `moot_memory_search`'s degenerate, precise sibling. Named
/// `memory_get` (noun_verb) per the lexicon's naming discipline: "an action
/// tool is verb_noun, a query tool is noun_verb." Mirrors Swift
/// `ToolDispatcher.runMemoryGet` exactly.
///
/// Routes through the same frame-faithful by-id load
/// (`Estate::get_drawers_matching_frame`, LocusKit — the Rust peer of Swift
/// `Estate.getDrawers(ids:matchingFrame:hydrationLevel:)`) that backs
/// `moot_memory_search`'s recall pipeline, with an EMPTY filter chain so
/// `BitmapEvaluator`'s default gate applies unchanged: currentlyBelieve
/// state, trustworthy trust, sensitivityAtMost(Elevated) — the IDENTICAL
/// gate `moot_memory_search` applies by default. A drawer that exists but
/// fails that gate is reported exactly like a genuinely absent id: "Memory
/// not found: <id>". This is deliberate — the by-id door must not become a
/// way to confirm the EXISTENCE of content the estate would otherwise
/// refuse to surface. Tombstoned rows are always excluded, independent of
/// the chain.
///
/// Hydration is `Full` for drawers that pass both gates — never `Structured`,
/// which strips the content blob this tool exists to return. Provenance
/// `Sensitivity::Restricted` and `Sensitivity::Secret` remain access-controlled
/// at the MCP boundary and are reported with the same not-found shape as other
/// gate failures. A live sensitivity grant lifts the ADJECTIVE ceiling ONLY —
/// the provenance gate is unconditional and does not consult the grant ledger,
/// matching Swift `ToolDispatcher.runMemoryGet` (conformance parity: if that
/// ruling is revisited, both verticals change together).
fn run_memory_get(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
    sensitivity_ledger: &SensitivityGrantLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    // Hydration depth (PR-03): one verb, three tiers — subject (dense row
    // only, travel), distilled (dense row + distilled rendering, confirm;
    // content fallback carries an explicit marker), full (complete record,
    // the DEFAULT — preserves the pre-PR-03 single-id reply shape). Batch
    // `ids:[...]` makes the Case-2 winnow one call. Mirrors Swift
    // runMemoryGet.
    let depth = optional_string(args, "depth")?.unwrap_or("full").to_string();
    if !["subject", "distilled", "full"].contains(&depth.as_str()) {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown depth: {depth}. Valid: subject, distilled, full"),
        ));
    }
    let mut row_ids: Vec<String> = Vec::new();
    if let Some(single) = optional_string(args, "id")? {
        row_ids.push(single.to_string());
    }
    if let Some(JsonValue::Array(raw_ids)) = args.get("ids") {
        for raw in raw_ids {
            match raw.as_str() {
                Some(s) => row_ids.push(s.to_string()),
                None => {
                    return Err(JSONRPCError::new(
                        JSONRPCErrorCode::INVALID_PARAMS,
                        "ids must be an array of memory UUID strings".to_string(),
                    ));
                }
            }
        }
    }
    if row_ids.is_empty() {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            "Provide id (single memory UUID) or ids (array of UUIDs).".to_string(),
        ));
    }
    let single_id_mode = row_ids.len() == 1;
    let row_id = row_ids[0].clone();
    let row_id = row_id.as_str();

    // `mut`: out-of-band sensitivity grants read-under-grant audit recording below needs a
    // mutable coordinator borrow. `locus_estate`'s immutable borrow (just
    // below) ends at its last use (`get_drawers_matching_frame`), well
    // before the mutable audit call, so this does not conflict — same
    // pattern as `run_memory_search` above.
    let mut coord = estate.coord.lock().unwrap();
    let locus_estate = coord.estate_for(&estate.handle).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, crate::dispatch::describe_glk_error(&e))
    })?;

    let now = wall_now();
    // sensitivity unlock: same grant-ceiling injection as
    // run_memory_search — see that function's comment. moot_memory_get
    // deliberately uses the SAME containment gate moot_memory_search does,
    // so the grant must lift it here too, or an unlocked restricted/secret
    // row would be visible in search but still "not found" by id — an
    // inconsistent, confusing half-unlock. Mirrors Swift `runMemoryGet`.
    let mut filter_chain: Vec<locus_kit::filter::Filter> = vec![];
    let mut sensitivity_ceiling_lifted = false;
    if let Some(ceiling) = sensitivity_ledger.ceiling_sensitivity(now) {
        filter_chain.push(locus_kit::filter::Filter::SensitivityAtMost(ceiling));
        sensitivity_ceiling_lifted = true;
    }
    let mut frame = RecallFrame::new(filter_chain);
    frame.hydration_level = locus_kit::filter::HydrationLevel::Full;
    let filtered = locus_estate
        .get_drawers_matching_frame(&row_ids, &frame)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e}")))?;

    // Provenance-sensitivity redaction boundary for by-id reads: the frame
    // gate above checks adjective sensitivity (bits 6–11);
    // Drawer::sensitivity() decodes provenance sensitivity (bits 30–35),
    // where Restricted/Secret content is access-controlled and must not be
    // returned verbatim. Gated rows use the standard not-found shape so
    // by-id lookup is not an oracle for hidden rows. Mirrors Swift.
    let admissible_by_id: BTreeMap<String, locus_kit::drawer::Drawer> = filtered
        .admissible
        .into_iter()
        .filter(|d| !matches!(
            d.sensitivity(),
            locus_kit::provenance::Sensitivity::Restricted
                | locus_kit::provenance::Sensitivity::Secret
        ))
        .map(|d| (d.id.clone(), d))
        .collect();

    // Single-id compat: the original thrown not-found stays. In batch mode
    // gate failures become per-row "not found:" lines instead — fail-loud
    // without sinking the whole winnow call.
    if single_id_mode && !admissible_by_id.contains_key(row_id) {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Memory not found: {row_id}"),
        ));
    }

    // Batch / shallow-depth rendering (PR-03). depth:full + single id falls
    // through to the original full record below.
    if !single_id_mode || depth != "full" {
        let mut lines: Vec<String> = Vec::new();
        // Structured twin (MXE-SS): one batched node-name read for room over
        // the admissible rows. Not-found ids are omitted from the structured
        // block — the text's "not found:" line is the signal, and the row
        // has no drawer fields to carry. Mirrors Swift runMemoryGet.
        let get_parent_ids: Vec<String> = {
            let mut seen = std::collections::HashSet::new();
            row_ids.iter()
                .filter_map(|id| admissible_by_id.get(id).map(|d| d.parent_node_id.clone()))
                .filter(|p| seen.insert(p.clone()))
                .collect()
        };
        let get_node_names = coord.resolve_drawer_node_names(&estate.handle, &get_parent_ids);
        let mut results: Vec<StructuredRow> = Vec::new();
        for id in &row_ids {
            let Some(d) = admissible_by_id.get(id) else {
                lines.push(format!("not found: {id}"));
                continue;
            };
            if sensitivity_ceiling_lifted {
                match d.adjective_sensitivity() {
                    locus_kit::adjectives::AdjectiveSensitivity::Restricted
                    | locus_kit::adjectives::AdjectiveSensitivity::Secret => {
                        let _ = coord.record_sensitivity_read_under_grant(
                            &estate.handle,
                            d.adjective_sensitivity(),
                            &d.id,
                            now,
                        );
                    }
                    _ => {}
                }
            }
            let room = get_node_names.get(&d.parent_node_id).map(|(_, room)| room.clone());
            match depth.as_str() {
                "subject" => {
                    lines.push(crate::dense_row::render(d));
                    // Content stays ABSENT at the travel tier — the text
                    // carries no body here, and the structured block must
                    // not defeat the depth knob's token economy.
                    results.push(structured_recall_row(&d.id, room, None, d));
                }
                "distilled" => {
                    lines.push(crate::dense_row::render(d));
                    match d.distilled.as_deref() {
                        Some(text) if !text.is_empty() => {
                            lines.push(text.to_string());
                            results.push(structured_recall_row(
                                &d.id, room, Some(text.to_string()), d));
                        }
                        _ => {
                            // Fallback marker on fallback hits ONLY (PR-03
                            // deviation-only contract): the text below is
                            // verbatim content, not a distillate.
                            lines.push("source: content (not yet distilled)".to_string());
                            lines.push(d.content.clone());
                            results.push(structured_recall_row(
                                &d.id, room, Some(d.content.clone()), d));
                        }
                    }
                }
                _ => {
                    // depth:full in batch mode — repeat the full record shape.
                    lines.extend(memory_get_full_record_lines(&mut coord, &estate.handle, d)?);
                    // Full-record tier: subject mirrors the text's deviation
                    // tolerance — the record omits the subject line when the
                    // drawer has none, so the field is omitted too.
                    // Provenance-gated rows cannot reach here
                    // (admissible_by_id excludes them), so the row is built
                    // directly, not via the marker switch.
                    results.push(StructuredRow {
                        id: d.id.clone(),
                        room,
                        content: Some(d.content.clone()),
                        subject: d.subject.clone(),
                    });
                }
            }
            lines.push(String::new());
        }
        if lines.last().map(|s| s.is_empty()).unwrap_or(false) {
            lines.pop();
        }
        return Ok(structured_text_result(&lines.join("\n"), &results));
    }

    let drawer = admissible_by_id.get(row_id).cloned().expect("guarded above");

    // same read-under-grant audit recording as
    // run_memory_search — gated on BOTH the ceiling having been lifted AND
    // the drawer's own sensitivity actually being restricted/secret.
    if sensitivity_ceiling_lifted {
        match drawer.adjective_sensitivity() {
            locus_kit::adjectives::AdjectiveSensitivity::Restricted
            | locus_kit::adjectives::AdjectiveSensitivity::Secret => {
                let _ = coord.record_sensitivity_read_under_grant(
                    &estate.handle,
                    drawer.adjective_sensitivity(),
                    &drawer.id,
                    now,
                );
            }
            locus_kit::adjectives::AdjectiveSensitivity::Normal
            | locus_kit::adjectives::AdjectiveSensitivity::Elevated => {}
        }
    }

    let mut lines = memory_get_full_record_lines(&mut coord, &estate.handle, &drawer)?;

    // Sensitivity-gate advisory — same rule as run_memory_search: grant
    // state alone, never estate contents. It matters more here than in
    // search, because this reply follows a SUCCESSFUL fetch of a visible
    // row; a contents-dependent advisory would attach an estate-wide
    // existence signal to that reply, which is precisely what this
    // function's containment contract (see its doc comment: gated rows
    // must be indistinguishable from absent ones) forbids.
    // Mirrors Swift `ToolDispatcher.runMemoryGet`.
    if !sensitivity_ceiling_lifted {
        lines.push(
            "sensitivity_advisory: a sensitivity tier gate is in effect on this estate — \
             run `mootx01 unlock private` to include restricted memories, \
             `mootx01 unlock secret` for secret memories.".to_string()
        );
    }
    // Structured twin (MXE-SS) of the single-id full record. The node tree
    // is consulted a second time here (memory_get_full_record_lines resolves
    // internally but returns rendered lines); one extra by-id lookup is
    // preferred over widening that function's signature. Subject is omitted
    // when the drawer has none, mirroring the record's omitted subject line;
    // provenance-gated rows cannot reach here (admissible_by_id excludes
    // them). Mirrors Swift runMemoryGet.
    let get_node_names =
        coord.resolve_drawer_node_names(&estate.handle, &[drawer.parent_node_id.clone()]);
    let row = StructuredRow {
        id: drawer.id.clone(),
        room: get_node_names.get(&drawer.parent_node_id).map(|(_, room)| room.clone()),
        content: Some(drawer.content.clone()),
        subject: drawer.subject.clone(),
    };
    Ok(structured_text_result(&lines.join("\n"), &[row]))
}

/// The full-record block for one drawer — the depth:full tier and the
/// original single-id moot_memory_get reply shape. Shared by the single-id
/// path and the batch depth:full path. Mirrors Swift `fullRecordLines`.
fn memory_get_full_record_lines(
    coord: &mut std::sync::MutexGuard<'_, genius_locus_kit::EstateCoordinator>,
    handle: &genius_locus_kit::EstateHandle,
    drawer: &locus_kit::drawer::Drawer,
) -> Result<Vec<String>, JSONRPCError> {
    // Drawer no longer carries stored wing/room; resolve via the
    // node tree, same pattern as every other read tool in this file.
    let node_names = coord.resolve_drawer_node_names(handle, &[drawer.parent_node_id.clone()]);
    let (wing, room) = node_names.get(&drawer.parent_node_id).cloned().unwrap_or_default();

    // Linked tunnel summary: estate-wide scan filtered to confirmed-active,
    // non-tombstoned tunnels touching this drawer on either end.
    // Lifecycle gate (FIND4 residual): proposed, withdrawn, and superseded
    // tunnels are excluded at the MCP boundary so AI clients see only
    // confirmed edges — the same gate moot_connection_search/moot_connection_map
    // enforce.
    let all_tunnels = coord
        .all_tunnels(handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;
    let row_id = drawer.id.as_str();
    let linked: Vec<_> = all_tunnels
        .iter()
        .filter(|t| {
            (t.source_drawer_id.as_deref() == Some(row_id) || t.target_drawer_id.as_deref() == Some(row_id))
                && t.tombstoned_at.is_none()
                && t.lifecycle() == locus_kit::tunnel_operational::TunnelLifecycle::Active
        })
        .collect();

    let mut lines = vec![
        format!("memory {}", drawer.id),
        format!("room: {room}  wing: {wing}"),
    ];
    // Subject line (PR-03): present only when the drawer carries one — the
    // full record is deviation-tolerant, absence simply omits the line (the
    // dense tiers show the absence marker). Mirrors Swift fullRecordLines.
    if let Some(ref subject) = drawer.subject {
        lines.push(format!("subject: {subject}"));
    }
    lines.extend(vec![
        format!("filed_at: {}", epoch_to_iso8601(drawer.filed_at)),
        format!("event_time: {}", epoch_to_iso8601(drawer.event_time)),
        format!("state: {:?}", drawer.state()).to_lowercase(),
        format!("trust: {:?}", drawer.trust()).to_lowercase(),
        format!("sensitivity: {:?}", drawer.adjective_sensitivity()).to_lowercase(),
        format!("exportability: {:?}", drawer.exportability()).to_lowercase(),
        format!("confirmation: {:?}", drawer.confirmation()).to_lowercase(),
        format!("lineage: {}", drawer.lineage_id),
        format!("tunnels: {}", linked.len()),
    ]);
    for tunnel in linked.iter().take(50) {
        let outgoing = tunnel.source_drawer_id.as_deref() == Some(row_id);
        let other = if outgoing {
            tunnel.target_drawer_id.clone().unwrap_or_else(|| format!("{}/{}", tunnel.target_wing, tunnel.target_room))
        } else {
            tunnel.source_drawer_id.clone().unwrap_or_else(|| format!("{}/{}", tunnel.source_wing, tunnel.source_room))
        };
        lines.push(format!("  {} {}  [{}]", if outgoing { "→" } else { "←" }, other, tunnel.label));
    }
    // Verbatim content, on its own trailing block — never truncated or
    // previewed (that is moot_memory_search's job). This is the field the
    // tool exists to return.
    lines.push("content:".to_string());
    lines.push(drawer.content.clone());
    Ok(lines)
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
        // Retention window: 30 days. `surfaced_at_secs` and `now` are epoch-ms
        // (epoch-millisecond instants; the `_secs` suffix is legacy naming), so the window is in ms.
        let since_ms = entry.surfaced_at_secs - 30 * 24 * 60 * 60 * 1000;
        let since = unix_epoch_ms_to_iso8601(since_ms);
        let now_str = unix_epoch_ms_to_iso8601(now);
        if let Ok(coord) = estate.coord.lock() {
            // Silently ignore errors — reward marking is best-effort.
            let _ = coord.mark_recall_used(&estate.handle, id, &since, &now_str);
        }
    }
}

/// Convert Unix epoch MILLISECONDS to an ISO 8601 string (UTC,
/// second precision — the reward window spans 30 days, so sub-second precision
/// is immaterial here). Used for the `since` and `now` parameters of
/// `mark_recall_used` which expects TEXT ISO8601 dates (fleet date rule).
fn unix_epoch_ms_to_iso8601(ms: i64) -> String {
    // Manual conversion — no external crate (zero-dep rule).
    // Gregorian calendar arithmetic for the range 1970–2106.
    let s = ms.max(0) as u64 / 1000;
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
    let estate = registry.resolve_direct(args)?;
    let id = require_string(args, "id")?;
    let mutation_str = require_string(args, "mutation")?;

    let kind = if mutation_str == "setSubject" {
        // setSubject carries its payload in a dedicated `subject` arg; the
        // `note` arg is read below and forwarded as the mutate payload —
        // the audit annotation — as for every other mutation.
        // Boundary-validated here so the caller gets the register
        // guidance, not the bare store error. Mirrors Swift runUpdateMemory.
        let subject = match args.get("subject").and_then(|v| v.as_str()) {
            Some(s) => s.trim().to_string(),
            None => {
                return Err(JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_PARAMS,
                    format!(
                        "mutation=setSubject requires a `subject` argument: one sentence \
                         (≤{SUBJECT_LENGTH_CONTRACT} chars) in the AI-facing register — \
                         telegraphic, entities and claims front-loaded."
                    ),
                ));
            }
        };
        let n = subject.chars().count();
        if n == 0 || n > SUBJECT_LENGTH_CONTRACT {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!(
                    "subject must be 1–{SUBJECT_LENGTH_CONTRACT} characters (got {n}). \
                     Compress, don't truncate."
                ),
            ));
        }
        MutationKind::SetSubject(subject)
    } else {
        decode_mutation_kind(mutation_str)?
    };
    // The optional `note` argument is the caller's audit annotation,
    // forwarded as the mutate payload so it reaches the sealed audit
    // row's `reason` column. Mirrors Swift runUpdateMemory's
    // `optionalString(args["note"], ...)` → MutateFrame.payload.
    let note = optional_string(args, "note")?;
    // Note usage before acquiring the coord lock so note_usage can also lock.
    note_usage(id, &estate, ledger);
    let coord = estate.coord.lock().unwrap();
    match coord.mutate(&estate.handle, id, kind, note.as_deref()) {
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
    let estate = registry.resolve_direct(args)?;
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
    let estate = registry.resolve_direct(args)?;
    let id = require_string(args, "id")?;
    let reason = require_string(args, "reason")?;
    let confirmed = optional_bool(args, "confirmed")?.unwrap_or(false);

    if !confirmed {
        // Security gate (Item 1 hardening): refuse at the AriaMcpKit boundary
        // before calling the substrate. Prevents prompt-injected agents from
        // triggering irreversible erasure without explicit owner acknowledgement.
        // Mirrors Swift ToolDispatcher.runEraseMemory. Both ports enforce this
        // gate at the ARIA surface rather than relying solely on the substrate.
        return Ok(error_result(
            &format!("expunge of {id} requires confirmed=true and a reason. \
                Set confirmed=true only after the owner has explicitly reviewed \
                and approved the deletion."),
        ));
    }

    let coord = estate.coord.lock().unwrap();
    // Wall-clock `now` enters at the ARIA boundary; the deferred-seal expunge
    // (§B-2a) threads it so the success-audit timestamp is deterministic downstream.
    let now = wall_now();
    match coord.expunge(&estate.handle, id, reason, confirmed, now) {
        // Honest reporting (SPEC B-8b, MXE-FA): a caller acting on this
        // sentence is making a privacy decision on it. When the audit gate
        // refused accepted lineage siblings, the expunge was partial — say
        // so, name the count, and name the surviving ids. The full-success
        // shape stays byte-identical to the historical response. Mirrors
        // Swift `runEraseMemory`.
        Ok(outcome) if !outcome.refused_sibling_ids.is_empty() => {
            let refused = &outcome.refused_sibling_ids;
            Ok(text_result(&format!(
                "partially erased memory {id}: {} accepted lineage sibling(s) \
                 refused erasure and remain readable: {}",
                refused.len(),
                refused.join(", ")
            )))
        }
        Ok(_) => Ok(text_result(&format!("erased memory {id}"))),
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
    let estate = registry.resolve_direct(args)?;
    let id = require_string(args, "id")?;
    // The optional `note` argument is the caller's audit annotation,
    // forwarded as the mutate payload. Mirrors Swift runConfirmMemory.
    let note = optional_string(args, "note")?;

    // Note usage: confirming a surfaced drawer means the user acted on it.
    note_usage(id, &estate, ledger);
    let coord = estate.coord.lock().unwrap();
    match coord.mutate(&estate.handle, id, MutationKind::Confirm, note.as_deref()) {
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
    let estate = registry.resolve_direct(args)?;
    let id = require_string(args, "id")?;
    let location = require_string(args, "location")?;
    // optional `wing` triggers a cross-wing move.
    // When absent, only the room changes and the wing stays unchanged.
    let wing = optional_string(args, "wing")?;

    // Note usage: moving a surfaced drawer means the user acted on it.
    note_usage(id, &estate, ledger);
    let coord = estate.coord.lock().unwrap();
    match coord.reanchor(&estate.handle, id, Some(location), wing, None) {
        Ok(()) => {
            let msg = if let Some(w) = wing {
                format!("moved memory {id} to {w}/{location}")
            } else {
                format!("moved memory {id} to {location}")
            };
            Ok(text_result(&msg))
        }
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
    let estate = registry.resolve_direct(args)?;
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
    // Explicit limit=256 (the engine's RECALL_CANDIDATE_CAP scan bound) so the
    // coordinator.recall cap doesn't silently truncate to 50 on large estates;
    // this ID-resolution path needs the full candidate set, not an analytics sample.
    let mut id_lookup_frame = RecallFrame::new(vec![]);
    id_lookup_frame.limit = Some(256);
    let all = coord
        .recall(&estate.handle, id_lookup_frame, now)
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
    // Resolve wing/room display names from node tree for both endpoints.
    let node_names = coord.resolve_drawer_node_names(
        &estate.handle,
        &[source.parent_node_id.clone(), target.parent_node_id.clone()],
    );
    let (src_wing, src_room) = node_names
        .get(&source.parent_node_id)
        .cloned()
        .unwrap_or_default();
    let (tgt_wing, tgt_room) = node_names
        .get(&target.parent_node_id)
        .cloned()
        .unwrap_or_default();
    let mut frame = TunnelCaptureFrame::new(
        src_wing,
        src_room,
        tgt_wing,
        tgt_room,
        kind_str,
        // Injected host identity: stamps provenance for the running binary.
        registry.server_identity.as_str(),
    );
    frame.source_drawer_id = Some(from_id.to_string());
    frame.target_drawer_id = Some(to_id.to_string());
    frame.kind = tunnel_kind;
    // `proposed: true` files the link in the PROPOSED lifecycle — the
    // agent-adjudication path: the caller judged a borderline candidate from
    // moot_hunt_contradictions and records the verdict as a reviewable
    // proposal instead of an immediately-active edge. The user settles it
    // via moot_review_tunnel. Mirrors Swift `runLinkMemories`.
    let proposed = optional_bool(args, "proposed")?.unwrap_or(false);
    if proposed {
        frame.lifecycle = locus_kit::tunnel_operational::TunnelLifecycle::Proposed;
    }

    // Access the estate directly for tunnel capture (not via coordinator, which
    // has no capture_tunnel wrapper — the estate_verbs surface exposes it).
    // coord.estate_for returns GeniusLocusKitError (not VerbDispatchError), so
    // route through describe_glk_error to surface a clean English reason.
    let locus_estate = coord.estate_for(&estate.handle).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, crate::dispatch::describe_glk_error(&e))
    })?;

    match locus_estate.capture_tunnel(frame, now) {
        Ok(tunnel) => {
            let state_note = if proposed {
                " [proposed — review via moot_review_tunnel]"
            } else {
                ""
            };
            let body = format!(
                "linked {from_id} → {to_id} via {kind_str} ({}){state_note}",
                tunnel.id
            );
            Ok(text_result(&body))
        }
        // LocusKitError has Display — surface the English reason without
        // leaking internal Rust enum variant names to the agent.
        Err(e) => Ok(error_result(&format!("link_memories failed: {e}"))),
    }
}

/// Map a proposal's label family to the tier lens recorded on a
/// review-ladder vote. The label-family contract is GLK's
/// (`rejection_tier_of_label`: "dcp: " → tier 1, "tier2:" → 2,
/// "tier3:" → 3). Labels outside the matrix family (hunter-filed,
/// agent-filed) default to tier 3 — the weakest epistemic class, so a
/// vote on an unlabeled proposal never inflates its standing. Parity:
/// Swift `ToolDispatcher.tierLens(forLabel:)`.
fn tier_lens_for_label(
    label: &str,
) -> genius_locus_kit::brain::tiered_contradiction_search::ContradictionTier {
    use genius_locus_kit::brain::conflict_projection_sweep::rejection_tier_of_label;
    use genius_locus_kit::brain::tiered_contradiction_search::ContradictionTier;
    match rejection_tier_of_label(label) {
        Some(1) => ContradictionTier::TypedProven,
        Some(2) => ContradictionTier::LexicalStructural,
        _ => ContradictionTier::LexicalValue,
    }
}

/// Review a PROPOSED tunnel on the MXE-CT3 review ladder (Rejected /
/// Proposed / Endorsed / Accepted):
///
/// - `accept` (user-only): activates via the existing
///   `respond_to_tunnel` path, recording `reviewed_by` in the review
///   ledger. Edge activation is human-authoritative — a model reviewer
///   can NEVER activate, no matter how many endorsements accumulate.
/// - `reject` with `reviewed_by` "user": withdraws permanently
///   (durable dedup — never re-proposed).
/// - `reject` with a model `reviewed_by`: the AI-objection path
///   (`object_to_tunnel`) — withdraws only when no model endorsement
///   exists (reopenable); otherwise the tunnel stays proposed and is
///   marked contested for user attention.
/// - `endorse` (any reviewer, user included): records an endorsement
///   vote (`endorse_tunnel`) without touching lifecycle; weight feeds
///   review-queue ranking only.
///
/// Mirrors Swift `runReviewTunnel`.
fn run_review_tunnel(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let tunnel_id = require_string(args, "tunnel_id")?;
    let verdict = require_string(args, "verdict")?;
    if verdict != "accept" && verdict != "reject" && verdict != "endorse" {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            "verdict must be \"accept\", \"reject\", or \"endorse\"".to_string(),
        ));
    }
    let reviewed_by = optional_string(args, "reviewed_by")?.unwrap_or("user");
    if reviewed_by.is_empty() {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            "reviewed_by must be a non-empty string".to_string(),
        ));
    }
    // The ladder's one hard wall, enforced at the public boundary:
    // edge activation is user-only. Models endorse or reject.
    if verdict == "accept" && reviewed_by != "user" {
        return Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            "edge activation is user-only — verdict \"accept\" requires reviewed_by \"user\"; model reviewers use \"endorse\" or \"reject\"".to_string(),
        ));
    }
    let reason = optional_string(args, "reason")?;

    // Review timestamps are wall-clock: this tool is a live I/O surface
    // (no `now` argument), and the deterministic engines receive the
    // instant from here, the I/O boundary.
    let now = wall_now();
    let coord = estate.coord.lock().unwrap();
    let locus_estate = coord.estate_for(&estate.handle).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, crate::dispatch::describe_glk_error(&e))
    })?;

    // Tier lens for ladder votes, derived from the proposal's label
    // family. A missing tunnel falls through to the GLK verb, which
    // owns the not-found error (single validation source).
    let label = locus_estate
        .get_tunnel(tunnel_id)
        .ok()
        .flatten()
        .map(|t| t.label)
        .unwrap_or_default();
    let lens = tier_lens_for_label(&label);

    if verdict == "endorse" {
        return match coord.endorse_tunnel(&estate.handle, tunnel_id, reviewed_by, lens, now) {
            Ok((_new_endorser, distinct_endorsers, contested)) => {
                let contested_note = if contested { ", contested" } else { "" };
                Ok(text_result(&format!(
                    "moot_review_tunnel: {tunnel_id} endorsed by {reviewed_by} (distinct endorsers: {distinct_endorsers}{contested_note})."
                )))
            }
            // Not-found and not-proposed are caller errors, surfaced as
            // clean tool-level messages rather than opaque failures.
            Err(e) => Ok(error_result(&format!(
                "moot_review_tunnel: {}",
                describe_verb_dispatch_error(&e)
            ))),
        };
    }
    if verdict == "reject" && reviewed_by != "user" {
        // AI rejection semantics: an objection, not a user verdict.
        return match coord.object_to_tunnel(&estate.handle, tunnel_id, reviewed_by, lens, now) {
            Ok((withdrawn, _contested)) => {
                let text = if withdrawn {
                    format!("objected by {reviewed_by} — withdrawn (no model endorsement on record; the user can reopen it)")
                } else {
                    format!("objected by {reviewed_by} — contested: a model endorsement exists, so the proposal stays for user review")
                };
                Ok(text_result(&format!("moot_review_tunnel: {tunnel_id} {text}.")))
            }
            Err(e) => Ok(error_result(&format!(
                "moot_review_tunnel: {}",
                describe_verb_dispatch_error(&e)
            ))),
        };
    }

    // User accept/reject — the existing settle path, now recording the
    // reviewer identity in the review ledger.
    match locus_estate.respond_to_tunnel(
        tunnel_id,
        verdict == "accept",
        reviewed_by,
        reason,
        now,
    ) {
        Ok(()) => {
            let outcome = if verdict == "accept" {
                "accepted — the contradicts link is now active"
            } else {
                "rejected — the link is withdrawn and this pair will never be re-proposed"
            };
            Ok(text_result(&format!(
                "moot_review_tunnel: {tunnel_id} {outcome}."
            )))
        }
        // Not-found and not-proposed are caller errors, surfaced as clean
        // tool-level messages rather than opaque failures. LocusKitError has
        // Display — mirror Swift's errorResult path.
        Err(e) => Ok(error_result(&format!("moot_review_tunnel: {e}"))),
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
    let estate = registry.resolve_direct(args)?;
    let from_id = require_string(args, "from_id")?;

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    // Recall all drawers to find the source drawer's wing.
    // Explicit limit=256 (the engine's RECALL_CANDIDATE_CAP scan bound) so the
    // coordinator.recall cap doesn't silently truncate to 50 on large estates;
    // this ID-resolution path needs the full candidate set, not an analytics sample.
    let mut id_lookup_frame = RecallFrame::new(vec![]);
    id_lookup_frame.limit = Some(256);
    let all = coord
        .recall(&estate.handle, id_lookup_frame, now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    let source = all.iter().find(|d| d.id == from_id).ok_or_else(|| {
        JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("from_id not found: {from_id}"),
        )
    })?;
    // Resolve wing display name from the node tree for the source drawer.
    let node_names = coord.resolve_drawer_node_names(
        &estate.handle,
        &[source.parent_node_id.clone()],
    );
    let wing = node_names
        .get(&source.parent_node_id)
        .map(|(w, _)| w.clone())
        .unwrap_or_default();

    let tunnels = coord
        .recall_tunnels(&estate.handle, &wing)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    // Lifecycle gate (FIND4): exclude proposed, withdrawn, and superseded
    // tunnels at the MCP boundary so AI clients see only confirmed edges.
    // Sensitivity ceiling (#58): exclude restricted/secret tunnels, matching
    // the default recall ceiling.
    let outgoing: Vec<_> = tunnels
        .iter()
        .filter(|t| {
            t.source_drawer_id.as_deref() == Some(from_id)
                && t.tombstoned_at.is_none()
                && t.lifecycle() == locus_kit::tunnel_operational::TunnelLifecycle::Active
                && t.adjective_sensitivity().is_bulk_exportable()
        })
        .collect();

    // Dense-row citations (PR-03): each drawer endpoint is cited as a dense
    // row so the AI can judge the neighbor without another call. Room-level
    // endpoints (no drawer id) keep the wing/room text. Endpoint drawers are
    // looked up from the id-resolution recall above. Mirrors Swift.
    let by_id: BTreeMap<&str, &locus_kit::drawer::Drawer> =
        all.iter().map(|d| (d.id.as_str(), d)).collect();
    let mut lines = vec![format!("connections from {from_id}: {}", outgoing.len())];
    for t in outgoing.iter().take(50) {
        let cite = match t.target_drawer_id.as_deref() {
            Some(id) => by_id
                .get(id)
                .map(|d| crate::dense_row::render(d))
                .unwrap_or_else(|| crate::dense_row::render_unhydrated(id)),
            None => format!("{}/{}", t.target_wing, t.target_room),
        };
        lines.push(format!("{}  [{}]  → {}", t.id, t.label, cite));
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
    let estate = registry.resolve_direct(args)?;
    let to_id = require_string(args, "to_id")?;

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();

    // Recall all drawers to discover all wings in the estate.
    // Explicit limit=256 (the engine's RECALL_CANDIDATE_CAP scan bound) so the
    // coordinator.recall cap doesn't silently truncate to 50 on large estates;
    // this ID-resolution path needs the full candidate set, not an analytics sample.
    let mut id_lookup_frame = RecallFrame::new(vec![]);
    id_lookup_frame.limit = Some(256);
    let all = coord
        .recall(&estate.handle, id_lookup_frame, now)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    // Resolve wing display names from the node tree for all drawers.
    let all_node_ids: Vec<String> = all.iter().map(|d| d.parent_node_id.clone()).collect();
    let node_names = coord.resolve_drawer_node_names(&estate.handle, &all_node_ids);
    let wings: std::collections::HashSet<String> = node_names
        .values()
        .map(|(w, _)| w.clone())
        .collect();

    // Scan every wing's tunnels for incoming edges to to_id.
    let mut incoming = Vec::new();
    for wing in &wings {
        let tunnels = coord
            .recall_tunnels(&estate.handle, wing)
            .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;
        for t in tunnels {
            // Lifecycle gate (FIND4): exclude proposed, withdrawn, and superseded
            // tunnels at the MCP boundary. Sensitivity ceiling (#58): same as
            // connection_search.
            if t.target_drawer_id.as_deref() == Some(to_id)
                && t.tombstoned_at.is_none()
                && t.lifecycle() == locus_kit::tunnel_operational::TunnelLifecycle::Active
                && t.adjective_sensitivity().is_bulk_exportable()
            {
                incoming.push(t);
            }
        }
    }

    // Dense-row citations (PR-03) — mirror of connection_search.
    let by_id: BTreeMap<&str, &locus_kit::drawer::Drawer> =
        all.iter().map(|d| (d.id.as_str(), d)).collect();
    let mut lines = vec![format!("connections to {to_id}: {}", incoming.len())];
    for t in incoming.iter().take(50) {
        let cite = match t.source_drawer_id.as_deref() {
            Some(id) => by_id
                .get(id)
                .map(|d| crate::dense_row::render(d))
                .unwrap_or_else(|| crate::dense_row::render_unhydrated(id)),
            None => format!("{}/{}", t.source_wing, t.source_room),
        };
        lines.push(format!("{}  [{}]  ← {}", t.id, t.label, cite));
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
    let estate = registry.resolve_direct(args)?;
    let subject = require_string(args, "subject")?;
    let predicate = require_string(args, "predicate")?;
    let object = require_string(args, "object")?;
    // source_id anchors the fact to a drawer in this estate. It is a local drawer
    // id or nothing — when the caller omits it the fact is filed sourceless, and a
    // value naming no drawer fails the write. The filing binary's identity
    // ("aria-mcp-server" or "mootx01") is provenance about the writer, not about
    // the source, so it is stamped into `added_by` rather than substituted here.
    let source_id = optional_string(args, "source_id")?.unwrap_or("");
    let origin = locus_kit::kg_fact::KGFactOrigin {
        added_by: registry.server_identity.clone(),
        ..Default::default()
    };

    let now = wall_now();
    let coord = estate.coord.lock().unwrap();
    match coord.add_kg_fact_with_origin(
        &estate.handle, subject, predicate, object, source_id, &origin, now,
    ) {
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
/// emits.
///
/// Mirrors Swift `runFactSearch`.
fn run_fact_search(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let query = optional_string(args, "query")?;
    let subject_exact = optional_string(args, "subject_exact")?;
    let predicate_exact = optional_string(args, "predicate_exact")?;
    let object_exact = optional_string(args, "object_exact")?;
    let source_exact = optional_string(args, "source_id_exact")?;
    let limit = clamp_limit(optional_integer(args, "limit")?, "limit", 100, crate::dispatch::LIMIT_HARD_CEILING)?;

    let coord = estate.coord.lock().unwrap();
    // Capture dense-lane availability before consuming the lock via recall_kg_facts.
    // `has_corpus` is a cheap registry lookup — no I/O — so it is safe to call
    // under the same lock acquisition before the recall call.
    let dense_lane_dark = !coord.has_corpus(&estate.handle);
    let facts_raw = coord
        .recall_kg_facts(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    // MCP disclosure ceiling: drop Restricted/Secret facts before any output.
    // Parity with the default BitmapEvaluator ceiling (SensitivityAtMost(Elevated))
    // that normal recall applies via insert_defaults. Filter at the ARIA tool boundary
    // only — recall_kg_facts has internal callers that need the full set.
    let facts: Vec<_> = facts_raw
        .into_iter()
        .filter(|f| f.adjective_sensitivity().is_bulk_exportable())
        .collect();

    let matches: Vec<_> = facts
        .iter()
        .filter(|f| {
            let query_matches = query.map(|q| {
                let q = q.to_lowercase();
                f.subject.to_lowercase().contains(&q)
                    || f.predicate.to_lowercase().contains(&q)
                    || f.object.to_lowercase().contains(&q)
            }).unwrap_or(true);
            query_matches
                && subject_exact.map(|v| f.subject == v).unwrap_or(true)
                && predicate_exact.map(|v| f.predicate == v).unwrap_or(true)
                && object_exact.map(|v| f.object == v).unwrap_or(true)
                && source_exact.map(|v| f.source_drawer_id == v).unwrap_or(true)
        })
        .collect();

    // Gate source-drawer IDs: for each distinct sourceDrawerID in the facts we are about
    // to emit, check whether it references an actual drawer row in the estate. If it does
    // AND that drawer is Restricted/Secret (outside the default sensitivity ceiling), hide
    // the ID at the MCP boundary. sourceDrawerID holds a local drawer id or "", so the
    // only non-matching value is the empty one, which names no drawer and stays visible.
    // Parity with Swift runFactSearch.
    let hidden_source_ids: std::collections::HashSet<String> = {
        let mut seen = std::collections::HashSet::new();
        let unique_source_ids: Vec<String> = matches
            .iter()
            .map(|f| f.source_drawer_id.clone())
            .filter(|id| seen.insert(id.clone()))
            .collect();
        let mut hidden = std::collections::HashSet::new();
        for id in &unique_source_ids {
            // Probe the raw store (bypasses frame filter) to determine whether this ID is a
            // real drawer. If it is and falls outside the ceiling, suppress it.
            if let Ok(Some(drawer)) = estate.store.get_drawer(id) {
                if !drawer.adjective_sensitivity().is_bulk_exportable() {
                    hidden.insert(id.clone());
                }
            }
        }
        hidden
    };

    let header = if let Some(q) = query {
        format!("facts matching \"{q}\": {}", matches.len())
    } else {
        format!("facts: {}", matches.len())
    };

    // Include evaluation fields (filed_at as ISO8601, source_drawer_id) so
    // callers can reason about provenance without a separate timeline call.
    // Mirrors Swift runFactSearch field additions.
    let mut lines = vec![header];
    for f in matches.iter().take(limit) {
        let filed_iso = epoch_to_iso8601(f.filed_at);
        // Gate source= on source-drawer sensitivity: hide only when the source drawer
        // EXISTS in the estate AND is Restricted/Secret. source_drawer_id holds a
        // local drawer id or "", so a sourceless fact renders an empty source=.
        let source_field = if hidden_source_ids.contains(&f.source_drawer_id) {
            "source=<hidden>".to_string()
        } else {
            format!("source={}", f.source_drawer_id)
        };
        // Row format mirrors Swift runFactSearch: "<id>  [<subject>] <predicate>
        // [<object>]  filed=<iso>  source=<id|hidden>  addedBy=<host>".
        // Double space after id, no leading indent, no dash separator.
        // added_by names the binary that filed the row — provenance about the
        // writer, distinct from which drawer the fact was drawn from. Never
        // gated: it is not a drawer id and carries no drawer's sensitivity.
        lines.push(format!(
            "{}  [{}] {} [{}]  filed={}  {}  addedBy={}",
            f.id, f.subject, f.predicate, f.object, filed_iso, source_field, f.added_by
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
    let estate = registry.resolve_direct(args)?;
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
/// "YYYY-MM-DDTHH:MM:SS+00:00". Returns epoch MILLISECONDS — the
/// fractional-seconds field is retained as the millisecond component, matching
/// Swift's `ISO8601DateFormatter().date(from:)` in `runFileMemory`.
fn parse_iso8601_to_ms(s: &str) -> Option<i64> {
    // Strip timezone suffix before splitting on T.
    let s = s
        .trim_end_matches('Z')
        .trim_end_matches("+00:00")
        .trim_end_matches("+0000");
    // Split optional fractional seconds (.mmm…) → milliseconds (3 digits,
    // padded/truncated).
    let (s, millis) = if let Some(dot_pos) = s.rfind('.') {
        let frac: String = s[dot_pos + 1..].chars().take(3).collect();
        let mut ms: i64 = frac.parse().ok()?;
        for _ in frac.len()..3 {
            ms *= 10;
        }
        (&s[..dot_pos], ms)
    } else {
        (s, 0)
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
    // Overflow-checked arithmetic: extreme year values (e.g. year 292278994)
    // can overflow i64 multiplication. Return None instead of panicking.
    let secs = days.checked_mul(86400)?
        .checked_add(h.checked_mul(3600)?)?
        .checked_add(min.checked_mul(60)?)?
        .checked_add(sec)?;
    secs.checked_mul(1000)?.checked_add(millis)
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
    let estate = registry.resolve_direct(args)?;
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

    // MCP disclosure ceiling: drop Restricted/Secret facts before any output.
    // Parity with the default BitmapEvaluator ceiling (SensitivityAtMost(Elevated))
    // that normal recall applies via insert_defaults. Filter at the ARIA tool boundary
    // only — recall_kg_fact_timeline has internal callers that need the full set.
    facts.retain(|f| f.adjective_sensitivity().is_bulk_exportable());

    // Gate source-drawer IDs: for each distinct sourceDrawerID in the facts we are about
    // to emit (capped at 200), check whether it references an actual drawer row in the
    // estate. If it does AND that drawer is Restricted/Secret (outside the default
    // sensitivity ceiling), hide the ID at the MCP boundary. sourceDrawerID holds a local
    // drawer id or "", so the only non-matching value is the empty one, which names no
    // drawer and stays visible. Parity with Swift runFactTimeline.
    let hidden_source_ids: std::collections::HashSet<String> = {
        let mut seen = std::collections::HashSet::new();
        let unique_source_ids: Vec<String> = facts
            .iter()
            .take(200)
            .map(|f| f.source_drawer_id.clone())
            .filter(|id| seen.insert(id.clone()))
            .collect();
        let mut hidden = std::collections::HashSet::new();
        for id in &unique_source_ids {
            if let Ok(Some(drawer)) = estate.store.get_drawer(id) {
                if !drawer.adjective_sensitivity().is_bulk_exportable() {
                    hidden.insert(id.clone());
                }
            }
        }
        hidden
    };

    let header = if let Some(e) = entity_raw {
        format!("fact timeline for \"{e}\": {}", facts.len())
    } else {
        format!("fact timeline: {}", facts.len())
    };

    let mut lines = vec![header];
    // Cap at 200 rows matching the Swift port.
    // Include source_drawer_id for provenance tracing, gated on source-drawer admissibility.
    for f in facts.iter().take(200) {
        let lifecycle_tag = lifecycle_tag_for_adjective_bitmap(f.adjective_bitmap);
        // Emit ISO8601 timestamps to match the Swift port's output format.
        // filed_at is epoch seconds; format as UTC RFC3339 / ISO8601.
        let filed_iso = epoch_to_iso8601(f.filed_at);
        // Gate source= on source-drawer sensitivity: hide only when the source drawer
        // EXISTS in the estate AND is Restricted/Secret. source_drawer_id holds a
        // local drawer id or "", so a sourceless fact renders an empty source=.
        let source_field = if hidden_source_ids.contains(&f.source_drawer_id) {
            "source=<hidden>".to_string()
        } else {
            format!("source={}", f.source_drawer_id)
        };
        lines.push(format!(
            "{}  {}  {}  [{}] {} [{}]  {}",
            filed_iso, lifecycle_tag, f.id, f.subject, f.predicate, f.object, source_field
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
    let estate = registry.resolve_direct(args)?;
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
///
/// # Timestamp unit
///
/// `DiaryEntry.filed_at` is stored as epoch **seconds** (matching the SQLite
/// TEXT ISO8601 round-trip in LocusKit's persistence layer — the column stores
/// TEXT but the Rust struct holds the i64 seconds value decoded from that text).
/// `epoch_to_iso8601` converts seconds to an ISO8601 UTC string.
///
/// # Row format
///
/// Mirrors Swift `runReadJournal`:
///   `[\(ISO8601)]  \(entry.prefix(200))`
/// The timestamp is bracketed and double-spaced before the entry text, matching
/// `ISO8601DateFormatter().string(from: e.filedAt)` in the Swift port.
fn run_read_journal(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let agent = optional_string(args, "agent")?.unwrap_or("mcp-agent");
    // Clamp last_n through the shared boundary funnel: rejects negatives/zero with
    // invalidParams (bare usize cast lets -1 overflow to usize::MAX → truncate no-op = all rows),
    // caps at LIMIT_HARD_CEILING=500. Default 10. Parity: matches Swift clampLimit in runReadJournal.
    let last_n = crate::dispatch::clamp_limit(
        optional_integer(args, "last_n")?,
        "last_n",
        10,
        crate::dispatch::LIMIT_HARD_CEILING,
    )?;

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
        // filed_at is epoch seconds. Convert to ISO8601 to match Swift's
        // ISO8601DateFormatter output: "[2026-06-20T17:06:29Z]  <entry text>".
        let filed_iso = epoch_to_iso8601(e.filed_at);
        let preview: String = e.entry.chars().take(200).collect();
        lines.push(format!("[{}]  {}", filed_iso, preview));
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
    version_skew: &str,
    update_advisory: Option<&crate::dispatcher::UpdateAdvisoryProvider>,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let coord = estate.coord.lock().unwrap();

    // Use all_drawers (unfiltered) then apply Cluster-A bitmap filter for the
    // active count. Mirrors Swift runEstateStatus which calls estate.allDrawers()
    // then filters by RowState.cluster(ofRawState:) == .a. Hint drawers
    // (AI_Charter_Hint room) are normal drawers counted in the active total.
    let all_drawers = coord
        .all_drawers(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    // "active" = Cluster-A rows. Cluster A is the partition where
    // (state_raw >> 4) & 0x3 == 0, with state_raw = adjective_bitmap & 0x3F.
    // This includes Active(0), Pending(1), Contested(2), Accepted(3).
    let active: Vec<_> = all_drawers
        .iter()
        .filter(|d| {
            let state_raw = (d.adjective_bitmap & 0x3F) as u8;
            (state_raw >> 4) & 0x3 == 0
        })
        .collect();

    let kg_facts = coord
        .recall_kg_facts(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;

    // Sensitivity ceiling (#50): restricted/secret drawers contribute nothing
    // to this surface — not the wing listing, and not any count. Wing names
    // derived from restricted/secret drawers leak topic metadata; a count that
    // moves with the restricted set is the same leak in scalar form, since
    // this tool has no sensitivity-grant plumbing and every caller is an
    // ungranted one. Matches the estate-map ceiling. `is_bulk_exportable` is
    // true for Normal and Elevated, false for Restricted and Secret — the
    // parity of Swift `AdjectiveSensitivity.isBulkExportable`.
    //
    // EVERY drawer-derived aggregate below reads from `visible` or
    // `visible_total`. An aggregate added here inherits that rule: derive it
    // from a filtered set, or the next reader learns the size of a population
    // they cannot see. Mirrors Swift runEstateStatus.
    let visible: Vec<_> = active
        .iter()
        .filter(|d| d.adjective_sensitivity().is_bulk_exportable())
        .collect();
    // "total" = all non-erased rows (tombstone = permanently erased), under
    // the same ceiling — hence the wider cluster scope but the identical
    // sensitivity predicate.
    let visible_total: Vec<_> = all_drawers
        .iter()
        .filter(|d| d.tombstoned_at.is_none() && d.adjective_sensitivity().is_bulk_exportable())
        .collect();
    let visible_node_ids: Vec<String> = visible.iter().map(|d| d.parent_node_id.clone()).collect();
    let visible_node_names = coord.resolve_drawer_node_names(&estate.handle, &visible_node_ids);
    let wings: std::collections::BTreeSet<String> = visible_node_names
        .values()
        .map(|(w, _)| w.clone())
        .collect();

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
    let fdc_floor = estate.store.get_meta(FDC_RECALCED_DATA_VERSION_META_KEY).map_err(|e| {
        JSONRPCError::new(
            JSONRPCErrorCode::TOOL_DISPATCH_FAILURE,
            format!("estate_status: failed to read estate FDC floor: {e}"),
        )
    })?;
    let current_fdc_recalculation_version = lattice_lib::Fdc::recalculation_version();
    let fdc_recalculation_state = if fdc_floor.as_deref() == Some(current_fdc_recalculation_version.as_str()) {
        "current"
    } else if fdc_floor.is_none() {
        "missing"
    } else {
        "stale"
    };

    // Subject-debt counter (PR-04): presence debt over the live
    // sensitivity-visible set — N subject-bearing / M eligible (non-empty
    // content), K missing. It counts `visible`, not `active`, under the
    // ceiling declared above: the debt an ungranted caller is being asked to
    // pay is exactly the debt it is allowed to see, so this counter and the
    // `moot_memory_list filter:missing_subject` enumerator it points the AI at
    // describe one population. The every-load reminder driving the
    // consent-gated interactive backfill (walk the enumerator → setSubject
    // only after the user grants time and permission). Presence debt only —
    // pipeline-version regeneration debt stays count_missing_subject's
    // concern. Mirrors Swift runEstateStatus.
    let subject_eligible = visible.iter().filter(|d| !d.content.is_empty()).count();
    let subject_bearing = visible
        .iter()
        .filter(|d| !d.content.is_empty() && d.subject.is_some())
        .count();

    // Field order and wording mirror Swift runEstateStatus exactly:
    //   estate / memories / subjects / wings / kg facts (space, "active" suffix) / trace_rows / sync
    //   [/ version_skew — plugin-owned MCP connections, appended only when the host detected one]
    let mut body = format!(
        "estate: {estate_name} [{estate_uuid}]\nmemories: {} active ({} total)\nsubjects: {}/{} ({} missing)\nwings: {}\nkg facts: {} active\ntrace_rows: {}\nsync: {}\nfdc_recalculation: {fdc_recalculation_state}\nfdc_recalculation_floor: {}\nfdc_recalculation_current: {current_fdc_recalculation_version}",
        visible.len(),
        visible_total.len(),
        subject_bearing,
        subject_eligible,
        subject_eligible - subject_bearing,
        wings_list,
        kg_facts.len(),
        trace_rows,
        sync_token,
        fdc_floor.as_deref().unwrap_or("none"),
    );
    // Shared-content migration/reclaim status (shared-content 1.1 P5):
    // appended only when a migration record exists — fresh estates that
    // never ran detection leave the response shape unchanged. Mirrors Swift
    // runEstateStatus (state token = the record's camelCase serde form).
    let reclaim = coord.shared_content_reclaim_status(&estate.handle);
    if let Some(state) = reclaim.state {
        let token = serde_json::to_string(&state).unwrap_or_default();
        let mut line = format!(
            "shared_content_migration: {}",
            token.trim_matches('"')
        );
        if let Some(estimated) = reclaim.estimated_reclaimable_bytes {
            line.push_str(&format!(", estimated_reclaimable_bytes: {estimated}"));
        }
        if let Some(reclaimed) = reclaim.reclaimed_bytes {
            line.push_str(&format!(", reclaimed_bytes: {reclaimed}"));
        }
        body.push_str(&format!("\n{line}"));
    }
    if !version_skew.is_empty() {
        body.push_str(&format!("\nversion_skew: {version_skew}"));
    }
    // Upstream-release advisory (see `UpdateAdvisoryProvider`): evaluated
    // lazily here and in ping only — the host rate-limits the underlying
    // release-feed probe, and the common up-to-date case appends nothing.
    // Mirrors Swift runEstateStatus.
    if let Some(line) = update_advisory.and_then(|provider| provider()) {
        body.push_str(&format!("\nupdate_available: {line}"));
    }
    body.push('\n');
    body.push_str(ARIA_SESSION_PROTOCOL);
    Ok(text_result(&body))
}

/// Return the estate's memory taxonomy as a tree grouped by wing and room.
///
/// Mirrors Swift `runEstateMap`.
///
/// Wing and room display names are resolved from the node tree via
/// `coord.resolve_drawer_node_names`. All drawers (including hint memories
/// in AI_Charter_Hint) are counted normally — no special-casing.
/// `moot_memory_list` — enumerate drawer IDs in a wing, optionally filtered
/// by room. Structural inventory, not semantic search. Returns each drawer's
/// ID, room, and an 80-char content preview. Capped at 200 results.
fn run_memory_list(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let wing = require_string(args, "wing")?;
    let room_filter = optional_string(args, "room")?;
    // Optional filter. `missing_subject` is the subject-debt backfill
    // enumerator (PR-02): id-only rows of live drawers whose subject is
    // NULL, so a consenting backfill session can walk them with
    // moot_update_memory mutation=setSubject without hauling content.
    // Mirrors Swift runMemoryList.
    let missing_subject_only = match optional_string(args, "filter")? {
        None => false,
        Some("missing_subject") => true,
        Some(other) => {
            return Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("Unknown filter: {other}. Accepted: missing_subject"),
            ));
        }
    };
    let coord = estate.coord.lock().unwrap();

    let all = coord
        .all_drawers(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;
    // Filter to Cluster A (currently-believed) + sensitivity ceiling (#9).
    // State cluster is in bits 0–5 of adjectiveBitmap; Cluster A values are
    // Active(0), Pending(1), Contested(2), Accepted(3) — all < 4.
    let drawers: Vec<_> = all.into_iter().filter(|d| {
        if d.tombstoned_at.is_some() { return false; }
        let state_raw = d.adjective_bitmap & 0x3F;
        if state_raw >= 4 { return false; } // Cluster B or C
        let sensitivity = AdjectiveSensitivity::from_raw((d.adjective_bitmap >> 6) & 0x3F);
        sensitivity != AdjectiveSensitivity::Restricted && sensitivity != AdjectiveSensitivity::Secret
    }).collect();

    let node_ids: Vec<String> = drawers.iter().map(|d| d.parent_node_id.clone()).collect();
    let node_names = coord.resolve_drawer_node_names(&estate.handle, &node_ids);
    drop(coord);

    let mut matches: Vec<(locus_kit::drawer::Drawer, String)> = Vec::new();
    for d in drawers {
        if missing_subject_only && d.subject.is_some() { continue; }
        let (d_wing, d_room) = node_names
            .get(&d.parent_node_id)
            .cloned()
            .unwrap_or_default();
        if d_wing != wing { continue; }
        if let Some(ref rf) = room_filter {
            if !rf.is_empty() && d_room != *rf { continue; }
        }
        matches.push((d, d_room));
    }

    let total = matches.len();
    matches.truncate(200);
    let filter_suffix = if missing_subject_only { " [filter: missing_subject]" } else { "" };
    let mut lines = vec![format!(
        "memory_list: {} drawer(s) in {}{}{}",
        matches.len(),
        wing,
        room_filter.as_ref().map(|r| format!("/{}", r)).unwrap_or_default(),
        filter_suffix
    )];
    if total > 200 {
        lines.push(format!("(showing first 200 of {})", total));
    }
    for (d, room) in &matches {
        // Debt enumeration stays id-only by design (PR-02): the backfill
        // walker fetches content per-row via moot_memory_get when ready to
        // write a subject. Every other listing row is the dense row (PR-03)
        // — address + assertion, no content preview. Mirrors Swift.
        if missing_subject_only {
            lines.push(format!("  {} [{}]", d.id, room));
        } else {
            lines.push(format!("  {}", crate::dense_row::render(d)));
        }
    }
    Ok(text_result(&lines.join("\n")))
}

fn run_estate_map(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let coord = estate.coord.lock().unwrap();

    // Resolve estate name for the header — mirrors Swift `handle.estateName`.
    let estate_info = coord.estate_for(&estate.handle).ok();
    let estate_name = estate_info
        .and_then(|e| e.manifest().ok())
        .map(|m| m.estate_name)
        .unwrap_or_else(|| "unknown".to_string());

    // Use all_drawers (unfiltered) then apply two filters:
    //   1. Active: non-tombstoned rows (mirrors Swift runEstateMap).
    //   2. Sensitivity ceiling: exclude restricted and secret drawers to match
    //      the default BitmapEvaluator ceiling (SensitivityAtMost(.elevated)).
    //      Without this filter, restricted/secret rows contribute wing/room names
    //      and counts to the public map, bypassing the access-control posture.
    //
    // AdjectiveSensitivity is read from adjective_bitmap bits 6–11 (cookbook §2.3
    // shift: (adjective_bitmap >> 6) & 0x3F). Normal (0) and Elevated (16) pass;
    // Restricted (32) and Secret (48) are excluded. Charter drawers (_charter
    // structural drawers) are auto-seeded at normal sensitivity and pass through.
    //
    // Mirrors Swift:
    //   let active = drawers.filter { $0.tombstonedAt == nil }
    //   let visible = active.filter { $0.adjectiveSensitivity.isBulkExportable }
    let all = coord
        .all_drawers(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, describe_verb_dispatch_error(&e)))?;
    let drawers: Vec<_> = all.into_iter().filter(|d| {
        if d.tombstoned_at.is_some() { return false; }
        let sensitivity = AdjectiveSensitivity::from_raw((d.adjective_bitmap >> 6) & 0x3F);
        sensitivity != AdjectiveSensitivity::Restricted && sensitivity != AdjectiveSensitivity::Secret
    }).collect();

    // Resolve wing/room display names from node tree for all visible drawers.
    let map_node_ids: Vec<String> = drawers.iter().map(|d| d.parent_node_id.clone()).collect();
    let map_node_names = coord.resolve_drawer_node_names(&estate.handle, &map_node_ids);

    // Group by wing then room, counting visible (sensitivity-gated) drawers per
    // location. Charter drawers (AI_Charter_Hint) pass at normal sensitivity.
    let mut tree: std::collections::BTreeMap<String, std::collections::BTreeMap<String, usize>> =
        std::collections::BTreeMap::new();
    for d in &drawers {
        let (wing, room) = map_node_names
            .get(&d.parent_node_id)
            .cloned()
            .unwrap_or_default();
        *tree
            .entry(wing)
            .or_default()
            .entry(room)
            .or_insert(0) += 1;
    }

    // Header mirrors Swift runEstateMap: "estate map: estateName".
    let mut lines = vec![format!("estate map: {estate_name}")];
    for (wing, rooms) in &tree {
        lines.push(format!("  {wing}/"));
        for (room, count) in rooms {
            lines.push(format!("    {room}: {count}"));
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
    version_skew: &str,
    update_advisory: Option<&crate::dispatcher::UpdateAdvisoryProvider>,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let coord = estate.coord.lock().unwrap();

    // coord.estate_for returns GeniusLocusKitError (not VerbDispatchError), so
    // route through describe_glk_error to surface a clean English reason.
    let locus_estate = coord.estate_for(&estate.handle).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, crate::dispatch::describe_glk_error(&e))
    })?;

    let manifest = locus_estate.manifest().map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("estate_ping: manifest read failed: {e}"))
    })?;

    // append the version-skew advisory when present — same
    // opt-in shape as run_estate_status.
    let mut pong = format!(
        "pong: estate {} [{}] is live — build {}",
        manifest.estate_name, manifest.estate_uuid, build_serial
    );
    if !version_skew.is_empty() {
        pong.push_str(&format!("\nversion_skew: {version_skew}"));
    }
    // Upstream-release advisory — same opt-in shape as version_skew. The
    // host's advisor caches behind a TTL, so this is a memory read on all
    // but the first ping of each cache window ("true lightweight ping"
    // preserved in the common case). Mirrors Swift runEstatePing.
    if let Some(line) = update_advisory.and_then(|provider| provider()) {
        pong.push_str(&format!("\nupdate_available: {line}"));
    }
    Ok(text_result(&pong))
}

// ===========================================================================
// Monitoring control
// ===========================================================================

/// Read or write the daemon's telemetry monitoring flag.
///
/// ## Read path (absent `enabled` argument)
/// Returns the current effective monitoring state without mutation.
///
/// ## Write path (present `enabled: bool` argument)
/// Persists `enabled` via the injected `MonitoringControl` and reports the
/// new effective state. The concrete implementation (`StatsStoreMonitoringControl`)
/// also writes `monitoring_source=user` so downstream readers can distinguish
/// operator-driven changes from env-var or default-seeded state.
///
/// ## No-store case
/// When `monitoring_control` is `None` (stdio mode, test harnesses, provision-less
/// contexts), the tool reports `monitoring: unavailable` and never fabricates a
/// false enabled/disabled state. Mirrors B-6 honesty discipline.
///
/// Mirrors Swift `ToolDispatcher.runMonitoringStatus`.
fn run_monitoring_status(
    args: &BTreeMap<String, JsonValue>,
    monitoring_control: Option<&dyn crate::monitoring_control::MonitoringControl>,
) -> Result<serde_json::Value, JSONRPCError> {
    let control = match monitoring_control {
        Some(c) => c,
        None => {
            // No stats store wired — honest "unavailable" response. Never say
            // "disabled" when the true answer is "no store to read from".
            return Ok(text_result("monitoring: unavailable (no telemetry store wired)"));
        }
    };

    // Write path: `enabled` argument present → set flag, return new state.
    if let Some(enabled) = optional_bool(args, "enabled")? {
        control.set(enabled);
        // Re-read the persisted value so the response reflects what was actually
        // written, not just what was requested.
        let effective = control.read();
        let state_str = match effective {
            Some(true) => "enabled",
            Some(false) => "disabled",
            None => "unavailable",
        };
        let mut lines = format!("monitoring: {state_str}\nmonitoring_source: user");
        if effective.is_none() {
            lines.push_str("\nwarning: flag was written but could not be re-read; retry moot_monitoring_status to confirm");
        }
        return Ok(text_result(&lines));
    }

    // Read path: no `enabled` argument → report current state only.
    let current = control.read();
    let state_str = match current {
        Some(true) => "enabled",
        Some(false) => "disabled",
        None => "unavailable",
    };
    Ok(text_result(&format!("monitoring: {state_str}")))
}

// ===========================================================================
// Maintenance
// ===========================================================================

/// Enqueue encode jobs for every active drawer that is not yet BM25/vector-
/// indexed in the estate. Returns the count enqueued. Idempotent. Mirrors
/// Swift `ToolDispatch.runReindex`. Requires `&mut` coord because
/// `reindex_missing` calls `enqueue_encode_job` → `mount_encode_queue`.
/// Reindex an estate's missing drawers WITHOUT holding the coordinator lock
/// across the (potentially huge) enqueue loop, so the daemon stays responsive to
/// other HTTP calls while it runs: brief lock to snapshot the work, LOCK-FREE
/// enqueue on the Corpus's own queue, brief lock to roll up the Merkle tree.
/// (Swift's actor coordinator interleaves awaits, so its `reindexMissing` is
/// already responsive; the Rust Mutex coordinator needs this explicit split —
/// parity of behavior, not of structure.)
fn run_reindex_responsive(
    coord_arc: &std::sync::Arc<std::sync::Mutex<genius_locus_kit::coordinator::EstateCoordinator>>,
    handle: &genius_locus_kit::handle::EstateHandle,
    now: i64,
) -> Result<usize, String> {
    // Lock-free enqueue on the Corpus's own queue (independent of the coord
    // Mutex), chunked so the filesystem backend fsyncs new/ ONCE per chunk
    // instead of per job (the per-job fsync was the last full-core bottleneck of
    // a bulk import), while the chunk bounds the brief queue-lock / fsync window
    // against concurrent live captures.
    const ENQUEUE_CHUNK: usize = 1024;
    let mut total = 0usize;

    // MEDIUM perf fix (Swift twin: `EncodeIntake.reindexMissing`'s upfront
    // sweep). Previously this function called `collect_reindex_jobs` once
    // PER PASS below, and `collect_reindex_jobs` internally reloaded the
    // WHOLE `drawers` table on every call — so a large backfill reloaded
    // the full table on every one of up to 1000 passes. `sweep_reindex_missing`
    // walks the table exactly ONCE, in bounded pages, and returns the
    // complete missing-job list (uncapped); this function then slices that
    // list into `REINDEX_MAX_JOBS`-sized passes itself, purely in-memory,
    // with no further table scans. `collect_reindex_jobs` is untouched and
    // still used wherever a single bounded collect is wanted (see its test
    // in encode_intake_parity.rs).
    let (corpus, missing_jobs, indexed_count) = {
        let mut c = coord_arc
            .lock()
            .map_err(|_| "reindex: coordinator lock poisoned".to_string())?;
        match c
            .sweep_reindex_missing(handle)
            .map_err(|e| describe_verb_dispatch_error(&e))?
        {
            Some(plan) => plan,
            None => return Ok(total), // no Corpus registered — nothing to reindex
        }
    };
    if missing_jobs.is_empty() {
        eprintln!("[reindex] nothing to index — reindex tail skipped");
        return Ok(0);
    }

    // Delta-aware tail: decided ONCE from the complete sweep above (which
    // saw the WHOLE missing set) — previously decided on the FIRST pass's
    // capped collect. When the missing set is a small fraction of an
    // already-trained corpus, the O(corpus) tail below (full basis retrain +
    // full re-embed + index rebuild) is grossly oversized — a ~1k-note vault
    // import into a 50k estate burned ~70 min of CPU, and an UNCHANGED
    // reimport burned the same for literally nothing. Small deltas instead
    // ride the ENCODE stream, whose drain embeds each chunk through the LIVE
    // basis as it ingests (the live-capture machinery, reused verbatim), and
    // the tail retrain is skipped: new vocabulary enters the basis at the
    // next large import, explicit `moot_reindex`, or scheduled maintenance.
    // Swift twin: the smallDelta branch in GeniusLocusKit.reindexMissing.
    let small_delta = genius_locus_kit::coordinator::EstateCoordinator::is_small_reindex_delta(
        missing_jobs.len(),
        indexed_count,
    );

    // Auto-continuation loop: slice the pre-computed missing_jobs list into
    // REINDEX_MAX_JOBS-sized passes, enqueue LOCK-FREE, poll its drain to
    // idle (lock-free — the Corpus queue is independent of the coord Mutex,
    // so concurrent HTTP handlers are never blocked while a pass encodes),
    // then advance to the next slice — repeating until the list is
    // exhausted. A large import reaches FULL coverage with no operator
    // follow-up, at any corpus size, while each pass stays bounded. The
    // 1000-pass ceiling is a backstop consistent with the previous design
    // (covers 10M drawers at the 10k cap).
    let mut missing_offset = 0usize;
    for _pass in 0..1000 {
        if missing_offset >= missing_jobs.len() {
            break; // every missing drawer enqueued — done
        }
        // Cap this pass to REINDEX_MAX_JOBS so a single pass cannot flood
        // the encode queue and starve live captures (Part 6 DoS bound).
        let pass_end = std::cmp::min(
            missing_offset
                + genius_locus_kit::coordinator::EstateCoordinator::reindex_max_jobs_cap(),
            missing_jobs.len(),
        );
        let jobs = &missing_jobs[missing_offset..pass_end];
        missing_offset = pass_end;
        // Shared-content 1.1: ONE canonical ingest stream. The jobs are
        // Drawer change references (id/revision/digest — never text); the
        // drain worker resolves CURRENT content by ID through the adapter
        // and indexes BM25 + vectors together, so the legacy import stream
        // (chunk + BM25 only, embed deferred) is retired with the copy
        // lane. The delta decision above still governs the TAIL: small
        // deltas skip the O(corpus) basis retrain below. Durable queue
        // either way, so a crash mid-import cold-starts: the drain worker
        // reclaims orphaned rows and resumes.
        for chunk in jobs.chunks(ENQUEUE_CHUNK) {
            if corpus.enqueue_change_batch(chunk).is_ok() {
                total += chunk.len();
            }
        }
        // Wait for THIS pass to reach TRUE idle before advancing to the next
        // slice, so an in-flight batch is never starved of drain capacity by
        // the next pass's enqueue.
        //
        // POLL, do not pump — the single lease-holding drain worker owns the
        // drain; this loop only observes the read-only depth probe FOR THE
        // STREAM the batch was enqueued on.
        loop {
            match corpus.ingest_queue_depth() {
                Ok((0, 0)) => break,
                Ok(_) => std::thread::sleep(std::time::Duration::from_millis(200)),
                Err(_) => break, // depth probe fault — stop rather than spin
            }
        }
    }
    // Nothing was missing: no new chunks entered the corpus, so the basis,
    // every embedding, and the Merkle tree are exactly as current as before
    // this call — the O(corpus) tail below would be pure waste (observed: an
    // UNCHANGED vault reimport into a 50k estate burned ~70 min of full
    // retrain + re-embed for a no-op). A previously interrupted import (chunks
    // present but basis stale) is repaired by the explicit `moot_reindex`
    // tool, which exists for exactly that. Swift twin: the total == 0 guard in
    // GeniusLocusKit.reindexMissing.
    if total == 0 {
        eprintln!("[reindex] nothing to index — reindex tail skipped");
        return Ok(0);
    }
    if small_delta {
        // Small delta: every enqueued chunk was already embedded through the
        // LIVE basis by the encode drain. Pump the barrier once — it publishes
        // the resident vector index, the searchability contract — and skip the
        // full retrain. New vocabulary enters the basis at the next large
        // import, explicit `moot_reindex`, or maintenance.
        let corpus_for_publish = {
            let c = coord_arc
                .lock()
                .map_err(|_| "reindex: coordinator lock poisoned".to_string())?;
            c.corpus_handle(handle)
        };
        if let Some(corpus) = corpus_for_publish {
            corpus
                .await_ingest_drain()
                .map_err(|e| format!("small-delta ingest barrier failed: {e:?}"))?;
        }
        eprintln!(
            "[reindex] small delta ({total} drawers) embedded via the live basis — full retrain skipped (moot_reindex retrains on demand)"
        );
    } else {
        // Full-corpus embedding-basis retrain, so the DENSE (semantic / vector /
        // RAG) recall lane is query-ready the moment the import cycle reports
        // complete.
        //
        // The loop above reaches full CHUNK coverage: every drawer is chunked
        // and BM25 (lexical) indexed — but import-stream ingest deliberately
        // does NOT embed. A query term that appears only in an unembedded chunk
        // reads dense_lane:dark:vocabMiss until the basis is trained on the
        // WHOLE corpus and every chunk embedded into that space. Corpus::reindex
        // does exactly that (train_and_persist_basis over all active chunks,
        // then reembed_chunks → one index rebuild). Lexical (BM25) and
        // structured (Locus) recall are already live from chunk coverage; THIS
        // is the step that lights up semantic recall — so it belongs at the
        // tail of the import cycle, not on a later cadence. Run on the
        // Arc<Corpus> OUTSIDE the coord lock (a full re-embed is long; the lock
        // must not be held across it).
        let corpus_for_retrain = {
            let c = coord_arc
                .lock()
                .map_err(|_| "reindex: coordinator lock poisoned".to_string())?;
            c.corpus_handle(handle)
        };
        if let Some(corpus) = corpus_for_retrain {
            corpus
                .reindex(now)
                .map_err(|e| format!("corpus basis retrain failed: {e:?}"))?;
        }
    }
    // Brief re-lock for the deferred Merkle full-tree rollup, once, after coverage.
    {
        let mut c = coord_arc
            .lock()
            .map_err(|_| "reindex: coordinator lock poisoned".to_string())?;
        c.rollup_after_reindex(handle, now)
            .map_err(|e| describe_verb_dispatch_error(&e))?;
    }
    Ok(total)
}

fn run_reindex(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let now = wall_now();
    // reindex now AUTO-CONTINUES (enqueue a pass → await its drain → re-collect)
    // to FULL coverage, which can take minutes on a large estate. Run it on a
    // detached worker so the HTTP handler returns immediately; the resident
    // daemon's encode-drain converges in the background. Poll moot_drain_status
    // to watch it finish. (Mirrors the palace-import background-processing model —
    // no repeated moot_reindex calls are needed, at any corpus size.)
    let bg_coord = std::sync::Arc::clone(&estate.coord);
    let bg_handle = estate.handle;
    std::thread::Builder::new()
        .name("reindex-backfill".into())
        .spawn(move || {
            match run_reindex_responsive(&bg_coord, &bg_handle, now) {
                Ok(n) => eprintln!(
                    "reindex: background backfill complete — {n} drawers indexed to full coverage"
                ),
                Err(e) => eprintln!("reindex: background backfill failed: {e}"),
            }
        })
        .ok();
    Ok(text_result(
        "reindex started: backfilling every unindexed drawer to full coverage in the background — poll moot_drain_status to watch the encode queue converge",
    ))
}

/// `moot_drain_status` — report every long-running background drain the estate
/// currently runs, for monitoring asynchronous work (e.g. watching an import's
/// encode queue converge after `moot_palace_import`).
///
/// Lightweight and pollable: unlike `moot_estate_status` it does NOT append the
/// ARIA session-protocol orientation block, because this tool is meant to be
/// called repeatedly while a drain settles. Today the only drain is
/// `corpus_encode`; the report is a LIST so additional drains surface here
/// automatically when they exist. Read-only. Mirrors Swift `runDrainStatus`.
///
/// Reserved lane name for the subject-backfill drain (PR-04): the
/// PR-09/10 rider registers a drain under this name and the generic
/// renderer carries it unchanged. Its `pending` will be a row-level
/// ELIGIBILITY count (subject debt), not queue depth — when the rider
/// lands, the benchmarker's `BARRIER_NON_GATING_LANES` denylist must
/// gain this name in the same mission (the distillation-lane
/// precedent). Twin: Swift `ToolDispatcher.subjectBackfillLaneName`.
pub const SUBJECT_BACKFILL_LANE_NAME: &str = "subject_backfill";

fn run_drain_status(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let coord = estate.coord.lock().unwrap();
    let drains = match coord.drain_statuses(&estate.handle) {
        Ok(d) => d,
        Err(e) => return Ok(error_result(&format!("{e:?}"))),
    };
    if drains.is_empty() {
        // No drains registered (a bare estate with no Corpus). Honest empty
        // report — distinct from "all drains idle", which lists drains at 0.
        return Ok(text_result("drains: none"));
    }
    let mut lines: Vec<String> = vec![format!("drains: {}", drains.len())];
    for d in &drains {
        let state = if d.is_draining() { "draining" } else { "idle" };
        let mut line = format!(
            "  {}: {} — pending: {}, in_flight: {}",
            d.name, state, d.pending, d.in_flight
        );
        if let Some(detail) = &d.detail {
            line.push_str(&format!(", {detail}"));
        }
        lines.push(line);
    }
    Ok(text_result(&lines.join("\n")))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FdcReclassifyMode {
    SuspectOnly,
    All,
}

impl FdcReclassifyMode {
    fn parse(raw: Option<&str>) -> Result<Self, JSONRPCError> {
        match raw.map(|s| s.trim().to_ascii_lowercase()) {
            None => Ok(Self::SuspectOnly),
            Some(s) if s.is_empty()
                || s == "suspectonly"
                || s == "suspect_only"
                || s == "suspect-only" => Ok(Self::SuspectOnly),
            Some(s) if s == "all" => Ok(Self::All),
            Some(s) => Err(JSONRPCError::new(
                JSONRPCErrorCode::INVALID_PARAMS,
                format!("mode must be \"suspectOnly\" or \"all\"; received {s}"),
            )),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::SuspectOnly => "suspectOnly",
            Self::All => "all",
        }
    }
}

struct FdcReclassifyChange {
    id: String,
    old_code: String,
    old_qid: Option<String>,
    new_code: String,
    new_qid: Option<String>,
}

impl FdcReclassifyChange {
    fn label(code: &str, qid: Option<&str>) -> String {
        match qid {
            Some(qid) => format!("{code} [{qid}]"),
            None => code.to_string(),
        }
    }

    fn old_label(&self) -> String {
        Self::label(&self.old_code, self.old_qid.as_deref())
    }

    fn new_label(&self) -> String {
        Self::label(&self.new_code, self.new_qid.as_deref())
    }
}

fn normalized_fdc_code(code: &str) -> String {
    let trimmed = code.trim();
    if trimmed.is_empty() {
        DEFAULT_LATTICE_CODE.to_string()
    } else {
        trimmed.to_string()
    }
}

fn normalized_qid(qid: Option<&str>) -> Option<String> {
    qid.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned)
}

fn should_repair_fdc_anchor(
    mode: FdcReclassifyMode,
    old_code: &str,
    old_qid: Option<&str>,
    new_code: &str,
    new_qid: Option<&str>,
) -> bool {
    match mode {
        FdcReclassifyMode::All => true,
        FdcReclassifyMode::SuspectOnly => {
            new_code == DEFAULT_LATTICE_CODE
                || old_code == DEFAULT_LATTICE_CODE
                || (old_code == new_code && old_qid != new_qid)
        }
    }
}

/// `moot_reclassify_fdc` — audit or repair stored FDC anchors.
///
/// Mirrors Swift `runReclassifyFDC`: recompute each active drawer's content
/// anchor with the current deterministic classifier, dry-run by default, and
/// optionally write candidate changes through the audited reanchor path.
fn run_reclassify_fdc(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let apply = optional_bool(args, "apply")?.unwrap_or(false);
    let mode = FdcReclassifyMode::parse(optional_string(args, "mode")?)?;
    let current_fdc_data_version = lattice_lib::Fdc::data_version();
    let current_fdc_recalculation_version = lattice_lib::Fdc::recalculation_version();
    let limit = match optional_integer(args, "limit")? {
        Some(raw) => Some(crate::dispatch::clamp_limit(Some(raw), "limit", 1, 50_000)?),
        None => None,
    };
    let prior_floor = estate.store.get_meta(FDC_RECALCED_DATA_VERSION_META_KEY).map_err(|e| {
        JSONRPCError::new(
            JSONRPCErrorCode::TOOL_DISPATCH_FAILURE,
            format!("fdc_reclassify: failed to read estate FDC floor: {e}"),
        )
    })?;

    let drawers = {
        let coord = estate.coord.lock().unwrap();
        coord
            .all_drawers(&estate.handle)
            .map_err(|e| JSONRPCError::new(
                JSONRPCErrorCode::TOOL_DISPATCH_FAILURE,
                describe_verb_dispatch_error(&e),
            ))?
    };
    let mut active: Vec<_> = drawers
        .into_iter()
        // Dataset handles (ContentKind::Dataset) carry structured JSON, not
        // classifiable free text. The FDC classifier must never reclassify them
        // — doing so would corrupt the DatasetHandleContent payload.
        // MX-TAB-4 locked decision: FDC classifier boundary.
        .filter(|d| {
            d.tombstoned_at.is_none()
                && d.is_currently_believed()
                && d.content_kind() != ContentKind::Dataset
        })
        .collect();
    if let Some(limit) = limit {
        active.truncate(limit);
    }

    let mut scanned = 0usize;
    let mut empty_content = 0usize;
    let mut unchanged = 0usize;
    let mut candidate_count = 0usize;
    let mut applied = 0usize;
    let mut skipped_non_candidate_changes = 0usize;
    let mut unclassified_after = 0usize;
    let mut examples: Vec<FdcReclassifyChange> = Vec::new();

    // Phase A — PARALLEL classify. Each drawer's content anchor is a pure
    // function of its content and stored kind over the pinned FDC artifacts:
    // `eidetic_lib::lookup_no_record` skips the only shared-mutable write (the
    // novel-token pool cache), and every other artifact on the path is
    // read-only after init or a lock-guarded pure-function memo. So the classify
    // is embarrassingly parallel and its result is independent of scheduling.
    // This is the single expensive step (content through the v4 classifier incl.
    // the semantic ranker), so lifting it off the serial path is the
    // core-saturation win. Anchors are returned in the SAME order as `active`,
    // preserving scan order for the serial audited write in Phase B.
    let inputs: Vec<(&str, lattice_lib::FdcContentKind)> = active.iter().map(|drawer| {
        let kind = if drawer.content_kind() == ContentKind::Code {
            lattice_lib::FdcContentKind::Code
        } else {
            lattice_lib::FdcContentKind::Text
        };
        (drawer.content.as_str(), kind)
    }).collect();
    let anchors = classify_contents_in_parallel(&inputs);

    // Phase B — SERIAL, ORDERED apply. Identical to the pre-parallel loop
    // except the inline classify call is replaced by the precomputed
    // `anchors[index]`. All counting, candidate selection, example capture, and
    // the audited `reanchor_anchor` write run in scan order exactly as before,
    // so the output (counters, ordered change list, audit sequence, and the
    // early return on a write error) is byte-identical to the serial version.
    for (index, drawer) in active.iter().enumerate() {
        scanned += 1;
        if drawer.content.trim().is_empty() {
            empty_content += 1;
        }

        let old_code = normalized_fdc_code(&drawer.udc_code);
        let old_qid = normalized_qid(drawer.wikidata_qid.as_deref());
        let anchor = &anchors[index];
        let new_code = normalized_fdc_code(&anchor.code);
        let new_qid = normalized_qid(anchor.wikidata_qid.as_deref());
        if old_code == new_code && old_qid == new_qid {
            unchanged += 1;
            continue;
        }

        let candidate = should_repair_fdc_anchor(
            mode,
            &old_code,
            old_qid.as_deref(),
            &new_code,
            new_qid.as_deref(),
        );
        if !candidate {
            skipped_non_candidate_changes += 1;
            continue;
        }

        candidate_count += 1;
        if new_code == DEFAULT_LATTICE_CODE {
            unclassified_after += 1;
        }
        if examples.len() < 25 {
            examples.push(FdcReclassifyChange {
                id: drawer.id.clone(),
                old_code: old_code.clone(),
                old_qid: old_qid.clone(),
                new_code: new_code.clone(),
                new_qid: new_qid.clone(),
            });
        }

        if apply {
            // Repair only the primary udc_code + wikidata_qid that FDC
            // re-lookup produced. udc_facets and wikidata_qids_secondary are
            // carried forward unchanged from the existing drawer anchor —
            // FDC re-lookup has no opinion on secondary classification, so a
            // reclassify apply must not silently wipe facets/secondary QIDs
            // a human or the enrichment daemon previously attached. Parity
            // with Swift `runReclassifyFDC`.
            let new_anchor = LatticeAnchor::new(
                new_code,
                drawer.udc_facets.clone(),
                new_qid,
                drawer.wikidata_qids_secondary.clone(),
            );
            let coord = estate.coord.lock().unwrap();
            // reanchor_anchor (not the generic reanchor) so the audit event
            // attributes this repair to the running server identity with a
            // tool-specific reason, matching Swift's
            // `estate.reanchorAnchor(rowID:toLattice:changedBy: serverIdentity,
            // reason: "FDC reclassified via moot_reclassify_fdc", now:)` —
            // the generic `coord.reanchor` path stamps the estate owner and
            // a generic "reanchored via Estate.reanchor" reason, which
            // misattributes an automated repair in the audit trail.
            if let Err(e) = coord.reanchor_anchor(
                &estate.handle,
                &drawer.id,
                new_anchor,
                registry.server_identity.as_str(),
                "FDC reclassified via moot_reclassify_fdc",
            ) {
                return Ok(error_result(&describe_verb_dispatch_error(&e)));
            }
            applied += 1;
        }
    }

    let mut floor_after = prior_floor.clone();
    let floor_stamp_status = if apply
        && mode == FdcReclassifyMode::All
        && limit.is_none()
        && skipped_non_candidate_changes == 0
    {
        estate
            .store
            .set_meta(FDC_RECALCED_DATA_VERSION_META_KEY, &current_fdc_recalculation_version)
            .map_err(|e| {
                JSONRPCError::new(
                    JSONRPCErrorCode::TOOL_DISPATCH_FAILURE,
                    format!("fdc_reclassify: failed to stamp estate FDC floor: {e}"),
                )
            })?;
        floor_after = Some(current_fdc_recalculation_version.clone());
        "stamped".to_string()
    } else if !apply {
        "dry-run".to_string()
    } else if limit.is_some() {
        "skipped: limited run cannot update estate-wide floor".to_string()
    } else if mode != FdcReclassifyMode::All {
        "skipped: mode=all is required for an estate-wide floor".to_string()
    } else {
        "skipped: changed non-suspect anchors remain".to_string()
    };

    let limit_suffix = limit.map(|n| format!(" (limit {n})")).unwrap_or_default();
    let mut lines = vec![
        format!("fdc_reclassify: {}", if apply { "applied" } else { "dry-run" }),
        format!("mode: {}", mode.as_str()),
        format!("estate: [{}]", Uuid::from_bytes(estate.handle.estate_uuid)),
        format!("fdc_data_version: {current_fdc_data_version}"),
        format!("fdc_recalculation_version: {current_fdc_recalculation_version}"),
        format!("estate_recalced_data_version_before: {}", prior_floor.as_deref().unwrap_or("none")),
        format!("scanned: {scanned} active drawer(s){limit_suffix}"),
        format!("unchanged: {unchanged}"),
        format!("empty_content: {empty_content}"),
        format!("candidates: {candidate_count}"),
        if apply {
            format!("updated: {applied}")
        } else {
            format!("would_update: {candidate_count}")
        },
        format!("unclassified_after: {unclassified_after}"),
        format!("skipped_non_candidate_changes: {skipped_non_candidate_changes}"),
        format!("estate_recalced_data_version_after: {}", floor_after.as_deref().unwrap_or("none")),
        format!("floor_stamp: {floor_stamp_status}"),
    ];
    if !apply {
        lines.push("dry_run: pass apply=true to write candidate anchor changes".to_string());
    }
    if mode == FdcReclassifyMode::SuspectOnly && skipped_non_candidate_changes > 0 {
        lines.push(format!(
            "note: mode=suspectOnly left {skipped_non_candidate_changes} changed non-suspect anchor(s) untouched; rerun with mode=all to reset every changed active drawer from content"
        ));
    }
    if !examples.is_empty() {
        lines.push("changes:".to_string());
        for example in &examples {
            lines.push(format!(
                "  {}: {} -> {}",
                example.id,
                example.old_label(),
                example.new_label()
            ));
        }
        if candidate_count > examples.len() {
            lines.push(format!("  ... {} more", candidate_count - examples.len()));
        }
    }
    Ok(text_result(&lines.join("\n")))
}

/// Classify each content/kind pair to its FDC anchor across a bounded worker
/// pool, returning anchors in the SAME order as `inputs`.
///
/// Used by `run_reclassify_fdc` to parallelize the one expensive step of a
/// reclassify scan (running content through the v4 classifier + semantic
/// ranker). `eidetic_lib::lookup_no_record_with_kind` is a pure function of its arguments
/// over the pinned artifacts and is thread-safe for concurrent calls — the
/// no-record seam skips the shared novel-token cache write, and the reference
/// tables / ranker / Q-ID-closure memo it reads are read-only after init or
/// lock-guarded — so classifying in parallel yields the exact anchor each
/// content would produce serially, regardless of scheduling.
///
/// Bounded to the available core count via `std::thread::scope` over contiguous
/// chunks (no external dependency, so the `--offline` / `--locked` app builds
/// are unaffected). Each worker owns a disjoint output slice; contiguous
/// chunking of the input and output in lockstep preserves index order, so the
/// caller's serial audited-write phase sees the identical scan order.
fn classify_contents_in_parallel(
    inputs: &[(&str, lattice_lib::FdcContentKind)],
) -> Vec<eidetic_lib::Anchor> {
    let n = inputs.len();
    if n == 0 {
        return Vec::new();
    }
    let workers = std::thread::available_parallelism()
        .map(|c| c.get())
        .unwrap_or(1)
        .min(n);
    if workers <= 1 {
        return inputs
            .iter()
            .map(|(content, kind)| eidetic_lib::lookup_no_record_with_kind(content, *kind))
            .collect();
    }

    // Pre-size the output so workers write disjoint index ranges. The classify
    // is order-independent, so contiguous chunking preserves order: out[i] is
    // the anchor for contents[i].
    let mut results: Vec<Option<eidetic_lib::Anchor>> = (0..n).map(|_| None).collect();
    let chunk = n.div_ceil(workers);
    std::thread::scope(|scope| {
        for (out_chunk, in_chunk) in results.chunks_mut(chunk).zip(inputs.chunks(chunk)) {
            scope.spawn(move || {
                for (slot, (content, kind)) in out_chunk.iter_mut().zip(in_chunk.iter()) {
                    *slot = Some(eidetic_lib::lookup_no_record_with_kind(content, *kind));
                }
            });
        }
    });
    results
        .into_iter()
        .map(|a| a.expect("every slot classified exactly once"))
        .collect()
}

/// `moot_palace_import` — import a MemPalace directly into the estate,
/// bypassing NoteIR. Reads palace/chroma.sqlite3, tunnels.json, and
/// knowledge_graph.sqlite3 from `palace_path`, then applies all four
/// import guards (tombstone, content-idempotent dedup, sensitivity floor,
/// tunnel signature dedup). Mirrors Swift `runPalaceImport`.
fn run_palace_import(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve_direct(args)?;
    let palace_path = require_string(args, "palace_path")?;
    let palace_root = std::path::Path::new(&palace_path);
    let now = wall_now();
    // mut: PalaceBridge holds &mut EstateCoordinator (same pattern as VaultBridge).
    let mut coord = estate.coord.lock().unwrap();
    let mut bridge = PalaceBridge::new(&mut coord);
    // mode (encode SPEED, default foreground): foreground drains the encode queue
    // hard on the performance cores; background yields for very large imports. The
    // WRITE strategy (bulk vs stream) is chosen automatically by source size inside
    // PalaceBridge, never by the caller. Fail-closed on an unknown value.
    let mode = match args.get("mode").and_then(|v| v.as_str()).map(|s| s.to_lowercase()) {
        None => EncodeSpeed::Foreground,
        Some(ref s) if s == "foreground" => EncodeSpeed::Foreground,
        Some(ref s) if s == "background" => EncodeSpeed::Background,
        Some(_) => {
            return Ok(error_result(
                "mode must be \"foreground\" or \"background\"; omit it to use the default (foreground)",
            ));
        }
    };
    let report = match bridge.import_palace(palace_root, &estate.handle, now,
        Some(&|processed, total| {
            // Live progress to stderr, fired by the bridge every 10 records.
            // The MCP response is returned only at completion, so stderr is the
            // sole live-progress channel during a long background import.
            eprintln!("palace import: {processed}/{total} drawers");
        }),
        mode)
    {
        Ok(report) => report,
        Err(e) => return Ok(error_result(&format!("palace import failed: {e}"))),
    };
    // Release the bridge's &mut borrow AND the lock guard before handing off, so
    // the background thread can re-acquire the estate lock.
    drop(bridge);
    drop(coord);
    // DESIGN: the import TRIGGERS its own post-import processing in the BACKGROUND
    // and releases the caller immediately — it does NOT rely on the AI to run
    // moot_reindex / moot_dream next (that is not the design). A detached worker
    // thread runs `reindex_missing`, which enqueues an encode job for every imported
    // drawer (the resident daemon's encode-drain worker then ingests them into the
    // BM25 + vector lanes and rolls up the touched rooms off the write path) and runs
    // the O(N) Merkle `rollup_all`; the governor's dreaming duty builds the
    // association matrix on its cadence. This call returns the moment the import rows
    // are durable, so the AI is freed while indexing/rollup/dreaming proceed in the
    // background on the resident daemon. (In a stdio one-shot the process exits when
    // its input closes, so a caller that needs the background work to finish must keep
    // the connection open — the resident HTTP daemon is the intended host.)
    let bg_coord = std::sync::Arc::clone(&estate.coord);
    let bg_handle = estate.handle;
    std::thread::Builder::new()
        .name("palace-import-reindex".into())
        .spawn(move || {
            // Lock-free enqueue so the daemon stays responsive to other HTTP
            // calls during this 49k-drawer reindex (see run_reindex_responsive).
            match run_reindex_responsive(&bg_coord, &bg_handle, now) {
                Ok(n) => eprintln!(
                    "palace import: background processing complete — {n} drawers indexed to full coverage (auto-continued reindex), corpus embedding-basis retrained on the full import, Merkle rolled up; semantic/vector recall now live"
                ),
                Err(e) => eprintln!("palace import: background reindex failed: {e}"),
            }
        })
        .ok();
    Ok(text_result(&format!(
        "palace import complete: {} written, {} updated, {} unchanged, {} tombstoned, {} tunnels, {} skipped. \
         Rows are durable NOW, but recall lights up in stages — background indexing has started and is not yet finished (no follow-up call is needed). \
         Keyword (exact-term) and structured (wing/room) recall work almost immediately. \
         Full SEMANTIC / vector recall — meaning-based RAG search — becomes available only AFTER background indexing completes: every drawer is chunked and embedded, then the corpus embedding-basis is retrained on the whole import and republished, so recently-imported terms enter the semantic vocabulary. On a large import that takes tens of seconds to a few minutes. \
         BE PATIENT: poll moot_drain_status until it reports idle before relying on semantic search over the imported memories, and tell the user that deep meaning-based recall over a fresh import becomes available shortly after import, not instantly.",
        report.drawers_written,
        report.drawers_updated,
        report.drawers_skipped_unchanged,
        report.drawers_skipped_tombstoned,
        report.tunnels_created,
        report.items_skipped,
    )))
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
                 supersede, revive, accept, correctExportability(public), \
                 correctExportability(private), setSubject (with a `subject` argument)"
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
