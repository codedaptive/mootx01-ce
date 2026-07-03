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
// e.g. `mcp__mootx01__moot_memory_search`.
//
// Tool names are INJECTED by the caller (the CLI derives them from the linked
// AriaMCP ToolProjection at runtime, mirroring the Rust vertical's
// build_tool_list()). A hardcoded name table previously lived here and went
// stale when the tool surface was renamed — --grant-permissions was granting
// 53 tools that no longer existed.
//
// All merges are additive and idempotent: entries the user already has (in
// ANY tier) are preserved and never duplicated or moved.

import Foundation

/// Manages the Claude Code permissions lists for ARIA tools.
public enum PermissionsWriter {

    // MARK: - Prefixing

    /// The MCP tool prefix for this server in Claude Code settings.
    public static let mcpPrefix = "mcp__mootx01__"

    /// `mcp__mootx01__<name>` for each injected tool name.
    public static func permissionEntries(toolNames: [String]) -> [String] {
        toolNames.map { "\(mcpPrefix)\($0)" }
    }

    // MARK: - Tier classification

    /// Default permission tier for a tool, by capability pattern.
    public enum Tier: String {
        case allow, ask, deny
    }

    /// Classify a bare tool name (no MCP prefix) into its default tier.
    ///
    /// Pattern-based on purpose: a new tool added to the surface lands in
    /// `ask` (the safe middle) unless its name marks it as a diagnostic
    /// (allow) or a destructive purge (deny). Patterns, not a name table, so
    /// this cannot go stale the way the old hardcoded list did.
    public static func classify(_ tool: String) -> Tier {
        // Destructive, irreversible: hard-deletes content from the estate.
        if tool.contains("erase") || tool.contains("expunge") || tool.contains("purge") {
            return .deny
        }
        // Diagnostics and pure listings: no estate content read or written.
        if tool.hasSuffix("_ping") || tool.hasSuffix("_status") || tool.contains("_list_") {
            return .allow
        }
        // Everything else — reads and writes — prompts the user.
        return .ask
    }

    // MARK: - Write (tiered default)

    /// Merge tool entries into `permissions.allow` / `.ask` / `.deny` by tier.
    ///
    /// A tool the user already placed in ANY of the three lists is left
    /// exactly where it is — the user's decision outranks our default.
    /// Returns the number of entries added per tier.
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
            let entry = "\(mcpPrefix)\(tool)"
            guard !existing.contains(entry) else { continue }
            switch classify(tool) {
            case .allow: allow.append(entry); added.allow += 1
            case .ask:   ask.append(entry);   added.ask += 1
            case .deny:  deny.append(entry);  added.deny += 1
            }
        }

        permissions["allow"] = allow
        permissions["ask"] = ask
        permissions["deny"] = deny
        root["permissions"] = permissions
        try writeSettings(root, to: settingsURL)
        return added
    }

    // MARK: - Write (allow-all opt-in)

    /// Merge every tool entry into `permissions.allow` (the explicit
    /// `--grant-permissions` opt-in). Additive and idempotent.
    ///
    /// - Parameters:
    ///   - settingsURL: path to the `settings.json` file.
    ///   - toolNames: bare tool names from the live server surface.
    public static func merge(into settingsURL: URL, toolNames: [String]) throws {
        var root = try readSettings(at: settingsURL)
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []

        let existing = Set(allow)
        for entry in permissionEntries(toolNames: toolNames) where !existing.contains(entry) {
            allow.append(entry)
        }

        permissions["allow"] = allow
        root["permissions"] = permissions
        try writeSettings(root, to: settingsURL)
    }

    // MARK: - Remove

    /// Remove every `mcp__mootx01__*` entry from all three permission lists.
    ///
    /// Prefix-based (no name list needed) so uninstall cleans up even tools
    /// that were renamed or removed since they were granted. No-ops gracefully
    /// if the file is absent or nothing of ours is present.
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
            list = list.filter { !$0.hasPrefix(mcpPrefix) }
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
