//! v2b-p2 lexicon surface: full AriaLexicon acceptance-matrix fan-out.
//!
//! Extends v2b-p1 (moot_capture_drawer, moot_drawer_recall, moot_capture_tunnel,
//! moot_mutate_drawer, moot_withdraw_drawer, moot_expunge_drawer,
//! moot_reanchor_drawer, moot_tunnel_recall) with the remaining 20 projected
//! lexicon tools plus the moot_cross_estate_recall federation stub.
//!
//! New tool groups:
//!   tunnel lifecycle: moot_mutate_tunnel, moot_withdraw_tunnel, moot_expunge_tunnel
//!   kgFact: moot_mutate_kgFact, moot_withdraw_kgFact, moot_expunge_kgFact, moot_kgFact_recall
//!   diaryEntry: moot_diaryEntry_recall
//!   proposal: moot_mutate_proposal, moot_withdraw_proposal, moot_expunge_proposal, moot_proposal_recall
//!   association: moot_mutate_association, moot_expunge_association, moot_association_recall
//!   learnedReference: moot_learn_learnedReference, moot_mutate_learnedReference,
//!                     moot_withdraw_learnedReference, moot_expunge_learnedReference,
//!                     moot_learnedReference_recall
//!   federation: moot_cross_estate_recall (scaffold — grant model not yet built)
//!
//! Domain errors (NotSupportedByEstate, ExpungeNotConfirmed, EmptyReanchor,
//! UnderlyingEstateFailure) surface as `error_result` tool responses (isError:
//! true), NOT as JSONRPCError transport faults — matching the Swift
//! ToolDispatcher's VerbError discipline (ToolDispatch.swift:184-192). Only
//! out-of-band conditions (missing required args, unknown estate, malformed
//! args) surface as JSONRPCError.
//!
//! Arg names are wire-identical to the Swift server for the tools that appear
//! in both (content, room, udcCode, addedBy, embeddingModelID, classificationScheme,
//! filter, limit, ordering, hydrationLevel, rowID, kind, reason, confirmation).
//!
//! # Swift-side reconciliation items
//!
//! The Swift server has no live handlers for the following tools; they fall
//! through to methodNotFound. The Rust server surfaces error_result instead
//! (better client experience). Each item below is flagged for Swift parity once
//! the Swift handlers land:
//!   - All recall tools for non-drawer nouns (kgFact, diaryEntry, proposal,
//!     association, learnedReference): Rust returns NotSupportedByEstate because
//!     the DrawerStore trait lacks all-rows accessors for these types.
//!   - moot_learn_learnedReference: both sides return NotSupportedByEstate.
//!   - moot_cross_estate_recall: the Rust GLK fan_out has no grant model;
//!     advertised but returns "not yet implemented: federation requires the grant
//!     model". The Swift side DOES have a live handler (but no test estate grants).
//!
//! # classificationScheme
//!
//! Per spec §5.8 (dual-scheme model), `capture_drawer` accepts an optional
//! `classificationScheme` arg: "udc" (default) or "mdcc". The substrate's
//! `LatticeAnchor` does not yet carry a scheme tag (a separate storage migration),
//! so both schemes construct the same anchor today; the discriminator's job is to
//! let a caller DECLARE and validate the scheme. The validated scheme is echoed in
//! the capture result, matching the Swift `ToolDispatcher.runCaptureDrawer` behavior.
//! This type is ARIA_MCP-local — it does not exist in LocusKit or any Rust kit.

use std::collections::BTreeMap;

use genius_locus_kit::EstateCoordinator;
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    drawer_operational::{CaptureChannel, ContentKind},
    estate_types::LatticeAnchor,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::{CaptureFrame, MutationKind, TunnelCaptureFrame},
};

use crate::dispatch::{error_result, require_string, text_result};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

