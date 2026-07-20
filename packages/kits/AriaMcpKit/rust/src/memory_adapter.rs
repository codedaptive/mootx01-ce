//! M-MEMTOOL-1: Anthropic memory_20250818 tool adapter (Rust).

use crate::dispatch::{error_result, optional_integer, optional_string, require_string, text_result, wall_now};
use crate::estate_registry::EstateRegistry;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};
use locus_kit::{
    drawer::Drawer,
    drawer_operational::CaptureChannel,
    estate_types::LatticeAnchor,
    frames::CaptureFrame,
};
use std::collections::BTreeMap;

const MEMORIES_ROOT: &str = "/memories";
const ADAPTER_WING: &str = "memories";
const MAX_FILE_SIZE: usize = 100 * 1024;

pub fn dispatch_memory(
    args: &BTreeMap<String, JsonValue>,
    registry: &EstateRegistry,
) -> Result<serde_json::Value, JSONRPCError> {
    // Guard: the memory tool is opt-in (MOOTX01_MEMORY_TOOL == "1"). The flag
    // gated only tool projection (the tool is absent from tools/list), so a
    // hard-coded tools/call to `memory` still reached this read/write surface.
    // Enforce the flag at dispatch too, mirroring the vault disabled-refusal.
    let enabled = std::env::var("MOOTX01_MEMORY_TOOL").map(|v| v == "1").unwrap_or(false);
    if !enabled {
        return Ok(error_result(
            "memory tool is disabled; run `mootx01 enable memory-tool` to activate it",
        ));
    }
    // Match Swift's guard: absent OR non-string → textResult (isError:false), not a
    // JSON-RPC protocol error. require_string would throw INVALID_PARAMS on miss.
    let command = match args.get("command").and_then(|v| v.as_str()) {
        Some(s) => s,
        None => return Ok(text_result("Error: missing or invalid 'command' parameter")),
    };
    match command {
        "view" => memory_view(args, registry),
        "create" => memory_create(args, registry),
        "str_replace" => memory_str_replace(args, registry),
        "insert" => memory_insert(args, registry),
        "delete" => memory_delete(args, registry),
        "rename" => memory_rename(args, registry),
        _ => Ok(error_result(&format!("Error: unknown command {command}"))),
    }
}

fn validate_path(args: &BTreeMap<String, JsonValue>, key: &str) -> Result<String, JSONRPCError> {
    let path = require_string(args, key)?;
    if path.to_lowercase().contains("%2e") || path.to_lowercase().contains("%2f") {
        return Err(JSONRPCError::new(JSONRPCErrorCode::INVALID_PARAMS, format!("URL-encoded traversal: {path}")));
    }
    if path.contains("..") {
        return Err(JSONRPCError::new(JSONRPCErrorCode::INVALID_PARAMS, format!("Path traversal: {path}")));
    }
    if !path.starts_with(MEMORIES_ROOT) {
        return Err(JSONRPCError::new(JSONRPCErrorCode::INVALID_PARAMS, format!("Must start with {MEMORIES_ROOT}: {path}")));
    }
    Ok(path.to_string())
}

fn path_to_room(path: &str) -> String {
    if path.len() <= MEMORIES_ROOT.len() + 1 { return "root".to_string(); }
    path[MEMORIES_ROOT.len() + 1..].to_string()
}

fn vpath(room: &str) -> String { format!("{MEMORIES_ROOT}/{room}") }

/// Sensitivity gate for the `memory` surface: only Normal-tier drawers
/// (adjective sensitivity Normal / Elevated) are visible. `memory` is a
/// bulk, path-addressed read/write surface with no grant ceremony, so it
/// matches BitmapEvaluator's default no-claims recall posture
/// (`sensitivityAtMost(.elevated)`, data-movement privacy tiers): Restricted and
/// Secret drawers neither list nor resolve here. The adjective axis is the
/// access-gate-relevant tier (spec § 7.9.2) — the provenance sensitivity
/// axis is deliberately NOT consulted. Mirrors `isMemoryAdapterVisible` in
/// the Swift MemoryToolAdapter.swift.
fn drawer_visible_to_adapter(drawer: &Drawer) -> bool {
    drawer.tombstoned_at.is_none()
        && (drawer.adjective_bitmap & 0x3F) < 4
        && drawer.adjective_sensitivity().is_bulk_exportable()
}

