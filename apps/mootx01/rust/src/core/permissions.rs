//! core/permissions.rs — Claude Code `permissions.allow`/`.ask`/`.deny` writer.
//!
//! Ported from Swift PermissionsWriter.swift (AIRA-INSTALL-P3 finding): the
//! settings key is `permissions.allow` (nested under a `permissions`
//! object), NOT top-level `allowedTools`. Entries take the MCP-prefixed
//! form `mcp__mootx01__<tool_name>` for the direct connection, and
//! `mcp__plugin_mootx01_mootx01__<tool_name>` for calls routed through the
//! installed plugin (ADR-024 §2, v1.0.15) — empirically confirmed against a
//! live `~/.claude/settings.json` carrying both prefixes side by side (this
//! installer's marketplace and plugin are both named `mootx01`, giving the
//! concrete plugin prefix `mcp__plugin_mootx01_mootx01__`). A rule written
//! for only one namespace matches zero calls made through the other
//! connection — every tier write in this file covers BOTH.
//!
//! Tool names are derived at runtime from the linked aria-mcp library
//! (`tool_list::build_tool_list()`), so the allow list can never drift from
//! the server's actual tool surface — no hardcoded name table for WHICH
//! tools exist. The TIER table below (`classify`) is a different kind of
//! name table: it classifies by verb semantics (read / additive-write /
//! mutation / destructive), which cannot be inferred from a generic pattern.
//!
//! The merge is additive and idempotent: existing entries are preserved,
//! ours are appended once — EXCEPT `migrate_tiers`, which re-tiers an
//! existing entry that predates the current classification but never moves
//! an entry already in `deny` (see its doc comment). `revoke` strips both
//! namespace prefixes and leaves everything else.

use std::collections::HashSet;
use std::path::Path;

use crate::core::merge::MergeError;

const PREFIX: &str = "mcp__mootx01__";

/// The MCP tool prefix Claude Code uses for calls routed through the
/// installed plugin. See the module doc comment for the empirical
/// confirmation and shape rationale.
const PLUGIN_PREFIX: &str = "mcp__plugin_mootx01_mootx01__";

/// Every namespace prefix a tool name must be written under.
const ALL_PREFIXES: [&str; 2] = [PREFIX, PLUGIN_PREFIX];

/// `mcp__mootx01__<name>` for every tool the linked server exposes (direct
/// namespace only — used by `grant`, the allow-all opt-in).
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

// ---------------------------------------------------------------------------
// Tier classification — Bob's re-tier ruling, 2026-07-04
//
// The PRIOR classifier put every tool that wasn't a diagnostic or a
// destructive purge into `ask`, including every pure read (all lenses,
// memory_search, recalls, fact/connection search, read_journal) — 55 ask
// rules on a real machine, unusable from real permission prompts. Verb
// semantics cannot be inferred from a generic name pattern the way "ends in
// _status" can, so the source of truth is the explicit tables below, not a
// pattern match. Mirrors Swift `PermissionsWriter`'s four tables exactly —
// both verticals must place the same tool in the same tier.
// ---------------------------------------------------------------------------

/// Reads: no estate content is created, changed, or removed.
const READ_TOOLS: &[&str] = &[
    "moot_estate_status", "moot_estate_ping", "moot_drain_status",
    "moot_list_lenses", "moot_list_recipes",
    "moot_vault_status", "moot_vault_job",
    "moot_memory_search", "moot_memory_get",
    "moot_recall_precise", "moot_recall_shaped", "moot_recall_distilled", "moot_recollect",
    "moot_fact_search", "moot_fact_timeline",
    "moot_connection_search", "moot_connection_map",
    "moot_estate_map", "moot_read_journal", "moot_federated_search",
    "moot_lens_anticipate", "moot_lens_apriori", "moot_lens_associations", "moot_lens_bias",
    "moot_lens_cohesion", "moot_lens_complexity", "moot_lens_concepts", "moot_lens_constellation",
    "moot_lens_contradiction", "moot_lens_divergence", "moot_lens_drift", "moot_lens_free_association",
    "moot_lens_keystones", "moot_lens_latent_themes", "moot_lens_moment", "moot_lens_node_motion",
    "moot_lens_overlap", "moot_lens_partial_cue", "moot_lens_precedence", "moot_lens_rhythm",
    "moot_lens_successors", "moot_lens_theme_weather", "moot_lens_trust_synthesis",
];

