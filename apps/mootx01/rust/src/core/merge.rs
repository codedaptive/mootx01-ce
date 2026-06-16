//! core/merge.rs — format-dispatched client config merge (spec §4.2).
//!
//! Ported from Swift Installer.swift (the reference):
//!   JSON  — parse, set `mcpServers.<server>`, write pretty + sorted keys.
//!           Blank file → `{}`; non-JSON content → refuse (never overwrite).
//!   TOML  — line-based `[mcp_servers.<server>]` table replace preserving all
//!           other lines verbatim; JSON-corruption fingerprint → refuse.
//!   YAML  — Continue's per-server file is written whole (it carries only the
//!           mootx01 entry). Other YAML configs (Hermes) are refused, same as
//!           the Swift dispatch refuses unknown formats.
//!
//! Backups (spec §4.2): before the first modification of any EXISTING config
//! file, copy it to `<filename>.bak-<YYYYMMDD-HHMMSS>` in the same directory.
//! Fresh files get no backup. Backups are never auto-deleted.
//!
//! Conformance (spec §7): TOML output is byte-equivalent to the Swift
//! implementation for the shared vectors; JSON is semantically equivalent
//! (Swift JSONSerialization and serde_json pretty-print differently — both
//! sorted-key, 2-space; key ordering and escaping match, separators differ
//! in whitespace only).

use std::fmt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::core::clients::McpClient;

#[derive(Debug)]
pub enum MergeError {
    /// Existing file content is the wrong format; refusing to overwrite.
    MalformedConfig { path: PathBuf, detail: String },
    Io(std::io::Error),
    Json(serde_json::Error),
}

impl fmt::Display for MergeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MergeError::MalformedConfig { path, detail } => {
                write!(f, "{}: {detail}", path.display())
            }
            MergeError::Io(e) => write!(f, "{e}"),
            MergeError::Json(e) => write!(f, "{e}"),
        }
    }
}

impl From<std::io::Error> for MergeError {
    fn from(e: std::io::Error) -> Self {
        MergeError::Io(e)
    }
}
impl From<serde_json::Error> for MergeError {
    fn from(e: serde_json::Error) -> Self {
        MergeError::Json(e)
    }
}

// ---------------------------------------------------------------------------
// Backup (§4.2)
// ---------------------------------------------------------------------------

/// Copy an existing config file to `<filename>.bak-<YYYYMMDD-HHMMSS>` beside
/// it. Returns the backup path, or None when the file does not exist (fresh
/// files are exempt). One backup per file per run is the caller's contract —
/// call once before the first write.
pub fn backup_existing(path: &Path) -> std::io::Result<Option<PathBuf>> {
    if !path.exists() {
        return Ok(None);
    }
    let stamp = timestamp_utc();
    let file_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("config");
    let backup = path.with_file_name(format!("{file_name}.bak-{stamp}"));
    std::fs::copy(path, &backup)?;
    Ok(Some(backup))
}

/// UTC `YYYYMMDD-HHMMSS` from the system clock, no external deps
/// (civil-from-days per Howard Hinnant's algorithm).
fn timestamp_utc() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = (secs / 86_400) as i64;
    let (y, m, d) = civil_from_days(days);
    let rem = secs % 86_400;
    let (hh, mm, ss) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    format!("{y:04}{m:02}{d:02}-{hh:02}{mm:02}{ss:02}")
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

// ---------------------------------------------------------------------------
// Entry shapes (mirrors Swift mergeIntoJSONConfig's entry builder)
// ---------------------------------------------------------------------------

/// The JSON entry for this client's transport.
///   supports_local_http → {"type":"http","url":daemon_url} or {"url":daemon_url}
///   use_proxy_bridge    → {"command":binary,"args":["proxy","--http",daemon_url],"env":{}}
///   headless stdio      → {"command":binary,"args":[],"env":{}}
pub fn entry_for(client: &McpClient, binary_path: &str, daemon_url: &str) -> serde_json::Value {
    if client.id == "opencode" {
        // Schema-verified (https://opencode.ai/config.json, McpRemoteConfig):
        // remote servers are { "type": "remote", "url": … } under the
        // top-level "mcp" key — not the mcpServers/"http" convention.
        serde_json::json!({ "type": "remote", "url": daemon_url })
    } else if client.supports_local_http {
        if client.http_entry_includes_type {
            serde_json::json!({ "type": "http", "url": daemon_url })
        } else {
            serde_json::json!({ "url": daemon_url })
        }
    } else if client.use_proxy_bridge {
        serde_json::json!({
            "command": binary_path,
            "args": ["proxy", "--http", daemon_url],
            "env": {}
        })
    } else {
        serde_json::json!({ "command": binary_path, "args": [], "env": {} })
    }
}

