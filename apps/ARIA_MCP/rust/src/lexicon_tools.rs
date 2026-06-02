//! v1 lexicon minimum: moot_capture_drawer, moot_drawer_recall, moot_capture_tunnel.
//!
//! Mirrors the Swift `ToolDispatcher.runCaptureDrawer` and `runRecallDrawer`
//! argument names and behavior. These three tools give an agent on the Rust
//! server the ability to put real data in front of the lenses.
//!
//! The full lexicon projection (mutate, withdraw, expunge, reanchor, learn,
//! cross_estate_recall, federation) is explicitly OUT of this mission's scope.
//! It is listed in the README as the v1 boundary.
//!
//! Arg names are wire-identical to the Swift server for the tools that appear
//! in both (content, room, udcCode, addedBy, embeddingModelID, filter, limit,
//! ordering, hydrationLevel).

use std::collections::BTreeMap;

use genius_locus_kit::EstateCoordinator;
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    drawer_operational::{CaptureChannel, ContentKind},
    estate_types::LatticeAnchor,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
    frames::{CaptureFrame, TunnelCaptureFrame},
};

use crate::dispatch::{require_string, text_result};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

const CAPTURE_DRAWER: &str = "moot_capture_drawer";
const RECALL_DRAWER: &str = "moot_drawer_recall";
const CAPTURE_TUNNEL: &str = "moot_capture_tunnel";

/// True when `name` is one of the v1 lexicon minimum tools.
pub fn is_lexicon_tool(name: &str) -> bool {
    matches!(name, CAPTURE_DRAWER | RECALL_DRAWER | CAPTURE_TUNNEL)
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
        "captured drawer {}\nroom: {}",
        drawer.id, drawer.room
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
// Argument decoders (lexicon-specific)
// ---------------------------------------------------------------------------

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
