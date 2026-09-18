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
//! - `embedding_model_id` = `"default"` (selects the default recall
//!   ensemble — RI and LSA fused in Lane D,
//!   trained on-corpus and reproducible cross-port; NOT a learned model-weight
//!   embedding)


use uuid::Uuid;

use locus_kit::adjectives::AdjectiveSensitivity;

use genius_locus_kit::{EncodeSpeed, VerbDispatchError, VerbError};



use vault_kit::json_import_bridge::JsonImportBridge;
use vault_kit::palace_bridge::PalaceBridge;

use crate::dispatch::bench_clock_now;
use crate::estate_registry::OpenEstate;
use crate::estate_posture::EstatePosture;
use crate::surfaced_recall_ledger::SurfacedRecallLedger;

// ---------------------------------------------------------------------------
// Server defaults — mirrors Swift ToolDispatch.swift constants
// ---------------------------------------------------------------------------

// NOTE: SERVER_ADDED_BY has been removed. The host identity is now carried in
// `EstateRegistry::server_identity`, injected at runtime startup so the shared
// dispatcher correctly stamps provenance for whichever binary is hosting it
// ("aria-mcp" or "mootx01"). Mirrors Swift `ToolDispatcher.serverIdentity`.

/// The canonical unclassified-content sentinel passed to the capture seam.
/// Matches `GeniusLocusKit::UNCLASSIFIED_SENTINEL` and the Swift
/// `GeniusLocusKit.unclassifiedSentinel`. The seam classifies the content
/// when it sees this sentinel (one-door principle). Previously "000.000"
/// (a child node); corrected to "000" (the UDC root, per the LatticeLib
/// Code grammar — the three-digit root is the correct unresolved sentinel).
// pub(crate) so the v2 data-mobility lower can read the same constant
// without duplicating it — single definition, both routes agree.
pub(crate) const DEFAULT_LATTICE_CODE: &str = "000";
/// Estate-wide floor: after a successful full FDC reclassification apply,
/// this key records the composite classifier/artifact version against which
/// every active stored anchor has been checked.
// pub(crate) so the v2 estate-diagnostics provider and data-mobility lower
// can read and stamp the same key without duplication.
pub(crate) const FDC_RECALCED_DATA_VERSION_META_KEY: &str = "aria.fdc.recalced_data_version";

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
///
/// `sensitivity_ledger` is the dispatcher's grant ledger: a live restricted
/// or secret grant floors the filed sensitivity (see the SECURITY note at
/// the decode site), the same ledger the recall runners read.


/// `true` if `f` constrains sensitivity anywhere in its structure (directly,
/// nested under `All`/`Any`, or negated). Used to suppress the out-of-band sensitivity grants
/// grant-ceiling injection when the caller's own `filter` argument already
/// specifies a sensitivity constraint — an explicit caller constraint
/// always wins over the grant-lifted default. Mirrors Swift
/// `ToolDispatcher.isSensitivityFilter` exactly.


/// Search memories in the estate using hybrid BM25+vector scored recall.
///
/// Requires `query`. Optional `door` (front-door family adjective; overrides
/// `scoring`), `scoring` (raw/rrf/matrixAware/discriminative; an unknown
/// non-empty value returns invalidParams), `limit` (default 20), and `ordering`
/// (see below). Scoring precedence: explicit door > explicit scoring > A1
/// per-corpus DoorManifest (provisioned by the quality optimizer) > MatrixAware.
/// Decodes the door/scoring arguments and routes through `recall_scored` with
/// mode=unionBest (the default for moot_memory_search).
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

