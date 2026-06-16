//! palace_pump_mapping — builds the per-item MemPalace `add_drawer` arguments
//! from one `NoteIR`. Rust parallel of the Swift `PalacePumpMapping`.
//!
//! Fixes the benchmarker TransferEngine's GAP A (content-only, fixed args).
//! Derives wing + room + source_file PER ITEM, and folds the unmappable fields
//! into the content via [`crate::palace_payload_envelope`].
//!
//! The native arg surface (verified against the live tool, v3.3.3):
//! `add_drawer` requires `wing`, `room`, `content`; optional `source_file`,
//! `added_by`.

use crate::note_ir::NoteIR;
use crate::palace_item::{PalaceItem, PalaceNoun};
use crate::palace_payload_envelope::{self, EnvelopeDecodeError, PalaceEnvelopePayload};
use std::collections::BTreeMap;

/// The `added_by` provenance value every pumped drawer carries.
pub const PUMP_ACTOR: &str = "mootx01-pump";
/// The wing assigned when a note has no path hierarchy to derive one from.
pub const DEFAULT_WING: &str = "mootx01";
/// The room assigned when the hierarchy is flat or one level deep.
pub const DEFAULT_ROOM: &str = "general";

/// The MemPalace `add_drawer` arguments for one note. Mirrors Swift
/// `PalaceDrawerArgs`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PalaceDrawerArgs {
    /// The `wing` argument — the project/top-level grouping.
    pub wing: String,
    /// The `room` argument — the aspect/sub-grouping.
    pub room: String,
    /// The `content` argument — verbatim body plus the fenced envelope.
    pub content: String,
    /// The `source_file` metadata argument — the note's stable source key.
    pub source_file: String,
    /// The `added_by` metadata argument — the pump actor id.
    pub added_by: String,
}

/// Build the `add_drawer` arguments for one note. The unmappable fields are
/// folded into `content` via the envelope codec.
pub fn make_args(note: &NoteIR) -> Result<PalaceDrawerArgs, EnvelopeDecodeError> {
    let (wing, room) = placement(note);
    let payload = PalaceEnvelopePayload::from_note(note);
    let content = palace_payload_envelope::encode(&note.flattened_body(), &payload)?;
    let source_file = if note.stable_source_key.is_empty() {
        "unknown".to_owned()
    } else {
        note.stable_source_key.clone()
    };
    Ok(PalaceDrawerArgs {
        wing,
        room,
        content,
        source_file,
        added_by: PUMP_ACTOR.to_owned(),
    })
}

/// Derive (wing, room) from a note's `path_components`, sanitizing each. The
/// mapping mirrors the Swift `placement(for:)`:
///   `[]` → (default, default); `[a]` → (a, default);
///   `[a, b, ...]` → (a, join(b..) with "/").
pub fn placement(note: &NoteIR) -> (String, String) {
    let parts = &note.path_components;
    match parts.len() {
        0 => (DEFAULT_WING.to_owned(), DEFAULT_ROOM.to_owned()),
        1 => {
            let w = sanitize(&parts[0]);
            (
                if w.is_empty() { DEFAULT_WING.to_owned() } else { w },
                DEFAULT_ROOM.to_owned(),
            )
        }
        _ => {
            let w = sanitize(&parts[0]);
            let room_raw = parts[1..]
                .iter()
                .map(|p| sanitize(p))
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join("/");
            (
                if w.is_empty() { DEFAULT_WING.to_owned() } else { w },
                if room_raw.is_empty() { DEFAULT_ROOM.to_owned() } else { room_raw },
            )
        }
    }
}