// ---------------------------------------------------------------------------
// JSON merge
// ---------------------------------------------------------------------------

/// Merge `<servers_key>.<server_name> = entry` into a JSON config. Blank or
/// absent file starts from `{}`; existing non-JSON content is refused. The
/// servers key is per-client (`mcpServers` for most; opencode uses `mcp`).
pub fn merge_into_json_config(
    path: &Path,
    servers_key: &str,
    server_name: &str,
    entry: serde_json::Value,
) -> Result<(), MergeError> {
    let mut root = read_json_root(path)?;
    let obj = root.as_object_mut().expect("root is object by construction");
    let servers = obj
        .entry(servers_key)
        .or_insert_with(|| serde_json::json!({}));
    if !servers.is_object() {
        return Err(MergeError::MalformedConfig {
            path: path.to_path_buf(),
            detail: format!("'{servers_key}' exists but is not an object; refusing to overwrite it."),
        });
    }
    servers[server_name] = entry;
    write_json(path, &root)
}

/// Remove `<servers_key>.<server_name>` from a JSON config. Absent file or
/// absent entry is a no-op. Returns true when an entry was removed.
pub fn remove_from_json_config(
    path: &Path,
    servers_key: &str,
    server_name: &str,
) -> Result<bool, MergeError> {
    if !path.exists() {
        return Ok(false);
    }
    let mut root = read_json_root(path)?;
    let removed = root
        .get_mut(servers_key)
        .and_then(|s| s.as_object_mut())
        .map(|s| s.remove(server_name).is_some())
        .unwrap_or(false);
    if removed {
        write_json(path, &root)?;
    }
    Ok(removed)
}

/// Strip a leading UTF-8 BOM (`\u{FEFF}`) if present. Some editors and Windows
/// tools — notably Windows PowerShell 5.1's `Set-Content -Encoding UTF8` —
/// prepend a BOM. serde_json, toml, and the YAML line probes all treat it as a
/// stray leading character (`str::trim` does NOT remove it — U+FEFF is not
/// Unicode White_Space), so every config reader strips it before parsing.
pub(crate) fn strip_bom(text: &str) -> &str {
    text.strip_prefix('\u{feff}').unwrap_or(text)
}

fn read_json_root(path: &Path) -> Result<serde_json::Value, MergeError> {
    if !path.exists() {
        return Ok(serde_json::json!({}));
    }
    let bytes = std::fs::read(path)?;
    let lossy = String::from_utf8_lossy(&bytes);
    let text = strip_bom(&lossy);
    if text.trim().is_empty() {
        return Ok(serde_json::json!({}));
    }
    match serde_json::from_str::<serde_json::Value>(text) {
        Ok(v) if v.is_object() => Ok(v),
        _ => Err(MergeError::MalformedConfig {
            path: path.to_path_buf(),
            detail: "existing file is not valid JSON; refusing to overwrite it. \
                     Inspect or remove the file, then re-run."
                .into(),
        }),
    }
}

fn write_json(path: &Path, root: &serde_json::Value) -> Result<(), MergeError> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // serde_json without preserve_order keeps object keys sorted (BTreeMap),
    // matching Swift's .sortedKeys; pretty output is 2-space indented.
    let mut out = serde_json::to_string_pretty(root)?;
    out.push('\n');
    std::fs::write(path, out)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// TOML merge (byte-for-byte port of Swift mergeIntoTOMLConfig)
// ---------------------------------------------------------------------------

