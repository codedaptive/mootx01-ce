//! v2b-p1 lexicon surface: moot_capture_drawer, moot_drawer_recall,
//! moot_capture_tunnel, moot_mutate_drawer, moot_withdraw_drawer,
//! moot_expunge_drawer, moot_reanchor_drawer, moot_tunnel_recall.
//!
//! Mirrors the Swift `ToolDispatcher.runCaptureDrawer`, `runRecallDrawer`,
//! `runMutate`, `runWithdraw`, `runExpunge`, `runReanchor` argument names and
//! behavior. The five new tools (v2b-p1) give an agent the full drawer
//! lifecycle surface plus the tunnel graph read-out.
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
//! filter, limit, ordering, hydrationLevel).
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

const CAPTURE_DRAWER: &str = "moot_capture_drawer";
const RECALL_DRAWER: &str = "moot_drawer_recall";
const CAPTURE_TUNNEL: &str = "moot_capture_tunnel";
// v2b-p1: drawer lifecycle verbs + tunnel graph read.
const MUTATE_DRAWER: &str = "moot_mutate_drawer";
const WITHDRAW_DRAWER: &str = "moot_withdraw_drawer";
const EXPUNGE_DRAWER: &str = "moot_expunge_drawer";
const REANCHOR_DRAWER: &str = "moot_reanchor_drawer";
const TUNNEL_RECALL: &str = "moot_tunnel_recall";

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

/// True when `name` is one of the lexicon tools (v1 minimum + v2b-p1 additions).
pub fn is_lexicon_tool(name: &str) -> bool {
    matches!(
        name,
        CAPTURE_DRAWER
            | RECALL_DRAWER
            | CAPTURE_TUNNEL
            | MUTATE_DRAWER
            | WITHDRAW_DRAWER
            | EXPUNGE_DRAWER
            | REANCHOR_DRAWER
            | TUNNEL_RECALL
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
        CAPTURE_DRAWER => run_capture_drawer(args, &mut coord, estate),
        RECALL_DRAWER => run_recall_drawer(args, &coord, estate),
        CAPTURE_TUNNEL => run_capture_tunnel(args, &mut coord, estate),
        MUTATE_DRAWER => run_mutate_drawer(args, &coord, estate),
        WITHDRAW_DRAWER => run_withdraw_drawer(args, &coord, estate),
        EXPUNGE_DRAWER => run_expunge_drawer(args, &coord, estate),
        REANCHOR_DRAWER => run_reanchor_drawer(args, &coord, estate),
        TUNNEL_RECALL => run_tunnel_recall(args, &coord, estate),
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
