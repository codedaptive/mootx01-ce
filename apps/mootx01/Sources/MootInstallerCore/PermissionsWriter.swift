// PermissionsWriter.swift
//
// Merges ARIA tool names into ~/.claude/settings.json under the
// `permissions.allow` key so Claude Code does not prompt for per-tool
// approval after a fresh mootx01 install.
//
// Schema confirmed against the live Claude Code settings format
// (AIRA-INSTALL-P3 finding): the key is `permissions.allow` (nested
// under a `permissions` object), NOT top-level `allowedTools`.
//
// Each tool name takes the MCP prefix form: `mcp__mootx01__<tool_name>`.
// For example: `mcp__mootx01__moot_capture_drawer`.
//
// The merge is additive and idempotent: existing entries in `allow`
// that are not in our list are preserved; entries we add are not
// duplicated on a second run.

import Foundation

/// Manages the Claude Code permissions allow-list for ARIA tools.
public enum PermissionsWriter {

    // MARK: - ARIA tool names

    /// The 53 ARIA tool names projected by ToolProjection.tools().
    /// Extracted from the acceptance matrix + RecipeTools + LensTools + VaultTools.
    /// Kept as a static constant to avoid importing AriaMCP/AriaLexiconLib
    /// from the installer core (which has no MCP stack dependency).
    public static let ariaToolNames: [String] = [
        // Lexicon — drawer (6)
        "moot_capture_drawer", "moot_reanchor_drawer", "moot_mutate_drawer",
        "moot_withdraw_drawer", "moot_expunge_drawer", "moot_drawer_recall",
        // Lexicon — tunnel (5)
        "moot_capture_tunnel", "moot_mutate_tunnel", "moot_withdraw_tunnel",
        "moot_expunge_tunnel", "moot_tunnel_recall",
        // Lexicon — kgFact (4)
        "moot_mutate_kgFact", "moot_withdraw_kgFact", "moot_expunge_kgFact", "moot_kgFact_recall",
        // Lexicon — diaryEntry (1)
        "moot_diaryEntry_recall",
        // Lexicon — proposal (4)
        "moot_mutate_proposal", "moot_withdraw_proposal",
        "moot_expunge_proposal", "moot_proposal_recall",
        // Lexicon — association (3)
        "moot_mutate_association", "moot_expunge_association", "moot_association_recall",
        // Lexicon — learnedReference (5)
        "moot_mutate_learnedReference", "moot_withdraw_learnedReference",
        "moot_expunge_learnedReference", "moot_learnedReference_recall",
        "moot_learn_learnedReference",
        // Federation (1)
        "moot_cross_estate_recall",
        // RecipeTools (4)
        "moot_list_recipes", "moot_grounded_synthesis",
        "moot_run_migration_benchmark", "moot_confirm_migration_promotion",
        // LensTools (16)
        "moot_keystones", "moot_constellation", "moot_free_association",
        "moot_theme_weather", "moot_latent_themes", "moot_bias",
        "moot_drift", "moot_contradiction", "moot_trust_grounded_synthesis",
        "moot_partial_cue_recall", "moot_anticipate", "moot_tunnel_successor",
        "moot_mind_overlap", "moot_estate_divergence",
        "moot_association_rules", "moot_formal_concepts",
        // VaultTools (4)
        "moot_vault_export", "moot_vault_import", "moot_vault_status", "moot_vault_reconcile",
    ]

    /// MCP-prefixed form of each tool name for the `permissions.allow` list.
    /// Format: `mcp__mootx01__<tool_name>` per the Claude Code settings schema.
    public static let permissionEntries: [String] = ariaToolNames.map {
        "mcp__mootx01__\($0)"
    }

    // MARK: - Write

    /// Merge ARIA permission entries into a Claude Code settings.json file.
    ///
    /// Reads the file (creating it with an empty object if absent), merges
    /// `permissionEntries` into `settings["permissions"]["allow"]` without
    /// duplicating existing entries, then writes back atomically.
    ///
    /// - Parameter settingsURL: path to the `settings.json` file.
    ///   Typically `MootPaths.globalClaudeSettingsURL(homeDirectory:)`.
    /// - Throws: filesystem or JSON serialization errors.
    public static func merge(into settingsURL: URL) throws {
        var root: [String: Any]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } else {
            root = [:]
        }

        // Drill down: root["permissions"]["allow"] → [String]
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []

        // Additive merge: append only entries not already present.
        let existing = Set(allow)
        for entry in permissionEntries where !existing.contains(entry) {
            allow.append(entry)
        }

        permissions["allow"] = allow
        root["permissions"] = permissions

        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Remove

    /// Remove ARIA permission entries from a Claude Code settings.json file.
    ///
    /// No-ops gracefully if the file is absent or the entries are not present.
    ///
    /// - Parameter settingsURL: path to the `settings.json` file.
    /// - Throws: filesystem or JSON serialization errors if the file exists
    ///   but cannot be read or written.
    public static func remove(from settingsURL: URL) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let data = try Data(contentsOf: settingsURL)
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard var permissions = root["permissions"] as? [String: Any],
              var allow = permissions["allow"] as? [String] else { return }

        let toRemove = Set(permissionEntries)
        allow = allow.filter { !toRemove.contains($0) }
        permissions["allow"] = allow.isEmpty ? nil : allow
        root["permissions"] = permissions.isEmpty ? nil : permissions

        let updated = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try updated.write(to: settingsURL, options: .atomic)
    }
}
