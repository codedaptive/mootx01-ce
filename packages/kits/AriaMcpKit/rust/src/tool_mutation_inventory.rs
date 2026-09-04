//! tool_mutation_inventory.rs — how every reachable tool behaves under the
//! frozen posture, and which tools change an estate.
//!
//! One inventory, two readers: the installer's tiered permission default
//! (mootx01-cli `core::permissions`) places the additive-write, mutation, and
//! destructive tools in the Allow / Ask / Deny tiers, and a frozen
//! `Dispatcher` refuses them. Keeping the tables here, in the crate that owns
//! the tool surface, means a new mutating tool is triaged once and both
//! readers see it.
//!
//! The frozen dispatcher reads three tables the installer does not:
//! `DARK_MUTATION_TOOLS` (mutating tools dispatched by name behind a launch
//! gate and never advertised, so no permission rule is ever written for
//! them), `FROZEN_READ_COMMANDS` (tools whose frozen decision is made per
//! call from their `command` argument), and `FROZEN_READ_TOOLS` (the explicit
//! allow-list of pure reads). Every reachable tool name is in exactly one of
//! the read set, the refused set, or the command-classified set; the in-file
//! tests hold that invariant against the live tool list under every opt-in
//! flag, so a new tool cannot reach a frozen serve unclassified.
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
    "moot_reindex", "moot_reclassify_fdc", "moot_dream", "moot_distill",
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

/// Mutating tools that are dispatched by name only when the serving process
/// was launched with `MOOTX01_MINT_TOOLS=1` and are never advertised by
/// tools/list (`recipe_tools::is_dark_mint_tool`). Both write adornment
/// state: minter registration replaces the active minter set, and the
/// adornment pass mints adornments onto drawers. They sit outside the
/// installer's tier tables because the installer writes rules only for
/// advertised names; a frozen dispatcher refuses them with the rest.
pub const DARK_MUTATION_TOOLS: &[&str] = &["moot_register_adornment_minter", "moot_run_adornment_pass"];

/// Every tool a frozen dispatcher refuses by name: anything that writes,
/// mutates, or deletes. Erasure is refused with the rest — a snapshot that
/// could be erased through is not a snapshot.
pub fn is_frozen_refused(tool: &str) -> bool {
    ADDITIVE_WRITE_TOOLS.contains(&tool)
        || MUTATION_TOOLS.contains(&tool)
        || DESTRUCTIVE_TOOLS.contains(&tool)
        || DARK_MUTATION_TOOLS.contains(&tool)
}

/// Tools whose frozen decision is made per call from their `command`
/// argument rather than from the tool name, paired with the commands that
/// only read. The dispatcher lets a listed command through and refuses every
/// other value, including a missing or unknown command, so the tool's
/// adapter never learns about posture.
///
/// `memory` (the Anthropic memory_20250818 adapter, opt-in via
/// `MOOTX01_MEMORY_TOOL=1`): `view` lists a directory or reads a file;
/// `create`, `str_replace`, `insert`, `delete`, and `rename` capture or
/// withdraw drawers.
pub const FROZEN_READ_COMMANDS: &[(&str, &[&str])] = &[("memory", &["view"])];

/// The read commands of a command-classified tool, or `None` when `tool` is
/// classified by name.
pub fn frozen_read_commands(tool: &str) -> Option<&'static [&'static str]> {
    FROZEN_READ_COMMANDS
        .iter()
        .find(|(name, _)| *name == tool)
        .map(|(_, commands)| *commands)
}

/// Pure reads a frozen dispatcher lets through unconditionally. Explicit on
/// purpose: the completeness test fails, naming the tool, when an advertised
/// name is in none of the three frozen sets, so the read set is a triage
/// decision and never a fall-through.
/// Tools a serve dispatches by name without advertising them: retired names
/// that answer with a notice so an old client learns the replacement. They
/// perform no write. The completeness tests count them as reachable, so a
/// dispatchable name can never sit outside the sets. Twin of Swift
/// `dispatchableUnadvertisedTools`.
pub const DISPATCHABLE_UNADVERTISED_TOOLS: &[&str] = &["moot_recollect"];

