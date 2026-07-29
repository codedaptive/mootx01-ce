// PermissionsWriter.swift
//
// Writes ARIA tool permissions into ~/.claude/settings.json under the
// `permissions` object. Two modes:
//
//   - Tiered (the install DEFAULT): each tool is classified into
//     `permissions.allow` / `permissions.ask` / `permissions.deny` by what it
//     can do — diagnostics are allowed, reads/writes ask, destructive purges
//     are denied. Without this a fresh install leaves every tool unapproved
//     and "nothing works" out of the box.
//   - Allow-all (`--grant-permissions`): every tool into `permissions.allow`,
//     for users who explicitly opt in to full auto-approval.
//
// Schema confirmed against the live Claude Code settings format
// (AIRA-INSTALL-P3 finding): the keys are `permissions.allow` / `.ask` /
// `.deny` (nested under a `permissions` object), NOT top-level `allowedTools`.
//
// Each tool name takes the MCP prefix form: `mcp__mootx01__<tool_name>`,
// e.g. `mcp__mootx01__moot_memory_search`. Since the v1.0.15 plugin-owned
// connection, Claude Code ALSO routes calls made through the
// installed plugin under a second, distinct namespace:
// `mcp__plugin_mootx01_mootx01__<tool_name>` (empirically confirmed against
// a live `~/.claude/settings.json` carrying both prefixes side by side —
// the plugin prefix shape is `mcp__plugin_<marketplace>_<plugin>__`, and
// this installer's marketplace and plugin are both named `mootx01`, see
// `registerClaudeCodeMarketplace`). A rule written for only one namespace
// matches zero calls made through the other connection — the exact "moot is
// unusable from permission prompts" defect this file now fixes: BOTH
// namespaces must carry every tier entry, or whichever connection Claude
// Code is actually using for a given call prompts (or is silently absent
// from `allow`) regardless of what the OTHER namespace's entry says.
//
// Tool names are INJECTED by the caller (the CLI derives them from the linked
// AriaMCP ToolProjection at runtime, mirroring the Rust vertical's
// build_tool_list()). A hardcoded name table previously lived here and went
// stale when the tool surface was renamed — --grant-permissions was granting
// 53 tools that no longer existed. The TIER table below is a deliberate,
// different kind of name table: it classifies by verb semantics (read /
// additive-write / mutation / destructive), which cannot be inferred from a
// generic pattern the way "ends in _status" can — see `classify`'s doc
// comment for why this one is intentionally exhaustive-by-name.
//
// All merges are additive and idempotent: entries the user already has (in
// ANY tier) are preserved and never duplicated or moved — EXCEPT for the
// migration pass (`migrateTiers`, run at upgrade time), which re-tiers an
// existing entry that predates this classification but never touches an
// entry the user explicitly placed in `deny` (see its doc comment).

import Foundation

/// Manages the Claude Code permissions lists for ARIA tools.
public enum PermissionsWriter {

    // MARK: - Prefixing

    /// The MCP tool prefix for this server in Claude Code settings, for the
    /// direct (non-plugin) connection.
    public static let mcpPrefix = "mcp__mootx01__"

    /// The MCP tool prefix Claude Code uses for calls routed through the
    /// installed plugin (plugin-owned MCP connections, v1.0.15). Shape:
    /// `mcp__plugin_<marketplace>__<plugin>__` — empirically confirmed
    /// against a live settings.json (both this installer's marketplace and
    /// plugin are named `mootx01`, so the concrete prefix is
    /// `mcp__plugin_mootx01_mootx01__`). A settings file with rules ONLY
    /// under `mcpPrefix` matches nothing for a plugin-routed call — every
    /// tier write in this file must cover BOTH prefixes.
    public static let pluginMcpPrefix = "mcp__plugin_mootx01_mootx01__"

    /// Every namespace prefix a tool name must be written under.
    public static let allPrefixes = [mcpPrefix, pluginMcpPrefix]