// v1 lexicon minimum.
const CAPTURE_DRAWER: &str = "moot_capture_drawer";
const RECALL_DRAWER: &str = "moot_drawer_recall";
const CAPTURE_TUNNEL: &str = "moot_capture_tunnel";
// v2b-p1: drawer lifecycle verbs + tunnel graph read.
const MUTATE_DRAWER: &str = "moot_mutate_drawer";
const WITHDRAW_DRAWER: &str = "moot_withdraw_drawer";
const EXPUNGE_DRAWER: &str = "moot_expunge_drawer";
const REANCHOR_DRAWER: &str = "moot_reanchor_drawer";
const TUNNEL_RECALL: &str = "moot_tunnel_recall";
// v2b-p2: full acceptance-matrix fan-out.
const MUTATE_TUNNEL: &str = "moot_mutate_tunnel";
const WITHDRAW_TUNNEL: &str = "moot_withdraw_tunnel";
const EXPUNGE_TUNNEL: &str = "moot_expunge_tunnel";
const MUTATE_KG_FACT: &str = "moot_mutate_kgFact";
const WITHDRAW_KG_FACT: &str = "moot_withdraw_kgFact";
const EXPUNGE_KG_FACT: &str = "moot_expunge_kgFact";
const KG_FACT_RECALL: &str = "moot_kgFact_recall";
const DIARY_ENTRY_RECALL: &str = "moot_diaryEntry_recall";
const MUTATE_PROPOSAL: &str = "moot_mutate_proposal";
const WITHDRAW_PROPOSAL: &str = "moot_withdraw_proposal";
const EXPUNGE_PROPOSAL: &str = "moot_expunge_proposal";
const PROPOSAL_RECALL: &str = "moot_proposal_recall";
const MUTATE_ASSOCIATION: &str = "moot_mutate_association";
const EXPUNGE_ASSOCIATION: &str = "moot_expunge_association";
const ASSOCIATION_RECALL: &str = "moot_association_recall";
const LEARN_LEARNED_REFERENCE: &str = "moot_learn_learnedReference";
const MUTATE_LEARNED_REFERENCE: &str = "moot_mutate_learnedReference";
const WITHDRAW_LEARNED_REFERENCE: &str = "moot_withdraw_learnedReference";
const EXPUNGE_LEARNED_REFERENCE: &str = "moot_expunge_learnedReference";
const LEARNED_REFERENCE_RECALL: &str = "moot_learnedReference_recall";
/// Federation tool name. Sits above the lexicon projection; dispatched by name
/// via the top-level dispatch.rs router (not through is_lexicon_tool).
pub const CROSS_ESTATE_RECALL: &str = "moot_cross_estate_recall";

/// The classification scheme a lattice-anchor code belongs to.
///
/// Per spec §5.8 (dual-scheme model), an anchor code may be a UDC code or an
/// MDCC code. `moot_capture_drawer` lets a caller declare which scheme its
/// `udcCode` argument uses; "udc" is the default so omitting the discriminator
/// preserves the original UDC-only behavior. The scheme is validated and echoed
/// at the ARIA boundary — the substrate's `LatticeAnchor` does not yet carry a
/// scheme tag (separate storage migration), so this type lives here in
/// `lexicon_tools`, not in LocusKit. Wire-identical to Swift `ClassificationScheme`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClassificationScheme {
    Udc,
    Mdcc,
}

impl ClassificationScheme {
    /// The raw string value echoed in capture results and accepted as input.
    /// Wire-identical to Swift `ClassificationScheme.rawValue`.
    pub fn raw_value(self) -> &'static str {
        match self {
            ClassificationScheme::Udc => "udc",
            ClassificationScheme::Mdcc => "mdcc",
        }
    }
}

/// True when `name` is one of the lexicon tools (v1, v2b-p1, v2b-p2).
/// The federation tool `moot_cross_estate_recall` is NOT included here —
/// it is dispatched by name in `dispatch.rs` before the lexicon check,
/// matching the Swift ToolDispatcher's routing order for above-projection tools.
pub fn is_lexicon_tool(name: &str) -> bool {
    matches!(
        name,
        // v1
        CAPTURE_DRAWER
            | RECALL_DRAWER
            | CAPTURE_TUNNEL
            // v2b-p1
            | MUTATE_DRAWER
            | WITHDRAW_DRAWER
            | EXPUNGE_DRAWER
            | REANCHOR_DRAWER
            | TUNNEL_RECALL
            // v2b-p2: tunnel lifecycle
            | MUTATE_TUNNEL
            | WITHDRAW_TUNNEL
            | EXPUNGE_TUNNEL
            // v2b-p2: kgFact
            | MUTATE_KG_FACT
            | WITHDRAW_KG_FACT
            | EXPUNGE_KG_FACT
            | KG_FACT_RECALL
            // v2b-p2: diaryEntry
            | DIARY_ENTRY_RECALL
            // v2b-p2: proposal
            | MUTATE_PROPOSAL
            | WITHDRAW_PROPOSAL
            | EXPUNGE_PROPOSAL
            | PROPOSAL_RECALL
            // v2b-p2: association
            | MUTATE_ASSOCIATION
            | EXPUNGE_ASSOCIATION
            | ASSOCIATION_RECALL
            // v2b-p2: learnedReference
            | LEARN_LEARNED_REFERENCE
            | MUTATE_LEARNED_REFERENCE
            | WITHDRAW_LEARNED_REFERENCE
            | EXPUNGE_LEARNED_REFERENCE
            | LEARNED_REFERENCE_RECALL
    )
}

