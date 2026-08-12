// MCPEntryOwnership.swift
//
// MCP connection ownership and install-moment dedupe.
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
/// equivalent per-format) MCP entry.
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
    /// a non-default database: `serve` resolves the default
    /// data dir unless one of these overrides it, so an entry carrying
    /// neither is on the default database by construction.
    public static let overrideEnvKeys: [String] = ["MOOTX01_DATA_DIR", "ARIA_MCP_SQLITE_PATH"]

    /// Classify a JSON-decoded `mcpServers.<name>` entry (the object value,
    /// e.g. `{"command":...,"args":[...],"env":{...}}` or
    /// `{"type":"http","url":...}`). Callers pass only entries already known
    /// to exist under the server name.
    ///
    /// Adams #2 correction: a positive SHAPE check runs first. Classifying
    /// `.oursDefault` from the mere absence of an env override — without
    /// ever checking that the entry actually looks like ours — made a
    /// malformed entry (`{}`) or a user's own unrelated server that happens
    /// to sit under the key `"mootx01"` (with no env block) auto-removable
    /// on a routine `mootx01 install` once a plugin is present. An entry
    /// must resolve to the `mootx01` binary (command basename + `serve`/
    /// `proxy` args) OR the loopback daemon endpoint (`isLoopbackDaemonEntry`)
    /// before its env is even considered; anything else is `.foreign` —
    /// reported by name, never removed — regardless of its env block.
    ///
    /// Once the shape check passes: HTTP entries (no `env` key at all in
    /// every shape this installer writes) cannot disagree about the
    /// database — they reach whatever estate the resident daemon holds
    /// — so the absence of an `env` map is itself
    /// `.oursDefault`. Command/stdio entries (the proxy bridge, or a legacy
    /// bare `serve`) are `.oursDefault` only when their `env` carries
    /// neither override key.
    public static func classify(entry: [String: Any]) -> MCPEntryOwnership {
        guard looksLikeOurs(entry) else {
            return .foreign(reason: "entry shape does not resolve to the mootx01 binary or the loopback daemon endpoint")
        }
        // Args-level override (#67): `serve --db <name>` selects a non-default
        // estate without using either env key. Removing such an entry silently
        // collapses the user's estate isolation into the default estate. Check
        // args BEFORE env so both override mechanisms are honoured.
        if let args = entry["args"] as? [String], args.contains("--db") {
            return .foreign(reason: "args override: --db")
        }
        guard let env = entry["env"] as? [String: Any] else { return .oursDefault }
        return classify(env: env)
    }

    /// Classify from an already-extracted env map (used by the TOML/YAML
    /// merge paths, whose entries are not decoded through JSONSerialization).
    /// Callers of this overload have already established the entry's shape
    /// out of band (there is no raw entry object to shape-check here) — see
    /// `classify(entry:)` for the shape-checked JSON entry point.
    public static func classify(env: [String: Any]) -> MCPEntryOwnership {
        let overriding = overrideEnvKeys.filter { env[$0] != nil }
        guard overriding.isEmpty else {
            return .foreign(reason: "env override: \(overriding.joined(separator: ", "))")
        }
        return .oursDefault
    }

    /// Positive shape check (Adams #2): does `entry` actually look like an
    /// entry this installer itself would write?
    ///
    /// - Command/stdio shape: `command`'s last path component is exactly
    ///   `"mootx01"` (matches either the bare binary name or the absolute
    ///   placed-binary path), AND `args` contains `"serve"` or `"proxy"` —
    ///   the only two stdio shapes the installer ever writes.
    /// - HTTP shape: `url` matches the loopback daemon endpoint exactly
    ///   (`isLoopbackDaemonURL`) — the ONLY port this installer's default
    ///   wiring ever writes. A loopback URL on a non-default port does NOT
    ///   match: it may point at a different, deliberately-scoped daemon
    ///   instance (the HTTP analogue of an env override), so it fails the
    ///   shape check and is reported rather than assumed identical.
    ///
    /// A malformed entry (e.g. `{}`), an entry with neither key, or a
    /// foreign command/URL under our key name all fail this check.
    private static func looksLikeOurs(_ entry: [String: Any]) -> Bool {
        if let url = entry["url"] as? String {
            return isLoopbackDaemonURL(url)
        }
        if let command = entry["command"] as? String,
           URL(fileURLWithPath: command).lastPathComponent == "mootx01",
           let args = entry["args"] as? [String],
           args.contains("serve") || args.contains("proxy") {
            return true
        }
        return false
    }

    /// True only for the exact loopback daemon endpoint this installer
    /// writes: `http://127.0.0.1:<defaultResidentPort>` or
    /// `http://localhost:<defaultResidentPort>`, with nothing else in the
    /// string (no path, query, userinfo, or trailing characters after the
    /// port digits).
    private static func isLoopbackDaemonURL(_ url: String) -> Bool {
        for host in ["127.0.0.1", "localhost"] {
            let prefix = "http://\(host):\(MootPaths.defaultResidentPort)"
            if url == prefix { return true }
        }
        return false
    }
}

