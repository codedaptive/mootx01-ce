//! core/permissions.rs — Claude Code `permissions.allow` writer.
//!
//! Ported from Swift PermissionsWriter.swift (AIRA-INSTALL-P3 finding): the
//! settings key is `permissions.allow` (nested under a `permissions`
//! object), NOT top-level `allowedTools`. Entries take the MCP-prefixed
//! form `mcp__mootx01__<tool_name>`.
//!
//! Tool names are derived at runtime from the linked aria-mcp library
//! (`tool_list::build_tool_list()`), so the allow list can never drift from
//! the server's actual tool surface — no hardcoded name table.
//!
//! The merge is additive and idempotent: existing `allow` entries are
//! preserved, ours are appended once. `remove` strips exactly the
//! `mcp__mootx01__` entries and leaves everything else.

use std::path::Path;

use crate::core::merge::MergeError;

const PREFIX: &str = "mcp__mootx01__";

/// `mcp__mootx01__<name>` for every tool the linked server exposes.
pub fn permission_entries() -> Vec<String> {
    let list = aria_mcp::tool_list::build_tool_list();
    list.as_array()
        .map(|tools| {
            tools
                .iter()
                .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
                .map(|n| format!("{PREFIX}{n}"))
                .collect()
        })
        .unwrap_or_default()
}

/// Merge the permission entries into `settings.json` additively. Creates the
/// file (and parents) when absent. Returns the number of entries added.
pub fn grant(settings_path: &Path) -> Result<usize, MergeError> {
    let mut root = read_settings(settings_path)?;
    let obj = root.as_object_mut().expect("root object");
    let perms = obj
        .entry("permissions")
        .or_insert_with(|| serde_json::json!({}));
    if !perms.is_object() {
        return Err(MergeError::MalformedConfig {
            path: settings_path.to_path_buf(),
            detail: "'permissions' exists but is not an object; refusing to overwrite it.".into(),
        });
    }
    let allow = perms
        .as_object_mut()
        .unwrap()
        .entry("allow")
        .or_insert_with(|| serde_json::json!([]));
    let Some(arr) = allow.as_array_mut() else {
        return Err(MergeError::MalformedConfig {
            path: settings_path.to_path_buf(),
            detail: "'permissions.allow' exists but is not an array; refusing to overwrite it."
                .into(),
        });
    };
    let existing: std::collections::HashSet<String> = arr
        .iter()
        .filter_map(|v| v.as_str().map(String::from))
        .collect();
    let mut added = 0;
    for entry in permission_entries() {
        if !existing.contains(&entry) {
            arr.push(serde_json::Value::String(entry));
            added += 1;
        }
    }
    if added > 0 {
        write_settings(settings_path, &root)?;
    }
    Ok(added)
}

/// Remove every `mcp__mootx01__` entry from `permissions.allow`. Absent file
/// is a no-op. Returns the number of entries removed.
pub fn revoke(settings_path: &Path) -> Result<usize, MergeError> {
    if !settings_path.exists() {
        return Ok(0);
    }
    let mut root = read_settings(settings_path)?;
    let mut removed = 0;
    if let Some(arr) = root
        .get_mut("permissions")
        .and_then(|p| p.get_mut("allow"))
        .and_then(|a| a.as_array_mut())
    {
        let before = arr.len();
        arr.retain(|v| {
            v.as_str()
                .map(|s| !s.starts_with(PREFIX))
                .unwrap_or(true)
        });
        removed = before - arr.len();
    }
    if removed > 0 {
        write_settings(settings_path, &root)?;
    }
    Ok(removed)
}

fn read_settings(path: &Path) -> Result<serde_json::Value, MergeError> {
    if !path.exists() {
        return Ok(serde_json::json!({}));
    }
    let bytes = std::fs::read(path)?;
    let text = String::from_utf8_lossy(&bytes);
    if text.trim().is_empty() {
        return Ok(serde_json::json!({}));
    }
    match serde_json::from_str::<serde_json::Value>(&text) {
        Ok(v) if v.is_object() => Ok(v),
        _ => Err(MergeError::MalformedConfig {
            path: path.to_path_buf(),
            detail: "existing settings file is not valid JSON; refusing to overwrite it.".into(),
        }),
    }
}

fn write_settings(path: &Path, root: &serde_json::Value) -> Result<(), MergeError> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut out = serde_json::to_string_pretty(root)?;
    out.push('\n');
    std::fs::write(path, out)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("mootx01-perm-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn entries_derive_from_linked_server_and_are_prefixed() {
        let entries = permission_entries();
        assert!(entries.len() >= 50, "expected the full tool surface, got {}", entries.len());
        assert!(entries.iter().all(|e| e.starts_with(PREFIX)));
        assert!(entries.iter().any(|e| e == "mcp__mootx01__moot_memory_search"));
    }

    #[test]
    fn grant_is_additive_and_idempotent() {
        let dir = tmp("grant");
        let p = dir.join("settings.json");
        std::fs::write(&p, br#"{"permissions":{"allow":["Bash(ls:*)"]},"theme":"dark"}"#).unwrap();
        let added = grant(&p).unwrap();
        assert!(added >= 50);
        assert_eq!(grant(&p).unwrap(), 0); // idempotent
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(v["theme"], "dark");
        let allow = v["permissions"]["allow"].as_array().unwrap();
        assert_eq!(allow[0], "Bash(ls:*)"); // preserved, in place
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn revoke_strips_only_ours() {
        let dir = tmp("revoke");
        let p = dir.join("settings.json");
        grant(&p).unwrap();
        // Seed a foreign entry after granting.
        let mut v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        v["permissions"]["allow"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!("WebFetch"));
        std::fs::write(&p, serde_json::to_string_pretty(&v).unwrap()).unwrap();

        let removed = revoke(&p).unwrap();
        assert!(removed >= 50);
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        let allow = v["permissions"]["allow"].as_array().unwrap();
        assert_eq!(allow.len(), 1);
        assert_eq!(allow[0], "WebFetch");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
