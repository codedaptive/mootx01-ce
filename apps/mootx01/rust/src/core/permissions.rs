//! core/permissions.rs — Claude Code `permissions.allow`/`.ask`/`.deny` writer.
//!
//! Ported from Swift PermissionsWriter.swift (AIRA-INSTALL-P3 finding): the
//! settings key is `permissions.allow` (nested under a `permissions`
//! object), NOT top-level `allowedTools`. Entries take the MCP-prefixed
//! form `mcp__mootx01__<tool_name>` for the direct connection, and
//! `mcp__plugin_mootx01_memory__<tool_name>` for calls routed through the
//! installed plugin (Claude Code plugin mode, v1.1.0+: the plugin registers
//! its server under the key `"memory"`, giving the concrete prefix
//! `mcp__plugin_mootx01_memory__`). A rule written for only one namespace
//! matches zero calls made through the other connection — every tier write
//! in this file covers BOTH.
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

use std::collections::{HashMap, HashSet};
use std::path::Path;

use crate::core::merge::MergeError;

const PREFIX: &str = "mcp__mootx01__";

/// The MCP tool prefix Claude Code uses for calls routed through the
/// installed plugin (v1.1.0+: the plugin registers its server under the key
/// `"memory"`, so the prefix is `mcp__plugin_mootx01_memory__`).
const PLUGIN_PREFIX: &str = "mcp__plugin_mootx01_memory__";

/// Pre-v1.1.0 plugin prefix. The plugin registered its server under `"mootx01"`
/// before this release, giving `mcp__plugin_mootx01_mootx01__`. Kept ONLY in
/// the revoke list so `revoke` migrates away existing allow/deny entries on
/// upgrade; never written by grant paths.
const LEGACY_PLUGIN_PREFIX: &str = "mcp__plugin_mootx01_mootx01__";

/// Every namespace prefix a tool name must be written under.
const ALL_PREFIXES: [&str; 2] = [PREFIX, PLUGIN_PREFIX];

/// Tool names retired from the installer authorization inventory. This is a
/// defensive floor applied to whatever tool list is built from the linked server.
/// The linked projection does not carry a retired name today; the filter guards
/// against a future regression where a retired name re-enters the projection by
/// mistake. Mirrors Swift `PermissionsWriter.retiredToolNames`.
const RETIRED_TOOL_NAMES: &[&str] = &[
    "moot_file_packet",
    "moot_packet_get",
    "moot_packet_list",
    "moot_packet_lineage",
];

/// Single predicate: returns true for any name that is not in RETIRED_TOOL_NAMES.
/// Both adapters below call this so the rule lives in one place.
fn is_authorized_name(name: &str) -> bool {
    !RETIRED_TOOL_NAMES.contains(&name)
}

/// Filter `names` to those not in `RETIRED_TOOL_NAMES`. Borrowed form for tests.
fn authorized_names<'a>(names: &[&'a str]) -> Vec<&'a str> {
    names
        .iter()
        .copied()
        .filter(|n| is_authorized_name(n))
        .collect()
}

/// Filter `names` to those not in `RETIRED_TOOL_NAMES`. Owned form used by
/// grant, grant_tiered, and migrate_tiers so the filter is applied uniformly
/// on every path, matching Swift's three-site coverage of authorizedToolNames.
fn authorized_names_owned(names: Vec<String>) -> Vec<String> {
    names
        .into_iter()
        .filter(|n| is_authorized_name(n.as_str()))
        .collect()
}