/// Detects whether a Claude-Code-family plugin is installed, by reading the
/// user's own plugin registry. Read-only — never writes.
public enum PluginDetector {
    /// Codex keeps plugin enablement in config.toml and materializes marketplace
    /// packages under ~/.codex/plugins/cache/<marketplace>/<name>/<version>.
    /// Both signals are required before the installer lets the plugin own MCP.
    public static func isCodexPluginEnabled(pluginID: String, homeDirectory: URL) -> Bool {
        let config = homeDirectory.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        let acceptedHeaders = ["[plugins.\"\(pluginID)\"]", "[plugins.'\(pluginID)']"]
        var inTable = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inTable = acceptedHeaders.contains(trimmed)
                continue
            }
            guard inTable, !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equal].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if key == "enabled" { return value == "true" }
        }
        return false
    }

    public static func codexInstalledVersion(
        pluginID: String = "mootx01@mootx01", homeDirectory: URL
    ) -> String? {
        let parts = pluginID.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let root = homeDirectory
            .appendingPathComponent(".codex/plugins/cache", isDirectory: true)
            .appendingPathComponent(parts[1], isDirectory: true)
            .appendingPathComponent(parts[0], isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return nil }
        return versions.compactMap { directory -> String? in
            // Codex can install a shared marketplace whose historical source
            // exposes only the Claude discovery manifest. Prefer the native
            // Codex manifest, but recognize that installed legacy package so
            // upgrade-time ownership dedupe can converge it safely.
            for relative in [".codex-plugin/plugin.json", ".claude-plugin/plugin.json"] {
                let manifest = directory.appendingPathComponent(relative)
                guard let data = try? Data(contentsOf: manifest),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let version = object["version"] as? String { return version }
            }
            return nil
        }.sorted(by: versionGreaterThan).first
    }

    public static func ownsCodexConnection(
        pluginID: String, homeDirectory: URL
    ) -> Bool {
        isCodexPluginEnabled(pluginID: pluginID, homeDirectory: homeDirectory)
            && codexInstalledVersion(pluginID: pluginID, homeDirectory: homeDirectory) != nil
    }

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
        installedEntry(pluginID: pluginID, homeDirectory: homeDirectory) != nil
    }

    /// Returns `true` when `pluginID` is enabled in
    /// `~/.claude/settings.json`'s `enabledPlugins` map (Adams #5
    /// correction).
    ///
    /// Claude Code tracks installation and enablement SEPARATELY:
    /// `installed_plugins.json` records what is present; `settings.json`
    /// carries `"enabledPlugins": {"<id>": true/false, ...}` recording what
    /// is actually active. An installed-but-disabled plugin does NOT own
    /// the MCP connection — treating "installed" alone as "owns the
    /// connection" would make `mootx01 install` silently strip the
    /// client's only working direct entry out from under it, leaving no
    /// connection at all.
    ///
    /// Fails CLOSED toward "not enabled": an absent file, absent
    /// `enabledPlugins` key, absent entry for `pluginID`, or any decode
    /// failure all return `false` — the safer direction, since the caller
    /// uses this to decide whether to skip/remove the direct entry, and
    /// keeping a redundant direct entry is far less harmful than removing
    /// the client's only connection.
    ///
    /// - Parameter homeDirectory: user's home directory. Inject in tests —
    ///   SAFETY: never point this at the real `~/.claude` in a test.
    public static func isPluginEnabled(pluginID: String, homeDirectory: URL) -> Bool {
        let path = homeDirectory.appendingPathComponent(".claude/settings.json", isDirectory: false)
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = root["enabledPlugins"] as? [String: Any]
        else { return false }
        return (enabled[pluginID] as? Bool) == true
    }

    /// True when the plugin both HAS an installed entry and IS enabled —
    /// the combined condition that actually means "this plugin owns the
    /// MCP connection right now" (plugin-owned MCP connections, Adams #5 correction).
    /// Callers deciding whether to skip/remove a direct entry must use
    /// this, not `isPluginInstalled` alone.
    public static func ownsConnection(pluginID: String, homeDirectory: URL) -> Bool {
        isPluginInstalled(pluginID: pluginID, homeDirectory: homeDirectory)
            && isPluginEnabled(pluginID: pluginID, homeDirectory: homeDirectory)
    }

    /// Returns the installed plugin manifest version (e.g. `"1.0.15"`) from
    /// the first entry for `pluginID`, or `nil` when not installed. Used by
    /// the daemon's version-skew advisory to compare the
    /// plugin's declared version against the running binary's version.
    public static func installedVersion(pluginID: String, homeDirectory: URL) -> String? {
        installedEntry(pluginID: pluginID, homeDirectory: homeDirectory)?["version"] as? String
    }

    private static func installedEntry(pluginID: String, homeDirectory: URL) -> [String: Any]? {
        let path = homeDirectory
            .appendingPathComponent(".claude/plugins/installed_plugins.json", isDirectory: false)
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any],
              let entries = plugins[pluginID] as? [Any],
              let first = entries.first as? [String: Any]
        else { return nil }
        return first
    }

    private static func versionGreaterThan(_ a: String, _ b: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").map {
                Int($0.prefix(while: \.isNumber)) ?? 0
            }
        }
        let lhs = parts(a), rhs = parts(b)
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return a > b
    }
}