/// Build the structured row for a drawer. The subject slot applies the same
/// redaction priority as `result_composer::candidate_from_drawer`:
/// restricted/secret sensitivity → marker → stored subject → absence marker.
/// The SAME provenance redaction extends to the content field: restricted/secret
/// rows never expose body content in the structured block. Content values at the
/// call site (`PreciseMatch.content`) are PRE-redaction; they must pass through
/// this switch, never directly into a row. Mirrors Swift
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
            content: content.map(|_| crate::result_composer::RESTRICTED_MARKER.to_string()),
            subject: Some(crate::result_composer::RESTRICTED_MARKER.to_string()),
        },
        Sensitivity::Secret => StructuredRow {
            id: id.to_string(),
            room,
            content: content.map(|_| crate::result_composer::SECRET_MARKER.to_string()),
            subject: Some(crate::result_composer::SECRET_MARKER.to_string()),
        },
        _ => StructuredRow {
            id: id.to_string(),
            room,
            content,
            subject: Some(
                drawer
                    .subject
                    .clone()
                    .unwrap_or_else(|| crate::result_composer::NO_SUBJECT_MARKER.to_string()),
            ),
        },
    }
}

/// Opaque structured row for an id the text path renders without a drawer
/// (gated or unhydrated). Subject is set to `NO_SUBJECT_MARKER` so the row
/// carries a non-nil subject (structurally admissible) while being
/// identifiable as opaque; room and content are absent. Readers that filter
/// on the marker skip opaque rows rather than surfacing them as "(no subject)"
/// entries for content the caller cannot see.
pub fn opaque_structured_row(id: &str) -> StructuredRow {
    StructuredRow {
        id: id.to_string(),
        room: None,
        content: None,
        subject: Some(crate::result_composer::NO_SUBJECT_MARKER.to_string()),
    }
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


/// The full-record block for one drawer — the depth:full tier and the
/// original single-id moot_memory_get reply shape. Shared by the single-id
/// path and the batch depth:full path. Mirrors Swift `fullRecordLines`.


/// Note that a drawer id was "used" (acted upon) by a dereference verb.
///
/// If the id is present in the session ledger (i.e., it was surfaced by a
/// prior `moot_memory_search` in this session), call `mark_recall_used` on
/// the coordinator so the dreaming daemon's reward sweep assigns reward 1.0
/// for that drawer's trace rows (DESIGN_TRACE_REWARD_2026-06-12.md).
///
/// Failures are silenced — a reward-marking failure must never break the
/// dereference verb's primary result.
pub(crate) fn note_usage(
    id: &str,
    estate: &crate::estate_registry::OpenEstate,
    ledger: &SurfacedRecallLedger,
    posture: EstatePosture,
) {
    // Frozen: the ledger still records what a search surfaced (it is
    // session memory, not estate state), but the reward mark is a
    // persistent write and is skipped. Mirrors Swift noteUsage.
    if posture.is_frozen() {
        return;
    }
    if let Some(entry) = ledger.get(id) {
        // Bench-clock: pins to MOOT_BENCH_EPOCH_NOW in replay; wall clock otherwise.
    let now = bench_clock_now();
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
/// accept.


/// Withdraw a memory (soft-delete). Requires `id`. Optional `reason`.
///


/// Permanently erase a memory. Requires `id`, `reason`, and `confirmed: true`.
///


/// Confirm a memory (promote to UserConfirmed). Requires `id`.
///


/// Move a memory to a different room. Requires `id` and `location`.
///
/// `location` maps to the new `room`.


// ===========================================================================
// Tier 2 — Connections
// ===========================================================================

/// Link two memories with a typed tunnel. Requires `from_id`, `to_id`, `kind`.
///
/// Looks up both drawers by ID to resolve their wing/room coordinates, then
/// calls `estate.capture_tunnel`.


/// Map a proposal's label family to the tier lens recorded on a
/// review-ladder vote. The label-family contract is GLK's
/// (`rejection_tier_of_label`: "dcp: " → tier 1, "tier2:" → 2,
/// "tier3:" → 3). Labels outside the matrix family (hunter-filed,
/// agent-filed) default to tier 3 — the weakest epistemic class, so a
/// vote on an unlabeled proposal never inflates its standing.


/// Review a PROPOSED tunnel on the MXE-CT3 review ladder (Rejected /
/// Proposed / Endorsed / Accepted):
///
/// - `accept` (user-only): activates via the existing
///   `respond_to_tunnel` path, recording the authenticated reviewer in the review
///   ledger. Edge activation is human-authoritative — a model reviewer
///   can NEVER activate, no matter how many endorsements accumulate.
/// - `reject` by the authenticated user: withdraws permanently
///   (durable dedup — never re-proposed).
/// - `reject` by an authenticated model: the AI-objection path
///   (`object_to_tunnel`) — withdraws only when no model endorsement
///   exists (reopenable); otherwise the tunnel stays proposed and is
///   marked contested for user attention.
/// - `endorse` (any reviewer, user included): records an endorsement
///   vote (`endorse_tunnel`) without touching lifecycle; weight feeds
///   review-queue ranking only.
///


/// List outgoing connections from a memory. Requires `from_id`.
///
/// Recalls the source drawer to resolve its wing, then reads tunnels from
/// that wing filtered by `source_drawer_id`.


/// List incoming connections to a memory. Requires `to_id`.
///
/// Scans tunnels across all wings (derived from recalling all drawers) and
/// filters by `target_drawer_id`.


// ===========================================================================
// Tier 3 — Knowledge graph
// ===========================================================================

/// File a knowledge-graph fact. Requires `subject`, `predicate`, `object`.
///
/// `source_id` grounds the fact; when the caller omits it, it defaults to the
/// ingest channel that asserted it (never unanchored). Calls
/// `coordinator.add_kg_fact`.


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


/// Retire a knowledge-graph fact. Requires `id`.
///
/// Transitions the fact to `Withdrawn` via `coordinator.withdraw_kg_fact`.


/// Format an epoch-seconds timestamp as an ISO8601 / RFC3339 UTC string.
///
/// Convert epoch seconds to ISO8601 UTC string.
///
/// `pub(crate)` so that `lens_tools` can call it directly for the
/// contradiction lens `filed=` field (Part 4 — filed_at ISO8601 fix).
/// Delegates to the canonical helper in NeuronKit's topology_analysis module;
/// the duplication in recipe_tools stays private (its own use only).


/// Minimal ISO8601 UTC parser — handles the subset the ARIA MCP server accepts.
///
/// Accepts "YYYY-MM-DDTHH:MM:SSZ", "YYYY-MM-DDTHH:MM:SS.mmmZ", and
/// "YYYY-MM-DDTHH:MM:SS+00:00". Returns epoch MILLISECONDS — the
/// fractional-seconds field is retained as the millisecond component, matching
/// Swift's `ISO8601DateFormatter().date(from:)` in `runFileMemory`.




/// Render a retired lifecycle cluster as its single-letter label for the
/// fact-timeline tag (`retired(B)` / `retired(C)`). Kept identical to the
/// Swift port's `clusterLabel` so both ports emit byte-identical tags.


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


// ===========================================================================
// Tier 4 — Journal
// ===========================================================================

/// Write a journal entry. Requires `entry`. Optional `agent` (default "mcp-agent").
///
/// Calls `coordinator.add_diary_entry`.


/// Read journal entries. Optional `agent` (default "mcp-agent") and `last_n` (default 10).
///
/// Uses `coordinator.diary_entries` to push agent_name equality into SQL via
/// idx_diary_agent — no post-fetch filter. Returns the most-recent `last_n`.
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
///   `[\(ISO8601)]  \(entry.prefix(200))`
/// The timestamp is bracketed and double-spaced before the entry text, matching
/// `ISO8601DateFormatter().string(from: e.filedAt)` in the Swift port.


// ===========================================================================
// Tier 5 — Estate
// ===========================================================================

/// Return estate statistics. Appends the ARIA session protocol block.
///
/// Counts active drawers, KG facts, and wings.
///
/// `sync:` reports the real ConvergenceKit backend state via
/// `EstateCoordinator::sync_state_token`. When no sync engine is registered
/// the field reads `"sync: local-only"`. The fabricated constant that
/// previously appeared here has been removed (OP-1 honesty fix).


/// Return the estate's memory taxonomy as a tree grouped by wing and room.
///
///
/// Wing and room display names are resolved from the node tree via
/// `coord.resolve_drawer_node_names`. All drawers (including hint memories
/// in AI_Charter_Hint) are counted normally — no special-casing.
/// `moot_memory_list` — enumerate drawer IDs in a wing, optionally filtered
/// by room. Structural inventory, not semantic search. Returns each drawer's
/// ID, room, and an 80-char content preview. Capped at 200 results.




/// Verify the estate is reachable. Returns a pong with estate name, UUID,
/// and the build serial of this running binary.
///
/// The build serial is forwarded from
/// `build_serial::derive()`, computed once at server startup and threaded
/// through the dispatch chain — no filesystem access per call.
///
/// Response format: `pong: estate <name> [<uuid>] is live — build <serial>`
///
/// The serial changes on every relink so a driver can confirm it is
/// talking to the most recently compiled binary. Override via
/// `MOOTX01_BUILD_SERIAL` to inject a known value (CI, tests, debugging).


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


// ===========================================================================
// Maintenance
// ===========================================================================

/// Typed receipt for a scheduled reindex. The v1 renderer supplies prose over
/// this direct lower result; v2 consumes it without entering that renderer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReindexLaunch {
    Running,
}

/// Source-faithful typed receipt from a MemPalace import.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PalaceImportReceipt {
    pub drawers_written: usize,
    pub drawers_updated: usize,
    pub drawers_skipped_unchanged: usize,
    pub drawers_skipped_tombstoned: usize,
    pub drawers_skipped_partial_write: usize,
    pub tunnels_created: usize,
    pub items_skipped: usize,
    pub fdc_classified: usize,
    pub fdc_unclassified: usize,
    pub fields_dropped: std::collections::BTreeMap<String, usize>,
    pub enqueued_for_encode: usize,
}

/// Source-faithful typed receipt from a seed JSON import.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonImportReceipt {
    pub seed_name: String,
    pub drawers_written: usize,
    pub facts_written: usize,
    pub tunnels_created: usize,
    pub enqueued_for_encode: usize,
    pub subjects_provided: i64,
    pub subjects_debt: i64,
    pub seed_sha256: String,
    pub drawer_id_by_record_id: std::collections::BTreeMap<String, String>,
}