/// `mcp__mootx01__<name>` for every authorized tool the linked server exposes
/// (direct namespace only — used by `grant`, the allow-all opt-in). Retired
/// tool names are filtered out as a defensive floor; the linked projection does
/// not carry them today, but the filter guards against future regressions.
pub fn permission_entries() -> Vec<String> {
    let list = aria_mcp::tool_list::build_tool_list();
    list.as_array()
        .map(|tools| {
            let names: Vec<&str> = tools
                .iter()
                .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
                .collect();
            authorized_names(&names)
                .iter()
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
    // Rebuild OPERATIONS are mutating; this is the read-only progress poll
    // for them (same split as moot_drain_status over the drain workers).
    "moot_rebuild_status",
    // C3/A6: audit-derived timing metrics — pure audit-log read.
    "moot_timing_report",
    "moot_list_lenses", "moot_list_recipes",
    // Grounded synthesis reads candidates and generates text; it writes no
    // drawer, packet, journal, meta, trace or reward (FRZ-3 read set).
    "moot_synthesize",
    "moot_vault_status", "moot_vault_job",
    "moot_memory_search", "moot_memory_get", "moot_memory_list",
    "moot_recall_precise", "moot_recall_connected", "moot_recall_shaped", "moot_recall_distilled",
    "moot_recall_vague",
    // Walk (breadth-first traversal) and temporal (time-ordered recall) are
    // pure read operations — no estate content is created, changed, or removed.
    // Added here when aria-mcp shipped the two new recall endpoints; mirrors
    // the Swift PermissionsWriter.readTools parity requirement.
    "moot_recall_walk", "moot_recall_temporal",
    "moot_fact_search", "moot_fact_timeline",
    "moot_connection_search", "moot_connection_map",
    "moot_estate_map", "moot_read_journal",
    // Grant-authorized federated read.
    "moot_federated_recall",
    // Surface help: capability discovery, always a pure read.
    "moot_help",
    // Transcript recall: reads session transcript, no estate writes.
    "moot_memory_recall_transcript",
    // Similar recall: nearest drawers by whole-record vector, no estate writes.
    "moot_recall_similar",
    // Monitoring inspection: reads daemon telemetry state without changing it.
    "moot_monitoring_status",
    // Migration candidate evaluation (read-only, does not commit).
    "moot_migration_run",
    // Dataset reads (MX-TAB-7): query rows / column stats are read-only.
    "moot_dataset_query", "moot_dataset_stats",
    "moot_lens_anticipate", "moot_lens_apriori", "moot_lens_associations", "moot_lens_bias",
    "moot_lens_cohesion", "moot_lens_complexity", "moot_lens_concepts", "moot_lens_constellation",
    "moot_lens_contradiction", "moot_lens_divergence", "moot_lens_drift", "moot_lens_free_association",
    "moot_lens_keystones", "moot_lens_latent_themes", "moot_lens_moment", "moot_lens_node_motion",
    "moot_lens_overlap", "moot_lens_partial_cue", "moot_lens_precedence", "moot_lens_rhythm",
    "moot_lens_successors", "moot_lens_theme_weather", "moot_lens_trust_synthesis",
];

/// The additive-write, mutation and destructive tables live in aria-mcp
/// (`tool_mutation_inventory`), the crate that owns the tool surface: the
/// tiered installer default here and the frozen serve posture in the
/// dispatcher read the same tables, so a new mutating tool is triaged once.
/// Only the read table is installer-local.
///
/// The allow tier holds `moot_file_memory` without a confirmation prompt
/// because the server, not the host, enforces the sensitivity tier: a memory
/// filed while a restricted or secret grant is live takes the grant's tier
/// when the caller names none and refuses a lower one, so no prompt is
/// needed to stop a handoff downgrading granted material.
use aria_mcp::tool_mutation_inventory::{ADDITIVE_WRITE_TOOLS, DESTRUCTIVE_TOOLS, MUTATION_TOOLS};

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
    let raw_names: Vec<String> = list
        .as_array()
        .map(|tools| {
            tools
                .iter()
                .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    // Defensive floor: retired tool names must not be granted even if the
    // linked projection somehow re-introduces them (mirrors Swift's
    // authorizedToolNames call in permissionEntries).
    let names = authorized_names_owned(raw_names);
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
///
/// The variant order is deliberate and load-bearing: it ascends by how much
/// the tier RESTRICTS, so the derived `Ord` gives `Allow < Ask < Deny` and
/// `grant_tiered` can resolve a disagreement between a tool's two namespace
/// entries with `.max()` — most restrictive wins. Reordering the variants
/// would silently invert that rule.
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Clone, Copy)]
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
/// left exactly where it is — this function only ever ADDS, never moves an
/// entry that already exists. Writes BOTH namespace prefixes per tool.
///
/// **A placement under either namespace binds its twin.** `PREFIX` and
/// `PLUGIN_PREFIX` are two addresses for one capability, not two
/// capabilities. So an install that only ever wrote `PREFIX` gets its
/// missing `PLUGIN_PREFIX` twin added at the SIBLING'S tier, not at
/// `classify`'s default. Where the two namespaces disagree, the MOST
/// RESTRICTIVE tier found wins for the newly added entry only:
/// `Deny` > `Ask` > `Allow`. Only when neither namespace carries the tool
/// at all does `classify` decide.
///
/// Backfilling at the classifier default instead would bypass a user's
/// `deny`: someone who denies `mcp__mootx01__moot_memory_get` would get
/// `mcp__plugin_mootx01_memory__moot_memory_get` added to `allow` on the
/// next install or upgrade, because that exact string is "genuinely
/// absent". A user cannot place an entry for a namespace they have never
/// seen.
///
/// The sibling's tier is read from the settings file as it stands on
/// entry, which at every production call site is AFTER `migrate_tiers` has
/// run (`commands::install` and `commands::upgrade` run the two passes in
/// that order, as do the Swift twins), so inheritance reads a tier that
/// has already converged on the current default. The lookup is computed
/// once per tool, before either namespace entry is pushed, so the order in
/// which this run writes the two prefixes cannot change the result.
///
/// Mirrors Swift `PermissionsWriter.mergeTiered` (Swift leads), including
/// the conflict rule. Returns (allow, ask, deny) counts added (both
/// namespaces combined).
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

    // The user's existing placement (any tier) wins over our default — and
    // WHERE each existing entry sits is load-bearing, not merely whether it
    // exists, because an absent entry inherits its twin's tier. An entry
    // cannot legitimately appear in more than one tier (this function never
    // duplicates); if it somehow does, the first tier found wins, matching
    // `migrate_tiers`' reverse index.
    let mut existing_tier: HashMap<String, Tier> = HashMap::new();
    for (tier, key) in [(Tier::Allow, "allow"), (Tier::Ask, "ask"), (Tier::Deny, "deny")] {
        for v in perms[key].as_array().unwrap() {
            if let Some(s) = v.as_str() {
                existing_tier.entry(s.to_string()).or_insert(tier);
            }
        }
    }

    let list = aria_mcp::tool_list::build_tool_list();
    let raw_names: Vec<String> = list
        .as_array()
        .map(|tools| {
            tools
                .iter()
                .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    // Defensive floor: mirrors Swift authorizedToolNames in mergeTiered.
    let names = authorized_names_owned(raw_names);

    let mut added = (0usize, 0usize, 0usize);
    for name in names {
        // Computed from the pre-existing state, once per tool and before
        // either entry is pushed. Scanning every prefix rather than only
        // "the other one" is equivalent here and stays correct if a third
        // namespace is ever added: a prefix whose entry is absent
        // contributes nothing, and one whose entry is present is exactly a
        // sibling to inherit from. `max()` is most-restrictive-wins — see
        // `Tier`'s variant-order note.
        let inherited = ALL_PREFIXES
            .iter()
            .filter_map(|p| existing_tier.get(&format!("{p}{name}")).copied())
            .max();
        let tier = inherited.unwrap_or_else(|| classify(&name));
        for prefix in ALL_PREFIXES {
            let entry = format!("{prefix}{name}");
            if existing_tier.contains_key(&entry) {
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
    let raw_names: Vec<String> = list
        .as_array()
        .map(|tools| {
            tools
                .iter()
                .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    // Defensive floor: mirrors Swift authorizedToolNames in migrateTiers.
    let names = authorized_names_owned(raw_names);

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
            // Rule 2 (ask convergence): an entry sitting at ask converges
            // onto the shipped tier. This loosens ask→allow ONLY for
            // allow-class tools (reads + additive writes) — the class an old
            // default fossilized at ask, which made moot unusable from
            // permission prompts. A user-set ask on a mutation/destructive
            // tool is never loosened by construction: those classify as ask
            // (or deny), so convergence is a no-op or a tightening for them.
            // Mirrors Swift PermissionsWriter.migrateTiers (Swift leads).
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

/// Remove every `mcp__mootx01__`, `mcp__plugin_mootx01_memory__`, and
/// `mcp__plugin_mootx01_mootx01__` (pre-v1.1.0 plugin prefix) entry from
/// `permissions.allow` / `.ask` / `.deny`. Prefix-based, so tools renamed or
/// removed since being granted are cleaned too. The legacy prefix is stripped
/// here so an upgrade on a machine installed before v1.1.0 migrates away
/// existing allow/deny entries rather than stranding them. Absent file is a
/// no-op. Returns the number removed.
pub fn revoke(settings_path: &Path) -> Result<usize, MergeError> {
    if !settings_path.exists() {
        return Ok(0);
    }
    let mut root = read_settings(settings_path)?;
    let mut removed = 0;
    // All prefixes to strip: current direct, current plugin, and the pre-v1.1.0
    // plugin prefix for migration (LEGACY_PLUGIN_PREFIX).
    let revoke_prefixes = [PREFIX, PLUGIN_PREFIX, LEGACY_PLUGIN_PREFIX];
    for key in ["allow", "ask", "deny"] {
        if let Some(arr) = root
            .get_mut("permissions")
            .and_then(|p| p.get_mut(key))
            .and_then(|a| a.as_array_mut())
        {
            let before = arr.len();
            arr.retain(|v| {
                v.as_str()
                    .map(|s| !revoke_prefixes.iter().any(|p| s.starts_with(p)))
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

    // ------------------------------------------------------------------
    // Finding F: retired names are filtered (mirrors Swift retiredToolNames)
    // ------------------------------------------------------------------

    #[test]
    fn authorized_names_filters_retired_and_keeps_ordinary() {
        // A retired name fed to authorized_names must not appear in the output,
        // while an ordinary name in the same call must survive. Both halves are
        // asserted so the test cannot pass by returning an empty list.
        let retired = "moot_file_packet";
        let ordinary = "moot_memory_get";
        let result = authorized_names(&[retired, ordinary]);
        assert!(
            !result.contains(&retired),
            "retired name {retired} must be filtered by authorized_names"
        );
        assert!(
            result.contains(&ordinary),
            "ordinary name {ordinary} must be kept by authorized_names"
        );
    }

    #[test]
    fn permission_entries_does_not_contain_retired_names() {
        // Absence check over the live projection: the shipped permission set
        // must name no retired operation under any prefix. This is not a gate
        // on the filter itself — it asserts the end state, not the mechanism.
        // The test that gates the filter (retired-name-in / absent-out) is
        // `authorized_names_owned_filters_retired_and_keeps_ordinary`.
        let entries = permission_entries();
        for retired in RETIRED_TOOL_NAMES {
            for prefix in ALL_PREFIXES {
                let banned = format!("{prefix}{retired}");
                assert!(
                    !entries.contains(&banned),
                    "permission_entries must not emit retired tool {retired} under {prefix}"
                );
            }
        }
    }

    // ------------------------------------------------------------------
    // Finding G: retired names filtered on the tiered-writer paths
    // ------------------------------------------------------------------

    #[test]
    fn grant_tiered_does_not_emit_retired_names() {
        // Absence check over the tiered-write output: grant_tiered (the default
        // install path, mirroring Swift mergeTiered) must not emit any retired
        // name in any tier under either prefix. This is not a gate on the filter
        // itself — it asserts the end state of the live projection, not the
        // mechanism. The test that gates the filter (retired-name-in / absent-out)
        // is `authorized_names_owned_filters_retired_and_keeps_ordinary`.
        //
        // grant_tiered is the default install path (mirrors Swift mergeTiered).
        // Its output must not contain any retired name under either prefix,
        // while ordinary names still land in their classifier-assigned tiers.
        let dir = tmp("grant-tiered-retired");
        let p = dir.join("settings.json");
        grant_tiered(&p).unwrap();

        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        for tier_key in ["allow", "ask", "deny"] {
            let list = v["permissions"][tier_key].as_array().cloned().unwrap_or_default();
            for retired in RETIRED_TOOL_NAMES {
                for prefix in ALL_PREFIXES {
                    let banned = format!("{prefix}{retired}");
                    assert!(
                        !list.contains(&serde_json::Value::String(banned.clone())),
                        "grant_tiered must not emit {banned} in {tier_key}"
                    );
                }
            }
        }
        // Ordinary name must still land somewhere.
        let ordinary = "moot_memory_get";
        let all_entries: Vec<String> = ["allow", "ask", "deny"]
            .iter()
            .flat_map(|k| {
                v["permissions"][k]
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|e| e.as_str().map(String::from))
            })
            .collect();
        assert!(
            all_entries.iter().any(|e| e.contains(ordinary)),
            "ordinary tool {ordinary} must appear in some tier after grant_tiered"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn migrate_tiers_does_not_write_retired_names() {
        // migrate_tiers is the upgrade path (mirrors Swift migrateTiers).
        // It must not ADD any retired name to any tier. Seed an ordinary tool
        // in ask (the old all-ask default) so the function has real work to do;
        // verify the retired name never appears in the output while the ordinary
        // name is present in some tier after migration.
        //
        // Note: migrate_tiers calls authorized_names_owned, not authorized_names.
        // This test is an absence check on a name that is never seeded — it
        // confirms the function does not invent entries from build_tool_list()
        // for retired names. The discriminating unit test for authorized_names_owned
        // (retired-in/absent-out, ordinary-in/present-out) is
        // `authorized_names_owned_filters_retired_and_keeps_ordinary` below.
        let dir = tmp("migrate-tiers-retired");
        let p = dir.join("settings.json");
        let retired = "moot_file_packet";
        let ordinary = "moot_memory_get";
        // Seed with the ordinary tool fossilised in ask (old default) and no
        // retired entries — the function processes names from build_tool_list(),
        // so a retired name absent from the settings file is never added.
        let seed = serde_json::json!({
            "permissions": {
                "ask": [
                    format!("{PREFIX}{ordinary}"),
                    format!("{PLUGIN_PREFIX}{ordinary}"),
                ]
            }
        });
        std::fs::write(&p, serde_json::to_string(&seed).unwrap()).unwrap();

        migrate_tiers(&p).unwrap();

        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        let all_entries: Vec<String> = ["allow", "ask", "deny"]
            .iter()
            .flat_map(|k| {
                v["permissions"][k]
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|e| e.as_str().map(String::from))
            })
            .collect();

        // Ordinary name must be present in some tier after migration (presence
        // check; the specific tier is not asserted here).
        assert!(
            all_entries.iter().any(|e| e.contains(ordinary)),
            "ordinary tool {ordinary} must be present after migrate_tiers"
        );
        // Retired name must not have been added to any tier under any prefix
        // (absence check against a name that was never seeded).
        for prefix in ALL_PREFIXES {
            let banned = format!("{prefix}{retired}");
            assert!(
                !all_entries.contains(&banned),
                "retired tool {retired} must not appear in any tier under {prefix} after migrate_tiers"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn authorized_names_owned_filters_retired_and_keeps_ordinary() {
        // authorized_names_owned is the owned adapter called by grant,
        // grant_tiered, and migrate_tiers. It must apply the same rule as
        // authorized_names (the borrowed adapter). Both halves are asserted so
        // the test cannot pass by returning an empty list.
        let retired = "moot_file_packet".to_string();
        let ordinary = "moot_memory_get".to_string();
        let result = authorized_names_owned(vec![retired.clone(), ordinary.clone()]);
        assert!(
            !result.contains(&retired),
            "retired name {retired} must be filtered by authorized_names_owned"
        );
        assert!(
            result.contains(&ordinary),
            "ordinary name {ordinary} must be kept by authorized_names_owned"
        );
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
        assert_eq!(classify("moot_json_import"), Tier::Ask);
        assert_eq!(classify("moot_vault_import"), Tier::Ask);
        // moot_monitoring_status is inspection-only in v2 — pure read, no estate writes.
        assert_eq!(classify("moot_monitoring_status"), Tier::Allow, "inspection-only in v2 — pure read, no estate writes");

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

        let stale: Vec<&&str> = classified
            .iter()
            .filter(|c| !real_tools.contains(**c))
            .collect();
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
        assert!(allow.contains(&"mcp__plugin_mootx01_memory__moot_memory_search"));
        assert!(deny.contains(&"mcp__mootx01__moot_erase_memory"));
        assert!(deny.contains(&"mcp__plugin_mootx01_memory__moot_erase_memory"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------
    // A placement under either namespace binds its twin.
    //
    // Codex finding 2d36552ac03c8191867d26bb6ae32376: matching entries by
    // exact string and backfilling each prefix independently would let a
    // user who denies a tool under the namespace they can see get the other
    // namespace's twin added to `allow` on the next install or upgrade.
    // These pin the rule that prevents it, mirroring the Swift suite case for case
    // (Swift leads). `moot_memory_search` is the subject throughout: it is
    // a real tool on the live surface and classifies `Allow`, so a user
    // `deny` on it is maximally visible if inheritance fails.
    // -----------------------------------------------------------------

    const DIRECT_SEARCH: &str = "mcp__mootx01__moot_memory_search";
    const PLUGIN_SEARCH: &str = "mcp__plugin_mootx01_memory__moot_memory_search";

    /// Seed a settings.json with `seed`, run `grant_tiered`, and return the
    /// three resulting tier lists. Every inheritance test has the same
    /// shape — place one entry by hand, merge, inspect where the twin
    /// landed — so the plumbing lives here rather than six times over.
    fn seed_and_grant(tag: &str, seed: serde_json::Value) -> (Vec<String>, Vec<String>, Vec<String>) {
        let dir = tmp(tag);
        let p = dir.join("settings.json");
        std::fs::write(&p, serde_json::to_string_pretty(&seed).unwrap()).unwrap();
        grant_tiered(&p).unwrap();
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        let list = |k: &str| -> Vec<String> {
            v["permissions"][k]
                .as_array()
                .map(|a| a.iter().filter_map(|e| e.as_str().map(String::from)).collect())
                .unwrap_or_default()
        };
        let out = (list("allow"), list("ask"), list("deny"));
        let _ = std::fs::remove_dir_all(&dir);
        out
    }

    #[test]
    fn grant_tiered_deny_under_direct_namespace_binds_absent_plugin_twin() {
        // The user denied the tool under the only namespace they have ever
        // seen. Backfilling the plugin twin at the classifier default would
        // put the SAME capability in `allow` — the bypass under test.
        let (allow, _ask, deny) = seed_and_grant(
            "grant-tiered-deny-binds-twin",
            serde_json::json!({ "permissions": { "deny": [DIRECT_SEARCH] } }),
        );
        assert!(
            deny.iter().any(|e| e == DIRECT_SEARCH),
            "the user's deny must survive untouched"
        );
        assert!(
            deny.iter().any(|e| e == PLUGIN_SEARCH),
            "the absent plugin twin must inherit deny — a user cannot place an entry for a namespace they have never seen"
        );
        assert!(
            !allow.iter().any(|e| e == PLUGIN_SEARCH),
            "the denied capability must not reappear in allow under the sibling namespace"
        );
    }

    #[test]
    fn grant_tiered_ask_under_direct_namespace_binds_absent_plugin_twin() {
        // Same shape, one tier looser: an `ask` the user set is still a
        // decision about the capability, not about a string.
        let (allow, ask, _deny) = seed_and_grant(
            "grant-tiered-ask-binds-twin",
            serde_json::json!({ "permissions": { "ask": [DIRECT_SEARCH] } }),
        );
        assert!(ask.iter().any(|e| e == DIRECT_SEARCH), "the user's ask must survive untouched");
        assert!(ask.iter().any(|e| e == PLUGIN_SEARCH), "the absent plugin twin must inherit ask");
        assert!(
            !allow.iter().any(|e| e == PLUGIN_SEARCH),
            "must not take classify's allow default"
        );
    }

    #[test]
    fn grant_tiered_plugin_deny_binds_absent_direct_twin() {
        // The mirror image. Neither prefix is privileged — whichever one
        // carries the user's decision is the one the other inherits from.
        let (allow, _ask, deny) = seed_and_grant(
            "grant-tiered-plugin-deny-binds-twin",
            serde_json::json!({ "permissions": { "deny": [PLUGIN_SEARCH] } }),
        );
        assert!(deny.iter().any(|e| e == PLUGIN_SEARCH), "the user's deny must survive untouched");
        assert!(deny.iter().any(|e| e == DIRECT_SEARCH), "the absent direct twin must inherit deny");
        assert!(
            !allow.iter().any(|e| e == DIRECT_SEARCH),
            "must not take classify's allow default"
        );
    }

    #[test]
    fn grant_tiered_never_moves_disagreeing_siblings() {
        // One namespace allowed, the other denied. With both entries present
        // there is nothing left to add for this tool, so the observable
        // guarantee is that grant_tiered MOVES NEITHER — inheritance decides
        // the tier of new entries only and is never a licence to re-tier an
        // existing one (that is migrate_tiers' job, and deny is sacred
        // there). The most-restrictive tie-break itself is unreachable while
        // there are exactly two namespaces: a disagreement implies both
        // entries exist, so no entry is added to apply it to. It is
        // defensive, and becomes observable only if a third prefix is added.
        let (allow, ask, deny) = seed_and_grant(
            "grant-tiered-disagreeing-siblings",
            serde_json::json!({
                "permissions": { "allow": [DIRECT_SEARCH], "deny": [PLUGIN_SEARCH] }
            }),
        );
        assert!(allow.iter().any(|e| e == DIRECT_SEARCH), "the user's allow must stay put");
        assert!(deny.iter().any(|e| e == PLUGIN_SEARCH), "the user's deny must stay put");
        assert!(
            !deny.iter().any(|e| e == DIRECT_SEARCH),
            "the allowed entry must not be duplicated into deny"
        );
        assert!(
            !allow.iter().any(|e| e == PLUGIN_SEARCH),
            "the denied entry must not be duplicated into allow"
        );
        assert!(!ask.iter().any(|e| e == DIRECT_SEARCH || e == PLUGIN_SEARCH));
    }

    #[test]
    fn grant_tiered_falls_back_to_classify_when_no_sibling_exists() {
        // The unchanged path: inheritance only fires when a sibling exists.
        // A settings file carrying an unrelated tool must not perturb how
        // any other tool is tiered.
        let (allow, ask, deny) = seed_and_grant(
            "grant-tiered-no-sibling",
            serde_json::json!({ "permissions": { "deny": ["mcp__mootx01__moot_estate_ping"] } }),
        );
        for prefix in ALL_PREFIXES {
            assert!(
                deny.iter().any(|e| e == &format!("{prefix}moot_erase_memory")),
                "destructive default unchanged under {prefix}"
            );
            assert!(
                ask.iter().any(|e| e == &format!("{prefix}moot_withdraw_memory")),
                "mutation default unchanged under {prefix}"
            );
            assert!(
                allow.iter().any(|e| e == &format!("{prefix}moot_memory_search")),
                "read default unchanged under {prefix}"
            );
        }
        // The unrelated tool's own inheritance still applies to ITS twin.
        assert!(deny.iter().any(|e| e == "mcp__plugin_mootx01_memory__moot_estate_ping"));
    }

    #[test]
    fn grant_tiered_inheritance_is_idempotent() {
        let dir = tmp("grant-tiered-inherit-idempotent");
        let p = dir.join("settings.json");
        std::fs::write(
            &p,
            serde_json::to_string_pretty(
                &serde_json::json!({ "permissions": { "deny": [DIRECT_SEARCH] } }),
            )
            .unwrap(),
        )
        .unwrap();

        grant_tiered(&p).unwrap();
        let first = std::fs::read_to_string(&p).unwrap();

        let second_added = grant_tiered(&p).unwrap();
        assert_eq!(second_added, (0, 0, 0), "a second run must add nothing");
        assert_eq!(
            first,
            std::fs::read_to_string(&p).unwrap(),
            "settings.json must be byte-identical across runs"
        );
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
                    "allow": ["mcp__mootx01__moot_estate_ping", "mcp__plugin_mootx01_memory__moot_estate_ping"],
                    "ask": [
                        "mcp__mootx01__moot_memory_search", "mcp__plugin_mootx01_memory__moot_memory_search",
                        "mcp__mootx01__moot_withdraw_memory", "mcp__plugin_mootx01_memory__moot_withdraw_memory",
                    ],
                    "deny": ["mcp__mootx01__moot_erase_memory", "mcp__plugin_mootx01_memory__moot_erase_memory"],
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
        assert!(allow.contains(&"mcp__plugin_mootx01_memory__moot_memory_search".to_string()));
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

        std::fs::write(&p, br#"{"permissions":{"deny":["mcp__plugin_mootx01_memory__moot_erase_memory"]}}"#).unwrap();
        assert!(has_any_moot_entries(&p), "plugin-namespace entry must count");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