/// Dispatch a lexicon tool call.
pub fn dispatch(
    name: &str,
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    let estate = registry.resolve(args, "estateID")?;
    let mut coord = estate.coord.lock().unwrap();
    match name {
        // v1 lexicon minimum.
        CAPTURE_DRAWER => run_capture_drawer(args, &mut coord, estate),
        RECALL_DRAWER => run_recall_drawer(args, &coord, estate),
        CAPTURE_TUNNEL => run_capture_tunnel(args, &mut coord, estate),
        // v2b-p1: drawer lifecycle verbs + tunnel recall.
        MUTATE_DRAWER => run_mutate_drawer(args, &coord, estate),
        WITHDRAW_DRAWER => run_withdraw_drawer(args, &coord, estate),
        EXPUNGE_DRAWER => run_expunge_drawer(args, &coord, estate),
        REANCHOR_DRAWER => run_reanchor_drawer(args, &coord, estate),
        TUNNEL_RECALL => run_tunnel_recall(args, &coord, estate),
        // v2b-p2: tunnel lifecycle. Routes through the drawer path — the
        // estate's mutate/withdraw/expunge verbs address rows by ID; a
        // non-drawer row ID surfaces DrawerNotFound → UnderlyingEstateFailure,
        // which is the correct observable behavior at this stage. Mirrors the
        // Swift ToolDispatcher's noun-agnostic routing for these verbs.
        MUTATE_TUNNEL => run_noun_mutate(args, &coord, estate, "tunnel"),
        WITHDRAW_TUNNEL => run_noun_withdraw(args, &coord, estate, "tunnel"),
        EXPUNGE_TUNNEL => run_noun_expunge(args, &coord, estate, "tunnel"),
        // v2b-p2: kgFact lifecycle and recall.
        MUTATE_KG_FACT => run_noun_mutate(args, &coord, estate, "kgFact"),
        WITHDRAW_KG_FACT => run_noun_withdraw(args, &coord, estate, "kgFact"),
        EXPUNGE_KG_FACT => run_noun_expunge(args, &coord, estate, "kgFact"),
        KG_FACT_RECALL => run_kg_fact_recall(&coord, estate),
        // v2b-p2: diaryEntry recall (read-only; no lifecycle verbs on the surface).
        DIARY_ENTRY_RECALL => run_diary_entry_recall(&coord, estate),
        // v2b-p2: proposal lifecycle and recall.
        MUTATE_PROPOSAL => run_noun_mutate(args, &coord, estate, "proposal"),
        WITHDRAW_PROPOSAL => run_noun_withdraw(args, &coord, estate, "proposal"),
        EXPUNGE_PROPOSAL => run_noun_expunge(args, &coord, estate, "proposal"),
        PROPOSAL_RECALL => run_proposal_recall(&coord, estate),
        // v2b-p2: association lifecycle (no withdraw — not in acceptance matrix)
        // and recall.
        MUTATE_ASSOCIATION => run_noun_mutate(args, &coord, estate, "association"),
        EXPUNGE_ASSOCIATION => run_noun_expunge(args, &coord, estate, "association"),
        ASSOCIATION_RECALL => run_association_recall(&coord, estate),
        // v2b-p2: learnedReference learn + lifecycle + recall.
        LEARN_LEARNED_REFERENCE => run_learn_learned_reference(args, &coord, estate),
        MUTATE_LEARNED_REFERENCE => run_noun_mutate(args, &coord, estate, "learnedReference"),
        WITHDRAW_LEARNED_REFERENCE => run_noun_withdraw(args, &coord, estate, "learnedReference"),
        EXPUNGE_LEARNED_REFERENCE => run_noun_expunge(args, &coord, estate, "learnedReference"),
        LEARNED_REFERENCE_RECALL => run_learned_reference_recall(&coord, estate),
        _ => Err(JSONRPCError::new(
            JSONRPCErrorCode::METHOD_NOT_FOUND,
            format!("Unknown lexicon tool: {name}"),
        )),
    }
}