/// Import failures preserve the v1 distinction between an input refusal and
/// an operational import failure while giving v2 a typed, non-rendered seam.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JsonImportFailure {
    Adapter(String),
    /// The seed file failed to decode or validate (`VaultKitError::SeedFileInvalid`);
    /// the message names the first offending element and is the caller's to fix.
    InvalidSeed(String),
    Failed(String),
}

/// Enqueue encode jobs for every active drawer that is not yet BM25/vector-
/// indexed in the estate. Returns the count enqueued. Idempotent. Mirrors
/// Requires `&mut` coord because
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
            // Reclaim superseded vector generations immediately after the shadow
            // swap so pending-reclaim rows are cleared within the same user-
            // visible operation rather than deferred to the weekly REM-BETA cycle
            // (VEC-SHADOWSWAP-01, finding 13b8e1a).
            //
            // `corpus.reindex` calls publishShadowGeneration, which atomically
            // flips the serving generation and marks the old one 'pending-reclaim'.
            // Nothing else clears that state until the next REM-BETA run — which
            // can be up to 7 days away. Running reclaim here closes the window.
            //
            // Non-fatal: a reclaim failure leaves the rows for the next BETA pass.
            // The rows are invisible to all queries; correctness is unaffected.
            let vs_opt = {
                let c = coord_arc
                    .lock()
                    .map_err(|_| "reindex: coordinator lock poisoned".to_string())?;
                c.vector_store_for(handle)
            };
            if let Some(vs) = vs_opt {
                match vs.reclaim_superseded_generations(None) {
                    Ok(summary) => {
                        let total_reclaimed: usize = summary.values().sum();
                        if total_reclaimed > 0 {
                            eprintln!("[reindex] reclaimed {total_reclaimed} superseded vector row(s) across {} model(s)", summary.len());
                        }
                    }
                    Err(e) => {
                        eprintln!("[reindex] reclaim_superseded_generations non-fatal: {e:?}");
                    }
                }
            }
        }
    }
    // Brief re-lock for the deferred Merkle full-tree rollup, once, after coverage.
    {
        let mut c = coord_arc
            .lock()
            .map_err(|_| "reindex: coordinator lock poisoned".to_string())?;
        c.rollup_after_reindex(handle, now)
            .map_err(|e| describe_verb_dispatch_error(&e))?;

        // C3 reindex-completion marker: the CYCLE tier-3 boundary — this is
        // the chokepoint every Rust reindex driver flows through. Estate-
        // anchored like the dream brackets; flag-gated with the A2 marker
        // facility; best-effort but LOGGED. Swift twin: reindexMissing tail.
        if c.encode_markers_on() {
            let session = format!("reindex-{now}-{total}");
            if let Err(e) = c.append_reindex_complete_marker(handle, total, &session, now) {
                eprintln!("[glk] reindexComplete marker failed: {e:?}");
            }
        }
    }
    Ok(total)
}