/// at daemon startup (and in `moot_estate_ping` /
/// `moot_estate_status`), when a plugin is detected, compare the plugin
/// manifest version against the binary version and report skew. Checking at
/// runtime (rather than only at install time) catches skew regardless of
/// install order — plugin-then-binary or binary-then-plugin both leave a
/// point-in-time version pinned in `installed_plugins.json` that can drift
/// from the binary as either side upgrades independently.
public enum VersionSkewAdvisory {
    /// Compute the advisory string for `pluginID`, or `nil` when the plugin
    /// is not installed or its version matches `binaryVersion` exactly (no
    /// skew to report). Deterministic and side-effect-free — the daemon
    /// computes this once at startup and threads it into `ToolDispatcher`.
    ///
    /// Direction-aware: the remedy depends on WHICH side is newer.
    /// - Binary newer than plugin: the plugin bundle needs refreshing
    ///   (`mootx01 install` rewrites it; `claude plugin update` also works).
    /// - Plugin newer than binary: the binary needs upgrading
    ///   (`mootx01 upgrade` fetches the latest release).
    public static func compute(
        pluginID: String, binaryVersion: String, homeDirectory: URL
    ) -> String? {
        guard let pluginVersion = PluginDetector.installedVersion(
            pluginID: pluginID, homeDirectory: homeDirectory
        ), pluginVersion != binaryVersion else { return nil }

        if versionGreaterThan(binaryVersion, pluginVersion) {
            // Binary is ahead of the plugin — the plugin bundle is stale.
            // `mootx01 install` rewrites the bundle to the current version;
            // `claude plugin update mootx01@mootx01` does the same via Claude Code.
            return "binary \(binaryVersion) is newer than plugin \(pluginVersion) — refresh the plugin with `mootx01 install` or `claude plugin update mootx01@mootx01`"
        } else {
            // Plugin is ahead of the binary — the binary needs upgrading.
            return "plugin \(pluginVersion) expects binary ≥ \(pluginVersion); binary is \(binaryVersion) — run `mootx01 upgrade`"
        }
    }

    /// Compare two semver strings numerically, component by component.
    ///
    /// Returns `true` when `a > b`. Splits on "." and compares each component
    /// as an integer so "1.0.10" > "1.0.9" (string comparison would disagree).
    /// Missing trailing components are treated as 0 (e.g. "1.2" == "1.2.0").
    /// Returns `false` on parse failure or equality.
    /// Parse the leading decimal digits of a version component, ignoring any
    /// trailing prerelease/build suffix (e.g. "15-rc1" → 15, "0+meta" → 0).
    /// Returns nil only when the component has no leading digit, so a fully
    /// non-numeric component is still dropped (and the empty-parts guard fires).
    /// Without this, `compactMap { Int($0) }` drops the WHOLE "15-rc1"
    /// component, collapsing "1.0.15-rc1" to [1, 0] and misordering it against
    /// "1.0.11" — the advisory would then recommend the wrong side.
    private static func leadingInt(_ s: some StringProtocol) -> Int? {
        let digits = s.prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func versionGreaterThan(_ a: String, _ b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Self.leadingInt($0) }
        let bParts = b.split(separator: ".").compactMap { Self.leadingInt($0) }
        guard !aParts.isEmpty, !bParts.isEmpty else { return false }
        let len = max(aParts.count, bParts.count)
        for i in 0..<len {
            let aVal = i < aParts.count ? aParts[i] : 0
            let bVal = i < bParts.count ? bParts[i] : 0
            if aVal != bVal { return aVal > bVal }
        }
        return false // equal
    }
}