/// Merge the mootx01 entry into a TOML config (Codex CLI / Desktop) by
/// replacing only the `[mcp_servers.<server>]` table. Refuses a file whose
/// content is a JSON object (the fingerprint of a prior broken install).
pub fn merge_into_toml_config(
    path: &Path,
    client: &McpClient,
    server_name: &str,
    binary_path: &str,
    daemon_url: &str,
) -> Result<(), MergeError> {
    let header = format!("[mcp_servers.{server_name}]");
    let mut block = vec![header.clone()];
    if client.supports_local_http {
        block.push(format!("url = \"{daemon_url}\""));
    } else if client.use_proxy_bridge {
        block.push(format!("command = \"{binary_path}\""));
        block.push(format!("args = [\"proxy\", \"--http\", \"{daemon_url}\"]"));
    } else {
        block.push(format!("command = \"{binary_path}\""));
        block.push("args = []".to_string());
    }
    let new_table = block.join("\n");

    let existing = read_toml_text(path)?;
    let merged = replacing_toml_table(&existing, &header, &new_table);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(path, merged)?;
    Ok(())
}

/// Remove the `[mcp_servers.<server>]` table from a TOML config. Absent file
/// is a no-op. Returns true when the table was present.
pub fn remove_from_toml_config(path: &Path, server_name: &str) -> Result<bool, MergeError> {
    if !path.exists() {
        return Ok(false);
    }
    let header = format!("[mcp_servers.{server_name}]");
    let existing = read_toml_text(path)?;
    let present = existing.lines().any(|l| l.trim() == header);
    if present {
        let stripped = removing_toml_table(&existing, &header);
        std::fs::write(path, stripped)?;
    }
    Ok(present)
}

fn read_toml_text(path: &Path) -> Result<String, MergeError> {
    if !path.exists() {
        return Ok(String::new());
    }
    let bytes = std::fs::read(path)?;
    let text = strip_bom(&String::from_utf8_lossy(&bytes)).to_owned();
    // A config.toml whose content is a JSON object is the fingerprint of a
    // prior broken install (JSON written into the TOML file). Refuse and tell
    // the user how to recover rather than compounding the corruption.
    let trimmed = text.trim();
    if trimmed.starts_with('{')
        && serde_json::from_str::<serde_json::Value>(trimmed).is_ok()
    {
        return Err(MergeError::MalformedConfig {
            path: path.to_path_buf(),
            detail: "file contains JSON, not TOML (likely a prior broken install). \
                     Restore from the .bak- backup beside it or remove it, then re-run."
                .into(),
        });
    }
    Ok(text)
}

/// Return `text` with the table named by `header` (and any child subtables)
/// removed and `new_table` appended at the end — exact port of the Swift
/// `replacingTOMLTable` (line-based, preserves everything else verbatim,
/// trailing blanks trimmed so the appended table is separated by exactly one
/// blank line).
pub fn replacing_toml_table(text: &str, header: &str, new_table: &str) -> String {
    let mut output = removing_toml_table_lines(text, header);
    while output
        .last()
        .map(|l| l.trim().is_empty())
        .unwrap_or(false)
    {
        output.pop();
    }
    let mut result = output.join("\n");
    if !result.is_empty() {
        result.push_str("\n\n");
    }
    result.push_str(new_table);
    result.push('\n');
    result
}

/// `replacing_toml_table` without the append — used by uninstall.
fn removing_toml_table(text: &str, header: &str) -> String {
    let mut output = removing_toml_table_lines(text, header);
    while output
        .last()
        .map(|l| l.trim().is_empty())
        .unwrap_or(false)
    {
        output.pop();
    }
    let mut result = output.join("\n");
    if !result.is_empty() {
        result.push('\n');
    }
    result
}

fn removing_toml_table_lines<'a>(text: &'a str, header: &str) -> Vec<&'a str> {
    // header "[mcp_servers.mootx01]"; child prefix "[mcp_servers.mootx01."
    let child_prefix = format!("{}.", &header[..header.len() - 1]);
    let lines: Vec<&str> = if text.is_empty() {
        Vec::new()
    } else {
        text.split('\n').collect()
    };
    let mut output = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let trimmed = lines[i].trim();
        if trimmed == header || trimmed.starts_with(&child_prefix) {
            // Skip this table's header and body up to the next unrelated
            // table header or EOF; child subtables mid-skip are consumed too.
            i += 1;
            while i < lines.len() {
                let t = lines[i].trim();
                if t.starts_with('[') && t != header && !t.starts_with(&child_prefix) {
                    break;
                }
                i += 1;
            }
            continue;
        }
        output.push(lines[i]);
        i += 1;
    }
    output
}