/// Schedule the source-faithful asynchronous reindex for one admitted estate.
/// The spawn failure remains intentionally non-fatal because the v1 behavior
/// has always acknowledged the request after opening the rebuild span.
pub fn start_reindex(open: &OpenEstate, now: i64) -> Result<ReindexLaunch, String> {
    // reindex now AUTO-CONTINUES (enqueue a pass → await its drain → re-collect)
    // to FULL coverage, which can take minutes on a large estate. Run it on a
    // detached worker so the HTTP handler returns immediately; the resident
    // daemon's encode-drain converges in the background. Poll moot_drain_status
    // to watch it finish. (Mirrors the palace-import background-processing model —
    // no repeated moot_reindex calls are needed, at any corpus size.)
    let bg_coord = std::sync::Arc::clone(&open.coord);
    let bg_handle = open.handle;
    // moot_rebuild_status span: opened BEFORE the worker thread spawns so the
    // status never reads idle in the scheduling gap between "reindex started"
    // and the backfill actually running; closed by the thread on every exit
    // path. Twin of Swift's reindexGuard + GLK span pairing.
    bg_coord.lock().unwrap().derived_rebuild_span(&bg_handle, true);
    std::thread::Builder::new()
        .name("reindex-backfill".into())
        .spawn(move || {
            match run_reindex_responsive(&bg_coord, &bg_handle, now) {
                Ok(n) => eprintln!(
                    "reindex: background backfill complete — {n} drawers indexed to full coverage"
                ),
                Err(e) => eprintln!("reindex: background backfill failed: {e}"),
            }
            bg_coord.lock().unwrap().derived_rebuild_span(&bg_handle, false);
        })
        .ok();
    Ok(ReindexLaunch::Running)
}



