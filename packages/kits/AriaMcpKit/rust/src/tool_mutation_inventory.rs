//! tool_mutation_inventory.rs — the tools that change an estate.
//!
//! One inventory, two readers: the installer's tiered permission default
//! (mootx01-cli `core::permissions`) places these tools in the Ask / Deny
//! tiers, and a frozen `Dispatcher` refuses them. Keeping the tables here, in
//! the crate that owns the tool surface, means a new mutating tool is triaged
//! once and both readers see it.
//!
//! Read tools are not listed: the installer keeps its own read table (Allow
//! tier), and a frozen dispatcher lets every tool outside these tables through.
//!
//! Swift twin: packages/kits/AriaMcpKit/Sources/AriaMCP/ToolMutationInventory.swift.

/// Additive-unconfirmed writes: create NEW content; nothing already
/// committed is changed, moved, or removed. Same risk class as a read from
/// the user's perspective — undoable by withdrawing/retiring the new row,
/// never a mutation of prior state.
pub const ADDITIVE_WRITE_TOOLS: &[&str] =
    &["moot_file_memory", "moot_file_fact", "moot_write_journal", "moot_link_memories"];

/// Mutations of existing state: something already committed changes shape,
/// is superseded, moves, or a background process alters estate-wide
/// indexes/consolidation state. The installer prompts for these (Ask tier).
pub const MUTATION_TOOLS: &[&str] = &[
    "moot_update_memory", "moot_move_memory", "moot_withdraw_memory", "moot_confirm_memory",
    "moot_retire_fact", "moot_confirm_migration", "moot_run_migration",
    "moot_reindex", "moot_reclassify_fdc", "moot_dream", "moot_distill", "moot_synthesize",
    // Force-redistill all active items + full lane-scope reindex: overwrites
    // every active non-empty drawer's representation unconditionally and
    // rebuilds BM25 + dense indexes. Ask posture: same as moot_distill.
    "moot_redistill",
    "moot_palace_import", "moot_vault_import", "moot_vault_export", "moot_vault_reconcile",
    // Seed-file JSON import: reads a seed file from the filesystem and
    // bulk-writes the estate — same Ask posture as palace/vault import.
    "moot_json_import",
    // Dataset import: creates a backend table and can read a csv_path from
    // the filesystem — same Ask posture as palace/vault import.
    "moot_file_dataset",
    // Monitoring flag mutation: sets daemon telemetry state when `enabled`
    // is supplied. Ask tier because it changes daemon behaviour.
    "moot_monitoring_status",
    // Contradiction hunter: estate-wide sweep that persists PROPOSED
    // contradicts tunnels (same sweep runs inside moot_dream, already ask
    // tier). Review settles a proposed tunnel's lifecycle — a mutation of
    // committed state, and rejection is durable (never re-proposed).
    "moot_hunt_contradictions", "moot_review_tunnel",
];

/// Destructive, irreversible: hard-deletes content from the estate.
pub const DESTRUCTIVE_TOOLS: &[&str] = &["moot_erase_memory"];

/// Every tool a frozen dispatcher refuses: anything that writes, mutates, or
/// deletes. Erasure is refused with the rest — a snapshot that could be
/// erased through is not a snapshot.
pub fn is_frozen_refused(tool: &str) -> bool {
    ADDITIVE_WRITE_TOOLS.contains(&tool) || MUTATION_TOOLS.contains(&tool) || DESTRUCTIVE_TOOLS.contains(&tool)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    /// Every name in the inventory must be a tool the projection really
    /// serves; a renamed or retired tool must fail here, not silently stop
    /// being refused.
    #[test]
    fn inventory_names_only_real_tools() {
        let list = crate::tool_list::build_tool_list();
        let real: HashSet<String> = list
            .as_array()
            .expect("tool list is an array")
            .iter()
            .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
            .map(String::from)
            .collect();
        // `moot_redistill` is dispatchable here (recipe_tools) and listed in
        // the installer tier tables of both ports, but neither port's tool
        // list advertises it today (the Swift recipe and tool never reached
        // develop; the Rust list was never extended). A frozen dispatcher
        // must still refuse a callable mutating tool, so the inventory keeps
        // the name and this test tolerates exactly that one absence.
        let known_unadvertised = ["moot_redistill"];
        let stale: Vec<&&str> = ADDITIVE_WRITE_TOOLS
            .iter()
            .chain(MUTATION_TOOLS.iter())
            .chain(DESTRUCTIVE_TOOLS.iter())
            .filter(|t| !real.contains(**t) && !known_unadvertised.contains(*t))
            .collect();
        assert!(stale.is_empty(), "inventory names tool(s) not in the projection: {stale:?}");
    }

    #[test]
    fn writers_are_refused_and_readers_are_not() {
        for tool in ["moot_file_memory", "moot_update_memory", "moot_redistill", "moot_erase_memory", "moot_dream", "moot_json_import"] {
            assert!(is_frozen_refused(tool), "{tool} must be refused when frozen");
        }
        for tool in ["moot_memory_search", "moot_estate_status", "moot_memory_get", "moot_recall_precise", "moot_lens_concepts", "moot_estate_ping", "moot_drain_status"] {
            assert!(!is_frozen_refused(tool), "{tool} is a read and must stay callable when frozen");
        }
        // The three tables are disjoint: a tool has exactly one tier.
        let a: HashSet<&&str> = ADDITIVE_WRITE_TOOLS.iter().collect();
        let m: HashSet<&&str> = MUTATION_TOOLS.iter().collect();
        let d: HashSet<&&str> = DESTRUCTIVE_TOOLS.iter().collect();
        assert!(a.is_disjoint(&m) && m.is_disjoint(&d) && a.is_disjoint(&d));
    }
}