/// Sanitize one path component into a MemPalace-safe identifier fragment:
/// trim, keep alphanumerics + `_`/`-`, collapse other runs to a single
/// hyphen, drop a trailing hyphen. Returns "" when nothing survives. Mirrors
/// the Swift `sanitize(_:)` exactly.
pub fn sanitize(raw: &str) -> String {
    let mut out = String::new();
    let mut last_was_hyphen = false;
    for ch in raw.trim().chars() {
        if ch.is_alphanumeric() {
            out.push(ch);
            last_was_hyphen = false;
        } else if ch == '_' || ch == '-' {
            out.push(ch);
            last_was_hyphen = ch == '-';
        } else if !last_was_hyphen && !out.is_empty() {
            out.push('-');
            last_was_hyphen = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}

// --- Four-noun mapping (drawer / tunnel / KG fact / diary) ---
//
// The four MemPalace tools the canonical pump drives, verified against the live
// server (v3.3.3). For each noun the mapper picks the tool, builds native args
// from `native_fields`, and folds `envelope_fields` into whichever native arg
// persists the noun's text. Rust parallel of the Swift `PalacePumpMapping.call`.

/// MemPalace `mempalace_add_drawer` — the drawer write tool.
pub const ADD_DRAWER_TOOL: &str = "mempalace_add_drawer";
/// MemPalace `mempalace_create_tunnel` — the tunnel write tool.
pub const CREATE_TUNNEL_TOOL: &str = "mempalace_create_tunnel";
/// MemPalace `mempalace_kg_add` — the KG-fact write tool.
pub const KG_ADD_TOOL: &str = "mempalace_kg_add";
/// MemPalace `mempalace_diary_write` — the diary write tool.
pub const DIARY_WRITE_TOOL: &str = "mempalace_diary_write";
/// MemPalace `mempalace_get_drawer` — the drawer read-back tool (verify).
pub const GET_DRAWER_TOOL: &str = "mempalace_get_drawer";

/// The MemPalace call a [`PalaceItem`] maps to: the tool name and its native
/// argument map (the envelope is already folded into the noun's text arg).
/// Mirrors Swift `PalaceCall`.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PalaceCall {
    /// The MemPalace MCP tool name.
    pub tool: String,
    /// The native arguments, keyed by the MemPalace arg name.
    pub arguments: BTreeMap<String, serde_json::Value>,
}

/// Read a native field as a string, or `default` when absent/non-string.
fn native_str(item: &PalaceItem, key: &str, default: &str) -> String {
    item.native_fields
        .get(key)
        .and_then(|v| v.as_str())
        .unwrap_or(default)
        .to_owned()
}

/// Build the MemPalace call for one [`PalaceItem`], dispatching on the noun.
/// The envelope is folded into the noun's text-bearing arg. Byte-identical to
/// the Swift `PalacePumpMapping.call(for:)`.
pub fn call(item: &PalaceItem) -> Result<PalaceCall, EnvelopeDecodeError> {
    match item.noun {
        PalaceNoun::Drawer => drawer_call(item),
        PalaceNoun::Tunnel => tunnel_call(item),
        PalaceNoun::KgFact => kg_fact_call(item),
        PalaceNoun::DiaryEntry => diary_call(item),
    }
}

/// Drawer → `add_drawer(wing, room, content+envelope, added_by)`.
fn drawer_call(item: &PalaceItem) -> Result<PalaceCall, EnvelopeDecodeError> {
    let wing = native_str(item, "wing", "wing_moot");
    let room = native_str(item, "room", "imported");
    let content = palace_payload_envelope::encode_fields(&item.body, &item.envelope_fields)?;
    let mut args = BTreeMap::new();
    args.insert("wing".to_owned(), serde_json::Value::String(wing));
    args.insert("room".to_owned(), serde_json::Value::String(room));
    args.insert("content".to_owned(), serde_json::Value::String(content));
    args.insert(
        "added_by".to_owned(),
        serde_json::Value::String(PUMP_ACTOR.to_owned()),
    );
    Ok(PalaceCall {
        tool: ADD_DRAWER_TOOL.to_owned(),
        arguments: args,
    })
}

/// Tunnel → `create_tunnel(endpoints, label+envelope)`. The envelope rides
/// `label` (create_tunnel has no free-text body); endpoints map natively.
fn tunnel_call(item: &PalaceItem) -> Result<PalaceCall, EnvelopeDecodeError> {
    let mut args = BTreeMap::new();
    for key in [
        "source_wing",
        "source_room",
        "target_wing",
        "target_room",
        "source_drawer_id",
        "target_drawer_id",
    ] {
        if let Some(v) = item.native_fields.get(key) {
            args.insert(key.to_owned(), v.clone());
        }
    }
    let human_label = native_str(item, "label", "");
    let label = palace_payload_envelope::encode_fields(&human_label, &item.envelope_fields)?;
    args.insert("label".to_owned(), serde_json::Value::String(label));
    Ok(PalaceCall {
        tool: CREATE_TUNNEL_TOOL.to_owned(),
        arguments: args,
    })
}

/// KGFact → `kg_add(subject, predicate, object, valid_from, source_closet)`.
/// The envelope rides `source_closet` (unbounded), never the 128-capped object
/// — the original write-failure bug. An empty envelope sends no source_closet.
fn kg_fact_call(item: &PalaceItem) -> Result<PalaceCall, EnvelopeDecodeError> {
    let subject = native_str(item, "subject", "");
    let predicate = native_str(item, "predicate", "");
    let object = native_str(item, "object", "");
    let valid_from = native_str(item, "valid_from", "");
    let mut args = BTreeMap::new();
    args.insert("subject".to_owned(), serde_json::Value::String(subject));
    args.insert("predicate".to_owned(), serde_json::Value::String(predicate));
    args.insert("object".to_owned(), serde_json::Value::String(object));
    args.insert(
        "valid_from".to_owned(),
        serde_json::Value::String(valid_from),
    );
    let envelope = palace_payload_envelope::encode_fields("", &item.envelope_fields)?;
    if !envelope.is_empty() {
        args.insert(
            "source_closet".to_owned(),
            serde_json::Value::String(envelope),
        );
    }
    Ok(PalaceCall {
        tool: KG_ADD_TOOL.to_owned(),
        arguments: args,
    })
}

/// DiaryEntry → `diary_write(agent_name, entry+envelope, topic, wing)`. wing is
/// optional (server defaults to wing_<agent>), sent only when the source names
/// one.
fn diary_call(item: &PalaceItem) -> Result<PalaceCall, EnvelopeDecodeError> {
    let agent = native_str(item, "agent_name", "moot");
    let topic = native_str(item, "topic", "general");
    let wing = native_str(item, "wing", "");
    let entry = palace_payload_envelope::encode_fields(&item.body, &item.envelope_fields)?;
    let mut args = BTreeMap::new();
    args.insert("agent_name".to_owned(), serde_json::Value::String(agent));
    args.insert("entry".to_owned(), serde_json::Value::String(entry));
    args.insert("topic".to_owned(), serde_json::Value::String(topic));
    if !wing.is_empty() {
        args.insert("wing".to_owned(), serde_json::Value::String(wing));
    }
    Ok(PalaceCall {
        tool: DIARY_WRITE_TOOL.to_owned(),
        arguments: args,
    })
}