// ---------------------------------------------------------------------------
// moot_capture_drawer
// ---------------------------------------------------------------------------

fn run_capture_drawer(
    args: &BTreeMap<String, JsonValue>,
    coord: &mut EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    let content = require_string(args, "content")?;
    let room = require_string(args, "room")?;
    let udc_code = require_string(args, "udcCode")?;
    let added_by = require_string(args, "addedBy")?;
    let model_id = require_string(args, "embeddingModelID")?;

    let channel = decode_channel(args.get("channel").and_then(|v| v.as_str()))?;
    let sensitivity = decode_sensitivity(args.get("sensitivity").and_then(|v| v.as_str()))?;
    let kind = decode_content_kind(args.get("kind").and_then(|v| v.as_str()))?;
    // Validate the declared classification scheme at the ARIA boundary.
    // The substrate's LatticeAnchor stores a bare code with no scheme tag yet
    // (a separate storage migration, §5.8 dual-scheme model), so both schemes
    // construct the same anchor today; the discriminator's job is to let a caller
    // DECLARE the scheme and have it validated here. Echoed in the result so the
    // caller can confirm how its code was interpreted. Matches Swift behavior.
    let scheme =
        decode_classification_scheme(args.get("classificationScheme").and_then(|v| v.as_str()))?;

    let mut frame = CaptureFrame::new(
        content,
        channel,
        room,
        LatticeAnchor::udc(udc_code),
        added_by,
        model_id,
    );
    frame.sensitivity = sensitivity;
    frame.kind = kind;

    let now = crate::dispatch::wall_now();
    let drawer = coord.capture(&estate.handle, frame, now).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}"))
    })?;

    Ok(text_result(&format!(
        "captured drawer {}\nroom: {}\nscheme: {}",
        drawer.id,
        drawer.room,
        scheme.raw_value()
    )))
}

// ---------------------------------------------------------------------------
// moot_drawer_recall
// ---------------------------------------------------------------------------

fn run_recall_drawer(
    args: &BTreeMap<String, JsonValue>,
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    let filter = decode_filter_arg(args.get("filter").and_then(|v| v.as_str()));
    let hydration = decode_hydration(args.get("hydrationLevel").and_then(|v| v.as_str()))?;
    let ordering = decode_ordering(args.get("ordering").and_then(|v| v.as_str()))?;
    let limit = args
        .get("limit")
        .and_then(|v| v.as_i64())
        .map(|i| i as usize);

    let mut frame = RecallFrame::new(vec![filter]);
    frame.hydration_level = hydration;
    frame.ordering = ordering;
    frame.limit = limit;

    let now = crate::dispatch::wall_now();
    let rows = coord.recall(&estate.handle, frame, now).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}"))
    })?;

    let header = format!("recalled {} drawer(s)", rows.len());
    let lines: Vec<String> = rows
        .iter()
        .take(50) // cap at 50 rows per the Swift server's discipline
        .map(|d| {
            format!(
                "{}  [{}]  {}",
                d.id,
                d.room,
                &d.content[..d.content.len().min(80)]
            )
        })
        .collect();
    let body = std::iter::once(header)
        .chain(lines)
        .collect::<Vec<_>>()
        .join("\n");
    Ok(text_result(&body))
}

// ---------------------------------------------------------------------------
// moot_capture_tunnel
// ---------------------------------------------------------------------------