fn find_drawer(path: &str, args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry)
    -> Result<Option<Drawer>, JSONRPCError>
{
    let room = path_to_room(path);
    let estate = registry.resolve_direct(args)?;
    let coord = estate.coord.lock().unwrap();
    let all = coord.all_drawers(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, format!("{e:?}")))?;
    let names = coord.resolve_drawer_node_names(&estate.handle,
        &all.iter().map(|d| d.parent_node_id.clone()).collect::<Vec<_>>());
    Ok(all.into_iter().find(|d| {
        drawer_visible_to_adapter(d)
            && names.get(&d.parent_node_id).map_or(false, |(w, r)| w == ADAPTER_WING && r == &room)
    }))
}

fn list_drawers(args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry)
    -> Result<Vec<(Drawer, String)>, JSONRPCError>
{
    let estate = registry.resolve_direct(args)?;
    let coord = estate.coord.lock().unwrap();
    let all = coord.all_drawers(&estate.handle)
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, format!("{e:?}")))?;
    let names = coord.resolve_drawer_node_names(&estate.handle,
        &all.iter().map(|d| d.parent_node_id.clone()).collect::<Vec<_>>());
    Ok(all.into_iter().filter_map(|d| {
        if !drawer_visible_to_adapter(&d) { return None; }
        let (w, r) = names.get(&d.parent_node_id)?;
        if w != ADAPTER_WING { return None; }
        Some((d, r.clone()))
    }).collect())
}

/// Build a capture frame for the adapter wing. `sensitivity` is the
/// adjective-sensitivity tier the new drawer is filed at: creates pass
/// Normal; edit/rename re-captures pass the SOURCE drawer's tier — a
/// hardcoded Normal here silently DOWNGRADED elevated drawers on edit.
fn new_frame(
    content: &str,
    room: &str,
    identity: &str,
    sensitivity: locus_kit::adjectives::AdjectiveSensitivity,
) -> CaptureFrame {
    let mut frame = CaptureFrame::new(
        content, CaptureChannel::Actuator, room,
        LatticeAnchor::udc("000"), identity, "default",
    );
    frame.wing = Some(ADAPTER_WING.to_string());
    frame.sensitivity = sensitivity;
    frame
}

fn memory_view(args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry) -> Result<serde_json::Value, JSONRPCError> {
    let path = validate_path(args, "path")?;
    if path == MEMORIES_ROOT || path == format!("{MEMORIES_ROOT}/") {
        let drawers = list_drawers(args, registry)?;
        let mut listing = vec![format!("4.0K\t{MEMORIES_ROOT}")];
        let mut seen = std::collections::HashSet::new();
        for (_, room) in &drawers {
            listing.push(format!("1.0K\t{}", vpath(room)));
            let parts: Vec<&str> = room.split('/').collect();
            if parts.len() > 1 {
                let p = format!("{MEMORIES_ROOT}/{}", parts[0]);
                if seen.insert(p.clone()) { listing.insert(1, format!("4.0K\t{p}")); }
            }
        }
        return Ok(text_result(&format!(
            "Here're the files and directories up to 2 levels deep in {path}, excluding hidden items and node_modules:\n{}", listing.join("\n"))));
    }
    match find_drawer(&path, args, registry)? {
        Some(d) => {
            let mut lines: Vec<&str> = d.content.split('\n').collect();
            // start_offset: the 1-based line number of lines[0] after any view_range slice.
            let mut start_offset: usize = 1;

            // view_range: "start,end" string or [start, end] integer array.
            // s is 1-based; e == -1 means EOF. Parsing failures are silently
            // ignored (matches Swift's silent-ignore behavior on malformed input).
            match args.get("view_range") {
                Some(JsonValue::String(range_str)) => {
                    let parts: Vec<i64> = range_str.split(',')
                        .filter_map(|p| p.trim().parse::<i64>().ok())
                        .collect();
                    if parts.len() == 2 {
                        let s = parts[0].max(1) as usize;
                        let e = if parts[1] == -1 {
                            lines.len()
                        } else {
                            (parts[1].max(0) as usize).min(lines.len())
                        };
                        if s <= lines.len() && s.saturating_sub(1) <= e {
                            lines = lines[(s - 1)..e].to_vec();
                            start_offset = s;
                        }
                    }
                }
                Some(JsonValue::Array(arr)) if arr.len() == 2 => {
                    let sv = arr[0].as_i64().unwrap_or(1).max(1) as usize;
                    let ev_raw = arr[1].as_i64().unwrap_or(-1);
                    let ev = if ev_raw == -1 {
                        lines.len()
                    } else {
                        (ev_raw.max(0) as usize).min(lines.len())
                    };
                    if sv <= lines.len() && sv.saturating_sub(1) <= ev {
                        lines = lines[(sv - 1)..ev].to_vec();
                        start_offset = sv;
                    }
                }
                _ => {}
            }

            // Hard line limit matching Swift's 999,999-line cap.
            if lines.len() > 999_999 {
                return Ok(text_result(&format!("File {path} exceeds maximum line limit of 999,999 lines.")));
            }

            let numbered: Vec<String> = lines.iter().enumerate()
                .map(|(i, l)| format!("{:6}\t{l}", i + start_offset))
                .collect();
            Ok(text_result(&format!("Here's the content of {path} with line numbers:\n{}", numbered.join("\n"))))
        }
        None => {
            let drawers = list_drawers(args, registry)?;
            let pfx = if path.ends_with('/') { path.clone() } else { format!("{path}/") };
            let ch: Vec<_> = drawers.iter().filter(|(_, r)| vpath(r).starts_with(&pfx)).collect();
            if !ch.is_empty() {
                let mut l = vec![format!("4.0K\t{path}")];
                for (_, r) in &ch { l.push(format!("1.0K\t{}", vpath(r))); }
                return Ok(text_result(&format!("Here're the files and directories up to 2 levels deep in {path}, excluding hidden items and node_modules:\n{}", l.join("\n"))));
            }
            Ok(text_result(&format!("The path {path} does not exist. Please provide a valid path.")))
        }
    }
}

