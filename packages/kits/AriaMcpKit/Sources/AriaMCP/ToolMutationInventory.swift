// ToolMutationInventory.swift — the tools that change an estate.
//
// One inventory, two readers: the installer's tiered permission default
// (MootInstallerCore.PermissionsWriter) places these tools in the Ask / Deny
// tiers, and a frozen ToolDispatcher refuses them. Keeping the sets here, in
// the kit that owns the tool surface, means a new mutating tool is triaged
// once and both readers see it.
//
// Read tools are not listed: the installer keeps its own read table (Allow
// tier), and a frozen dispatcher lets every tool outside these sets through.
//
// Rust twin: packages/kits/AriaMcpKit/rust/src/tool_mutation_inventory.rs.

/// Tool names, by the kind of change they make to committed estate state.
public enum ToolMutationInventory {

    /// Additive-unconfirmed writes: create NEW content; nothing already
    /// committed is changed, moved, or removed. Same risk class as a read
    /// from the user's perspective — undoable by withdrawing/retiring the
    /// new row, never a mutation of prior state.
    public static let additiveWriteTools: Set<String> = [
        "moot_file_memory", "moot_file_fact", "moot_write_journal", "moot_link_memories",
    ]

    /// Mutations of existing state: something already committed changes
    /// shape, is superseded, moves, or a background process alters
    /// estate-wide indexes/consolidation state. The installer prompts for
    /// these (Ask tier) — the pre-re-tier default put EVERYTHING except
    /// diagnostics here, producing 55 ask rules on a real machine including
    /// every pure read; this table exists so only genuine mutations land here.
    public static let mutationTools: Set<String> = [
        "moot_update_memory", "moot_move_memory", "moot_withdraw_memory", "moot_confirm_memory",
        "moot_retire_fact", "moot_confirm_migration", "moot_run_migration",
        "moot_reindex", "moot_reclassify_fdc", "moot_dream", "moot_distill", "moot_synthesize",
        // Force-redistill all active items + full laneScope .all reindex (CDL-02):
        // overwrites every active non-empty drawer's representation unconditionally
        // and rebuilds BM25 + dense indexes. Ask posture: same as moot_distill.
        "moot_redistill",
        "moot_palace_import", "moot_vault_import", "moot_vault_export", "moot_vault_reconcile",
        // Seed-file JSON import (MXE-JI-1): reads a seed file from the
        // filesystem and bulk-writes the estate — same Ask posture as
        // palace/vault import.
        "moot_json_import",
        // Dataset import (MX-TAB-7): creates a backend table and can read a
        // csv_path from the filesystem — same Ask posture as palace/vault import.
        "moot_file_dataset",
        // Monitoring flag mutation: sets daemon telemetry state
        // when `enabled` is supplied. Ask tier because it changes daemon behaviour.
        "moot_monitoring_status",
        // Contradiction hunter: estate-wide sweep that persists PROPOSED
        // contradicts tunnels (same sweep runs inside moot_dream, already ask
        // tier). Review settles a proposed tunnel's lifecycle — a mutation
        // of committed state, and rejection is durable (never re-proposed).
        "moot_hunt_contradictions", "moot_review_tunnel",
    ]

    /// Destructive, irreversible: hard-deletes content from the estate.
    public static let destructiveTools: Set<String> = ["moot_erase_memory"]

    /// Every tool a frozen dispatcher refuses: anything that writes, mutates,
    /// or deletes. Erasure is refused with the rest — a snapshot that could
    /// be erased through is not a snapshot.
    public static var frozenRefusedTools: Set<String> {
        additiveWriteTools.union(mutationTools).union(destructiveTools)
    }
}
