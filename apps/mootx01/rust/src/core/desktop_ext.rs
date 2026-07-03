//! Install mootx01 as a Claude Desktop extension — Desktop's equivalent of a
//! plugin. Desktop does NOT read a plugin directory or a settings file; it
//! discovers extensions from its OWN registry inside the Claude data dir. A
//! `.mcpb` double-click writes three things, and this reproduces them
//! programmatically so `mootx01 install` wires Desktop with no manual step:
//!
//!   1. `Claude Extensions/<id>/manifest.json`      — the unpacked manifest
//!   2. `extensions-installations.json` `<id>` entry — the registry record
//!   3. `Claude Extensions Settings/<id>.json`       — `{"isEnabled": true}`
//!
//! The registry `source` is `"local"` and `signatureInfo` is unsigned — both
//! accepted for sideloaded extensions. The manifest's `mcp_config.command` is
//! the real installed binary path, resolved at install time, so nothing is
//! hardcoded. This is the Rust install vertical, which ships on Windows; the
//! Claude data dir is resolved from the client's config path (MSIX Store or
//! Win32 location on Windows). The macOS vertical is Swift; this file mirrors
//! `MootInstallerCore/ClaudeDesktopExtension.swift` byte-for-byte in behavior.

use crate::core::clients::McpClient;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::path::Path;

/// Stable extension id. Every install path (this installer, a `.mcpb`
/// double-click, the marketplace) MUST use the same id/name so Desktop
/// collapses them to a single entry rather than showing duplicates.
pub const EXTENSION_ID: &str = "local.mcpb.codedaptive.mootx01";

/// Install (or refresh) the Desktop extension for `client` (claude-desktop).
/// Returns `Ok(false)` when Claude Desktop's data dir is not present on this
/// machine (nothing to do); `Err` only on a genuine write failure.
pub fn install(
    client: &McpClient,
    home: &Path,
    binary_path: &str,
    version: &str,
) -> std::io::Result<bool> {
    // The Claude data dir is the directory that holds claude_desktop_config.json
    // — the same dir Desktop keeps its extension registry in.
    let config = match client.config_path(home) {
        Some(c) => c,
        None => return Ok(false),
    };
    let claude_dir = match config.parent() {
        Some(d) => d.to_path_buf(),
        None => return Ok(false),
    };
    if !claude_dir.exists() {
        return Ok(false);
    }

    // Manifest — display_name matches `name` ("mootx01") so this collapses with
    // the raw mcpServers entry install also writes.
    let manifest = json!({
        "manifest_version": "0.2",
        "name": "mootx01",
        "display_name": "mootx01",
        "version": version,
        "description": "MOOTx01 as active long-term memory and a low-token reasoning substrate: recall, analyze, contradiction-check, and write back durable knowledge.",
        "author": { "name": "Codedaptive", "url": "https://mootx01.ai" },
        "homepage": "https://mootx01.ai",
        "server": {
            "type": "binary",
            "entry_point": "mootx01",
            "mcp_config": { "command": binary_path, "args": ["proxy"], "env": {} }
        }
    });
    let manifest_bytes = serde_json::to_vec_pretty(&manifest)?;

    // 1. Unpack the manifest into the extensions dir.
    let ext_dir = claude_dir.join("Claude Extensions").join(EXTENSION_ID);
    std::fs::create_dir_all(&ext_dir)?;
    std::fs::write(ext_dir.join("manifest.json"), &manifest_bytes)?;

    // 2. Register it (merge — never clobber other installed extensions). The
    //    hash is a record only: Desktop discards the .mcpb after unpacking and
    //    zip output is non-deterministic, so it cannot re-derive it on load — a
    //    stable sha256 of the manifest serves.
    let reg_path = claude_dir.join("extensions-installations.json");
    let mut reg: Value = std::fs::read(&reg_path)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .filter(|v| v.is_object())
        .unwrap_or_else(|| json!({}));
    let hash: String = {
        let mut h = Sha256::new();
        h.update(&manifest_bytes);
        h.finalize().iter().map(|b| format!("{b:02x}")).collect()
    };
    let entry = json!({
        "id": EXTENSION_ID,
        "version": version,
        "hash": hash,
        "installedAt": now_iso8601(),
        "manifest": manifest,
        "signatureInfo": { "status": "unsigned" },
        "source": "local"
    });
    {
        let obj = reg.as_object_mut().expect("reg is an object");
        let exts = obj.entry("extensions").or_insert_with(|| json!({}));
        if !exts.is_object() {
            *exts = json!({});
        }
        exts.as_object_mut()
            .expect("extensions is an object")
            .insert(EXTENSION_ID.to_string(), entry);
    }
    std::fs::write(&reg_path, serde_json::to_vec_pretty(&reg)?)?;

    // 3. Enable it — the enabled flag lives in a separate settings file, and an
    //    absent file reads as DISABLED (the extension would install but stay off
    //    until the user toggles it).
    let settings_dir = claude_dir.join("Claude Extensions Settings");
    std::fs::create_dir_all(&settings_dir)?;
    std::fs::write(
        settings_dir.join(format!("{EXTENSION_ID}.json")),
        serde_json::to_vec(&json!({ "isEnabled": true }))?,
    )?;

    Ok(true)
}