/// Additive-unconfirmed writes: create NEW content; nothing already
/// committed is changed, moved, or removed.
const ADDITIVE_WRITE_TOOLS: &[&str] =
    &["moot_file_memory", "moot_file_fact", "moot_write_journal", "moot_link_memories"];

/// Mutations of existing state: something already committed changes shape,
/// is superseded, moves, or a background process alters estate-wide
/// indexes/consolidation state.
const MUTATION_TOOLS: &[&str] = &[
    "moot_update_memory", "moot_move_memory", "moot_withdraw_memory", "moot_confirm_memory",
    "moot_retire_fact", "moot_confirm_migration", "moot_run_migration",
    "moot_reindex", "moot_dream", "moot_consolidate", "moot_synthesize",
    "moot_palace_import", "moot_vault_import", "moot_vault_export", "moot_vault_reconcile",
    // Monitoring flag mutation (ADR-025 wave 8.2): sets daemon telemetry state
    // when `enabled` is supplied. Ask tier because it changes daemon behaviour.
    // Mirrors Swift PermissionsWriter.mutationTools (parity required).
    "moot_monitoring_status",
];

/// Destructive, irreversible: hard-deletes content from the estate.
const DESTRUCTIVE_TOOLS: &[&str] = &["moot_erase_memory"];

/// Every tool name this module has explicitly triaged into a tier. Exposed
/// so a test can assert this set equals the REAL tool inventory
/// (`aria_mcp::tool_list::build_tool_list()`) — a tool the classification
/// tables have not been updated for must fail that test, not silently fall
/// through `classify`'s safe-middle default into `ask` unnoticed.
pub fn explicitly_classified_tools() -> HashSet<&'static str> {
    READ_TOOLS
        .iter()
        .chain(ADDITIVE_WRITE_TOOLS.iter())
        .chain(MUTATION_TOOLS.iter())
        .chain(DESTRUCTIVE_TOOLS.iter())
        .copied()
        .collect()
}

/// Merge the permission entries into `settings.json` additively. Creates the
/// file (and parents) when absent. Writes BOTH namespace prefixes for each
/// tool (see the module doc comment) — the identical "matches zero calls
/// through the other connection" defect that motivated `grant_tiered`'s
/// both-namespaces fix applies here too. Returns the number of entries
/// added (both namespaces combined).
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
    let list = aria_mcp::tool_list::build_tool_list();
    let names: Vec<String> = list
        .as_array()
        .map(|tools| {
            tools
                .iter()
                .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    for name in &names {
        for prefix in ALL_PREFIXES {
            let entry = format!("{prefix}{name}");
            if !existing.contains(&entry) {
                arr.push(serde_json::Value::String(entry));
                added += 1;
            }
        }
    }
    if added > 0 {
        write_settings(settings_path, &root)?;
    }
    Ok(added)
}

/// Default permission tier for a tool. Mirrors the Swift
/// `PermissionsWriter.classify` exactly — both verticals must place the
/// same tool in the same tier.
///
/// Exhaustive name-table based (Bob's re-tier ruling, 2026-07-04): verb
/// semantics cannot be inferred from a generic name pattern the way "ends
/// in _status" can, so the source of truth is `READ_TOOLS` /
/// `ADDITIVE_WRITE_TOOLS` / `MUTATION_TOOLS` / `DESTRUCTIVE_TOOLS`, not a
/// pattern match. A tool absent from all four tables (a brand-new addition
/// not yet triaged) still lands in `Ask`, the safe middle — but
/// `explicitly_classified_tools` lets a test catch that omission instead of
/// shipping it silently.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Tier {
    Allow,
    Ask,
    Deny,
}

pub fn classify(tool: &str) -> Tier {
    if DESTRUCTIVE_TOOLS.contains(&tool) {
        return Tier::Deny;
    }
    if MUTATION_TOOLS.contains(&tool) {
        return Tier::Ask;
    }
    if READ_TOOLS.contains(&tool) || ADDITIVE_WRITE_TOOLS.contains(&tool) {
        return Tier::Allow;
    }
    // Untriaged tool — safe middle; see explicitly_classified_tools.
    Tier::Ask
}