/// `moot_drain_status` — report every long-running background drain the estate
/// currently runs, for monitoring asynchronous work (e.g. watching an import's
/// encode queue converge after `moot_palace_import`).
///
/// Lightweight and pollable: unlike `moot_estate_status` it does NOT append the
/// ARIA session-protocol orientation block, because this tool is meant to be
/// called repeatedly while a drain settles. Today the only drain is
/// `corpus_encode`; the report is a LIST so additional drains surface here
/// automatically when they exist. Read-only.
///
/// Reserved lane name for the subject-backfill drain (PR-04): the
/// PR-09/10 rider registers a drain under this name and the generic
/// renderer carries it unchanged. Its `pending` will be a row-level
/// ELIGIBILITY count (subject debt), not queue depth — when the rider
/// lands, the benchmarker's `BARRIER_NON_GATING_LANES` denylist must
/// gain this name in the same mission (the distillation-lane
/// precedent).
pub const SUBJECT_BACKFILL_LANE_NAME: &str = "subject_backfill";

/// `moot_rebuild_status` — the derived-state rebuild operation status (Bob
/// ruling 2026-08-26: a rebuild is an OPERATION, never a drain lane — drains
/// are queues). Reports `rebuild: running` while a derived-rebuild span is
/// open for the estate (reindex backfill / basis retrain + re-embed, whoever
/// triggered it). `moot_estate_status` composes this line; settle gates poll
/// this tool directly.