fn run_capture_tunnel(
    args: &BTreeMap<String, JsonValue>,
    coord: &mut EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    let source_wing = require_string(args, "sourceWing")?;
    let source_room = require_string(args, "sourceRoom")?;
    let target_wing = require_string(args, "targetWing")?;
    let target_room = require_string(args, "targetRoom")?;
    let kind_str = require_string(args, "kind")?;
    let added_by = require_string(args, "addedBy")?;
    let source_drawer_id = args
        .get("sourceDrawerID")
        .and_then(|v| v.as_str())
        .map(str::to_owned);
    let target_drawer_id = args
        .get("targetDrawerID")
        .and_then(|v| v.as_str())
        .map(str::to_owned);

    // TunnelCaptureFrame::new takes (source_wing, source_room, target_wing,
    // target_room, label, added_by) — 6 args. The tunnel kind is the label.
    let mut frame = TunnelCaptureFrame::new(
        source_wing,
        source_room,
        target_wing,
        target_room,
        kind_str, // kind string used as the relation label
        added_by,
    );
    frame.source_drawer_id = source_drawer_id;
    frame.target_drawer_id = target_drawer_id;

    let now = crate::dispatch::wall_now();
    // capture_tunnel lives on the Estate, accessed via EstateCoordinator::estate_for.
    let locus_estate = coord.estate_for(&estate.handle).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}"))
    })?;
    let tunnel = locus_estate.capture_tunnel(frame, now).map_err(|e| {
        JSONRPCError::new(JSONRPCErrorCode::TOOL_DISPATCH_FAILURE, format!("{e:?}"))
    })?;

    Ok(text_result(&format!("captured tunnel {}", tunnel.id)))
}

// ---------------------------------------------------------------------------
// moot_mutate_drawer  (v2b-p1)
// ---------------------------------------------------------------------------