/// Merge every tool into its tier: `permissions.allow` / `.ask` / `.deny`
/// (the install DEFAULT). A tool the user already placed in ANY tier is
/// left exactly where it is. Writes BOTH namespace prefixes per tool — an
/// install that only ever wrote `PREFIX` gets its missing `PLUGIN_PREFIX`
/// twin backfilled here at `classify`'s CURRENT default tier, not copied
/// from whatever tier the `PREFIX` sibling happens to sit in. Returns
/// (allow, ask, deny) counts added (both namespaces combined).
pub fn grant_tiered(settings_path: &Path) -> Result<(usize, usize, usize), MergeError> {
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
    let perms = perms.as_object_mut().unwrap();
    for key in ["allow", "ask", "deny"] {
        let list = perms.entry(key).or_insert_with(|| serde_json::json!([]));
        if !list.is_array() {
            return Err(MergeError::MalformedConfig {
                path: settings_path.to_path_buf(),
                detail: format!(
                    "'permissions.{key}' exists but is not an array; refusing to overwrite it."
                ),
            });
        }
    }

    // The user's existing placement (any tier) wins over our default.
    let existing: std::collections::HashSet<String> = ["allow", "ask", "deny"]
        .iter()
        .flat_map(|k| perms[*k].as_array().unwrap().iter())
        .filter_map(|v| v.as_str().map(String::from))
        .collect();

    let list = aria_mcp::tool_list::build_tool_list();
    let names: Vec<String> = list
        .as_array()
        .map(|tools| {
            tools
                .iter()
                .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();

    let mut added = (0usize, 0usize, 0usize);
    for name in names {
        let tier = classify(&name);
        for prefix in ALL_PREFIXES {
            let entry = format!("{prefix}{name}");
            if existing.contains(&entry) {
                continue;
            }
            let (key, slot) = match tier {
                Tier::Allow => ("allow", &mut added.0),
                Tier::Ask => ("ask", &mut added.1),
                Tier::Deny => ("deny", &mut added.2),
            };
            perms[key]
                .as_array_mut()
                .unwrap()
                .push(serde_json::Value::String(entry));
            *slot += 1;
        }
    }

    if added != (0, 0, 0) {
        write_settings(settings_path, &root)?;
    }
    Ok(added)
}

/// Re-tier existing permission entries for OUR tools whose current tier no
/// longer matches `classify`'s current default — the migration pass that
/// lets an install from BEFORE a tiering change converge, instead of
/// fossilizing whatever tiering shipped at install time. `grant_tiered`
/// alone cannot do this: it only ADDS an entry when none of the three tiers
/// already contain it.
///
/// Two hard rules, both non-negotiable:
///   1. **Deny is sacred.** An entry already in `deny` is NEVER moved,
///      regardless of what `classify` says today.
///   2. **Foreign entries are untouched.** An entry for a tool NOT in the
///      live tool inventory is never inspected or moved — this loop only
///      ever builds candidate keys from tools `aria_mcp::tool_list::build_tool_list()`
///      returns, under our own two prefixes.
///
/// Never CREATES an entry that doesn't already exist in some tier — that
/// remains `grant_tiered`'s job. Callers should run this BEFORE
/// `grant_tiered` so the two passes compose. Returns the number of entries
/// moved into a different tier.
pub fn migrate_tiers(settings_path: &Path) -> Result<usize, MergeError> {
    let mut root = read_settings(settings_path)?;
    let Some(perms) = root.get("permissions").and_then(|p| p.as_object()) else {
        return Ok(0);
    };
    let mut lists: std::collections::HashMap<&'static str, Vec<String>> =
        std::collections::HashMap::new();
    for key in ["allow", "ask", "deny"] {
        let list = perms
            .get(key)
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_default();
        lists.insert(key, list);
    }

    // Reverse index: entry string -> the tier key currently holding it.
    let mut current_tier: std::collections::HashMap<String, &'static str> =
        std::collections::HashMap::new();
    for key in ["allow", "ask", "deny"] {
        for entry in &lists[key] {
            current_tier.entry(entry.clone()).or_insert(key);
        }
    }

    let list = aria_mcp::tool_list::build_tool_list();
    let names: Vec<String> = list
        .as_array()
        .map(|tools| {
            tools
                .iter()
                .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();

    let mut moved = 0;
    for name in &names {
        let target_key = match classify(name) {
            Tier::Allow => "allow",
            Tier::Ask => "ask",
            Tier::Deny => "deny",
        };
        for prefix in ALL_PREFIXES {
            let entry = format!("{prefix}{name}");
            let Some(&existing_key) = current_tier.get(&entry) else { continue }; // absent — grant_tiered's job
            if existing_key == "deny" {
                continue; // Rule 1: deny is sacred.
            }
            if existing_key == target_key {
                continue; // already correct.
            }
            lists.get_mut(existing_key).unwrap().retain(|e| e != &entry);
            lists.get_mut(target_key).unwrap().push(entry.clone());
            current_tier.insert(entry, target_key);
            moved += 1;
        }
    }

    if moved == 0 {
        return Ok(0);
    }
    let obj = root.as_object_mut().expect("root object");
    let perms = obj.get_mut("permissions").unwrap().as_object_mut().unwrap();
    for key in ["allow", "ask", "deny"] {
        perms.insert(
            key.to_string(),
            serde_json::Value::Array(
                lists[key].iter().cloned().map(serde_json::Value::String).collect(),
            ),
        );
    }
    write_settings(settings_path, &root)?;
    Ok(moved)
}

/// `true` if `settings_path` exists and already carries at least one
/// `PREFIX`/`PLUGIN_PREFIX` entry in any tier. Used to gate permission-
/// migration passes that should only ever CONVERGE an existing mootx01
/// Claude Code integration, never create one from nothing for a user who
/// never selected Claude Code as an install target.
pub fn has_any_moot_entries(settings_path: &Path) -> bool {
    let Ok(root) = read_settings(settings_path) else { return false };
    let Some(permissions) = root.get("permissions").and_then(|p| p.as_object()) else {
        return false;
    };
    for key in ["allow", "ask", "deny"] {
        let Some(list) = permissions.get(key).and_then(|v| v.as_array()) else { continue };
        if list
            .iter()
            .filter_map(|v| v.as_str())
            .any(|s| s.starts_with(PREFIX) || s.starts_with(PLUGIN_PREFIX))
        {
            return true;
        }
    }
    false
}

/// Remove every `mcp__mootx01__` AND `mcp__plugin_mootx01_mootx01__` entry
/// from `permissions.allow` / `.ask` / `.deny`. Prefix-based, so tools
/// renamed or removed since being granted are cleaned too, and both
/// namespaces so an uninstall does not strand the plugin-prefixed twin
/// entries `grant`/`grant_tiered` now write. Absent file is a no-op.
/// Returns the number removed.
pub fn revoke(settings_path: &Path) -> Result<usize, MergeError> {
    if !settings_path.exists() {
        return Ok(0);
    }
    let mut root = read_settings(settings_path)?;
    let mut removed = 0;
    for key in ["allow", "ask", "deny"] {
        if let Some(arr) = root
            .get_mut("permissions")
            .and_then(|p| p.get_mut(key))
            .and_then(|a| a.as_array_mut())
        {
            let before = arr.len();
            arr.retain(|v| {
                v.as_str()
                    .map(|s| !ALL_PREFIXES.iter().any(|p| s.starts_with(p)))
                    .unwrap_or(true)
            });
            removed += before - arr.len();
        }
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
    let lossy = String::from_utf8_lossy(&bytes);
    // Tolerate a leading UTF-8 BOM (e.g. a settings.json written by Windows
    // PowerShell 5.1's `Set-Content -Encoding UTF8`) — serde_json rejects it.
    let text = crate::core::merge::strip_bom(&lossy);
    if text.trim().is_empty() {
        return Ok(serde_json::json!({}));
    }
    match serde_json::from_str::<serde_json::Value>(text) {
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
    fn grant_tolerates_leading_utf8_bom() {
        // Regression: Windows PowerShell 5.1's `Set-Content -Encoding UTF8`
        // writes a UTF-8 BOM. serde_json rejected the resulting settings.json
        // as "not valid JSON", so `mootx01 install` refused to merge the
        // Claude Code permission allow-list. read_settings now strips the BOM.
        let dir = tmp("bom");
        let p = dir.join("settings.json");
        let mut bytes = vec![0xEF, 0xBB, 0xBF]; // UTF-8 BOM
        bytes.extend_from_slice(br#"{"permissions":{"allow":["Bash(ls:*)"]},"theme":"dark"}"#);
        std::fs::write(&p, &bytes).unwrap();

        let added = grant(&p).unwrap();
        assert!(added >= 50, "BOM'd settings must still merge, got {added}");
        // The rewrite drops the BOM, and the foreign data survives.
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(v["theme"], "dark");
        assert_eq!(v["permissions"]["allow"][0], "Bash(ls:*)");
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

    #[test]
    fn revoke_strips_both_namespace_prefixes() {
        let dir = tmp("revoke-both-ns");
        let p = dir.join("settings.json");
        grant_tiered(&p).unwrap();
        let removed = revoke(&p).unwrap();
        assert!(removed >= 100, "expected both-namespace entries removed, got {removed}");
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        for key in ["allow", "ask", "deny"] {
            let list = v["permissions"][key].as_array().cloned().unwrap_or_default();
            assert!(
                list.iter().all(|e| {
                    let s = e.as_str().unwrap();
                    !s.starts_with(PREFIX) && !s.starts_with(PLUGIN_PREFIX)
                }),
                "{key} must hold no entries of ours in either namespace"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    // MARK/NOTE: mirrors Swift PermissionsWriterTests.classifyTiers.
    #[test]
    fn classify_reads_and_additive_writes_allow_mutations_ask_destructive_deny() {
        assert_eq!(classify("moot_estate_ping"), Tier::Allow);
        assert_eq!(classify("moot_memory_search"), Tier::Allow, "a search is a read — must not ask");
        assert_eq!(classify("moot_memory_get"), Tier::Allow, "fetch-by-id is a read — must not ask");
        assert_eq!(classify("moot_lens_keystones"), Tier::Allow, "every lens is a read");
        assert_eq!(classify("moot_file_memory"), Tier::Allow);
        assert_eq!(classify("moot_file_fact"), Tier::Allow);
        assert_eq!(classify("moot_write_journal"), Tier::Allow);
        assert_eq!(classify("moot_link_memories"), Tier::Allow);

        assert_eq!(classify("moot_update_memory"), Tier::Ask);
        assert_eq!(classify("moot_withdraw_memory"), Tier::Ask, "withdraw is reversible — ask, not deny");
        assert_eq!(classify("moot_dream"), Tier::Ask);
        assert_eq!(classify("moot_reindex"), Tier::Ask);
        assert_eq!(classify("moot_palace_import"), Tier::Ask);
        assert_eq!(classify("moot_vault_import"), Tier::Ask);
        // ADR-025 wave 8.2: monitoring_status mutates daemon behaviour — ask tier.
        assert_eq!(classify("moot_monitoring_status"), Tier::Ask, "monitoring_status is mutating — ask tier");

        assert_eq!(classify("moot_erase_memory"), Tier::Deny);

        // Untriaged tool — safe middle.
        assert_eq!(classify("moot_future_tool"), Tier::Ask);
    }

    /// Priority coverage for the re-tier ruling: the tier table must be
    /// exhaustive over the REAL tool inventory (reachable live here, unlike
    /// the Swift side — this crate already depends on aria_mcp directly),
    /// so a future tool addition fails this test instead of silently
    /// landing in Ask unnoticed.
    #[test]
    fn classification_table_is_exhaustive_over_the_real_tool_inventory() {
        let list = aria_mcp::tool_list::build_tool_list();
        let real_tools: std::collections::HashSet<String> = list
            .as_array()
            .map(|tools| {
                tools
                    .iter()
                    .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
                    .map(String::from)
                    .collect()
            })
            .unwrap_or_default();
        assert!(!real_tools.is_empty(), "the live tool inventory must not be empty");

        let classified = explicitly_classified_tools();
        let untriaged: Vec<&String> = real_tools.iter().filter(|t| !classified.contains(t.as_str())).collect();
        assert!(untriaged.is_empty(), "real tool(s) with no explicit tier classification: {untriaged:?}");

        let stale: Vec<&&str> = classified.iter().filter(|c| !real_tools.contains(**c)).collect();
        assert!(stale.is_empty(), "classification table names tool(s) no longer in the real surface: {stale:?}");
    }

    #[test]
    fn grant_tiered_writes_both_namespace_prefixes() {
        let dir = tmp("grant-tiered-both-ns");
        let p = dir.join("settings.json");
        let (a, k, d) = grant_tiered(&p).unwrap();
        assert!(a > 0 && k > 0 && d > 0);
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        let allow: Vec<&str> = v["permissions"]["allow"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e.as_str().unwrap())
            .collect();
        let deny: Vec<&str> = v["permissions"]["deny"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e.as_str().unwrap())
            .collect();
        assert!(allow.contains(&"mcp__mootx01__moot_memory_search"));
        assert!(allow.contains(&"mcp__plugin_mootx01_mootx01__moot_memory_search"));
        assert!(deny.contains(&"mcp__mootx01__moot_erase_memory"));
        assert!(deny.contains(&"mcp__plugin_mootx01_mootx01__moot_erase_memory"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn migrate_tiers_converges_an_old_all_ask_tiered_fixture() {
        let dir = tmp("migrate-converge");
        let p = dir.join("settings.json");
        // Simulate the PRE re-tier default: reads fossilized in ask.
        std::fs::write(
            &p,
            serde_json::to_string_pretty(&serde_json::json!({
                "permissions": {
                    "allow": ["mcp__mootx01__moot_estate_ping", "mcp__plugin_mootx01_mootx01__moot_estate_ping"],
                    "ask": [
                        "mcp__mootx01__moot_memory_search", "mcp__plugin_mootx01_mootx01__moot_memory_search",
                        "mcp__mootx01__moot_withdraw_memory", "mcp__plugin_mootx01_mootx01__moot_withdraw_memory",
                    ],
                    "deny": ["mcp__mootx01__moot_erase_memory", "mcp__plugin_mootx01_mootx01__moot_erase_memory"],
                }
            }))
            .unwrap(),
        )
        .unwrap();

        let moved = migrate_tiers(&p).unwrap();
        assert_eq!(moved, 2, "moot_memory_search moves ask->allow in both namespaces");

        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        let allow: Vec<String> = v["permissions"]["allow"]
            .as_array().unwrap().iter().map(|e| e.as_str().unwrap().to_string()).collect();
        let ask: Vec<String> = v["permissions"]["ask"]
            .as_array().unwrap().iter().map(|e| e.as_str().unwrap().to_string()).collect();
        assert!(allow.contains(&"mcp__mootx01__moot_memory_search".to_string()));
        assert!(allow.contains(&"mcp__plugin_mootx01_mootx01__moot_memory_search".to_string()));
        assert!(!ask.contains(&"mcp__mootx01__moot_memory_search".to_string()));
        assert!(ask.contains(&"mcp__mootx01__moot_withdraw_memory".to_string()), "a genuine mutation must stay in ask");

        // Idempotent.
        assert_eq!(migrate_tiers(&p).unwrap(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn migrate_tiers_never_moves_an_entry_the_user_placed_in_deny() {
        let dir = tmp("migrate-deny-sacred");
        let p = dir.join("settings.json");
        std::fs::write(
            &p,
            br#"{"permissions":{"deny":["mcp__mootx01__moot_memory_search"]}}"#,
        )
        .unwrap();

        let moved = migrate_tiers(&p).unwrap();
        assert_eq!(moved, 0, "an entry already in deny must never be migrated");
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        let deny: Vec<&str> = v["permissions"]["deny"].as_array().unwrap().iter().map(|e| e.as_str().unwrap()).collect();
        assert!(deny.contains(&"mcp__mootx01__moot_memory_search"), "user's explicit deny must survive migration");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn migrate_tiers_never_touches_a_foreign_entry() {
        let dir = tmp("migrate-foreign");
        let p = dir.join("settings.json");
        std::fs::write(
            &p,
            serde_json::to_string_pretty(&serde_json::json!({
                "permissions": {
                    "allow": ["Bash(ls:*)", "mcp__other_server__some_tool"],
                    "ask": ["mcp__mootx01__moot_memory_search"],
                }
            }))
            .unwrap(),
        )
        .unwrap();

        let moved = migrate_tiers(&p).unwrap();
        assert_eq!(moved, 1, "only our own stale-tiered entry moves");
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        let allow: Vec<&str> = v["permissions"]["allow"].as_array().unwrap().iter().map(|e| e.as_str().unwrap()).collect();
        assert!(allow.contains(&"Bash(ls:*)"));
        assert!(allow.contains(&"mcp__other_server__some_tool"));
        assert!(allow.contains(&"mcp__mootx01__moot_memory_search"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn migrate_tiers_does_not_create_settings_file_when_nothing_moves() {
        let dir = tmp("migrate-no-create");
        let p = dir.join("settings.json");
        let moved = migrate_tiers(&p).unwrap();
        assert_eq!(moved, 0);
        assert!(!p.exists(), "migrate_tiers must not create settings.json when there is nothing to move");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn has_any_moot_entries_false_then_true() {
        let dir = tmp("has-any");
        let p = dir.join("settings.json");
        assert!(!has_any_moot_entries(&p), "absent file");

        std::fs::write(&p, br#"{"permissions":{"allow":["Bash(ls:*)"]}}"#).unwrap();
        assert!(!has_any_moot_entries(&p), "foreign-only file");

        std::fs::write(&p, br#"{"permissions":{"deny":["mcp__plugin_mootx01_mootx01__moot_erase_memory"]}}"#).unwrap();
        assert!(has_any_moot_entries(&p), "plugin-namespace entry must count");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