/// ISO8601 UTC timestamp `yyyy-mm-ddTHH:MM:SS.000Z`, dependency-free (the crate
/// ships no chrono). Civil-from-days (Howard Hinnant) per `depth::backup_stamp`.
fn now_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (h, mi, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{h:02}:{mi:02}:{s:02}.000Z")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::clients;

    #[test]
    fn writes_manifest_registry_and_enabled_flag_preserving_others() {
        let tmp = std::env::temp_dir().join(format!("moot-ext-{}", std::process::id()));
        // Mirror the macOS Claude data-dir layout config_path() resolves to.
        let claude = tmp.join("Library").join("Application Support").join("Claude");
        std::fs::create_dir_all(&claude).unwrap();
        // A pre-existing extension MUST survive the merge.
        std::fs::write(
            claude.join("extensions-installations.json"),
            br#"{"extensions":{"other.ext":{"id":"other.ext"}}}"#,
        )
        .unwrap();

        let client = clients::supported()
            .into_iter()
            .find(|c| c.id == "claude-desktop")
            .expect("claude-desktop client");
        let wrote = install(&client, &tmp, "/opt/mootx01/bin/mootx01", "1.0.11").unwrap();
        assert!(wrote, "should write when the Claude dir exists");

        // 1. manifest — real command path, name collapses with raw wiring.
        let mpath = claude
            .join("Claude Extensions")
            .join(EXTENSION_ID)
            .join("manifest.json");
        let m: Value = serde_json::from_slice(&std::fs::read(&mpath).unwrap()).unwrap();
        assert_eq!(m["name"], "mootx01");
        assert_eq!(m["display_name"], "mootx01");
        assert_eq!(m["server"]["mcp_config"]["command"], "/opt/mootx01/bin/mootx01");
        assert_eq!(m["server"]["mcp_config"]["args"][0], "proxy");

        // 2. registry — our entry (local/unsigned) AND the pre-existing one.
        let reg: Value =
            serde_json::from_slice(&std::fs::read(claude.join("extensions-installations.json")).unwrap())
                .unwrap();
        assert_eq!(reg["extensions"][EXTENSION_ID]["source"], "local");
        assert_eq!(reg["extensions"][EXTENSION_ID]["signatureInfo"]["status"], "unsigned");
        assert_eq!(reg["extensions"][EXTENSION_ID]["version"], "1.0.11");
        assert_eq!(reg["extensions"]["other.ext"]["id"], "other.ext");

        // 3. enabled flag (else Desktop installs it disabled).
        let flag: Value = serde_json::from_slice(
            &std::fs::read(
                claude
                    .join("Claude Extensions Settings")
                    .join(format!("{EXTENSION_ID}.json")),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(flag["isEnabled"], true);

        std::fs::remove_dir_all(&tmp).ok();
    }
}
