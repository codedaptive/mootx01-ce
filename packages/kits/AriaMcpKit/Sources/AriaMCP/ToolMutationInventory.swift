// ToolMutationInventory.swift — how every reachable tool behaves under the
// frozen posture, and which tools change an estate.
//
// One inventory, two readers: the installer's tiered permission default
// (MootInstallerCore.PermissionsWriter) places the additive-write, mutation,
// and destructive tools in the Allow / Ask / Deny tiers, and a frozen
// ToolDispatcher refuses them. Keeping the sets here, in the kit that owns
// the tool surface, means a new mutating tool is triaged once and both
// readers see it.
//
// The frozen dispatcher reads three tables the installer does not:
// `darkMutationTools` (mutating tools dispatched by name behind a launch
// gate and never advertised, so no permission rule is ever written for
// them), `frozenReadCommands` (tools whose frozen decision is made per call
// from their `command` argument), and `frozenReadTools` (the explicit
// allow-list of pure reads). Every reachable tool name is in exactly one of
// the read set, the refused set, or the command-classified set;
// FrozenPostureTests holds that invariant against the live projection under
// every opt-in flag, so a new tool cannot reach a frozen serve unclassified.
//
// Rust twin: packages/kits/AriaMcpKit/rust/src/tool_mutation_inventory.rs.

/// Tool names, by the kind of change they make to committed estate state,
/// plus the frozen-posture allow-lists.
public enum ToolMutationInventory {

    /// Additive-unconfirmed writes: create NEW content; nothing already
    /// committed is changed, moved, or removed. Same risk class as a read
    /// from the user's perspective — undoable by withdrawing/retiring the
    /// new row, never a mutation of prior state.
    ///
    /// `moot_file_memory` stays in this tier because its sensitivity follows
    /// the live grant ceiling on the server: while a restricted or secret
    /// grant is live an omitted sensitivity files at the grant's tier and a
    /// lower explicit tier is refused (`ToolDispatcher.runFileMemory`), so
    /// an allow-tier write cannot downgrade material recalled under a grant.
    /// The opt-in `memory` adapter's create, str_replace and insert also file
    /// at the ceiling without an argument (`MemoryToolAdapter`).
    public static let additiveWriteTools: Set<String> = [
        "moot_file_memory", "moot_file_fact", "moot_write_journal", "moot_link_memories",
        // Contradiction resolution: settles proposed contradiction tunnel
        // lifecycle records (transitions PROPOSED → SETTLED). Creates or
        // updates tunnel records without removing any prior content.
        "moot_propose_contradictions",
    ]

    /// Mutations of existing state: something already committed changes
    /// shape, is superseded, moves, or a background process alters
    /// estate-wide indexes/consolidation state. The installer prompts for
    /// these (Ask tier) — the pre-re-tier default put EVERYTHING except
    /// diagnostics here, producing 55 ask rules on a real machine including
    /// every pure read; this table exists so only genuine mutations land here.
    public static let mutationTools: Set<String> = [
        "moot_update_memory", "moot_move_memory", "moot_withdraw_memory", "moot_confirm_memory",
        "moot_retire_fact", "moot_migration_confirm", "moot_migration_run",
        "moot_reindex", "moot_reclassify_fdc", "moot_dream",
        "moot_palace_import", "moot_vault_import", "moot_vault_export", "moot_vault_reconcile",
        // Seed-file JSON import (MXE-JI-1): reads a seed file from the
        // filesystem and bulk-writes the estate — same Ask posture as
        // palace/vault import.
        "moot_json_import",
        // Dataset import (MX-TAB-7): creates a backend table and can read a
        // csv_path from the filesystem — same Ask posture as palace/vault import.
        "moot_file_dataset",
        // Monitoring set: writes the daemon telemetry enabled/disabled flag.
        // moot_monitoring_status is a pure read (inspection only) and lives
        // in frozenReadTools.
        "moot_monitoring_set",
        // Contradiction hunter: estate-wide sweep that persists PROPOSED
        // contradiction tunnels (same sweep runs inside moot_dream, already ask
        // tier). Review settles a proposed tunnel's lifecycle — a mutation
        // of committed state, and rejection is durable (never re-proposed).
        "moot_hunt_contradictions", "moot_review_tunnel",
    ]

    /// Destructive, irreversible: hard-deletes content from the estate.
    public static let destructiveTools: Set<String> = ["moot_erase_memory"]

    /// Every tool a frozen dispatcher refuses by name: anything that writes,
    /// mutates, or deletes. Erasure is refused with the rest — a snapshot
    /// that could be erased through is not a snapshot.
    public static var frozenRefusedTools: Set<String> {
        additiveWriteTools.union(mutationTools).union(destructiveTools)
    }

    /// Tools whose frozen decision is made per call from their `command`
    /// argument rather than from the tool name, mapped to the commands that
    /// only read. The dispatcher lets a listed command through and refuses
    /// every other value, including a missing or unknown command, so the
    /// tool's adapter never learns about posture.
    ///
    /// `memory` (the Anthropic memory_20250818 adapter, opt-in via
    /// `MOOTX01_MEMORY_TOOL=1`): `view` lists a directory or reads a file;
    /// `create`, `str_replace`, `insert`, `delete`, and `rename` capture or
    /// withdraw drawers.
    public static let frozenReadCommands: [String: Set<String>] = [
        "memory": ["view"],
    ]

    /// The tool names classified per call by `frozenReadCommands`.
    public static var commandClassifiedTools: Set<String> {
        Set(frozenReadCommands.keys)
    }

    /// Pure reads a frozen dispatcher lets through unconditionally. Explicit
    /// on purpose: the completeness test fails, naming the tool, when an
    /// advertised name is in none of the three frozen sets, so the read set
    /// is a triage decision and never a fall-through.
    public static let frozenReadTools: Set<String> = [
        // Surface help: capability discovery, always a pure read.
        "moot_help",
        // Tier 1-5 interface reads.
        "moot_memory_search", "moot_memory_list", "moot_memory_get",
        "moot_memory_recall_transcript",
        // Similar recall: nearest drawers by whole-record vector, pure read.
        "moot_recall_similar",
        "moot_connection_search", "moot_connection_map",
        "moot_fact_search", "moot_fact_timeline",
        "moot_read_journal",
        "moot_estate_status", "moot_estate_map", "moot_estate_ping",
        // Maintenance and diagnostics that only report.
        "moot_drain_status", "moot_rebuild_status", "moot_timing_report",
        // Monitoring inspection: reads daemon telemetry state without changing it.
        // moot_monitoring_set (the write path) lives in mutationTools.
        "moot_monitoring_status",
        // Grant-authorized federated read (v2 name: moot_federated_recall).
        "moot_federated_recall",
        // Recipe reads: catalogs and the recall family.
        "moot_list_lenses", "moot_list_recipes",
        "moot_recall_precise", "moot_recall_temporal", "moot_recall_shaped",
        "moot_recall_connected", "moot_recall_distilled", "moot_recall_vague",
        "moot_recall_walk",
        // Grounded synthesis: reads candidates via recall and generates text;
        // writes no drawer, packet, journal, meta, trace, or reward — pure read.
        // Moved from mutationTools (FRZ-3): a frozen serve must answer it.
        "moot_synthesize",
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
    ]
}