    /// `mcp__mootx01__<name>` for each injected tool name (direct namespace
    /// only — used by the allow-all `merge`, which historically only wrote
    /// this one prefix; see `mergeTiered` for the both-namespaces writer).
    public static func permissionEntries(toolNames: [String]) -> [String] {
        toolNames.map { "\(mcpPrefix)\($0)" }
    }

    // MARK: - Tier classification

    /// Default permission tier for a tool, by capability pattern.
    public enum Tier: String {
        case allow, ask, deny
    }

    /// Reads: no estate content is created, changed, or removed. Includes
    /// diagnostics, pure listings, every search/recall shape, every
    /// reasoning lens (all read the estate, none write it), and the
    /// federated read (its own grant-authorization gate, GLK-side, governs
    /// what it can reach — the tool call itself is a read).
    private static let readTools: Set<String> = [
        "moot_estate_status", "moot_estate_ping", "moot_drain_status",
        "moot_list_lenses", "moot_list_recipes",
        "moot_vault_status", "moot_vault_job",
        "moot_memory_search", "moot_memory_get", "moot_memory_list",
        "moot_recall_precise", "moot_recall_shaped", "moot_recall_distilled",
        "moot_fact_search", "moot_fact_timeline",
        "moot_connection_search", "moot_connection_map",
        "moot_estate_map", "moot_read_journal", "moot_federated_search",
        // Dataset reads (MX-TAB-7): query rows / column stats are read-only.
        "moot_dataset_query", "moot_dataset_stats",
        "moot_lens_anticipate", "moot_lens_apriori", "moot_lens_associations", "moot_lens_bias",
        "moot_lens_cohesion", "moot_lens_complexity", "moot_lens_concepts", "moot_lens_constellation",
        "moot_lens_contradiction", "moot_lens_divergence", "moot_lens_drift", "moot_lens_free_association",
        "moot_lens_keystones", "moot_lens_latent_themes", "moot_lens_moment", "moot_lens_node_motion",
        "moot_lens_overlap", "moot_lens_partial_cue", "moot_lens_precedence", "moot_lens_rhythm",
        "moot_lens_successors", "moot_lens_theme_weather", "moot_lens_trust_synthesis",
    ]

    /// Additive-unconfirmed writes: create NEW content; nothing already
    /// committed is changed, moved, or removed. Same risk class as a read
    /// from the user's perspective — undoable by withdrawing/retiring the
    /// new row, never a mutation of prior state.
    private static let additiveWriteTools: Set<String> = [
        "moot_file_memory", "moot_file_fact", "moot_write_journal", "moot_link_memories",
    ]