// ---------------------------------------------------------------------------
// Hermes shared YAML (line-based block merge under `mcp_servers:`)
// ---------------------------------------------------------------------------

/// Merge the mootx01 entry into Hermes' shared `config.yaml`. Schema verified
/// against the real hermes-agent `cli-config.yaml.example`: a top-level
/// `mcp_servers:` mapping whose HTTP entries carry a `url:` key. Line-based,
/// same discipline as the TOML merge: only our own block is touched, every
/// other line preserved verbatim. Flow style (`mcp_servers: {…}`) is refused
/// rather than risked — a line editor cannot safely extend it.
pub fn merge_into_hermes_yaml(path: &Path, server_name: &str, url: &str) -> Result<(), MergeError> {
    let existing = read_hermes_text(path)?;
    let block = format!("  {server_name}:\n    url: {url}");
    let merged = replacing_hermes_block(path, &existing, server_name, Some(&block))?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(path, merged)?;
    Ok(())
}

/// Remove the mootx01 block from Hermes' `config.yaml`. Absent file or
/// absent entry is a no-op. Returns true when the entry was present. When
/// the removal leaves `mcp_servers:` with no children at all (the section
/// we created on install), the bare section line and its preceding blank
/// separator are dropped too, so install → uninstall restores the original
/// file byte-identically. A section retaining any content — entries or
/// comments — is left untouched.
pub fn remove_from_hermes_yaml(path: &Path, server_name: &str) -> Result<bool, MergeError> {
    if !path.exists() {
        return Ok(false);
    }
    let existing = read_hermes_text(path)?;
    let entry_header = format!("  {server_name}:");
    let present = existing.lines().any(|l| l.trim_end() == entry_header);
    if present {
        let stripped = replacing_hermes_block(path, &existing, server_name, None)?;
        let stripped = dropping_empty_hermes_section(&stripped);
        std::fs::write(path, stripped)?;
    }
    Ok(present)
}

/// Drop a `mcp_servers:` line whose section body is empty (blank lines only
/// up to the next top-level key or EOF), plus one preceding blank separator.
fn dropping_empty_hermes_section(text: &str) -> String {
    let lines: Vec<&str> = text.split('\n').collect();
    let Some(idx) = lines.iter().position(|l| {
        l.strip_prefix("mcp_servers:")
            .map(|after| {
                let after = after.trim();
                after.is_empty() || after.starts_with('#')
            })
            .unwrap_or(false)
    }) else {
        return text.to_string();
    };
    // Section body: lines after idx until the next top-level key.
    let mut end = idx + 1;
    while end < lines.len() {
        let l = lines[end];
        if !l.trim().is_empty() && !l.starts_with(' ') {
            break;
        }
        if !l.trim().is_empty() {
            return text.to_string(); // section still has content
        }
        end += 1;
    }
    let mut output: Vec<&str> = Vec::new();
    output.extend_from_slice(&lines[..idx]);
    // Collapse the single blank separator we add when creating the section.
    if output.last().map(|l| l.trim().is_empty()).unwrap_or(false)
        && output
            .iter()
            .rev()
            .nth(1)
            .map(|l| !l.trim().is_empty())
            .unwrap_or(false)
    {
        output.pop();
    }
    output.extend_from_slice(&lines[end..]);
    let mut result = output.join("\n");
    if !result.ends_with('\n') {
        result.push('\n');
    }
    result
}

fn read_hermes_text(path: &Path) -> Result<String, MergeError> {
    if !path.exists() {
        return Ok(String::new());
    }
    let bytes = std::fs::read(path)?;
    let text = strip_bom(&String::from_utf8_lossy(&bytes)).to_owned();
    let trimmed = text.trim();
    if trimmed.starts_with('{') && serde_json::from_str::<serde_json::Value>(trimmed).is_ok() {
        return Err(MergeError::MalformedConfig {
            path: path.to_path_buf(),
            detail: "file contains JSON, not YAML (likely a prior broken install). \
                     Restore from the .bak- backup beside it or remove it, then re-run."
                .into(),
        });
    }
    Ok(text)
}