fn memory_create(args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry) -> Result<serde_json::Value, JSONRPCError> {
    let path = validate_path(args, "path")?;
    // Match Swift's guard: absent → textResult (isError:false), not INVALID_PARAMS.
    let file_text = match optional_string(args, "file_text")? {
        Some(s) => s,
        None => return Ok(text_result("Error: missing 'file_text' parameter")),
    };
    if file_text.len() > MAX_FILE_SIZE { return Ok(error_result("Error: File content exceeds maximum size")); }
    if find_drawer(&path, args, registry)?.is_some() { return Ok(text_result(&format!("Error: File {path} already exists"))); }
    let room = path_to_room(&path);
    let estate = registry.resolve_direct(args)?;
    let coord = estate.coord.lock().unwrap();
    coord.capture(&estate.handle, new_frame(file_text, &room, &registry.server_identity,
        locus_kit::adjectives::AdjectiveSensitivity::Normal), wall_now())
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, format!("{e:?}")))?;
    Ok(text_result(&format!("File created successfully at: {path}")))
}

fn memory_str_replace(args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry) -> Result<serde_json::Value, JSONRPCError> {
    let path = validate_path(args, "path")?;
    // Match Swift's guard: absent → textResult (isError:false), not INVALID_PARAMS.
    let old_str = match optional_string(args, "old_str")? {
        Some(s) => s,
        None => return Ok(text_result("Error: missing 'old_str' parameter")),
    };
    let new_str = optional_string(args, "new_str")?.unwrap_or_default();
    let d = match find_drawer(&path, args, registry)? {
        Some(d) => d,
        None => return Ok(text_result(&format!("Error: The path {path} does not exist. Please provide a valid path."))),
    };
    if !d.content.contains(old_str) {
        return Ok(text_result(&format!("No replacement was performed, old_str `{old_str}` did not appear verbatim in {path}.")));
    }
    if d.content.matches(old_str).count() > 1 {
        let ln: Vec<String> = d.content.lines().enumerate().filter(|(_, l)| l.contains(old_str)).map(|(i, _)| (i+1).to_string()).collect();
        return Ok(text_result(&format!("No replacement was performed. Multiple occurrences of old_str `{old_str}` in lines: {}. Please ensure it is unique", ln.join(", "))));
    }
    let new_content = d.content.replacen(old_str, &new_str, 1);
    let room = path_to_room(&path);
    let estate = registry.resolve_direct(args)?;
    let coord = estate.coord.lock().unwrap();
    coord.capture(&estate.handle, new_frame(&new_content, &room, &registry.server_identity,
        d.adjective_sensitivity()), wall_now())
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, format!("{e:?}")))?;
    let _ = coord.withdraw(&estate.handle, &d.id, Some("memory str_replace supersession"), wall_now());
    Ok(text_result("The memory file has been edited."))
}