/// Apply a named mutation to a drawer. The Confirm kind transitions the row's
/// confirmation axis to UserConfirmed. State-axis kinds (Reject, Contest,
/// Resolve, Supersede, Revive) are not yet wired in LocusKit and return
/// NotSupportedByEstate, surfaced as an error_result per the Swift
/// ToolDispatcher VerbError discipline (ToolDispatch.swift:184-192).
fn run_mutate_drawer(
    args: &BTreeMap<String, JsonValue>,
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    let row_id = require_string(args, "rowID")?;
    let kind_name = require_string(args, "kind")?;
    let kind = decode_mutation_kind(kind_name)?;
    let payload = args.get("payload").and_then(|v| v.as_str());

    match coord.mutate(&estate.handle, row_id, kind, payload) {
        Ok(()) => Ok(text_result(&format!(
            "mutated drawer {row_id} ({kind_name})"
        ))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

// ---------------------------------------------------------------------------
// moot_withdraw_drawer  (v2b-p1)
// ---------------------------------------------------------------------------

/// Move a drawer's state to withdrawn. Parity of the Swift
/// `ToolDispatcher.runWithdraw`. VerbErrors surface as error_result.
fn run_withdraw_drawer(
    args: &BTreeMap<String, JsonValue>,
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    let row_id = require_string(args, "rowID")?;
    let reason = args.get("reason").and_then(|v| v.as_str());

    let now = crate::dispatch::wall_now();
    match coord.withdraw(&estate.handle, row_id, reason, now) {
        Ok(()) => Ok(text_result(&format!("withdrew drawer {row_id}"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

// ---------------------------------------------------------------------------
// moot_expunge_drawer  (v2b-p1)
// ---------------------------------------------------------------------------

/// Tombstone a drawer and zeroize its content. Requires `confirmation: true`;
/// expunge with confirmation omitted or false is refused without reaching the
/// estate — matching the coordinator's boundary guard and the Swift
/// `ToolDispatcher.runExpunge` behavior. VerbErrors surface as error_result.
fn run_expunge_drawer(
    args: &BTreeMap<String, JsonValue>,
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    let row_id = require_string(args, "rowID")?;
    let reason = require_string(args, "reason")?;
    // Absent or non-boolean confirmation is treated as false per the Swift side
    // (ToolDispatch.swift:327: `args["confirmation"]?.boolValue ?? false`).
    let confirmation = args
        .get("confirmation")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    match coord.expunge(&estate.handle, row_id, reason, confirmation) {
        Ok(()) => Ok(text_result(&format!("expunged drawer {row_id}"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

// ---------------------------------------------------------------------------
// moot_reanchor_drawer  (v2b-p1)
// ---------------------------------------------------------------------------

/// Move a drawer's room and/or lattice anchor. An empty reanchor (neither
/// toRoom nor toUDC supplied) is refused at the coordinator boundary without
/// reaching the estate — parity of the Swift `ToolDispatcher.runReanchor`
/// boundary guard. VerbErrors surface as error_result.
fn run_reanchor_drawer(
    args: &BTreeMap<String, JsonValue>,
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    let row_id = require_string(args, "rowID")?;
    let to_room = args.get("toRoom").and_then(|v| v.as_str());
    let to_udc = args.get("toUDC").and_then(|v| v.as_str());
    let to_lattice = to_udc.map(LatticeAnchor::udc);

    match coord.reanchor(&estate.handle, row_id, to_room, to_lattice) {
        Ok(()) => Ok(text_result(&format!("reanchored drawer {row_id}"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

// ---------------------------------------------------------------------------
// moot_tunnel_recall  (v2b-p1)
// ---------------------------------------------------------------------------

/// Read the tunnels originating in `wing` from the estate. The wing is the
/// graph partition: outgoing edges from that wing's drawers. Returns all
/// tunnels in insertion order (the coordinator delegates to
/// `Estate::tunnels_from_wing`). VerbErrors surface as error_result.
fn run_tunnel_recall(
    args: &BTreeMap<String, JsonValue>,
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    let wing = require_string(args, "wing")?;

    match coord.recall_tunnels(&estate.handle, wing) {
        Ok(tunnels) => {
            let header = format!("recalled {} tunnel(s) from wing {wing}", tunnels.len());
            let lines: Vec<String> = tunnels
                .iter()
                .take(50) // cap at 50 per the Swift server's discipline on wide recalls
                .map(|t| {
                    format!(
                        "{}  {} -> {}/{}",
                        t.id, t.source_wing, t.target_wing, t.target_room
                    )
                })
                .collect();
            let body = std::iter::once(header)
                .chain(lines)
                .collect::<Vec<_>>()
                .join("\n");
            Ok(text_result(&body))
        }
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

// ---------------------------------------------------------------------------
// Argument decoders (lexicon-specific)
// ---------------------------------------------------------------------------

fn decode_classification_scheme(name: Option<&str>) -> Result<ClassificationScheme, JSONRPCError> {
    // Absent defaults to Udc, preserving the prior bare-UDC behavior so no
    // existing caller breaks. An unrecognized scheme is an out-of-band client
    // error (invalidParams), consistent with the other enum decoders in this
    // file. Matches Swift `ToolDispatcher.decodeClassificationScheme(_:)`.
    match name {
        None | Some("udc") => Ok(ClassificationScheme::Udc),
        Some("mdcc") => Ok(ClassificationScheme::Mdcc),
        Some(unknown) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown classification scheme: {unknown}"),
        )),
    }
}

/// Decode a mutation kind from its wire name. Wire names match the Swift
/// `decodeMutationKind` argument names (ToolDispatch.swift). CorrectSensitivity
/// and CorrectTrust are not exposed on the MCP surface (they require typed
/// companion args; a future schema extension can add them). An unknown kind
/// is an invalidParams transport fault — the caller supplied a bad value,
/// not a substrate refusal.
fn decode_mutation_kind(name: &str) -> Result<MutationKind, JSONRPCError> {
    match name {
        "confirm" => Ok(MutationKind::Confirm),
        "reject" => Ok(MutationKind::Reject),
        "contest" => Ok(MutationKind::Contest),
        "resolve" => Ok(MutationKind::Resolve),
        "supersede" => Ok(MutationKind::Supersede),
        "revive" => Ok(MutationKind::Revive),
        "accept" => Ok(MutationKind::Accept),
        unknown => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown mutation kind: {unknown}"),
        )),
    }
}

fn decode_channel(name: Option<&str>) -> Result<CaptureChannel, JSONRPCError> {
    match name {
        None | Some("typed") => Ok(CaptureChannel::Typed),
        Some("voiced") => Ok(CaptureChannel::Voiced),
        Some("ocr") => Ok(CaptureChannel::Ocr),
        Some("importedFile") => Ok(CaptureChannel::ImportedFile),
        Some("sensor") => Ok(CaptureChannel::Sensor),
        Some(unknown) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown channel: {unknown}"),
        )),
    }
}

fn decode_sensitivity(name: Option<&str>) -> Result<AdjectiveSensitivity, JSONRPCError> {
    match name {
        None | Some("normal") => Ok(AdjectiveSensitivity::Normal),
        Some("elevated") => Ok(AdjectiveSensitivity::Elevated),
        Some("restricted") => Ok(AdjectiveSensitivity::Restricted),
        Some("secret") => Ok(AdjectiveSensitivity::Secret),
        Some(unknown) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown sensitivity: {unknown}"),
        )),
    }
}

fn decode_content_kind(name: Option<&str>) -> Result<ContentKind, JSONRPCError> {
    match name {
        None | Some("prose") => Ok(ContentKind::Prose),
        Some("code") => Ok(ContentKind::Code),
        Some("transcript") => Ok(ContentKind::Transcript),
        Some("list") => Ok(ContentKind::List),
        Some("structuredJSON") => Ok(ContentKind::StructuredJson),
        Some("imageCaption") => Ok(ContentKind::ImageCaption),
        Some(unknown) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown content kind: {unknown}"),
        )),
    }
}

fn decode_filter_arg(name: Option<&str>) -> Filter {
    match name {
        Some("userConfirmed") => Filter::UserConfirmed,
        Some("exportable") => Filter::Exportable,
        Some("contained") => Filter::Contained,
        _ => Filter::Unconfirmed,
    }
}

fn decode_hydration(name: Option<&str>) -> Result<HydrationLevel, JSONRPCError> {
    match name {
        None | Some("structured") => Ok(HydrationLevel::Structured),
        Some("full") => Ok(HydrationLevel::Full),
        Some("bitmapOnly") => Ok(HydrationLevel::BitmapOnly),
        Some(unknown) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown hydration level: {unknown}"),
        )),
    }
}

fn decode_ordering(name: Option<&str>) -> Result<Ordering, JSONRPCError> {
    match name {
        None | Some("byCaptureTimeDesc") => Ok(Ordering::ByCaptureTimeDesc),
        Some("byCaptureTimeAsc") => Ok(Ordering::ByCaptureTimeAsc),
        Some("byRoomAsc") => Ok(Ordering::ByRoomAsc),
        Some("byRelevanceDesc") => Ok(Ordering::ByRelevanceDesc),
        Some(unknown) => Err(JSONRPCError::new(
            JSONRPCErrorCode::INVALID_PARAMS,
            format!("Unknown ordering: {unknown}"),
        )),
    }
}

// TunnelCaptureFrame uses the kind string as a label directly; TunnelKind is
// set on the frame separately if the caller wants typed semantics. For v1 the
// label is sufficient and the kind defaults to References (the frame default).

// ---------------------------------------------------------------------------
// v2b-p2 generic noun runners — mutate / withdraw / expunge
// ---------------------------------------------------------------------------
//
// These runners handle mutate, withdraw, and expunge for non-drawer nouns
// (tunnel, kgFact, proposal, learnedReference, association). The underlying
// EstateCoordinator verbs (mutate/withdraw/expunge) address rows by ID and
// operate on the drawer table. For non-drawer row IDs the estate returns
// DrawerNotFound → VerbError::UnderlyingEstateFailure → error_result.
//
// This is the correct observable behavior at the current stage of the
// substrate: these tools are advertised, the dispatch reaches the substrate,
// and the substrate reports that the row is not in the drawer table. Mirror
// of the Swift ToolDispatcher's noun-agnostic routing (runMutate/runWithdraw/
// runExpunge are called for all nouns without discrimination).

/// Apply a named mutation to any noun that accepts mutate. `noun_name` is
/// used in the success result text (e.g. "mutated tunnel {id} (confirm)").
fn run_noun_mutate(
    args: &BTreeMap<String, JsonValue>,
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
    noun_name: &str,
) -> Result<serde_json::Value, JSONRPCError> {
    let row_id = require_string(args, "rowID")?;
    let kind_name = require_string(args, "kind")?;
    let kind = decode_mutation_kind(kind_name)?;
    let payload = args.get("payload").and_then(|v| v.as_str());

    match coord.mutate(&estate.handle, row_id, kind, payload) {
        Ok(()) => Ok(text_result(&format!(
            "mutated {noun_name} {row_id} ({kind_name})"
        ))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Withdraw any noun that accepts withdraw. `noun_name` is used in result text.
fn run_noun_withdraw(
    args: &BTreeMap<String, JsonValue>,
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
    noun_name: &str,
) -> Result<serde_json::Value, JSONRPCError> {
    let row_id = require_string(args, "rowID")?;
    let reason = args.get("reason").and_then(|v| v.as_str());

    let now = crate::dispatch::wall_now();
    match coord.withdraw(&estate.handle, row_id, reason, now) {
        Ok(()) => Ok(text_result(&format!("withdrew {noun_name} {row_id}"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Hard-erase any noun that accepts expunge. Requires confirmation == true;
/// expunge without confirmation is refused before reaching the estate,
/// matching the coordinator boundary guard and the Swift ToolDispatcher
/// discipline. `noun_name` is used in result text.
fn run_noun_expunge(
    args: &BTreeMap<String, JsonValue>,
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
    noun_name: &str,
) -> Result<serde_json::Value, JSONRPCError> {
    let row_id = require_string(args, "rowID")?;
    let reason = require_string(args, "reason")?;
    // Absent or non-boolean confirmation is treated as false — matches
    // Swift ToolDispatch.swift:327 `args["confirmation"]?.boolValue ?? false`.
    let confirmation = args
        .get("confirmation")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    match coord.expunge(&estate.handle, row_id, reason, confirmation) {
        Ok(()) => Ok(text_result(&format!("expunged {noun_name} {row_id}"))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

// ---------------------------------------------------------------------------
// v2b-p2 recall stubs — non-drawer nouns
// ---------------------------------------------------------------------------
//
// The DrawerStore trait has no all-rows accessors for kg_facts, diary_entries,
// proposals, associations, or learned_references (only by-source filtered
// queries exist). Until the trait gains unconstrained accessors, each recall
// surfaces error_result with NotSupportedByEstate. Advertised honestly so
// clients can see the tool exists; the MCP error surface (isError: true with
// the reason) is better than the Swift server's methodNotFound for these tools.

/// Recall kg-fact rows. Stub: returns NotSupportedByEstate because the
/// DrawerStore trait has no all_kg_facts() accessor.
fn run_kg_fact_recall(
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    match coord.recall_kg_facts(&estate.handle) {
        Ok(facts) => {
            let header = format!("recalled {} kg_fact(s)", facts.len());
            Ok(text_result(&header))
        }
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Recall diary-entry rows. Stub: returns NotSupportedByEstate because the
/// DrawerStore trait has no unconstrained diary-entries accessor.
fn run_diary_entry_recall(
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    match coord.recall_diary_entries(&estate.handle) {
        Ok(entries) => {
            let header = format!("recalled {} diaryEntry(s)", entries.len());
            Ok(text_result(&header))
        }
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Recall proposal rows. Stub: returns NotSupportedByEstate because the
/// DrawerStore trait has no all_proposals() accessor.
fn run_proposal_recall(
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    match coord.recall_proposals(&estate.handle) {
        Ok(proposals) => {
            let header = format!("recalled {} proposal(s)", proposals.len());
            Ok(text_result(&header))
        }
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Recall association rows. Stub: returns NotSupportedByEstate because the
/// DrawerStore trait has no all_associations() accessor.
fn run_association_recall(
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    match coord.recall_associations(&estate.handle) {
        Ok(associations) => {
            let header = format!("recalled {} association(s)", associations.len());
            Ok(text_result(&header))
        }
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

/// Recall learned-reference rows. Stub: returns NotSupportedByEstate because
/// the DrawerStore trait has no all_learned_references() accessor.
fn run_learned_reference_recall(
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    match coord.recall_learned_references(&estate.handle) {
        Ok(refs) => {
            let header = format!("recalled {} learnedReference(s)", refs.len());
            Ok(text_result(&header))
        }
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}

// ---------------------------------------------------------------------------
// v2b-p2 learn_learnedReference
// ---------------------------------------------------------------------------

/// Ingest a learned reference. Dispatches to the coordinator's learn stub,
/// which raises NotSupportedByEstate (Brain layer not yet present). Mirrors
/// the Swift ToolDispatcher.runLearn behavior: the tool is callable, reaches
/// the substrate boundary, and the substrate reports not-supported.
fn run_learn_learned_reference(
    args: &BTreeMap<String, JsonValue>,
    coord: &EstateCoordinator,
    estate: &crate::estate_registry::OpenEstate,
) -> Result<serde_json::Value, JSONRPCError> {
    let source_handle = require_string(args, "handle")?;

    match coord.learn(&estate.handle, source_handle) {
        Ok(()) => Ok(text_result(&format!(
            "learned learnedReference {source_handle}"
        ))),
        Err(e) => Ok(error_result(&format!("{e:?}"))),
    }
}
