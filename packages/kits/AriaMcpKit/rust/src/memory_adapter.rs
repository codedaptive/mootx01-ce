//! M-MEMTOOL-1: Anthropic memory_20250818 tool adapter (Rust).

use crate::dispatch::{error_result, opt_integer, optional_string, require_string, text_result, wall_now};
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
    let command = require_string(args, "command")?;
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

fn drawer_visible_to_adapter(drawer: &Drawer) -> bool {
    if drawer.tombstoned_at.is_some() || (drawer.adjective_bitmap & 0x3F) >= 4 { return false; }
    if !drawer.adjective_sensitivity().is_bulk_exportable() { return false; }
    matches!(
        drawer.sensitivity(),
        locus_kit::provenance::Sensitivity::Normal | locus_kit::provenance::Sensitivity::Elevated
    )
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

fn new_frame(content: &str, room: &str, identity: &str) -> CaptureFrame {
    let mut frame = CaptureFrame::new(
        content, CaptureChannel::Actuator, room,
        LatticeAnchor::udc("000"), identity, "default",
    );
    frame.wing = Some(ADAPTER_WING.to_string());
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
            let lines: Vec<&str> = d.content.split('\n').collect();
            let numbered: Vec<String> = lines.iter().enumerate().map(|(i, l)| format!("{:6}\t{l}", i + 1)).collect();
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
    let file_text = require_string(args, "file_text")?;
    if file_text.len() > MAX_FILE_SIZE { return Ok(error_result("Error: File content exceeds maximum size")); }
    if find_drawer(&path, args, registry)?.is_some() { return Ok(text_result(&format!("Error: File {path} already exists"))); }
    let room = path_to_room(&path);
    let estate = registry.resolve_direct(args)?;
    let mut coord = estate.coord.lock().unwrap();
    coord.capture(&estate.handle, new_frame(file_text, &room, &registry.server_identity), wall_now())
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, format!("{e:?}")))?;
    Ok(text_result(&format!("File created successfully at: {path}")))
}

fn memory_str_replace(args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry) -> Result<serde_json::Value, JSONRPCError> {
    let path = validate_path(args, "path")?;
    let old_str = require_string(args, "old_str")?;
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
    let mut coord = estate.coord.lock().unwrap();
    coord.capture(&estate.handle, new_frame(&new_content, &room, &registry.server_identity), wall_now())
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, format!("{e:?}")))?;
    let _ = coord.withdraw(&estate.handle, &d.id, Some("memory str_replace supersession"), wall_now());
    Ok(text_result("The memory file has been edited."))
}

fn memory_insert(args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry) -> Result<serde_json::Value, JSONRPCError> {
    let path = validate_path(args, "path")?;
    let insert_line = opt_integer(args, "insert_line", 0)? as usize;
    let insert_text = require_string(args, "insert_text")?;
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
    let mut coord = estate.coord.lock().unwrap();
    coord.capture(&estate.handle, new_frame(&new_content, &room, &registry.server_identity), wall_now())
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, format!("{e:?}")))?;
    let _ = coord.withdraw(&estate.handle, &d.id, Some("memory insert supersession"), wall_now());
    Ok(text_result(&format!("The file {path} has been edited.")))
}

fn memory_delete(args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry) -> Result<serde_json::Value, JSONRPCError> {
    let path = validate_path(args, "path")?;
    if path == MEMORIES_ROOT || path == format!("{MEMORIES_ROOT}/") { return Ok(error_result("Error: Cannot delete the memory root directory")); }
    if let Some(d) = find_drawer(&path, args, registry)? {
        let estate = registry.resolve_direct(args)?;
        let mut coord = estate.coord.lock().unwrap();
        let _ = coord.withdraw(&estate.handle, &d.id, Some(&format!("memory delete: {path}")), wall_now());
        return Ok(text_result(&format!("Successfully deleted {path}")));
    }
    let drawers = list_drawers(args, registry)?;
    let pfx = if path.ends_with('/') { path.clone() } else { format!("{path}/") };
    let ch: Vec<_> = drawers.into_iter().filter(|(_, r)| vpath(r).starts_with(&pfx)).collect();
    if ch.is_empty() { return Ok(text_result(&format!("Error: The path {path} does not exist"))); }
    let estate = registry.resolve_direct(args)?;
    let mut coord = estate.coord.lock().unwrap();
    for (c, _) in &ch { let _ = coord.withdraw(&estate.handle, &c.id, Some(&format!("memory delete (recursive): {path}")), wall_now()); }
    Ok(text_result(&format!("Successfully deleted {path}")))
}

fn memory_rename(args: &BTreeMap<String, JsonValue>, registry: &EstateRegistry) -> Result<serde_json::Value, JSONRPCError> {
    let old_path = validate_path(args, "old_path")?;
    let new_path = validate_path(args, "new_path")?;
    if old_path == MEMORIES_ROOT { return Ok(error_result("Error: Cannot rename the memory root directory")); }
    let d = match find_drawer(&old_path, args, registry)? {
        Some(d) => d,
        None => return Ok(text_result(&format!("Error: The path {old_path} does not exist"))),
    };
    if find_drawer(&new_path, args, registry)?.is_some() { return Ok(text_result(&format!("Error: The destination {new_path} already exists"))); }
    let new_room = path_to_room(&new_path);
    let estate = registry.resolve_direct(args)?;
    let mut coord = estate.coord.lock().unwrap();
    coord.capture(&estate.handle, new_frame(&d.content, &new_room, &registry.server_identity), wall_now())
        .map_err(|e| JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, format!("{e:?}")))?;
    let _ = coord.withdraw(&estate.handle, &d.id, Some(&format!("memory rename: {old_path} → {new_path}")), wall_now());
    Ok(text_result(&format!("Successfully renamed {old_path} to {new_path}")))
}
