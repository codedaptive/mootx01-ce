// MCPEntryOwnership.swift
//
// ADR-024 §3/§4: MCP connection ownership and install-moment dedupe.
//
// Two install moments can wire a client's MCP connection: the CLI installer
// (this binary) and the Claude Code plugin (`mootx01@mootx01`, a declarative
// manifest with no install-time script). When both are present, the plugin
// is the preferred connection owner (§1) and the installer must detect it,
// skip writing a competing direct entry, and clean up any direct entry a
// PRIOR install wrote — but only when that entry is confirmed to be ours and
// on the default database (§4). An entry carrying a data-dir/estate override
// (a development rig, or any other explicitly-scoped install) is reported by
// name and path and never auto-removed; silently deleting someone's
// dev-rig wiring is worse than leaving a stale entry behind.
//
// This file is the single, shared classification used by both the CLI
// installer's act-mode dedupe (Installer.dedupeDirectEntry, InstallCommand)
// and its ownership-aware uninstall path (Installer.uninstall). The plugin's
// SessionStart hook (tools/moot-packager/Data/canonical/hooks/moot_hooks.py,
// EE) implements the same "our server name present" detection independently
// in Python — it is read-only and never edits config, so it does not need
// (and cannot easily share) this Swift classifier; keep the two in sync by
// hand if the ownership rule ever changes.

import Foundation

/// Ownership classification for an existing direct `mcpServers.<name>` (or
/// equivalent per-format) MCP entry, per ADR-024 §4.
public enum MCPEntryOwnership: Equatable, Sendable {
    /// Our server name, and no data-dir/estate env override. Mechanically on
    /// the default database by construction (`serve` resolves the default
    /// data dir unless overridden) — safe for the installer to replace or
    /// remove.
    case oursDefault
    /// Carries an env override pointing at a non-default data dir/estate
    /// (e.g. a development rig). Never auto-removed or auto-replaced;
    /// callers report it by name and path instead. `reason` names the
    /// specific override(s) found, for the printed report.
    case foreign(reason: String)
}

/// Classifies a decoded MCP server entry's ownership. Pure — no filesystem
/// access; callers resolve the entry's presence/absence and hand the decoded
/// object (or env map) to `classify`.
public enum MCPEntryClassifier {
    /// Env keys whose presence on an existing entry marks it as pointing at
    /// a non-default database (ADR-024 §4): `serve` resolves the default
    /// data dir unless one of these overrides it, so an entry carrying
    /// neither is on the default database by construction.
    public static let overrideEnvKeys: [String] = ["MOOTX01_DATA_DIR", "ARIA_MCP_SQLITE_PATH"]

    /// Classify a JSON-decoded `mcpServers.<name>` entry (the object value,
    /// e.g. `{"command":...,"args":[...],"env":{...}}` or
    /// `{"type":"http","url":...}`). Callers pass only entries already known
    /// to exist under the server name.
    ///
    /// HTTP entries (no `env` key at all in every shape this installer
    /// writes) cannot disagree about the database — they reach whatever
    /// estate the resident daemon holds (ADR-024 §4) — so the absence of an
    /// `env` map is itself `.oursDefault`. Command/stdio entries (the proxy
    /// bridge, or a legacy bare `serve`) are `.oursDefault` only when their
    /// `env` carries neither override key.
    public static func classify(entry: [String: Any]) -> MCPEntryOwnership {
        guard let env = entry["env"] as? [String: Any] else { return .oursDefault }
        return classify(env: env)
    }

    /// Classify from an already-extracted env map (used by the TOML/YAML
    /// merge paths, whose entries are not decoded through JSONSerialization).
    public static func classify(env: [String: Any]) -> MCPEntryOwnership {
        let overriding = overrideEnvKeys.filter { env[$0] != nil }
        guard overriding.isEmpty else {
            return .foreign(reason: "env override: \(overriding.joined(separator: ", "))")
        }
        return .oursDefault
    }
}

/// Detects whether a Claude-Code-family plugin is installed, by reading the
/// user's own plugin registry. Read-only — never writes.
public enum PluginDetector {
    /// Returns `true` when `pluginID` (e.g. `"mootx01@mootx01"`) has at
    /// least one installed entry in `~/.claude/plugins/installed_plugins.json`.
    ///
    /// Shape (Claude Code, verified against a real installation):
    /// `{"version":2,"plugins":{"<id>":[{"scope":"user","installPath":...,
    /// "version":"1.0.11", ...}]}}`. Absence of the file, an empty entry
    /// array, or any decode failure all mean "not installed" — the caller
    /// falls back to normal direct wiring.
    ///
    /// - Parameter homeDirectory: user's home directory. Inject in tests —
    ///   SAFETY: never point this at the real `~/.claude` in a test; use an
    ///   injected temp home (see InstallerTests' pattern).
    public static func isPluginInstalled(pluginID: String, homeDirectory: URL) -> Bool {
        let path = homeDirectory
            .appendingPathComponent(".claude/plugins/installed_plugins.json", isDirectory: false)
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any],
              let entries = plugins[pluginID] as? [Any]
        else { return false }
        return !entries.isEmpty
    }
}