/// Rewrite the `mcp_servers:` block: drop any existing `  <server>:` entry
/// (with its more-indented children), then insert `replacement` immediately
/// after the `mcp_servers:` line (creating the section at EOF when absent).
/// `replacement: None` = removal. Everything else preserved verbatim.
fn replacing_hermes_block(
    path: &Path,
    text: &str,
    server_name: &str,
    replacement: Option<&str>,
) -> Result<String, MergeError> {
    let lines: Vec<&str> = if text.is_empty() {
        Vec::new()
    } else {
        text.split('\n').collect()
    };

    // Locate the top-level `mcp_servers:` line; refuse flow style.
    let mut section_idx: Option<usize> = None;
    for (i, line) in lines.iter().enumerate() {
        if let Some(after) = line.strip_prefix("mcp_servers:") {
            let after = after.trim();
            if !(after.is_empty() || after.starts_with('#')) {
                return Err(MergeError::MalformedConfig {
                    path: path.to_path_buf(),
                    detail: "the 'mcp_servers' key uses YAML flow style; \
                             add the mootx01 entry manually."
                        .into(),
                });
            }
            section_idx = Some(i);
            break;
        }
    }

    // Drop our existing entry (2-space key + >=4-space children), tracking
    // whether we are inside the mcp_servers section.
    let entry_header = format!("  {server_name}:");
    let mut output: Vec<String> = Vec::new();
    let mut in_section = false;
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if Some(i) == section_idx {
            in_section = true;
        } else if in_section
            && !line.trim().is_empty()
            && !line.starts_with(' ')
            && !line.starts_with('#')
        {
            in_section = false; // next top-level key ends the section
        }
        if in_section && line.trim_end() == entry_header {
            i += 1;
            while i < lines.len() {
                let l = lines[i];
                if l.starts_with("    ") && !l.trim().is_empty() {
                    i += 1; // child of our entry
                } else {
                    break;
                }
            }
            continue;
        }
        output.push(line.to_string());
        i += 1;
    }

    if let Some(block) = replacement {
        match output.iter().position(|l| l.starts_with("mcp_servers:")) {
            Some(pos) => output.insert(pos + 1, block.to_string()),
            None => {
                while output.last().map(|l| l.trim().is_empty()).unwrap_or(false) {
                    output.pop();
                }
                if !output.is_empty() {
                    output.push(String::new());
                }
                output.push("mcp_servers:".to_string());
                output.push(block.to_string());
            }
        }
    }

    let mut result = output.join("\n");
    if !result.ends_with('\n') {
        result.push('\n');
    }
    Ok(result)
}

// ---------------------------------------------------------------------------
// Continue YAML (per-server file, written whole)
// ---------------------------------------------------------------------------