/// Hard cap on audit events collected per `moot_timing_report` call.
///
/// The MCP tool surface is reachable by any connected client, so an uncapped
/// `since_ms: 0` scan was a caller-triggerable resource exhaustion: the
/// 4096-per-page loop bounded peak memory per PAGE, but the whole window
/// still accumulated in memory before deriving.
///
/// 262,144 = 64 full pages of 4,096. Chosen against measurement, not a round
/// number: the largest real estate observed (live CE estate, 2026-08-15)
/// carries 162,860 audit events (33 MB, ~216 B/row), so the cap is ~1.6×
/// that — every real estate today keeps single-call full-history semantics,
/// while the worst case is bounded at ~57 MB transient instead of unbounded.
/// Beyond the cap, the existing `watermark_ms` paging contract continues the
/// scan (clamp, not reject).


/// Collect the audit window for the timing derivation, capped at
/// `max_events` total events for the call.
///
/// The paging cursor is seeded from `since_ms` when > 0, matching Swift
/// `collectTimingWindow`: physical_time = since_ms, logical_count = 0,
/// node_id = 0 sits at the very start of that millisecond; same-millisecond
/// events with logical_count > 0 are re-fetched but excluded by
/// `derive_timings`' since_exclusive_ms guard (A6 exactly-once contract).
/// (The seed is load-bearing: an unseeded cursor pages the entire log from
/// epoch on every call, including incremental scans. Swift seeds its cursor
/// identically — the ports must not diverge here.)
///
/// Truncation semantics: when the cap cuts the window, tier 3/4 pair
/// captures whose markers land beyond the cut pair-lose for this call (they
/// surface in the report's `unbounded` counts), and events sharing the
/// boundary millisecond are excluded by the next call's since_exclusive_ms
/// guard. Acceptable for a statistical p50/p95 maintenance metric. The
/// returned bool is true when the window MAY have more events; the caller
/// pages forward with the returned watermark.


/// `moot_timing_report` — derive INGEST and CYCLE timing metrics from the
/// estate's audit log (C3+A6, benchmark reset 2026-08-13).
///
/// ONE derivation, TWO consumers (§6b): this tool and the future
/// performance-health duty both call neuron-kit's `derive_timings`, so the
/// benchmark and the product can never disagree about what "INGEST time"
/// means. Read-only and stateless server-side: the CALLER keeps the returned
/// `watermark_ms` and passes it back as `since_ms` for incremental scans (A6).
/// The window is capped at `TIMING_WINDOW_MAX_EVENTS` per call; a clamped
/// report says so on its final line. Like `run_drain_status`, no orientation
/// block — harnesses and duties call this repeatedly. Mirrors Swift


// pub(crate): the v2 data-mobility lower converts from V2FdcReclassifyMode
// (the v2 request type) to this enum before passing it to the shared helpers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FdcReclassifyMode {
    SuspectOnly,
    All,
}

impl FdcReclassifyMode {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::SuspectOnly => "suspectOnly",
            Self::All => "all",
        }
    }
}







// pub(crate): shared by v1 run_reclassify_fdc (below) and the v2 lower
// (data_mobility_lower.rs::reclassify_fdc). Single normalisation rule,
// both routes agree: empty or whitespace-only code becomes the sentinel.
pub(crate) fn normalized_fdc_code(code: &str) -> String {
    let trimmed = code.trim();
    if trimmed.is_empty() {
        DEFAULT_LATTICE_CODE.to_string()
    } else {
        trimmed.to_string()
    }
}

// pub(crate): shared by both routes for consistent QID normalisation.
pub(crate) fn normalized_qid(qid: Option<&str>) -> Option<String> {
    qid.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned)
}