pub const FROZEN_READ_TOOLS: &[&str] = &[
    // Tier 1-5 interface reads.
    "moot_memory_search", "moot_memory_list", "moot_memory_get",
    "moot_connection_search", "moot_connection_map",
    "moot_fact_search", "moot_fact_timeline",
    "moot_read_journal",
    "moot_estate_status", "moot_estate_map", "moot_estate_ping",
    // Maintenance and diagnostics that only report.
    "moot_drain_status", "moot_rebuild_status", "moot_timing_report",
    // Grant-authorized federated read.
    "moot_federated_search",
    // Recipe reads: catalogs and the recall family.
    "moot_list_lenses", "moot_list_recipes",
    "moot_recall_precise", "moot_recall_temporal", "moot_recall_shaped",
    "moot_recall_connected", "moot_recall_distilled", "moot_recall_vague",
    "moot_recall_walk",
    // Grounded synthesis: reads candidates via recall and generates text;
    // writes no drawer, packet, journal, meta, trace, or reward — pure read.
    // Moved from MUTATION_TOOLS (FRZ-3): a frozen serve must answer it.
    "moot_synthesize",
    "moot_recollect",
    // The 23 reasoning lenses.
    "moot_lens_anticipate", "moot_lens_apriori", "moot_lens_associations",
    "moot_lens_bias", "moot_lens_cohesion", "moot_lens_complexity",
    "moot_lens_concepts", "moot_lens_constellation", "moot_lens_contradiction",
    "moot_lens_divergence", "moot_lens_drift", "moot_lens_free_association",
    "moot_lens_keystones", "moot_lens_latent_themes", "moot_lens_moment",
    "moot_lens_node_motion", "moot_lens_overlap", "moot_lens_partial_cue",
    "moot_lens_precedence", "moot_lens_rhythm", "moot_lens_successors",
    "moot_lens_theme_weather", "moot_lens_trust_synthesis",
    // Vault status and job lookup report on completed work.
    "moot_vault_status", "moot_vault_job",
    // Dataset reads.
    "moot_dataset_query", "moot_dataset_stats",
];

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    /// Every tool name a serve launched with these flags can dispatch: the
    /// advertised list, plus the dark mint tools when the mint gate is on.
    fn reachable(vault_on: bool, memory_on: bool, mint_on: bool) -> HashSet<String> {
        let list = crate::tool_list::build_tool_list_with_flags(vault_on, memory_on);
        let mut names: HashSet<String> = list
            .as_array()
            .expect("tool list is an array")
            .iter()
            .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
            .map(String::from)
            .collect();
        if mint_on {
            names.extend(DARK_MUTATION_TOOLS.iter().map(|t| t.to_string()));
        }
        names
    }

    /// Every flag combination a serve can be launched with.
    const FLAG_COMBINATIONS: [(bool, bool, bool); 8] = [
        (true, false, false), (false, false, false),
        (true, true, false), (false, true, false),
        (true, false, true), (false, false, true),
        (true, true, true), (false, true, true),
    ];

    /// Every name in the inventory must be a tool a serve can really
    /// dispatch; a renamed or retired tool must fail here, not silently stop
    /// being refused (or stop being allowed).
    #[test]
    fn inventory_names_only_reachable_tools() {
        let mut real = reachable(true, true, true);
        real.extend(DISPATCHABLE_UNADVERTISED_TOOLS.iter().map(|s| s.to_string()));
        let stale: Vec<&&str> = ADDITIVE_WRITE_TOOLS
            .iter()
            .chain(MUTATION_TOOLS.iter())
            .chain(DESTRUCTIVE_TOOLS.iter())
            .chain(DARK_MUTATION_TOOLS.iter())
            .chain(FROZEN_READ_TOOLS.iter())
            .chain(FROZEN_READ_COMMANDS.iter().map(|(name, _)| name))
            .filter(|t| !real.contains(**t))
            .collect();
        assert!(stale.is_empty(), "inventory names tool(s) no serve can dispatch: {stale:?}");
    }

    /// The structural guarantee: a tool a frozen serve can dispatch is in
    /// exactly one of the read set, the refused set, or the command-classified
    /// set, under every opt-in flag combination. A new tool in none of them
    /// fails here with its name.
    #[test]
    fn every_reachable_tool_is_in_exactly_one_frozen_set() {
        for (vault_on, memory_on, mint_on) in FLAG_COMBINATIONS {
            let mut names: Vec<String> = reachable(vault_on, memory_on, mint_on).into_iter().collect();
            names.sort();
            for name in names {
                let buckets = [
                    FROZEN_READ_TOOLS.contains(&name.as_str()),
                    is_frozen_refused(&name),
                    frozen_read_commands(&name).is_some(),
                ]
                .iter()
                .filter(|hit| **hit)
                .count();
                assert_eq!(
                    buckets, 1,
                    "{name} is in {buckets} frozen sets (vault_on={vault_on}, memory_on={memory_on}, mint_on={mint_on}); \
                     every reachable tool must be in exactly one of FROZEN_READ_TOOLS / the refused inventory / FROZEN_READ_COMMANDS"
                );
            }
        }
    }

    #[test]
    fn writers_are_refused_and_readers_are_not() {
        for tool in [
            "moot_file_memory", "moot_update_memory", "moot_redistill", "moot_erase_memory", "moot_dream",
            "moot_json_import", "moot_register_adornment_minter", "moot_run_adornment_pass",
        ] {
            assert!(is_frozen_refused(tool), "{tool} must be refused when frozen");
        }
        for tool in ["moot_memory_search", "moot_estate_status", "moot_memory_get", "moot_recall_precise", "moot_lens_concepts", "moot_estate_ping", "moot_drain_status"] {
            assert!(!is_frozen_refused(tool), "{tool} is a read and must stay callable when frozen");
            assert!(FROZEN_READ_TOOLS.contains(&tool), "{tool} is a read and must be in the explicit read set");
        }
        // The four tables are disjoint: a tool has exactly one tier.
        let a: HashSet<&&str> = ADDITIVE_WRITE_TOOLS.iter().collect();
        let m: HashSet<&&str> = MUTATION_TOOLS.iter().collect();
        let d: HashSet<&&str> = DESTRUCTIVE_TOOLS.iter().collect();
        let k: HashSet<&&str> = DARK_MUTATION_TOOLS.iter().collect();
        assert!(a.is_disjoint(&m) && m.is_disjoint(&d) && a.is_disjoint(&d));
        assert!(k.is_disjoint(&a) && k.is_disjoint(&m) && k.is_disjoint(&d));
    }

    /// The dark set is exactly the two dark mint tools the recipe surface
    /// gates at launch, so the two tables cannot drift apart.
    #[test]
    fn dark_mutation_tools_are_the_dark_mint_tools() {
        assert_eq!(DARK_MUTATION_TOOLS.len(), 2);
        for tool in DARK_MUTATION_TOOLS {
            assert!(crate::recipe_tools::is_dark_mint_tool(tool), "{tool} must be a dark mint tool");
        }
    }

    #[test]
    fn memory_is_command_classified_with_view_as_its_only_read() {
        assert_eq!(frozen_read_commands("memory"), Some(&["view"][..]));
        assert_eq!(frozen_read_commands("moot_memory_search"), None);
        assert!(!is_frozen_refused("memory"), "memory is classified by command, never by name");
    }
}