/// Write Continue's per-server YAML. HTTP-capable → streamable-http with the
/// daemon url; otherwise the stdio command entry. Mirrors Swift
/// `installContinue` byte for byte.
pub fn write_continue_yaml(
    path: &Path,
    binary_path: &str,
    http_url: Option<&str>,
) -> Result<(), MergeError> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let yaml = match http_url {
        Some(url) => format!("type: streamable-http\nurl: {url}\n"),
        None => format!("command: {binary_path}\nargs: []\n"),
    };
    std::fs::write(path, yaml)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::clients;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("mootx01-merge-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn client(id: &str) -> clients::McpClient {
        clients::supported().into_iter().find(|c| c.id == id).unwrap()
    }

    // --- TOML conformance vectors (byte-exact vs Swift replacingTOMLTable) ---

    #[test]
    fn toml_replace_preserves_other_content_verbatim() {
        let existing = "# my codex config\nmodel = \"o3\"\n\n[profiles.fast]\nmodel = \"o4-mini\"\n\n[mcp_servers.mootx01]\nurl = \"http://127.0.0.1:9999\"\n\n[mcp_servers.other]\ncommand = \"x\"\n";
        let got = replacing_toml_table(
            existing,
            "[mcp_servers.mootx01]",
            "[mcp_servers.mootx01]\nurl = \"http://127.0.0.1:4242\"",
        );
        let want = "# my codex config\nmodel = \"o3\"\n\n[profiles.fast]\nmodel = \"o4-mini\"\n\n[mcp_servers.other]\ncommand = \"x\"\n\n[mcp_servers.mootx01]\nurl = \"http://127.0.0.1:4242\"\n";
        assert_eq!(got, want);
    }

    #[test]
    fn toml_replace_consumes_child_subtables() {
        let existing = "[mcp_servers.mootx01]\nurl = \"old\"\n\n[mcp_servers.mootx01.headers]\nx = \"1\"\n\n[other]\nk = \"v\"\n";
        let got = replacing_toml_table(
            existing,
            "[mcp_servers.mootx01]",
            "[mcp_servers.mootx01]\nurl = \"new\"",
        );
        assert_eq!(got, "[other]\nk = \"v\"\n\n[mcp_servers.mootx01]\nurl = \"new\"\n");
    }

    #[test]
    fn toml_replace_on_empty_input_is_just_the_table() {
        let got = replacing_toml_table("", "[mcp_servers.mootx01]", "[mcp_servers.mootx01]\nurl = \"u\"");
        assert_eq!(got, "[mcp_servers.mootx01]\nurl = \"u\"\n");
    }

    #[test]
    fn toml_merge_refuses_json_fingerprint() {
        let dir = tmp("toml-json");
        let p = dir.join("config.toml");
        std::fs::write(&p, br#"{"mcpServers":{"mootx01":{}}}"#).unwrap();
        let err = merge_into_toml_config(&p, &client("codex"), "mootx01", "/b", "http://u")
            .unwrap_err();
        assert!(matches!(err, MergeError::MalformedConfig { .. }));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn toml_remove_round_trip() {
        let dir = tmp("toml-rm");
        let p = dir.join("config.toml");
        std::fs::write(&p, "model = \"o3\"\n").unwrap();
        merge_into_toml_config(&p, &client("codex"), "mootx01", "/b", "http://u").unwrap();
        assert!(std::fs::read_to_string(&p).unwrap().contains("[mcp_servers.mootx01]"));
        assert!(remove_from_toml_config(&p, "mootx01").unwrap());
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "model = \"o3\"\n");
        assert!(!remove_from_toml_config(&p, "mootx01").unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // --- JSON ---

    #[test]
    fn json_merge_creates_and_is_idempotent() {
        let dir = tmp("json");
        let p = dir.join("c.json");
        let e = entry_for(&client("claude-code"), "/b", "http://127.0.0.1:4242");
        merge_into_json_config(&p, "mcpServers", "mootx01", e.clone()).unwrap();
        let first = std::fs::read_to_string(&p).unwrap();
        merge_into_json_config(&p, "mcpServers", "mootx01", e).unwrap();
        assert_eq!(first, std::fs::read_to_string(&p).unwrap());
        let v: serde_json::Value = serde_json::from_str(&first).unwrap();
        assert_eq!(v["mcpServers"]["mootx01"]["type"], "http");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn json_merge_preserves_existing_servers_and_keys() {
        let dir = tmp("json-merge");
        let p = dir.join("c.json");
        std::fs::write(&p, br#"{"theme":"dark","mcpServers":{"other":{"command":"x"}}}"#).unwrap();
        merge_into_json_config(&p, "mcpServers", "mootx01", entry_for(&client("cursor"), "/b", "http://u")).unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(v["theme"], "dark");
        assert_eq!(v["mcpServers"]["other"]["command"], "x");
        assert_eq!(v["mcpServers"]["mootx01"]["url"], "http://u");
        assert!(v["mcpServers"]["mootx01"].get("type").is_none()); // cursor: bare url
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn json_merge_tolerates_leading_utf8_bom() {
        // A BOM'd JSON config (Windows PowerShell 5.1 `Set-Content -Encoding
        // UTF8`) must merge, not get rejected as malformed. The rewrite also
        // drops the BOM so the file is clean afterward.
        let dir = tmp("json-bom");
        let p = dir.join("c.json");
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(br#"{"theme":"dark","mcpServers":{"other":{"command":"x"}}}"#);
        std::fs::write(&p, &bytes).unwrap();
        merge_into_json_config(&p, "mcpServers", "mootx01", entry_for(&client("cursor"), "/b", "http://u")).unwrap();
        let written = std::fs::read(&p).unwrap();
        assert_ne!(&written[..3], b"\xEF\xBB\xBF", "BOM should be gone after rewrite");
        let v: serde_json::Value = serde_json::from_slice(&written).unwrap();
        assert_eq!(v["theme"], "dark");
        assert_eq!(v["mcpServers"]["other"]["command"], "x");
        assert_eq!(v["mcpServers"]["mootx01"]["url"], "http://u");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn json_merge_refuses_non_json_content() {
        let dir = tmp("json-bad");
        let p = dir.join("c.json");
        std::fs::write(&p, b"model = \"o3\"\n").unwrap();
        let err = merge_into_json_config(&p, "mcpServers", "mootx01", serde_json::json!({})).unwrap_err();
        assert!(matches!(err, MergeError::MalformedConfig { .. }));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn json_remove_round_trip() {
        let dir = tmp("json-rm");
        let p = dir.join("c.json");
        std::fs::write(&p, br#"{"mcpServers":{"mootx01":{"url":"u"},"other":{}}}"#).unwrap();
        assert!(remove_from_json_config(&p, "mcpServers", "mootx01").unwrap());
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        assert!(v["mcpServers"].get("mootx01").is_none());
        assert!(v["mcpServers"].get("other").is_some());
        assert!(!remove_from_json_config(&p, "mcpServers", "mootx01").unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // --- Entry shapes ---

    #[test]
    fn proxy_bridge_entry_shape() {
        let e = entry_for(&client("claude-desktop"), "/usr/local/bin/mootx01", "http://127.0.0.1:4242");
        assert_eq!(e["command"], "/usr/local/bin/mootx01");
        assert_eq!(e["args"], serde_json::json!(["proxy", "--http", "http://127.0.0.1:4242"]));
        assert_eq!(e["env"], serde_json::json!({}));
    }

    // --- Backup ---

    #[test]
    fn backup_copies_existing_and_skips_fresh() {
        let dir = tmp("bak");
        let p = dir.join("config.toml");
        assert!(backup_existing(&p).unwrap().is_none()); // fresh: exempt
        std::fs::write(&p, b"model = \"o3\"\n").unwrap();
        let bak = backup_existing(&p).unwrap().expect("backup path");
        let name = bak.file_name().unwrap().to_str().unwrap();
        assert!(name.starts_with("config.toml.bak-"), "{name}");
        assert_eq!(std::fs::read(&bak).unwrap(), b"model = \"o3\"\n");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // --- Continue YAML ---

    #[test]
    fn continue_yaml_shapes() {
        let dir = tmp("yaml");
        let p = dir.join("mootx01.yaml");
        write_continue_yaml(&p, "/b", Some("http://u")).unwrap();
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            "type: streamable-http\nurl: http://u\n"
        );
        write_continue_yaml(&p, "/b", None).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "command: /b\nargs: []\n");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // --- Hermes shared YAML ---

    #[test]
    fn hermes_merge_creates_section_at_eof_when_absent() {
        let dir = tmp("hermes-new");
        let p = dir.join("config.yaml");
        std::fs::write(&p, "model:\n  default: \"x\"\n").unwrap();
        merge_into_hermes_yaml(&p, "mootx01", "http://127.0.0.1:4242").unwrap();
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            "model:\n  default: \"x\"\n\nmcp_servers:\n  mootx01:\n    url: http://127.0.0.1:4242\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hermes_merge_preserves_other_servers_and_replaces_ours() {
        let dir = tmp("hermes-merge");
        let p = dir.join("config.yaml");
        std::fs::write(
            &p,
            "# comment\nmcp_servers:\n  time:\n    command: uvx\n    args: [\"mcp-server-time\"]\n  mootx01:\n    url: http://stale:1\n\ntts:\n  engine: edge\n",
        )
        .unwrap();
        merge_into_hermes_yaml(&p, "mootx01", "http://127.0.0.1:4242").unwrap();
        let got = std::fs::read_to_string(&p).unwrap();
        assert_eq!(
            got,
            "# comment\nmcp_servers:\n  mootx01:\n    url: http://127.0.0.1:4242\n  time:\n    command: uvx\n    args: [\"mcp-server-time\"]\n\ntts:\n  engine: edge\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hermes_merge_refuses_flow_style() {
        let dir = tmp("hermes-flow");
        let p = dir.join("config.yaml");
        std::fs::write(&p, "mcp_servers: {}\n").unwrap();
        let err = merge_into_hermes_yaml(&p, "mootx01", "http://u").unwrap_err();
        assert!(matches!(err, MergeError::MalformedConfig { .. }));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hermes_does_not_touch_same_key_under_other_sections() {
        // A `  mootx01:` line under a DIFFERENT top-level key must survive.
        let dir = tmp("hermes-scope");
        let p = dir.join("config.yaml");
        std::fs::write(
            &p,
            "aliases:\n  mootx01:\n    note: unrelated\nmcp_servers:\n  mootx01:\n    url: http://stale:1\n",
        )
        .unwrap();
        merge_into_hermes_yaml(&p, "mootx01", "http://new:2").unwrap();
        let got = std::fs::read_to_string(&p).unwrap();
        assert!(got.contains("aliases:\n  mootx01:\n    note: unrelated"));
        assert!(got.contains("mcp_servers:\n  mootx01:\n    url: http://new:2"));
        assert!(!got.contains("stale"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hermes_remove_round_trip() {
        let dir = tmp("hermes-rm");
        let p = dir.join("config.yaml");
        let original = "model:\n  default: \"x\"\nmcp_servers:\n  time:\n    command: uvx\n";
        std::fs::write(&p, original).unwrap();
        merge_into_hermes_yaml(&p, "mootx01", "http://u").unwrap();
        assert!(std::fs::read_to_string(&p).unwrap().contains("  mootx01:"));
        assert!(remove_from_hermes_yaml(&p, "mootx01").unwrap());
        assert_eq!(std::fs::read_to_string(&p).unwrap(), original);
        assert!(!remove_from_hermes_yaml(&p, "mootx01").unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hermes_remove_drops_section_we_created_byte_identical() {
        // No mcp_servers section in the original (only a commented one, as
        // hermes' seeded example file has): install creates it, uninstall
        // must remove it again — byte-identical restore.
        let dir = tmp("hermes-rm-section");
        let p = dir.join("config.yaml");
        let original = "model:\n  default: \"x\"\n\n# mcp_servers:\n#   time:\n#     command: uvx\n";
        std::fs::write(&p, original).unwrap();
        merge_into_hermes_yaml(&p, "mootx01", "http://u").unwrap();
        assert!(std::fs::read_to_string(&p).unwrap().ends_with("\nmcp_servers:\n  mootx01:\n    url: http://u\n"));
        assert!(remove_from_hermes_yaml(&p, "mootx01").unwrap());
        assert_eq!(std::fs::read_to_string(&p).unwrap(), original);
        // A section that retains real content is never dropped (covered by
        // hermes_remove_round_trip above).
        let _ = std::fs::remove_dir_all(&dir);
    }

    // --- opencode (top-level `mcp` key, type:"remote") ---

    #[test]
    fn opencode_uses_mcp_key_and_remote_type() {
        let dir = tmp("opencode-key");
        let p = dir.join("opencode.jsonc");
        std::fs::write(&p, br#"{"$schema": "https://opencode.ai/config.json"}"#).unwrap();
        let clients = crate::core::clients::supported();
        let oc = clients.iter().find(|c| c.id == "opencode").unwrap();
        let entry = entry_for(oc, "/bin/mootx01", "http://127.0.0.1:4242");
        merge_into_json_config(&p, oc.json_servers_key(), "mootx01", entry).unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        assert!(v.get("mcpServers").is_none());
        assert_eq!(v["mcp"]["mootx01"]["type"], "remote");
        assert_eq!(v["mcp"]["mootx01"]["url"], "http://127.0.0.1:4242");
        assert_eq!(v["$schema"], "https://opencode.ai/config.json");
        assert!(remove_from_json_config(&p, oc.json_servers_key(), "mootx01").unwrap());
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        assert!(v["mcp"].as_object().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