// pub(crate): shared candidate-selection predicate. The v2 lower calls this
// with the same FdcReclassifyMode it converted from V2FdcReclassifyMode.
pub(crate) fn should_repair_fdc_anchor(
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
/// Recompute each active drawer's content anchor with the current deterministic
/// classifier, dry-run by default, and optionally write candidate changes through
/// the audited reanchor path.


/// Classify each content/kind pair to its FDC anchor across a bounded worker
/// pool, returning anchors in the SAME order as `inputs`.
// pub(crate): the v2 data-mobility lower calls this directly rather than
// going through run_reclassify_fdc (which builds a v1 text result and cannot
// return a structured V2ReclassifyFdcReport). Both callers share one parallel
// implementation so the determinism proof applies to both routes.
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
pub(crate) fn classify_contents_in_parallel(
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

/// Import a MemPalace through the typed VaultKit bridge and schedule its
/// source-required background index continuation without rendering a v1 result.
pub fn import_palace(
    open: &OpenEstate,
    palace_root: &std::path::Path,
    mode: EncodeSpeed,
    now: i64,
) -> Result<PalaceImportReceipt, String> {
    let mut coord = open.coord.lock().unwrap();
    let mut bridge = PalaceBridge::new(&mut coord);
    let report = bridge.import_palace(
        palace_root,
        &open.handle,
        now,
        Some(&|processed, total| eprintln!("palace import: {processed}/{total} drawers")),
        mode,
    ).map_err(|error| format!("palace import failed: {error}"))?;
    let receipt = PalaceImportReceipt {
        drawers_written: report.drawers_written,
        drawers_updated: report.drawers_updated,
        drawers_skipped_unchanged: report.drawers_skipped_unchanged,
        drawers_skipped_tombstoned: report.drawers_skipped_tombstoned,
        drawers_skipped_partial_write: report.drawers_skipped_partial_write,
        tunnels_created: report.tunnels_created,
        items_skipped: report.items_skipped,
        fdc_classified: report.fdc_classified,
        fdc_unclassified: report.fdc_unclassified,
        fields_dropped: report.fields_dropped,
        enqueued_for_encode: report.enqueued_for_encode,
    };
    drop(bridge);
    drop(coord);

    let bg_coord = std::sync::Arc::clone(&open.coord);
    let bg_handle = open.handle;
    std::thread::Builder::new()
        .name("palace-import-reindex".into())
        .spawn(move || {
            match run_reindex_responsive(&bg_coord, &bg_handle, now) {
                Ok(count) => eprintln!(
                    "palace import: background processing complete — {count} drawers indexed to full coverage (auto-continued reindex), corpus embedding-basis retrained on the full import, Merkle rolled up; semantic/vector recall now live"
                ),
                Err(error) => eprintln!("palace import: background reindex failed: {error}"),
            }
        })
        .ok();
    Ok(receipt)
}

/// `moot_palace_import` — import a MemPalace directly into the estate,
/// bypassing NoteIR. Reads palace/chroma.sqlite3, tunnels.json, and
/// knowledge_graph.sqlite3 from `palace_path`, then applies all four
/// import guards (tombstone, content-idempotent dedup, sensitivity floor,
/// tunnel signature dedup).


/// Import a schema-v1 seed file through the typed bridge. The result carries
/// the exact source receipt, including subject accounting and minted drawer IDs.
pub fn import_json_seed(
    open: &OpenEstate,
    seed_path: &std::path::Path,
    wing: Option<&str>,
    mode: EncodeSpeed,
    now: i64,
) -> Result<JsonImportReceipt, JsonImportFailure> {
    let mut coord = open.coord.lock().unwrap();
    let mut bridge = JsonImportBridge::new(&mut coord);
    let report = bridge.import_seed(
        seed_path,
        &open.handle,
        wing,
        now,
        Some(&|processed, total| eprintln!("json import: {processed}/{total} drawers")),
        mode,
    ).map_err(|error| match error {
        vault_kit::VaultKitError::AdapterError(message) => JsonImportFailure::Adapter(message),
        vault_kit::VaultKitError::SeedFileInvalid(message) => JsonImportFailure::InvalidSeed(message),
        error => JsonImportFailure::Failed(format!("json import failed: {error}")),
    })?;
    drop(bridge);
    drop(coord);

    // The bridge's encode sweep is ONE capped pass (`collect_reindex_jobs`,
    // at most `REINDEX_MAX_JOBS` drawers). The Swift bridge hands the rest to
    // `reindexMissingDeferred`, which continues in bounded passes in the
    // background until every imported drawer is indexed. Do the same here:
    // when the first pass filled the cap, a detached worker waits for that
    // pass to drain, then sweeps for what is still missing and continues
    // through `run_reindex_responsive`. Below the cap nothing is missing.
    // Observed 2026-09-18: a 19,195-drawer seed left 9,195 drawers with no
    // corpus vectors on this port while the Swift port indexed them all.
    if report.enqueued_for_encode
        >= genius_locus_kit::coordinator::EstateCoordinator::reindex_max_jobs_cap()
    {
        let bg_coord = std::sync::Arc::clone(&open.coord);
        let bg_handle = open.handle;
        std::thread::Builder::new()
            .name("json-import-reindex".into())
            .spawn(move || {
                let corpus = bg_coord.lock().ok().and_then(|c| c.corpus_handle(&bg_handle));
                if let Some(corpus) = corpus {
                    // The first pass must finish draining before the sweep,
                    // or its queued jobs read as still missing and are
                    // enqueued twice. POLL, do not pump.
                    loop {
                        match corpus.ingest_queue_depth() {
                            Ok((0, 0)) => break,
                            Ok(_) => std::thread::sleep(std::time::Duration::from_millis(200)),
                            Err(_) => break,
                        }
                    }
                }
                match run_reindex_responsive(&bg_coord, &bg_handle, now) {
                    Ok(n) => eprintln!(
                        "json import: background backfill complete — {n} more drawers indexed to full coverage"
                    ),
                    Err(e) => eprintln!("json import: background backfill failed: {e}"),
                }
            })
            .ok();
    }
    Ok(JsonImportReceipt {
        seed_name: report.seed_name,
        drawers_written: report.drawers_written,
        facts_written: report.facts_written,
        tunnels_created: report.tunnels_created,
        enqueued_for_encode: report.enqueued_for_encode,
        subjects_provided: report.subjects_provided,
        subjects_debt: report.subjects_debt,
        seed_sha256: report.seed_sha256,
        drawer_id_by_record_id: report.drawer_id_by_record_id,
    })
}

/// `moot_json_import` — import a seed file (rigid versioned JSON, schema
/// v1) into the estate: the bulk seeding lane. The whole file is validated
/// before any write; any schema violation or lineage collision (strict
/// append) is a tool-level error naming the offending element with the
/// estate untouched — the zero-partial-write contract. The selected surface performs
/// vault admission before this lower seam,
/// alongside `moot_palace_import`'s gate.


// ===========================================================================
// Argument decoders
// ===========================================================================

/// Map a mutation string to `MutationKind`. Returns `Err(invalidParams)` for
/// unknown strings.
///
/// Exportability mutations (DEBT-1 write path):
///   "correctExportability(public)"  → `MutationKind::CorrectExportability(Public)`
///   "correctExportability(private)" → `MutationKind::CorrectExportability(Private)`


/// Decode the optional `exportability` arg for a capture call.
///
/// Absent → `Private` (privacy-preserving default; all existing callers
/// continue to produce private drawers — DEBT-1 write-side fix).
/// Accepted string values: `"private"` → `Private`, `"public"` → `Public`.
/// Mirrors Swift `ToolDispatch.decodeExportability(_:)`.


/// Decode the optional `kind` arg for a file_memory capture call.
///
/// Absent → `None` (caller keeps the `CaptureFrame` default of `Prose`).
/// Unknown → `INVALID_PARAMS` listing accepted values.
/// Mirrors Swift `ToolDispatch.decodeContentKind(_:)`.


/// Decode the optional `sensitivity` arg for a file_memory capture call.
///
/// Absent → `None` (caller keeps the `CaptureFrame` default of `Normal`).
/// Unknown → `INVALID_PARAMS` listing accepted values.
/// Mirrors Swift `ToolDispatch.decodeSensitivity(_:)`.


/// The `sensitivity` argument spelling of a tier, the inverse of
/// `decode_sensitivity_arg`; used in replies and refusals that name a tier.
/// Mirrors Swift `ToolDispatcher.sensitivityArgumentName`. Shared with
/// `memory_adapter`, whose write replies name the tier the same way.
pub(crate) fn sensitivity_argument_name(sensitivity: AdjectiveSensitivity) -> &'static str {
    match sensitivity {
        AdjectiveSensitivity::Normal => "normal",
        AdjectiveSensitivity::Elevated => "elevated",
        AdjectiveSensitivity::Restricted => "restricted",
        AdjectiveSensitivity::Secret => "secret",
    }
}