    /// Mutations of existing state: something already committed changes
    /// shape, is superseded, moves, or a background process alters
    /// estate-wide indexes/consolidation state. Prompts — this is the
    /// bucket the pre-re-tier default put EVERYTHING (except diagnostics)
    /// into, producing 55 ask rules on a real machine including every pure
    /// read; this table exists so only genuine mutations land here.
    private static let mutationTools: Set<String> = [
        "moot_update_memory", "moot_move_memory", "moot_withdraw_memory", "moot_confirm_memory",
        "moot_retire_fact", "moot_confirm_migration", "moot_run_migration",
        "moot_reindex", "moot_reclassify_fdc", "moot_dream", "moot_distill", "moot_consolidate", "moot_synthesize",
        "moot_palace_import", "moot_vault_import", "moot_vault_export", "moot_vault_reconcile",
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
    private static let destructiveTools: Set<String> = ["moot_erase_memory"]

    /// Every tool name this module has explicitly triaged into a tier.
    /// Exposed so a test can assert this set equals the REAL tool inventory
    /// — a tool the classification tables have not been updated for must
    /// fail that test, not silently fall through `classify`'s safe-middle
    /// default into `ask` unnoticed (the failure mode `--grant-permissions`
    /// already fixed once for a hardcoded allow-all list; this is the same
    /// discipline applied to the tiered default).
    public static var explicitlyClassifiedTools: Set<String> {
        readTools.union(additiveWriteTools).union(mutationTools).union(destructiveTools)
    }

    /// Classify a bare tool name (no MCP prefix) into its default tier.
    ///
    /// Exhaustive name-table based (Bob's re-tier ruling, 2026-07-04): the
    /// PRIOR pattern-only classifier put every tool that wasn't a diagnostic
    /// or a destructive purge into `ask`, including every pure read (all
    /// lenses, memory_search, recalls, fact/connection search,
    /// read_journal) — unusable from real permission prompts (55 ask rules
    /// on a real machine). Verb semantics cannot be inferred from a generic
    /// name pattern the way "ends in _status" can (nothing about the string
    /// "moot_dream" says "mutation", and nothing about "moot_recall_shaped"
    /// says "read" via suffix alone), so the source of truth here is the
    /// explicit `readTools` / `additiveWriteTools` / `mutationTools` /
    /// `destructiveTools` tables, not a pattern match.
    ///
    /// A tool absent from all four tables (a brand-new addition to the
    /// surface not yet triaged) still lands in `ask`, the safe middle — but
    /// `explicitlyClassifiedTools` lets a test catch that omission instead
    /// of shipping it silently.
    public static func classify(_ tool: String) -> Tier {
        if destructiveTools.contains(tool) { return .deny }
        if mutationTools.contains(tool) { return .ask }
        if readTools.contains(tool) || additiveWriteTools.contains(tool) { return .allow }
        // Untriaged tool — safe middle; see explicitlyClassifiedTools.
        return .ask
    }

    // MARK: - Write (tiered default)

    /// Merge tool entries into `permissions.allow` / `.ask` / `.deny` by tier.
    ///
    /// A tool the user already placed in ANY of the three lists is left
    /// exactly where it is — the user's decision outranks our default.
    /// Writes an entry under BOTH `mcpPrefix` and `pluginMcpPrefix` for each
    /// tool (see the file header) — a rule under only one namespace matches
    /// zero calls made through the other Claude Code connection. The two
    /// namespaces are tracked and preserved INDEPENDENTLY against
    /// `existing`: an install that only ever wrote `mcpPrefix` (pre-plugin,
    /// or pre this fix) gets its missing `pluginMcpPrefix` twin backfilled
    /// here at `classify`'s CURRENT default tier — NOT copied from whatever
    /// tier the `mcpPrefix` sibling happens to sit in (which may itself be
    /// a user customization, or a stale pre-migration tier). If a user
    /// wants matching customizations in both namespaces, they place both
    /// entries themselves; this function only ever fills in what is
    /// genuinely absent.
    /// Returns the number of entries added per tier (both namespaces
    /// combined — a fresh install adds 2 entries per tool).
    ///
    /// - Parameters:
    ///   - settingsURL: path to the `settings.json` file.
    ///   - toolNames: bare tool names from the live server surface.
    @discardableResult
    public static func mergeTiered(
        into settingsURL: URL,
        toolNames: [String]
    ) throws -> (allow: Int, ask: Int, deny: Int) {
        var root = try readSettings(at: settingsURL)
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        var ask = permissions["ask"] as? [String] ?? []
        var deny = permissions["deny"] as? [String] ?? []

        // The user's existing placement (any tier) wins over our default.
        let existing = Set(allow).union(ask).union(deny)
        var added = (allow: 0, ask: 0, deny: 0)
        for tool in toolNames {
            let tier = classify(tool)
            for prefix in allPrefixes {
                let entry = "\(prefix)\(tool)"
                guard !existing.contains(entry) else { continue }
                switch tier {
                case .allow: allow.append(entry); added.allow += 1
                case .ask:   ask.append(entry);   added.ask += 1
                case .deny:  deny.append(entry);  added.deny += 1
                }
            }
        }

        permissions["allow"] = allow
        permissions["ask"] = ask
        permissions["deny"] = deny
        root["permissions"] = permissions
        try writeSettings(root, to: settingsURL)
        return added
    }

    // MARK: - Migration (existing installs converging on a new default)

    /// Re-tier existing permission entries for OUR tools whose current tier
    /// no longer matches `classify`'s current default — the migration pass
    /// that lets an install from BEFORE a tiering change (Bob's re-tier
    /// ruling, 2026-07-04: the old default put every non-diagnostic tool in
    /// `ask`) converge, instead of fossilizing whatever tiering shipped at
    /// install time. `mergeTiered` alone cannot do this: it only ADDS an
    /// entry when none of the three tiers already contain it, so it never
    /// revisits an entry that is already present somewhere, however stale
    /// its tier.
    ///
    /// Two hard rules, evaluated in order, both non-negotiable:
    ///   1. **Deny is sacred.** An entry already in `deny` — whether the
    ///      user put it there or an earlier install did — is NEVER moved,
    ///      regardless of what `classify` says today. This mirrors
    ///      `mergeTiered`'s "user's placement outranks our default"
    ///      contract; a migration is not license to override an explicit
    ///      restriction.
    ///   2. **Foreign entries are untouched.** An entry for a tool NOT in
    ///      `toolNames` — a different MCP server's rule, a non-MCP Claude
    ///      Code permission like `Bash(ls:*)`, or (after prefix-stripping)
    ///      anything that doesn't match one of our two namespaces at all —
    ///      is never inspected or moved in either direction.
    ///
    /// Applies to both namespace prefixes independently. This function
    /// never CREATES an entry that doesn't already exist in some tier —
    /// that remains `mergeTiered`'s job. Callers should run this BEFORE
    /// `mergeTiered` so the two passes compose: migrate what is already
    /// present into its correct tier, then add whatever is still missing
    /// under the current default.
    ///
    /// - Parameters:
    ///   - settingsURL: path to the `settings.json` file.
    ///   - toolNames: bare tool names from the live server surface.
    /// - Returns: the number of entries moved into a different tier.
    @discardableResult
    public static func migrateTiers(
        at settingsURL: URL,
        toolNames: [String]
    ) throws -> Int {
        var root = try readSettings(at: settingsURL)
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var lists: [Tier: [String]] = [
            .allow: permissions["allow"] as? [String] ?? [],
            .ask: permissions["ask"] as? [String] ?? [],
            .deny: permissions["deny"] as? [String] ?? [],
        ]

        // Reverse index: entry string -> the tier currently holding it. An
        // entry cannot legitimately appear in more than one tier
        // (mergeTiered never duplicates); if it somehow does, the first
        // tier found wins — resolving that inconsistency is not this
        // function's job.
        var currentTier: [String: Tier] = [:]
        for (tier, list) in lists {
            for entry in list where currentTier[entry] == nil {
                currentTier[entry] = tier
            }
        }

        // Rule 2 (foreign entries untouched) is structural, not a filter
        // step: this loop only ever builds candidate keys from `toolNames`
        // (our own tools) under our own two prefixes, so an entry for a
        // foreign tool, or a non-MCP permission string, is never a
        // candidate key and is never inspected, let alone moved.
        var moved = 0
        for tool in toolNames {
            let targetTier = classify(tool)
            for prefix in allPrefixes {
                let entry = "\(prefix)\(tool)"
                guard let existingTier = currentTier[entry] else { continue } // absent — mergeTiered's job
                guard existingTier != .deny else { continue }                 // Rule 1: deny is sacred
                // Rule 2 (ask convergence): an entry sitting at ask converges
                // onto the shipped tier. This loosens ask→allow ONLY for
                // allow-class tools (reads + additive writes) — the class an
                // old default fossilized at ask, which made moot unusable
                // from permission prompts (see InstallCommand's migrateTiers
                // note). A user-set ask on a mutation/destructive tool is
                // never loosened by construction: those classify as ask (or
                // deny), so convergence is a no-op or a tightening for them —
                // pinned by the mutation-ask survival test.
                guard existingTier != targetTier else { continue }            // already correct
                lists[existingTier]?.removeAll { $0 == entry }
                lists[targetTier, default: []].append(entry)
                currentTier[entry] = targetTier
                moved += 1
            }
        }

        guard moved > 0 else { return 0 }
        permissions["allow"] = lists[.allow] ?? []
        permissions["ask"] = lists[.ask] ?? []
        permissions["deny"] = lists[.deny] ?? []
        root["permissions"] = permissions
        try writeSettings(root, to: settingsURL)
        return moved
    }

    /// `true` if `settingsURL` exists and already carries at least one
    /// `mcpPrefix`/`pluginMcpPrefix` entry in any tier. Used to gate
    /// permission-migration passes that should only ever CONVERGE an
    /// existing mootx01 Claude Code integration, never create one from
    /// nothing for a user who never selected Claude Code as an install
    /// target (mirrors `DepthInstaller.hostsWithExistingPluginDirectory`'s
    /// "only converge what already exists" discipline for plugin
    /// rematerialization).
    public static func hasAnyMootEntries(at settingsURL: URL) -> Bool {
        guard let root = try? readSettings(at: settingsURL), !root.isEmpty else { return false }
        guard let permissions = root["permissions"] as? [String: Any] else { return false }
        for key in ["allow", "ask", "deny"] {
            guard let list = permissions[key] as? [String] else { continue }
            if list.contains(where: { $0.hasPrefix(mcpPrefix) || $0.hasPrefix(pluginMcpPrefix) }) {
                return true
            }
        }
        return false
    }

    // MARK: - Write (allow-all opt-in)

    /// Merge every tool entry into `permissions.allow` (the explicit
    /// `--grant-permissions` opt-in). Additive and idempotent. Writes both
    /// namespace prefixes (see `mergeTiered`'s doc comment) — the identical
    /// "matches zero calls through the other connection" defect applies
    /// here too.
    ///
    /// - Parameters:
    ///   - settingsURL: path to the `settings.json` file.
    ///   - toolNames: bare tool names from the live server surface.
    public static func merge(into settingsURL: URL, toolNames: [String]) throws {
        var root = try readSettings(at: settingsURL)
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []

        let existing = Set(allow)
        let entries = toolNames.flatMap { tool in allPrefixes.map { "\($0)\(tool)" } }
        for entry in entries where !existing.contains(entry) {
            allow.append(entry)
        }

        permissions["allow"] = allow
        root["permissions"] = permissions
        try writeSettings(root, to: settingsURL)
    }

    // MARK: - Remove

    /// Remove every `mcp__mootx01__*` AND `mcp__plugin_mootx01_mootx01__*`
    /// entry from all three permission lists.
    ///
    /// Prefix-based (no name list needed) so uninstall cleans up even tools
    /// that were renamed or removed since they were granted, and both
    /// namespaces (direct + plugin — see the file header) so an uninstall
    /// after this fix does not strand the plugin-prefixed twin entries
    /// `mergeTiered`/`merge` now write. No-ops gracefully if the file is
    /// absent or nothing of ours is present.
    ///
    /// - Parameter settingsURL: path to the `settings.json` file.
    public static func remove(from settingsURL: URL) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let data = try Data(contentsOf: settingsURL).strippingLeadingUTF8BOM
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        guard var permissions = root["permissions"] as? [String: Any] else { return }

        for key in ["allow", "ask", "deny"] {
            guard var list = permissions[key] as? [String] else { continue }
            list = list.filter { entry in
                !allPrefixes.contains { entry.hasPrefix($0) }
            }
            permissions[key] = list.isEmpty ? nil : list
        }
        root["permissions"] = permissions.isEmpty ? nil : permissions
        try writeSettings(root, to: settingsURL)
    }

    // MARK: - Settings IO

    private static func readSettings(at settingsURL: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL).strippingLeadingUTF8BOM
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func writeSettings(_ root: [String: Any], to settingsURL: URL) throws {
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }
}