fn memory_insert(args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry) -> Result<serde_json::Value, JSONRPCError> {
    let path = validate_path(args, "path")?;
    // Match Swift's guard: absent → textResult (isError:false), not a silent
    // default of 0 (which would silently prepend instead of refusing).
    let insert_line = match optional_integer(args, "insert_line")? {
        Some(n) => n as usize,
        None => return Ok(text_result("Error: missing 'insert_line' parameter")),
    };
    // Match Swift's guard: absent → textResult (isError:false), not INVALID_PARAMS.
    let insert_text = match optional_string(args, "insert_text")? {
        Some(s) => s,
        None => return Ok(text_result("Error: missing 'insert_text' parameter")),
    };
    let d = match find_drawer(&path, args, registry)? {
        Some(d) => d,
        None => return Ok(text_result(&format!("Error: The path {path} does not exist"))),
    };
    let mut lines: Vec<&str> = d.content.split('\n').collect();
    if insert_line > lines.len() {
        return Ok(text_result(&format!("Error: Invalid `insert_line` parameter: {insert_line}. It should be within the range of lines of the file: [0, {}]", lines.len())));
    }
    let new_lines: Vec<&str> = insert_text.trim_end_matches('\n').split('\n').collect();
    for (i, nl) in new_lines.iter().enumerate() { lines.insert(insert_line + i, nl); }
    let new_content = lines.join("\n");
    let room = path_to_room(&path);
    let estate = registry.resolve_direct(args)?;
    let coord = estate.coord.lock().unwrap();
    coord.capture(&estate.handle, new_frame(&new_content, &room, &registry.server_identity,
        d.adjective_sensitivity()), wall_now())
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, format!("{e:?}")))?;
    let _ = coord.withdraw(&estate.handle, &d.id, Some("memory insert supersession"), wall_now());
    Ok(text_result(&format!("The file {path} has been edited.")))
}

fn memory_delete(args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry) -> Result<serde_json::Value, JSONRPCError> {
    let path = validate_path(args, "path")?;
    // Contract §4.5: root-refusal is isError:false (text_result), matching Swift.
    if path == MEMORIES_ROOT || path == format!("{MEMORIES_ROOT}/") { return Ok(text_result("Error: Cannot delete the memory root directory")); }
    if let Some(d) = find_drawer(&path, args, registry)? {
        let estate = registry.resolve_direct(args)?;
        let coord = estate.coord.lock().unwrap();
        let _ = coord.withdraw(&estate.handle, &d.id, Some(&format!("memory delete: {path}")), wall_now());
        return Ok(text_result(&format!("Successfully deleted {path}")));
    }
    let drawers = list_drawers(args, registry)?;
    let pfx = if path.ends_with('/') { path.clone() } else { format!("{path}/") };
    let ch: Vec<_> = drawers.into_iter().filter(|(_, r)| vpath(r).starts_with(&pfx)).collect();
    if ch.is_empty() { return Ok(text_result(&format!("Error: The path {path} does not exist"))); }
    let estate = registry.resolve_direct(args)?;
    let coord = estate.coord.lock().unwrap();
    for (c, _) in &ch { let _ = coord.withdraw(&estate.handle, &c.id, Some(&format!("memory delete (recursive): {path}")), wall_now()); }
    Ok(text_result(&format!("Successfully deleted {path}")))
}

fn memory_rename(args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry) -> Result<serde_json::Value, JSONRPCError> {
    let old_path = validate_path(args, "old_path")?;
    let new_path = validate_path(args, "new_path")?;
    // Contract §4.6: root-refusal is isError:false (text_result), matching Swift.
    if old_path == MEMORIES_ROOT { return Ok(text_result("Error: Cannot rename the memory root directory")); }
    let d = match find_drawer(&old_path, args, registry)? {
        Some(d) => d,
        None => return Ok(text_result(&format!("Error: The path {old_path} does not exist"))),
    };
    if find_drawer(&new_path, args, registry)?.is_some() { return Ok(text_result(&format!("Error: The destination {new_path} already exists"))); }
    let new_room = path_to_room(&new_path);
    let estate = registry.resolve_direct(args)?;
    let coord = estate.coord.lock().unwrap();
    coord.capture(&estate.handle, new_frame(&d.content, &new_room, &registry.server_identity,
        d.adjective_sensitivity()), wall_now())
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, format!("{e:?}")))?;
    let _ = coord.withdraw(&estate.handle, &d.id, Some(&format!("memory rename: {old_path} → {new_path}")), wall_now());
    Ok(text_result(&format!("Successfully renamed {old_path} to {new_path}")))
}
